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


nonisolated enum AppSessionStore {
    private static let legacyKey = "oriveo.session.snapshot"
    private static let fileName = "session-snapshot.json"
    private static let backupFileName = "session-snapshot.backup-pre-grdb.json"
    private static let migratedKey = "oriveo.storage.partitioned"


    static let baseDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oriveo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()


    private static let activeUIDLock = NSLock()
    /// Chat cells read this on every configure, and several screens use it as a `.task(id:)` key in
    /// their body (over a hundred call sites). Opening the file on each read is pure waste: only the
    /// setter below writes it, so caching the value in process is enough.
    nonisolated(unsafe) private static var cachedActiveUID: String?
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
    #endif

    static var activeUID: String {
        get {
            activeUIDLock.lock()
            defer { activeUIDLock.unlock() }
            if let cachedActiveUID { return cachedActiveUID }
            #if DEBUG
            debugActiveUIDDiskReadStorage += 1
            #endif
            let file = baseDir.appendingPathComponent("active-uid")
            let raw = try? String(contentsOf: file, encoding: .utf8)
            let resolved = normalizedActiveUID(raw)
            cachedActiveUID = resolved
            return resolved
        }
        set {
            activeUIDLock.lock()
            defer { activeUIDLock.unlock() }
            let file = baseDir.appendingPathComponent("active-uid")
            do {
                try newValue.write(to: file, atomically: true, encoding: .utf8)
                cachedActiveUID = normalizedActiveUID(newValue)
            } catch {
                // The file still holds the previous value, so the next read goes back to disk,
                // exactly as it would without a cache.
                cachedActiveUID = nil
            }
        }
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

    static func clearPartition(for uid: String) {
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
