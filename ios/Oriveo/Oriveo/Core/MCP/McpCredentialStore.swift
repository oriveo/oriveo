import Foundation
import Security

// MARK: - Remote MCP credential storage
//
// Access tokens, refresh tokens, expiry, issuer, the `client_id` obtained through DCR and tokens pasted by the user
// all go through here; the DCR registration itself (keyed by `uid + issuer`, reused across servers) lives in the same
// medium. **None of this ever leaves the device or is written to a log.** Backed by a dedicated Keychain service
// (same approach as `ProviderAPIKeyStore`), outside iCloud Keychain.

nonisolated enum McpCredentialStoreError: Error, Equatable {
    /// Keychain write / delete failed (carries the `OSStatus`, never any credential content).
    case keychain(OSStatus)
    case encodingFailed
}

/// Credential storage backend. Production uses the Keychain; tests inject an in-memory implementation.
///
/// Key construction (`uid:serverId`), isolation by storage partition and cleanup on server removal all live in
/// `McpCredentialStore`, so tests still exercise the production path with only the medium swapped.
nonisolated protocol McpCredentialStorage: Sendable {
    func read(account: String) -> Data?
    /// A failed write must throw: callers rely on it to know whether the credential was actually stored, so it cannot
    /// be swallowed.
    func write(_ data: Data, account: String) throws
    /// A missing entry counts as success. A real deletion failure must throw: if it were swallowed, callers would
    /// believe the credential is gone while it is still on the device (removing a server and clearing a partition
    /// both depend on this).
    func delete(account: String) throws
    func accounts() -> [String]
}

/// Keychain backend. Dedicated service, outside iCloud Keychain.
nonisolated struct McpKeychainCredentialStorage: McpCredentialStorage {
    static let service = "ai.oriveo.community.mcp-credential"

    private let service: String

    init(service: String = McpKeychainCredentialStorage.service) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
    }

    func write(_ data: Data, account: String) throws {
        // `kSecAttrSynchronizable` is not set, so the entry stays out of iCloud Keychain; `ThisDeviceOnly`
        // additionally keeps it from being backed up or migrated to another device.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = baseQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            for (key, value) in attributes { addQuery[key] = value }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw McpCredentialStoreError.keychain(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw McpCredentialStoreError.keychain(status)
        }
    }

    func accounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// All MCP credentials for one server. **No field ever leaves the device or is written to a log.**
///
/// `description` / `debugDescription` are always redacted: when a credential type is printed through
/// `String(describing:)` or `String(reflecting:)` into a log, it must not leak secret values.
nonisolated struct McpCredentials: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// OAuth access token.
    var accessToken: String?
    /// OAuth refresh token.
    var refreshToken: String?
    /// Access token expiry.
    var expiresAt: Date?
    /// Issuer of the authorization server that issued these OAuth credentials. Client credentials are bound to the
    /// issuer and never reused across authorization servers.
    var issuer: String?
    /// CIMD document URL or the `client_id` obtained through DCR. Treated as a credential and redacted.
    var clientID: String?
    /// Canonical URI of the MCP server this credential may be sent to (RFC 8707). `resource` is mandatory when
    /// refreshing.
    var resource: String?
    /// Access token pasted by the user (the "access token" sign-in method).
    var pastedToken: String?

    init(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        issuer: String? = nil,
        clientID: String? = nil,
        resource: String? = nil,
        pastedToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.issuer = issuer
        self.clientID = clientID
        self.resource = resource
        self.pastedToken = pastedToken
    }

    var description: String { McpCredentials.redacted(self) }
    var debugDescription: String { description }

    /// Redacted description: reports which fields are present, never any secret value.
    static func redacted(_ credentials: McpCredentials) -> String {
        var fields: [String] = []
        if credentials.accessToken != nil { fields.append("accessToken=<redacted>") }
        if credentials.refreshToken != nil { fields.append("refreshToken=<redacted>") }
        if credentials.pastedToken != nil { fields.append("pastedToken=<redacted>") }
        if credentials.clientID != nil { fields.append("clientID=<redacted>") }
        if let expiresAt = credentials.expiresAt {
            // Not `Int(_:)`: the expiry comes from a server-provided lifetime, and an out-of-range conversion would
            // trap.
            fields.append("expiresAt=\(expiresAt.timeIntervalSince1970.rounded())")
        }
        if let issuer = credentials.issuer { fields.append("issuer=\(issuer)") }
        return "McpCredentials(\(fields.joined(separator: ", ")))"
    }
}

/// DCR registration cached on this device. Bound to the authorization server's `issuer` and never reused across
/// authorization servers; MCP servers behind the same authorization server share one registration instead of
/// registering again. **Stored on this device only.**
nonisolated struct McpStoredClientRegistration: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var clientID: String
    var issuer: String
    /// Redirect URIs reported to the authorization server at registration. After a release changes the redirect URI,
    /// the old registration can no longer be used.
    var redirectURIs: [String]

    var description: String { "McpStoredClientRegistration(issuer: \(issuer), clientID: <redacted>)" }
    var debugDescription: String { description }
}

/// MCP credential store. Key `uid:serverId`, where `uid` is the storage partition; removing a server deletes all
/// of its credentials.
nonisolated final class McpCredentialStore: Sendable {
    static let shared = McpCredentialStore()

    private let storage: any McpCredentialStorage

    init(storage: any McpCredentialStorage = McpKeychainCredentialStorage()) {
        self.storage = storage
    }

    /// Keychain account: `uid:serverId`. The `uid` prefix keeps the entries of each storage partition apart.
    static func account(serverId: UUID, uid: String) -> String {
        "\(uid):\(serverId.uuidString)"
    }

    /// Account for a DCR registration: `uid:dcr:issuer`. It also starts with `uid:`, so `deleteAll(for:)` clears it
    /// too; the `dcr:` middle segment is not a valid UUID, so it cannot collide with `uid:serverId`.
    static func registrationAccount(issuer: String, uid: String) -> String {
        "\(uid):dcr:\(issuer)"
    }

    /// Full address of a server whose URL looks like it embeds a secret (`localOnly`): `uid:endpoint:serverId`.
    /// Stored apart from the tokens: the authorizer rebuilds the whole `McpCredentials` when refreshing a token,
    /// which would wipe the address if they lived together. Also starts with `uid:` (cleared by `deleteAll(for:)`);
    /// the `endpoint:` middle segment is not a valid UUID, so it collides with no other key.
    static func endpointAccount(serverId: UUID, uid: String) -> String {
        "\(uid):endpoint:\(serverId.uuidString)"
    }

    /// Both encoding and write failures throw: if they were swallowed, callers would treat a token that was never
    /// stored as persisted.
    func save(_ credentials: McpCredentials, serverId: UUID, uid: String) throws {
        try write(credentials, account: Self.account(serverId: serverId, uid: uid))
    }

    func load(serverId: UUID, uid: String) -> McpCredentials? {
        guard let data = storage.read(account: Self.account(serverId: serverId, uid: uid)) else {
            return nil
        }
        return try? JSONDecoder().decode(McpCredentials.self, from: data)
    }

    /// Deletes all credentials of a server when it is removed. Throws when deletion fails: the caller then keeps the
    /// server record and tells the user, instead of silently leaving behind a credential nobody will ever clean up.
    ///
    /// The full address (`localOnly`) is deleted too: it is also a credential of this server.
    func delete(serverId: UUID, uid: String) throws {
        try storage.delete(account: Self.account(serverId: serverId, uid: uid))
        try storage.delete(account: Self.endpointAccount(serverId: serverId, uid: uid))
    }

    // MARK: Full address (localOnly)

    /// Throws on write failure: the caller uses it to decide whether this server is still usable (without the full
    /// address no request can be sent).
    func saveEndpoint(_ url: String, serverId: UUID, uid: String) throws {
        try storage.write(Data(url.utf8), account: Self.endpointAccount(serverId: serverId, uid: uid))
    }

    func loadEndpoint(serverId: UUID, uid: String) -> String? {
        storage.read(account: Self.endpointAccount(serverId: serverId, uid: uid))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: DCR registration

    func saveClientRegistration(_ registration: McpStoredClientRegistration, uid: String) throws {
        try write(registration, account: Self.registrationAccount(issuer: registration.issuer, uid: uid))
    }

    func loadClientRegistration(issuer: String, uid: String) -> McpStoredClientRegistration? {
        guard let data = storage.read(account: Self.registrationAccount(issuer: issuer, uid: uid)),
              let registration = try? JSONDecoder().decode(McpStoredClientRegistration.self, from: data),
              // Bound to the issuer: a stored entry for a different issuer is not accepted.
              registration.issuer == issuer else {
            return nil
        }
        return registration
    }

    /// Clears a registration the authorization server declared invalid. Does not throw when deletion fails: a
    /// registration is not a token, and keeping it only means the next sign-in is rejected once more and cleared
    /// again; real tokens go through `delete(serverId:uid:)`, which does throw.
    func deleteClientRegistration(issuer: String, uid: String) {
        try? storage.delete(account: Self.registrationAccount(issuer: issuer, uid: uid))
    }

    private func write<Value: Encodable>(_ value: Value, account: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw McpCredentialStoreError.encodingFailed
        }
        try storage.write(data, account: account)
    }

    /// Clears all MCP credentials and DCR registrations of one `uid` (used when a storage partition is cleared).
    /// Entries of other `uid`s are unaffected. Every entry is attempted; if any cannot be deleted, the
    /// first error is thrown at the end, so one failure does not leave all the following entries behind.
    func deleteAll(for uid: String) throws {
        let prefix = "\(uid):"
        var firstError: Error?
        for account in storage.accounts() where account.hasPrefix(prefix) {
            do {
                try storage.delete(account: account)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
