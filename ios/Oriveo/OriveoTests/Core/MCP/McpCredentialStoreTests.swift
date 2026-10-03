import Foundation
import Security
import Testing
@testable import Oriveo

// MARK: - MCP credential storage

/// In-memory credential backend. The semantics (key construction, isolation by storage partition, deletion) all
/// live in the production type `McpCredentialStore`; only the storage medium is swapped here, no logic is
/// reimplemented.
final class InMemoryMcpCredentialStorage: McpCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var writesFail = false
    private var deletesFail = false

    /// When true every write fails (simulates the Keychain refusing writes).
    var failWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return writesFail }
        set { lock.lock(); writesFail = newValue; lock.unlock() }
    }

    func read(account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if writesFail { throw McpCredentialStoreError.keychain(errSecInteractionNotAllowed) }
        items[account] = data
    }

    /// When true every delete fails (simulates the Keychain refusing deletes).
    var failDeletes: Bool {
        get { lock.lock(); defer { lock.unlock() }; return deletesFail }
        set { lock.lock(); deletesFail = newValue; lock.unlock() }
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if deletesFail { throw McpCredentialStoreError.keychain(errSecInteractionNotAllowed) }
        items[account] = nil
    }

    func accounts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.keys)
    }
}

@Suite("MCP credential storage")
struct McpCredentialStoreTests {
    private func makeStore() -> (McpCredentialStore, InMemoryMcpCredentialStorage) {
        let storage = InMemoryMcpCredentialStorage()
        return (McpCredentialStore(storage: storage), storage)
    }

    private let serverId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test("The Keychain account is uid:serverId, where uid is the storage partition")
    func accountFormat() {
        #expect(McpCredentialStore.account(serverId: serverId, uid: "part-a")
            == "part-a:11111111-2222-3333-4444-555555555555")
    }

    @Test("Round trip: access token, refresh token, expiry, issuer, client_id, pasted token")
    func roundTrip() throws {
        let (store, _) = makeStore()
        let credentials = McpCredentials(
            accessToken: "mcp_at_example",
            refreshToken: "mcp_rt_example",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            issuer: "https://auth.example.com",
            clientID: "oriveo_mcp_2f9c41",
            resource: "https://mcp.example.com/mcp",
            pastedToken: nil
        )
        try store.save(credentials, serverId: serverId, uid: "part-a")
        let loaded = try #require(store.load(serverId: serverId, uid: "part-a"))
        #expect(loaded == credentials)
    }

    @Test("A failed write must throw instead of silently counting as saved")
    func saveThrowsWhenStorageFails() throws {
        let (store, storage) = makeStore()
        storage.failWrites = true
        #expect(throws: McpCredentialStoreError.keychain(errSecInteractionNotAllowed)) {
            try store.save(McpCredentials(accessToken: "token-a"), serverId: serverId, uid: "part-a")
        }
        #expect(throws: McpCredentialStoreError.keychain(errSecInteractionNotAllowed)) {
            try store.saveClientRegistration(
                McpStoredClientRegistration(clientID: "c", issuer: "https://auth.example.com", redirectURIs: []),
                uid: "part-a"
            )
        }
        #expect(store.load(serverId: serverId, uid: "part-a") == nil)
        #expect(storage.accounts().isEmpty)

        // The failure leaves nothing behind: writes work again once storage recovers.
        storage.failWrites = false
        try store.save(McpCredentials(accessToken: "token-a"), serverId: serverId, uid: "part-a")
        #expect(store.load(serverId: serverId, uid: "part-a")?.accessToken == "token-a")
    }

    @Test("Describing a credential with an absurd expiry does not crash on rounding overflow")
    func descriptionSurvivesHugeExpiry() {
        let credentials = McpCredentials(accessToken: "a", expiresAt: Date(timeIntervalSince1970: 1e30))
        #expect(String(describing: credentials).contains("expiresAt="))
    }

    // MARK: DCR registration

    @Test("DCR registration: stored by partition + issuer; bound to the issuer, isolated by partition; not deleted along with a server")
    func clientRegistrationRoundTrip() throws {
        let (store, storage) = makeStore()
        let issuer = "https://auth.example.com"
        let registration = McpStoredClientRegistration(
            clientID: "oriveo_mcp_2f9c41", issuer: issuer, redirectURIs: McpClientMetadata.redirectURIs
        )
        try store.saveClientRegistration(registration, uid: "part-a")
        try store.save(McpCredentials(accessToken: "token-a"), serverId: serverId, uid: "part-a")

        #expect(McpCredentialStore.registrationAccount(issuer: issuer, uid: "part-a") == "part-a:dcr:https://auth.example.com")
        #expect(Set(storage.accounts()) == ["part-a:dcr:https://auth.example.com", "part-a:11111111-2222-3333-4444-555555555555"])
        #expect(store.loadClientRegistration(issuer: issuer, uid: "part-a") == registration)
        #expect(store.loadClientRegistration(issuer: "https://other.example.com", uid: "part-a") == nil)
        #expect(store.loadClientRegistration(issuer: issuer, uid: "part-b") == nil)

        // Removing a server leaves the registration alone: other servers behind the same authorization server still need it.
        try store.delete(serverId: serverId, uid: "part-a")
        #expect(store.loadClientRegistration(issuer: issuer, uid: "part-a") == registration)

        store.deleteClientRegistration(issuer: issuer, uid: "part-a")
        #expect(store.loadClientRegistration(issuer: issuer, uid: "part-a") == nil)
    }

    @Test("Clearing a storage partition: deleteAll also removes DCR registrations and leaves other partitions untouched")
    func deleteAllRemovesRegistrations() throws {
        let (store, storage) = makeStore()
        let issuer = "https://auth.example.com"
        for uid in ["part-a", "part-b"] {
            try store.saveClientRegistration(
                McpStoredClientRegistration(clientID: "client-\(uid)", issuer: issuer, redirectURIs: []), uid: uid
            )
            try store.save(McpCredentials(accessToken: "token-\(uid)"), serverId: serverId, uid: uid)
        }
        try store.deleteAll(for: "part-a")
        #expect(storage.accounts().allSatisfy { $0.hasPrefix("part-b:") })
        #expect(storage.accounts().count == 2)
        #expect(store.loadClientRegistration(issuer: issuer, uid: "part-b")?.clientID == "client-part-b")
    }

    @Test("The description of a stored DCR registration does not contain the client_id")
    func storedRegistrationDescriptionIsRedacted() throws {
        let (store, _) = makeStore()
        try store.saveClientRegistration(
            McpStoredClientRegistration(clientID: "oriveo_mcp_2f9c41", issuer: "https://auth.example.com", redirectURIs: []),
            uid: "part-a"
        )
        let produced = try #require(store.loadClientRegistration(issuer: "https://auth.example.com", uid: "part-a"))
        #expect(produced.clientID == "oriveo_mcp_2f9c41")
        for text in [String(describing: produced), String(reflecting: produced)] {
            #expect(!text.contains("oriveo_mcp_2f9c41"))
            #expect(text.contains("https://auth.example.com"))
        }
    }

    @Test("Credentials are isolated by storage partition: another partition cannot read them and clearing one does not affect another")
    func partitionIsolation() throws {
        let (store, _) = makeStore()
        let a = McpCredentials(accessToken: "token-a", issuer: "https://auth.example.com")
        let b = McpCredentials(accessToken: "token-b", issuer: "https://auth.example.com")
        try store.save(a, serverId: serverId, uid: "part-a")
        try store.save(b, serverId: serverId, uid: "part-b")

        #expect(store.load(serverId: serverId, uid: "part-a")?.accessToken == "token-a")
        #expect(store.load(serverId: serverId, uid: "part-b")?.accessToken == "token-b")

        try store.deleteAll(for: "part-a")
        #expect(store.load(serverId: serverId, uid: "part-a") == nil)
        #expect(store.load(serverId: serverId, uid: "part-b")?.accessToken == "token-b")
    }

    @Test("Removing a server deletes all of its credentials")
    func deleteRemovesServerCredentials() throws {
        let (store, _) = makeStore()
        try store.save(McpCredentials(accessToken: "token-a"), serverId: serverId, uid: "part-a")
        #expect(store.load(serverId: serverId, uid: "part-a") != nil)
        try store.delete(serverId: serverId, uid: "part-a")
        #expect(store.load(serverId: serverId, uid: "part-a") == nil)
    }

    @Test("A credential that cannot be deleted throws and stays in place, so callers never treat it as deleted")
    func deleteFailureIsReported() throws {
        let (store, storage) = makeStore()
        try store.save(McpCredentials(accessToken: "token-a"), serverId: serverId, uid: "part-a")
        storage.failDeletes = true

        #expect(throws: McpCredentialStoreError.keychain(errSecInteractionNotAllowed)) {
            try store.delete(serverId: serverId, uid: "part-a")
        }
        #expect(store.load(serverId: serverId, uid: "part-a")?.accessToken == "token-a")
        #expect(throws: McpCredentialStoreError.keychain(errSecInteractionNotAllowed)) {
            try store.deleteAll(for: "part-a")
        }

        storage.failDeletes = false
        try store.delete(serverId: serverId, uid: "part-a")
        #expect(store.load(serverId: serverId, uid: "part-a") == nil)
    }

    @Test("Deleting a credential that does not exist succeeds")
    func deletingAbsentCredentialsSucceeds() throws {
        let (store, storage) = makeStore()
        try store.delete(serverId: serverId, uid: "part-a")
        try store.deleteAll(for: "part-a")
        #expect(storage.accounts().isEmpty)
    }

    // MARK: Redaction

    @Test("The credential types redact their own string descriptions (kept out of logs)")
    func credentialsDescriptionIsRedacted() throws {
        let (store, _) = makeStore()
        let credentials = McpCredentials(
            accessToken: "mcp_at_example",
            refreshToken: "mcp_rt_example",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            issuer: "https://auth.example.com",
            clientID: "oriveo_mcp_2f9c41",
            resource: "https://mcp.example.com/mcp",
            pastedToken: "pasted_token_value"
        )
        try store.save(credentials, serverId: serverId, uid: "part-a")
        // Assert on an object the production code path actually produced (the copy read back by store.load).
        let produced = try #require(store.load(serverId: serverId, uid: "part-a"))
        let description = String(describing: produced)
        let reflecting = String(reflecting: produced)
        for secret in ["mcp_at_example", "mcp_rt_example", "oriveo_mcp_2f9c41", "pasted_token_value"] {
            #expect(!description.contains(secret))
            #expect(!reflecting.contains(secret))
        }
        #expect(description.contains("accessToken=<redacted>"))
        #expect(description.contains("refreshToken=<redacted>"))
        #expect(description.contains("clientID=<redacted>"))
        // Non-secret fields stay readable for troubleshooting.
        #expect(description.contains("https://auth.example.com"))
    }
}
