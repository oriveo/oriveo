import Foundation

// MARK: - Saved external search services (see the external search services contract)
//
// - The service list is a local file (Application Support/SearchServices, isExcludedFromBackup); it is not synced and not in app backups;
// - Keys go only into the Keychain (AfterFirstUnlockThisDeviceOnly, non-synchronizable, same backend as McpKeychainCredentialStorage, separate service);
// - A preset service stores the host confirmed at save time (checked against the catalog before sending the key); a reused model connection stores only the connection reference, never a separate key;
// - A custom service's key is bound to keyBindingOrigin (scheme://host[:port]); if the origin changes the key is cleared immediately.

nonisolated struct StoredSearchService: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case preset
        case reuseConnection = "reuse_connection"
        case custom
    }

    var id: String
    var kind: Kind
    /// preset / reuseConnection: the catalog entry id.
    var serviceId: String?
    var regionId: String?
    /// preset: the host confirmed at save time.
    var boundHost: String?
    /// reuseConnection: the model connection reference (the key follows the connection and is not stored here).
    var connectionRef: String?
    /// custom: display name, address, protocol (searxng / same_as / manual).
    var name: String?
    var address: String?
    var protocolID: String?
    /// custom: the raw JSON of a manual mapping or a "same as X" snapshot (order preserved).
    var mappingJSON: String?
    /// Detail page "Advanced > Results per search" (3 / 5 / 8 / 10); nil = default 5 (old records lack this field).
    var resultCount: Int?

    /// The count actually used (via searchResultCount: anything not among the selectable values falls back to the default 5).
    var effectiveResultCount: Int { SearchSettings.searchResultCount(resultCount) }

    /// Input for the settings-page row status: reused model connection = key comes from the connection; preset with its own key = own; custom key is optional.
    func rowInput(hasKey: Bool) -> SearchRowServiceInput {
        SearchRowServiceInput(
            kind: kind == .custom ? .custom : .preset,
            serviceId: serviceId,
            regionId: regionId,
            boundHost: boundHost,
            keySource: kind == .reuseConnection ? .connection : (kind == .custom && !hasKey ? .none : .own),
            connectionRef: connectionRef,
            hasKey: hasKey
        )
    }

    /// What the key is bound to: preset = host; custom = origin; reuse = none (no key stored).
    var keyBinding: String? {
        switch kind {
        case .preset: return boundHost.map { "host:\($0)" }
        case .custom: return SearchTransport.keyBindingOrigin(address).map { "origin:\($0)" }
        case .reuseConnection: return nil
        }
    }
}

nonisolated enum SearchServiceStoreError: Error, Equatable {
    /// The key failed normalizeSearchKey (key_empty / key_invalid) and was not saved.
    case invalidKey(String)
}

nonisolated private struct SearchKeyRecord: Codable {
    var secret: String
    var binding: String
}

actor SearchServiceStore {
    static let keychainService = "ai.oriveo.community.search-key"

    private let directory: URL
    private let credentials: any McpCredentialStorage
    /// Account scope (e.g. uid), isolating keys of different sign-in identities.
    private let scope: String

    init(
        directory: URL = SearchServiceStore.defaultDirectory,
        credentials: any McpCredentialStorage = McpKeychainCredentialStorage(service: SearchServiceStore.keychainService),
        scope: String
    ) {
        self.directory = directory
        self.credentials = credentials
        self.scope = scope
    }

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SearchServices", isDirectory: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("services-\(Self.safeFileComponent(scope)).json", isDirectory: false)
    }

    /// The default service id chosen by the user: a separate file in the same partition and directory as the list (not synced, not in backups).
    private var defaultFileURL: URL {
        directory.appendingPathComponent("default-\(Self.safeFileComponent(scope)).json", isDirectory: false)
    }

    private nonisolated static func safeFileComponent(_ raw: String) -> String {
        String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }

    private func account(_ serviceID: String) -> String { "\(scope):\(serviceID)" }

    // MARK: List

    func services() -> [StoredSearchService] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([StoredSearchService].self, from: data)) ?? []
    }

    /// Add or update. key non-nil = also write the new key (first through normalizeSearchKey; if not ok nothing is saved at all); when nil:
    /// a preset service whose host was reconfirmed → keep the key and rebind it to the new host; a custom service whose origin changed → clear the old key.
    func save(_ service: StoredSearchService, key: String? = nil) throws {
        var normalizedKey: String?
        if let key {
            let normalized = SearchTransport.normalizeSearchKey(key)
            guard normalized.ok, let value = normalized.key else {
                throw SearchServiceStoreError.invalidKey(normalized.error ?? "key_invalid")
            }
            normalizedKey = value
        }
        var list = services()
        if let index = list.firstIndex(where: { $0.id == service.id }) {
            list[index] = service
        } else {
            list.append(service)
        }
        try writeList(list)
        if service.kind == .reuseConnection {
            try credentials.delete(account: account(service.id))
            return
        }
        if let normalizedKey, let binding = service.keyBinding {
            let record = try JSONEncoder().encode(SearchKeyRecord(secret: normalizedKey, binding: binding))
            try credentials.write(record, account: account(service.id))
        } else if let record = storedRecord(service.id), record.binding != service.keyBinding {
            if service.kind == .preset, let binding = service.keyBinding {
                // The user reconfirmed the new host: the same key follows it
                let rebound = try JSONEncoder().encode(SearchKeyRecord(secret: record.secret, binding: binding))
                try credentials.write(rebound, account: account(service.id))
            } else {
                try credentials.delete(account: account(service.id))
            }
        }
    }

    /// Delete a service: if it is the stored default id, that key is cleared too; the effective default is derived by resolveDefaultSearchService from the remaining list.
    func remove(_ serviceID: String) throws {
        try writeList(services().filter { $0.id != serviceID })
        try credentials.delete(account: account(serviceID))
        if defaultServiceID() == serviceID { try setDefaultServiceID(nil) }
    }

    // MARK: Default service

    /// The stored default id (may point at a deleted service; the UI always goes through resolvedDefaultServiceID).
    func defaultServiceID() -> String? {
        guard let data = try? Data(contentsOf: defaultFileURL) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    /// nil = clear (back to "the earliest added"). Nothing is written if the value is unchanged.
    func setDefaultServiceID(_ serviceID: String?) throws {
        guard serviceID != defaultServiceID() else { return }
        guard let serviceID else {
            if FileManager.default.fileExists(atPath: defaultFileURL.path) { try FileManager.default.removeItem(at: defaultFileURL) }
            return
        }
        try prepareDirectory()
        try JSONEncoder().encode(serviceID).write(to: defaultFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The currently effective default service: use the stored one if it still exists, otherwise the earliest in storage order; no services = nil.
    func resolvedDefaultServiceID() -> String? {
        SearchSettings.resolveDefaultSearchService(serviceIds: services().map(\.id), storedDefault: defaultServiceID())
    }

    /// Fetch the key: if the binding does not match the service's current host / origin, never return it (a key is never sent to an unconfirmed host or new origin).
    /// A custom service whose origin mismatches is cleared; a preset service is kept until the user reconfirms the host and save rebinds.
    func key(for service: StoredSearchService) throws -> String? {
        guard let record = storedRecord(service.id) else { return nil }
        guard let binding = service.keyBinding, record.binding == binding else {
            if service.kind != .preset { try credentials.delete(account: account(service.id)) }
            return nil
        }
        return record.secret
    }

    // MARK: Per-conversation source

    /// Per-conversation source: a separate file in the same partition and directory as the service list (not synced, not in backups), key searchSourceStorageKey.
    private var sourcesFileURL: URL {
        directory.appendingPathComponent("sources-\(Self.safeFileComponent(scope)).json", isDirectory: false)
    }

    private func sourcesObject() -> SearchJSONObject {
        guard let data = try? Data(contentsOf: sourcesFileURL) else { return SearchJSONObject() }
        return (try? SearchJSON.parse(data))?.objectValue ?? SearchJSONObject()
    }

    /// The raw source value stored for this conversation (the stored input of resolveSearchSource, which normalizes bad values).
    func conversationSource(_ conversationID: String) -> SearchJSON? {
        sourcesObject()[SearchRoute.searchSourceStorageKey(conversationID)]
    }

    /// nil = delete the key. Nothing is written if the value is unchanged (a second write of the same snapshot is a zero-write).
    func setConversationSource(_ value: SearchSourceStored?, conversationID: String) throws {
        var object = sourcesObject()
        let key = SearchRoute.searchSourceStorageKey(conversationID)
        let encoded = try value.map { try SearchJSON.parse(JSONEncoder().encode($0)) }
        guard object[key] != encoded else { return }
        object[key] = encoded
        try writeSources(object)
    }

    /// Delete conversations: write the sources of those conversations in one go; nothing is written if there is nothing to delete.
    func removeConversationSources(_ conversationIDs: [String]) throws {
        var object = sourcesObject()
        let keys = conversationIDs.map(SearchRoute.searchSourceStorageKey).filter { object[$0] != nil }
        guard !keys.isEmpty else { return }
        for key in keys { object[key] = nil }
        try writeSources(object)
    }

    private func writeSources(_ object: SearchJSONObject) throws {
        try prepareDirectory()
        try Data(SearchJSON.object(object).encodedString().utf8)
            .write(to: sourcesFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Guest migration: merge the guest partition's per-conversation sources into this one (the conversations migrate wholesale in the same migration branch); an existing key on the account is not overwritten. Returns the number merged.
    @discardableResult
    func adoptConversationSources(_ incoming: SearchJSONObject) throws -> Int {
        var object = sourcesObject()
        var adopted = 0
        for entry in incoming.entries where object[entry.key] == nil {
            object[entry.key] = entry.value
            adopted += 1
        }
        if adopted > 0 { try writeSources(object) }
        return adopted
    }

    /// Clear all per-conversation sources in this partition (the guest partition after migrating away).
    func removeAllConversationSources() throws {
        if FileManager.default.fileExists(atPath: sourcesFileURL.path) { try FileManager.default.removeItem(at: sourcesFileURL) }
    }

    fileprivate func allConversationSources() -> SearchJSONObject { sourcesObject() }

    // MARK: guest → account

    /// Whether a partition has any saved search service (on sign-in, decides "the guest has data worth carrying over").
    nonisolated static func hasServices(scope: String, directory: URL = SearchServiceStore.defaultDirectory) async -> Bool {
        let store = SearchServiceStore(
            directory: directory,
            credentials: McpKeychainCredentialStorage(service: keychainService),
            scope: scope
        )
        return await !store.services().isEmpty
    }

    /// On sign-in, migrate the guest partition's services and keys into the account partition (same migration branch as BYOK provider / MCP credentials: migrate together or
    /// stay in guest). A service with the same id already in the account partition is not overwritten. After migrating, the guest list and keys are cleared.
    nonisolated static func migratePartition(
        from guestScope: String,
        to uid: String,
        directory: URL = SearchServiceStore.defaultDirectory,
        credentials: any McpCredentialStorage = McpKeychainCredentialStorage(service: SearchServiceStore.keychainService)
    ) async throws {
        let guest = SearchServiceStore(directory: directory, credentials: credentials, scope: guestScope)
        let account = SearchServiceStore(directory: directory, credentials: credentials, scope: uid)
        // Bring along the conversations whose per-conversation sources migrate too: unrelated to the service list, migrate first.
        let sources = await guest.allConversationSources()
        if !sources.isEmpty {
            try await account.adoptConversationSources(sources)
            try await guest.removeAllConversationSources()
        }
        let moving = await guest.services()
        guard !moving.isEmpty else { return }
        let accountIDs = await account.services().map(\.id)
        let existing = Set(accountIDs)
        var migrated: [String] = []
        for service in moving where !existing.contains(service.id) {
            try await account.adopt(service, record: await guest.storedRecordData(service.id))
            migrated.append(service.id)
        }
        // Only if the account had no services, bring over the guest's effective default (migratedDefaultSearchService)
        let carried = SearchSettings.migratedDefaultSearchService(
            accountServiceIds: accountIDs,
            guestServiceIds: moving.map(\.id),
            guestStoredDefault: await guest.defaultServiceID(),
            migratedIds: migrated
        )
        if carried.set, let id = carried.id { try await account.setDefaultServiceID(id) }
        for service in moving { try await guest.remove(service.id) }
        try await guest.setDefaultServiceID(nil)
    }

    private func storedRecordData(_ serviceID: String) -> Data? {
        credentials.read(account: account(serviceID))
    }

    private func adopt(_ service: StoredSearchService, record: Data?) throws {
        var list = services()
        list.append(service)
        try writeList(list)
        if let record { try credentials.write(record, account: account(service.id)) }
    }

    private func storedRecord(_ serviceID: String) -> SearchKeyRecord? {
        guard let data = credentials.read(account: account(serviceID)) else { return nil }
        return try? JSONDecoder().decode(SearchKeyRecord.self, from: data)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    private func writeList(_ list: [StoredSearchService]) throws {
        try prepareDirectory()
        try JSONEncoder().encode(list).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

