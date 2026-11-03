import Foundation
import Security

nonisolated struct AppSessionSnapshot: Codable {
    var selectedTab: AppTab
    var hasCompletedOnboarding: Bool
    var providers: [Provider]
    var conversations: [Conversation]?
    var lastUsedModelRef: LastUsedModelRef?
    var folders: [Folder]?

    private enum CodingKeys: String, CodingKey {
        case selectedTab, hasCompletedOnboarding, providers, conversations
        case lastUsedModelRef, folders
    }

    init(
        selectedTab: AppTab,
        hasCompletedOnboarding: Bool,
        providers: [Provider],
        conversations: [Conversation]? = nil,
        lastUsedModelRef: LastUsedModelRef?,
        folders: [Folder]? = nil
    ) {
        self.selectedTab = selectedTab
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.providers = providers
        self.conversations = conversations
        self.lastUsedModelRef = lastUsedModelRef
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedTab = try container.decode(AppTab.self, forKey: .selectedTab)
        hasCompletedOnboarding = try container.decode(Bool.self, forKey: .hasCompletedOnboarding)
        providers = try container.decode([Provider].self, forKey: .providers)
        conversations = try container.decodeIfPresent([Conversation].self, forKey: .conversations)
        lastUsedModelRef = try container.decodeIfPresent(LastUsedModelRef.self, forKey: .lastUsedModelRef)
        folders = try container.decodeIfPresent([Folder].self, forKey: .folders)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedTab, forKey: .selectedTab)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encode(providers, forKey: .providers)
        try container.encodeIfPresent(lastUsedModelRef, forKey: .lastUsedModelRef)
        try container.encodeIfPresent(folders, forKey: .folders)
    }

    func hydratingProviderAPIKeys(for uid: String) -> AppSessionSnapshot {
        var hydrated = self
        hydrated.providers = providers.map { provider in
            var copy = provider
            if let storedKey = ProviderAPIKeyStore.load(providerID: provider.id, uid: uid), !storedKey.isEmpty {
                copy.apiKey = storedKey
            } else if !provider.apiKey.isEmpty {
                ProviderAPIKeyStore.save(apiKey: provider.apiKey, providerID: provider.id, uid: uid)
            }
            copy.relayKeys = provider.relayKeys.map { keys in
                keys.enumerated().map { index, key in
                    var entry = key
                    guard index > 0 else {
                        // The primary key's value lives only in provider.apiKey.
                        entry.apiKey = ""
                        return entry
                    }
                    if let stored = ProviderAPIKeyStore.loadRelayKey(keyID: key.id, providerID: provider.id, uid: uid),
                       !stored.isEmpty {
                        entry.apiKey = stored
                    } else if !key.apiKey.isEmpty {
                        ProviderAPIKeyStore.persistRelayKey(apiKey: key.apiKey, keyID: key.id, providerID: provider.id, uid: uid)
                    }
                    return entry
                }
            }
            return copy
        }
        return hydrated
    }

    func persistingProviderAPIKeys(for uid: String) -> AppSessionSnapshot {
        var persisted = self
        let providerIDs = Set(providers.map(\.id))
        persisted.providers = providers.map { provider in
            var copy = provider
            if !copy.apiKey.isEmpty {
                ProviderAPIKeyStore.persistUnchanged(
                    apiKey: copy.apiKey,
                    providerID: copy.id,
                    uid: uid
                )
            }
            copy.apiKey = ""
            // Non-primary keys are kept like apiKey: the value goes to the Keychain (account `uid:providerUUID#keyID`) and the snapshot stores an empty string.
            copy.relayKeys = provider.relayKeys.map { keys in
                keys.enumerated().map { index, key in
                    if index > 0, !key.apiKey.isEmpty {
                        ProviderAPIKeyStore.persistRelayKey(apiKey: key.apiKey, keyID: key.id, providerID: provider.id, uid: uid)
                    }
                    return key.withoutSecret
                }
            }
            return copy
        }
        let relayKeyIDs = Dictionary(providers.map { provider in
            (provider.id, Set((provider.relayKeys ?? []).dropFirst().map(\.id)))
        }, uniquingKeysWith: { $0.union($1) })
        ProviderAPIKeyStore.deleteAllExcept(providerIDs: providerIDs, relayKeyIDs: relayKeyIDs, uid: uid)
        return persisted
    }
}

enum ProviderAPIKeyStore {
    private static let service = "ai.oriveo.community.provider-api-key"

    /// An unsigned test host cannot reach the Keychain: once testing is turned on, the four access primitives use an in-memory table, and the rest of the logic runs through the production path.
    private nonisolated static let testingBackendLock = NSLock()
    nonisolated(unsafe) private static var testingBackend: [String: String]?

    static func useInMemoryBackendForTesting(_ enabled: Bool) {
        testingBackendLock.withLock { testingBackend = enabled ? [:] : nil }
    }

    private static func withTestingBackend<T>(_ body: (inout [String: String]) -> T) -> T? {
        testingBackendLock.withLock {
            guard var backend = testingBackend else { return nil }
            let result = body(&backend)
            testingBackend = backend
            return result
        }
    }

    private static func account(providerID: UUID, uid: String) -> String {
        "\(uid):\(providerID.uuidString)"
    }

    /// Non-primary relay keys: the primary key's account plus `#<keyID>`.
    private static func relayKeyAccount(keyID: String, providerID: UUID, uid: String) -> String {
        "\(account(providerID: providerID, uid: uid))#\(keyID)"
    }

    static func save(apiKey: String, providerID: UUID, uid: String) {
        guard !apiKey.isEmpty else { return }
        write(apiKey: apiKey, providerID: providerID, uid: uid)
        ProviderCapabilityIdentityStore.advanceCredentialEpoch(providerID: providerID, partitionID: uid)
    }

    static func persistUnchanged(apiKey: String, providerID: UUID, uid: String) {
        write(apiKey: apiKey, providerID: providerID, uid: uid)
    }

    private static func write(apiKey: String, providerID: UUID, uid: String) {
        write(apiKey: apiKey, account: account(providerID: providerID, uid: uid))
    }

    /// A non-primary key only carries a value that is already in use, so it does not advance the credential epoch (the capability negative cache has no key dimension).
    static func persistRelayKey(apiKey: String, keyID: String, providerID: UUID, uid: String) {
        guard !apiKey.isEmpty else { return }
        write(apiKey: apiKey, account: relayKeyAccount(keyID: keyID, providerID: providerID, uid: uid))
    }

    static func loadRelayKey(keyID: String, providerID: UUID, uid: String) -> String? {
        load(account: relayKeyAccount(keyID: keyID, providerID: providerID, uid: uid))
    }

    private static func deleteAccount(_ account: String) {
        if withTestingBackend({ $0[account] = nil }) != nil { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func write(apiKey: String, account: String) {
        if withTestingBackend({ $0[account] = apiKey }) != nil { return }
        guard let data = apiKey.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func load(providerID: UUID, uid: String) -> String? {
        load(account: account(providerID: providerID, uid: uid))
    }

    private static func load(account: String) -> String? {
        if let stored = withTestingBackend({ $0[account] }) { return stored }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete(providerID: UUID, uid: String) {
        deleteAccount(account(providerID: providerID, uid: uid))
        // Non-primary relay keys live under `#keyID` accounts of the same service; remove them with the connection.
        deleteRelayKeys(providerID: providerID, uid: uid)
        GrokSubscriptionCredentialStore.delete(providerID: providerID, uid: uid)
        OpenAISubscriptionCredentialStore.delete(providerID: providerID, uid: uid)
        ProviderCapabilityIdentityStore.advanceCredentialEpoch(providerID: providerID, partitionID: uid)
    }

    static func deleteAll(for uid: String) {
        deleteAllExcept(providerIDs: Set<UUID>(), relayKeyIDs: [:], uid: uid)
    }

    /// - relayKeyIDs: the non-primary key ids still in the list for each retained connection; `#keyID` accounts not among them are deleted.
    static func deleteAllExcept(providerIDs: Set<UUID>, relayKeyIDs: [UUID: Set<String>], uid: String) {
        let prefix = "\(uid):"
        for account in accounts(withPrefix: prefix) {
            let rawID = String(account.dropFirst(prefix.count))
            if let separator = rawID.firstIndex(of: "#") {
                guard let providerID = UUID(uuidString: String(rawID[..<separator])) else { continue }
                let keyID = String(rawID[rawID.index(after: separator)...])
                if !providerIDs.contains(providerID) || relayKeyIDs[providerID]?.contains(keyID) != true {
                    deleteAccount(account)
                }
                continue
            }
            guard let providerID = UUID(uuidString: rawID), !providerIDs.contains(providerID) else {
                continue
            }
            delete(providerID: providerID, uid: uid)
        }
    }

    private static func deleteRelayKeys(providerID: UUID, uid: String) {
        for account in accounts(withPrefix: "\(account(providerID: providerID, uid: uid))#") {
            deleteAccount(account)
        }
    }

    private static func accounts(withPrefix prefix: String) -> [String] {
        if let stored = withTestingBackend({ Array($0.keys) }) { return stored.filter { $0.hasPrefix(prefix) } }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }
}

nonisolated enum GrokSubscriptionCredentialStore {
    private static let service = "ai.oriveo.community.provider-subscription-token"

    private static func account(providerID: UUID, uid: String) -> String {
        "\(uid):\(providerID.uuidString)"
    }

    static func save(_ tokens: GrokSubscriptionTokens, providerID: UUID, uid: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, uid: uid)
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func load(providerID: UUID, uid: String) -> GrokSubscriptionTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, uid: uid),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let tokens = try? JSONDecoder().decode(GrokSubscriptionTokens.self, from: data)
        else { return nil }
        return tokens
    }

    static func delete(providerID: UUID, uid: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, uid: uid)
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

nonisolated enum OpenAISubscriptionCredentialStore {
    private static let service = "ai.oriveo.community.provider-subscription-token-openai"

    private static func account(providerID: UUID, uid: String) -> String {
        "\(uid):\(providerID.uuidString)"
    }

    static func save(_ tokens: OpenAISubscriptionTokens, providerID: UUID, uid: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, uid: uid)
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func load(providerID: UUID, uid: String) -> OpenAISubscriptionTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, uid: uid),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let tokens = try? JSONDecoder().decode(OpenAISubscriptionTokens.self, from: data)
        else { return nil }
        return tokens
    }

    static func delete(providerID: UUID, uid: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, uid: uid)
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

/// Removing a partition directory while its uid still has a database connection open: deleting files under a live
/// SQLite connection risks disk I/O errors and a resurrected partition. Reported once per uid, not once per process.
@MainActor
enum PartitionRemovalDiagnostics {
    /// Tests swap in a recording sink.
    static var sink: ObservabilitySink = Observability.sink
    private static var reportedUIDs = Set<String>()

    static func reportOpenConnections(uid: String) {
        guard reportedUIDs.insert(uid).inserted else { return }
        let issue = DiagnosticIssue.databasePartitionRemovedWhileOpen
        let tags = ["db.partition": uid == "guest" ? "guest" : "account"]
        sink.issue(name: issue.rawValue, level: issue.level, fingerprint: issue.fingerprint(tags: tags), context: tags)
    }

    #if DEBUG
    static func hasReportedForTesting(uid: String) -> Bool {
        reportedUIDs.contains(uid)
    }
    #endif
}

// MARK: - Partition-aware session storage

nonisolated enum AppSessionStore {
    private static let legacyKey = "oriveo.session.snapshot"
    private static let fileName = "session-snapshot.json"
    private static let backupFileName = "session-snapshot.backup-pre-grdb.json"
    private static let migratedKey = "oriveo.storage.partitioned"


    /// Path only, no directory creation: the cold-start read path must not touch disk. Each writer calls `createDirectory(withIntermediateDirectories:)` itself.
    static let baseDir: URL = baseDir(
        under: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )

    static func baseDir(under root: URL) -> URL {
        root.appendingPathComponent("Oriveo", isDirectory: true)
    }


    private static let activeUIDLock = NSLock()
    /// Chat cells read this on every configure, and several screens use it as a `.task(id:)` key in
    /// their body (over a hundred call sites). Opening the file on each read is pure waste: only the
    /// setter below writes it, so caching the value in process is enough.
    nonisolated(unsafe) private static var cachedActiveUID: String?
    /// UserDefaults mirror of the active-uid file: a cold-start read does not touch disk. The file stays the source of truth; the setter writes both.
    /// After an upgrade the first launch finds the mirror empty, reads the file once, and backfills.
    static let activeUIDMirrorKey = "oriveo.session.activeUID.mirror"
    /// The CFBundleVersion when the mirror was written. A different build (or a missing one) means an older build may have written only the file in between,
    /// so the mirror is not trusted; the first launch after an upgrade reads the file once and backfills.
    static let activeUIDMirrorBuildKey = "oriveo.session.activeUID.mirror.build"
    private static let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    #if DEBUG
    nonisolated(unsafe) private static var debugActiveUIDDiskReadStorage = 0

    /// DEBUG only: how many times the active-uid file was actually read from disk.
    static var debugActiveUIDDiskReadCount: Int {
        activeUIDLock.lock()
        defer { activeUIDLock.unlock() }
        return debugActiveUIDDiskReadStorage
    }

    /// Drops only the in-process cache, the way an app relaunch reads the file again.
    static func dropActiveUIDCacheForTesting() {
        activeUIDLock.lock()
        defer { activeUIDLock.unlock() }
        cachedActiveUID = nil
    }

    nonisolated(unsafe) private static var debugPartitionOverrideStorage: String?

    /// DEBUG only: switches the whole process to a demo partition (store-screenshot seed).
    /// While set, the `activeUID` getter returns it and the setter no longer writes the active-uid file; the real partition and file are left untouched.
    static var debugPartitionOverride: String? {
        get {
            activeUIDLock.lock()
            defer { activeUIDLock.unlock() }
            return debugPartitionOverrideStorage
        }
        set {
            activeUIDLock.lock()
            defer { activeUIDLock.unlock() }
            debugPartitionOverrideStorage = newValue
        }
    }
    #endif

    static var activeUID: String {
        get {
            activeUIDLock.lock()
            defer { activeUIDLock.unlock() }
            if let cachedActiveUID { return cachedActiveUID }
            if let mirrored = trustedMirrorLocked() {
                let resolved = normalizedActiveUID(mirrored)
                cachedActiveUID = resolved
                return resolved
            }
            return readActiveUIDFileLocked()
        }
        set {
            activeUIDLock.lock()
            defer { activeUIDLock.unlock() }
            let file = baseDir.appendingPathComponent("active-uid")
            do {
                try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
                try newValue.write(to: file, atomically: true, encoding: .utf8)
                let resolved = normalizedActiveUID(newValue)
                cachedActiveUID = resolved
                writeMirrorLocked(resolved)
            } catch {
                // The file still holds the previous value, so the next read goes back to disk,
                // exactly as it would without a cache.
                cachedActiveUID = nil
                UserDefaults.standard.removeObject(forKey: activeUIDMirrorKey)
                UserDefaults.standard.removeObject(forKey: activeUIDMirrorBuildKey)
            }
        }
    }

    /// For a cold start without a Firebase sign-in: when the mirror points to an account (not guest), neither the mirror nor the cache is trusted; read the file once and backfill.
    /// If sign-out wrote the file but the mirror was not flushed before a power loss, the mirror still names the old account, and trusting it would load another account's partition.
    /// When the mirror is guest or untrusted, use the same rule as `activeUID`; a normal cold start does not read disk.
    static func activeUIDDistrustingMirror() -> String {
        activeUIDLock.lock()
        defer { activeUIDLock.unlock() }
        #if DEBUG
        if let debugPartitionOverrideStorage { return debugPartitionOverrideStorage }
        #endif
        guard let mirrored = trustedMirrorLocked() else { return readActiveUIDFileLocked() }
        let resolved = normalizedActiveUID(mirrored)
        guard resolved != "guest" else {
            cachedActiveUID = resolved
            return resolved
        }
        return readActiveUIDFileLocked()
    }

    /// Requires `activeUIDLock`. A mirror whose build differs from the current one (or is missing) is treated as untrusted.
    private static func trustedMirrorLocked() -> String? {
        let defaults = UserDefaults.standard
        guard let mirrored = defaults.string(forKey: activeUIDMirrorKey),
              defaults.string(forKey: activeUIDMirrorBuildKey) == currentBuild else { return nil }
        return mirrored
    }

    /// Requires `activeUIDLock`. Reads the active-uid file once, caches the value, and backfills the mirror.
    private static func readActiveUIDFileLocked() -> String {
        #if DEBUG
        debugActiveUIDDiskReadStorage += 1
        #endif
        let file = baseDir.appendingPathComponent("active-uid")
        let raw = try? String(contentsOf: file, encoding: .utf8)
        let resolved = normalizedActiveUID(raw)
        cachedActiveUID = resolved
        writeMirrorLocked(resolved)
        return resolved
    }

    /// Requires `activeUIDLock`.
    private static func writeMirrorLocked(_ uid: String) {
        UserDefaults.standard.set(uid, forKey: activeUIDMirrorKey)
        UserDefaults.standard.set(currentBuild, forKey: activeUIDMirrorBuildKey)
    }

    private static func normalizedActiveUID(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "guest" : trimmed
    }


    static func userDir(for uid: String) -> URL {
        baseDir.appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(uid, isDirectory: true)
    }

    static var currentUserDir: URL { userDir(for: activeUID) }

    static var snapshotPath: URL {
        currentUserDir.appendingPathComponent(fileName)
    }

    static func snapshotPath(for uid: String) -> URL {
        userDir(for: uid).appendingPathComponent(fileName)
    }

    static func backupSnapshotPath(for uid: String) -> URL {
        userDir(for: uid).appendingPathComponent(backupFileName)
    }

    static func recoverySnapshotPath(for uid: String) -> URL {
        userDir(for: uid).appendingPathComponent(LegacyConversationRecoverySnapshot.fileName)
    }

    static var databasePath: URL {
        databasePath(for: activeUID)
    }

    static func databasePath(for uid: String) -> URL {
        userDir(for: uid).appendingPathComponent(DatabaseSchema.fileName)
    }

    static var imagesDir: URL {
        imagesDir(for: activeUID)
    }

    static func imagesDir(for uid: String) -> URL {
        userDir(for: uid).appendingPathComponent("Images", isDirectory: true)
    }

    static var filesDir: URL {
        currentUserDir.appendingPathComponent("Files", isDirectory: true)
    }

    static func filesDir(for uid: String) -> URL {
        userDir(for: uid).appendingPathComponent("Files", isDirectory: true)
    }


    static func switchToUser(_ uid: String) {
        let dir = userDir(for: uid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Images", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Files", isDirectory: true),
            withIntermediateDirectories: true
        )
        activeUID = uid
    }

    /// Whether the given user partition has data.
    static func hasData(for uid: String) -> Bool {
        let snapshot = snapshotPath(for: uid)
        if FileManager.default.fileExists(atPath: snapshot.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: snapshot.path),
           let size = attrs[.size] as? UInt64,
           size > 2 {
            return true
        }

        let database = databasePath(for: uid)
        if FileManager.default.fileExists(atPath: database.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: database.path),
           let size = attrs[.size] as? UInt64,
           size > 0 {
            return true
        }

        return false
    }

    /// Whether the guest partition has valid data (non-empty providers or conversations).
    static func guestHasSignificantData() -> Bool {
        let saved = activeUID
        defer { if activeUID != saved { activeUID = saved } }

        let guestSnapshot = userDir(for: "guest").appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: guestSnapshot) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(AppSessionSnapshot.self, from: data) else { return false }
        return !snapshot.providers.isEmpty || !(snapshot.conversations ?? []).isEmpty
    }

    /// Moves the guest partition to the given user's partition (silent adoption).
    static func adoptGuestData(to uid: String) {
        let guestDir = userDir(for: "guest")
        let targetDir = userDir(for: uid)

        // Remove an existing target first (an empty shell directory) so moveItem succeeds.
        if FileManager.default.fileExists(atPath: targetDir.path) {
            try? FileManager.default.removeItem(at: targetDir)
        }

        do {
            try FileManager.default.moveItem(at: guestDir, to: targetDir)
        } catch {
            #if DEBUG
            print("[Partition] adoptGuestData failed: \(error)")
            #endif
        }

        // Recreate the empty guest directory.
        try? FileManager.default.createDirectory(at: guestDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: guestDir.appendingPathComponent("Images", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: guestDir.appendingPathComponent("Files", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// Copies the guest partition's images to the given user's partition (keeps the guest originals as a safety net).
    static func copyGuestImages(to uid: String) {
        let guestImages = userDir(for: "guest").appendingPathComponent("Images", isDirectory: true)
        let targetImages = userDir(for: uid).appendingPathComponent("Images", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: guestImages.path) else { return }
        for file in files {
            let src = guestImages.appendingPathComponent(file)
            let dst = targetImages.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
    }

    /// Records `PartitionRemovalDiagnostics` when `uid` still has a database connection open right before its
    /// directory is removed; the removal itself goes ahead either way. Returns whether a connection was open.
    @discardableResult
    static func reportIfConnectionsStillOpen(uid: String) -> Bool {
        guard DatabaseManager.shared.hasOpenConnections(uid: uid) else { return false }
        if Thread.isMainThread {
            MainActor.assumeIsolated { PartitionRemovalDiagnostics.reportOpenConnections(uid: uid) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PartitionRemovalDiagnostics.reportOpenConnections(uid: uid) }
            }
        }
        return true
    }

    /// Clears the given user's partition.
    static func clearPartition(for uid: String) {
        reportIfConnectionsStillOpen(uid: uid)
        let dir = userDir(for: uid)
        try? FileManager.default.removeItem(at: dir)
        ProviderAPIKeyStore.deleteAll(for: uid)
        // The partition's MCP server records went with its database file; their tokens and client
        // registrations live in the Keychain, outside the partition directory, and have to go too.
        try? McpCredentialStore.shared.deleteAll(for: uid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Images", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Files", isDirectory: true),
            withIntermediateDirectories: true
        )
    }


    static func load() -> AppSessionSnapshot? {
        load(for: activeUID)
    }

    static func load(for uid: String) -> AppSessionSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let url = snapshotPath(for: uid)
        if let data = try? Data(contentsOf: url),
           let snapshot = try? decoder.decode(AppSessionSnapshot.self, from: data) {
            return snapshot.hydratingProviderAPIKeys(for: uid)
        }
        return nil
    }

    static func save(_ snapshot: AppSessionSnapshot) {
        save(snapshot, for: activeUID)
    }

    /// This snapshot is the only place providers, the account and folders are persisted
    /// (conversations have the database as a fallback; these do not). Encoding and writing used to
    /// swallow a `try?` each, so on a full disk the provider list and its API key references went
    /// missing without a single trace — the next launch simply had no providers.
    static func save(_ snapshot: AppSessionSnapshot, for uid: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let dir = userDir(for: uid)
        let persistedSnapshot = snapshot.persistingProviderAPIKeys(for: uid)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder.encode(persistedSnapshot)
            try data.write(to: snapshotPath(for: uid), options: .atomic)
        } catch {
            AppLog.error(error, module: "persistence", context: ["op": "saveSessionSnapshot"])
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: snapshotPath)
        try? FileManager.default.removeItem(at: databasePath)
        try? FileManager.default.removeItem(at: filesDir)
        try? FileManager.default.removeItem(at: recoverySnapshotPath(for: activeUID))
        ProviderAPIKeyStore.deleteAll(for: activeUID)
        try? McpCredentialStore.shared.deleteAll(for: activeUID)
    }


    static func migrateToPartitionedStorageIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        let fm = FileManager.default
        let oldSnapshot = baseDir.appendingPathComponent(fileName)
        let oldImages = baseDir.appendingPathComponent("Images", isDirectory: true)

        let hasOldFile = fm.fileExists(atPath: oldSnapshot.path)
        let hasLegacyUD = UserDefaults.standard.data(forKey: legacyKey) != nil

        guard hasOldFile || hasLegacyUD else {
            UserDefaults.standard.set(true, forKey: migratedKey)
            switchToUser("guest")
            return
        }

        let targetUID = "guest"
        let targetDir = userDir(for: targetUID)
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        if let udData = UserDefaults.standard.data(forKey: legacyKey), !hasOldFile {
            try? udData.write(to: oldSnapshot)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        if fm.fileExists(atPath: oldSnapshot.path) {
            let dest = targetDir.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: oldSnapshot, to: dest)
            }
        }

        if fm.fileExists(atPath: oldImages.path) {
            let dest = targetDir.appendingPathComponent("Images", isDirectory: true)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: oldImages, to: dest)
            } else {
                if let files = try? fm.contentsOfDirectory(atPath: oldImages.path) {
                    for file in files {
                        let src = oldImages.appendingPathComponent(file)
                        let dst = dest.appendingPathComponent(file)
                        try? fm.moveItem(at: src, to: dst)
                    }
                }
                try? fm.removeItem(at: oldImages)
            }
        }

        UserDefaults.standard.removeObject(forKey: legacyKey)

        activeUID = targetUID
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}
