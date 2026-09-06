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
            return copy
        }
        ProviderAPIKeyStore.deleteAllExcept(providerIDs: providerIDs, uid: uid)
        return persisted
    }
}

enum ProviderAPIKeyStore {
    private static let service = "ai.oriveo.community.provider-api-key"

    private static func account(providerID: UUID, uid: String) -> String {
        "\(uid):\(providerID.uuidString)"
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
        guard let data = apiKey.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, uid: uid)
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
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete(providerID: UUID, uid: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(providerID: providerID, uid: uid)
        ]
        _ = SecItemDelete(query as CFDictionary)
        GrokSubscriptionCredentialStore.delete(providerID: providerID, uid: uid)
        OpenAISubscriptionCredentialStore.delete(providerID: providerID, uid: uid)
        ProviderCapabilityIdentityStore.advanceCredentialEpoch(providerID: providerID, partitionID: uid)
    }

    static func deleteAll(for uid: String) {
        deleteAllExcept(providerIDs: Set<UUID>(), uid: uid)
    }

    static func deleteAllExcept(providerIDs: Set<UUID>, uid: String) {
        let prefix = "\(uid):"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else {
                continue
            }
            let rawID = String(account.dropFirst(prefix.count))
            guard let providerID = UUID(uuidString: rawID), !providerIDs.contains(providerID) else {
                continue
            }
            delete(providerID: providerID, uid: uid)
        }
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


    static var activeUID: String {
        get {
            let file = baseDir.appendingPathComponent("active-uid")
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return "guest" }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "guest" : trimmed
        }
        set {
            let file = baseDir.appendingPathComponent("active-uid")
            try? newValue.write(to: file, atomically: true, encoding: .utf8)
        }
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

    static func save(_ snapshot: AppSessionSnapshot, for uid: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let dir = userDir(for: uid)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let persistedSnapshot = snapshot.persistingProviderAPIKeys(for: uid)
        guard let data = try? encoder.encode(persistedSnapshot) else { return }
        try? data.write(to: snapshotPath(for: uid), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: snapshotPath)
        try? FileManager.default.removeItem(at: databasePath)
        try? FileManager.default.removeItem(at: filesDir)
        try? FileManager.default.removeItem(at: recoverySnapshotPath(for: activeUID))
        ProviderAPIKeyStore.deleteAll(for: activeUID)
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
