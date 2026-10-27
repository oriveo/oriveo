import Foundation
import Testing
@testable import Oriveo

/// In-memory credential backend: follows SearchServiceStore's production semantics, only swapping the medium.
private final class InMemorySearchCredentials: McpCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func read(account: String) -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    func delete(account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }
    func accounts() -> [String] { lock.withLock { Array(items.keys) } }
}

/// Storage of saved services: the list is a local file (excluded from backup), keys go only to the credential backend; presets bind to a host, custom services bind to a source, reuse stores no key.
/// For the key binding semantics see bindingCases in shared/search-contracts/custom-service.v1.json.
@Suite("External search service storage")
struct SearchServiceStoreTests {
    private static func makeStore() -> (SearchServiceStore, InMemorySearchCredentials, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-services-\(UUID().uuidString)", isDirectory: true)
        let credentials = InMemorySearchCredentials()
        return (SearchServiceStore(directory: directory, credentials: credentials, scope: "uid-1"), credentials, directory)
    }

    @Test("Custom service: a path change keeps the key, a source change clears it; the list file holds no key and is excluded from backup")
    func customKeyFollowsOrigin() async throws {
        let (store, credentials, directory) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var service = StoredSearchService(
            id: "s1", kind: .custom, name: "NAS", address: "https://a.example/v1/search", protocolID: "searxng"
        )
        try await store.save(service, key: "secret-token-1")
        #expect(try await store.key(for: service) == "secret-token-1")

        service.address = "https://a.example/v2/search"
        try await store.save(service)
        #expect(try await store.key(for: service) == "secret-token-1")

        service.address = "https://b.example/v2/search"
        try await store.save(service)
        #expect(try await store.key(for: service) == nil)
        #expect(credentials.accounts().isEmpty)

        #expect(await store.services() == [service])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let text = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(!text.contains("secret-token-1"))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("Preset service key binds to the confirmed host; reusing a model connection stores only a reference, not a key; removal clears the key too")
    func presetAndReuseBindings() async throws {
        let (store, credentials, directory) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var preset = StoredSearchService(id: "p1", kind: .preset, serviceId: "tavily", regionId: "global", boundHost: "api.tavily.com")
        try await store.save(preset, key: "tvly-key-0001")
        #expect(try await store.key(for: preset) == "tvly-key-0001")

        // Catalog host changed and the user has not reconfirmed: the key is not sent
        preset.boundHost = "search.tavily.com"
        #expect(try await store.key(for: preset) == nil)
        // Saved after reconfirmation: the same key is rebound to the new host
        try await store.save(preset)
        #expect(try await store.key(for: preset) == "tvly-key-0001")

        let reuse = StoredSearchService(id: "r1", kind: .reuseConnection, serviceId: "kimi", regionId: "cn", connectionRef: "conn-42")
        try await store.save(reuse, key: "should-not-store")
        #expect(try await store.key(for: reuse) == nil)
        #expect(credentials.accounts() == ["uid-1:p1"])

        try await store.save(preset, key: "tvly-key-0002")
        try await store.remove("p1")
        #expect(credentials.accounts().isEmpty)
        #expect(await store.services().map(\.id) == ["r1"])
    }

    @Test("The key first goes through normalizeSearchKey: stored after trimming surrounding whitespace; an invalid one is not stored at all")
    func keyIsNormalizedBeforeSaving() async throws {
        let (store, credentials, directory) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = StoredSearchService(id: "s1", kind: .custom, name: "x", address: "https://a.example/search", protocolID: "searxng")
        await #expect(throws: SearchServiceStoreError.invalidKey("key_invalid")) {
            try await store.save(service, key: "tvly-密钥")
        }
        #expect(await store.services().isEmpty)
        #expect(credentials.accounts().isEmpty)

        try await store.save(service, key: "  tok-123\n")
        #expect(try await store.key(for: service) == "tok-123")
    }

    @Test("guest → account: services and keys migrate into the account partition and guest is cleared; an existing service with the same id in the account is not overwritten")
    func guestPartitionMigratesToAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-services-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemorySearchCredentials()
        let guest = SearchServiceStore(directory: directory, credentials: credentials, scope: "guest")
        let account = SearchServiceStore(directory: directory, credentials: credentials, scope: "uid-9")
        let moving = StoredSearchService(id: "g1", kind: .preset, serviceId: "tavily", regionId: "global", boundHost: "api.tavily.com")
        let clash = StoredSearchService(id: "both", kind: .custom, name: "guest", address: "https://g.example", protocolID: "searxng")
        let kept = StoredSearchService(id: "both", kind: .custom, name: "account", address: "https://a.example", protocolID: "searxng")
        try await guest.save(moving, key: "tvly-guest-key")
        try await guest.save(clash, key: "guest-clash-key")
        try await account.save(kept, key: "account-key")

        try await SearchServiceStore.migratePartition(from: "guest", to: "uid-9", directory: directory, credentials: credentials)

        #expect(await guest.services().isEmpty)
        #expect(try await guest.key(for: moving) == nil)
        #expect(Set(await account.services().map(\.name)) == [nil, "account"])
        #expect(try await account.key(for: moving) == "tvly-guest-key")
        #expect(try await account.key(for: kept) == "account-key")
    }

    @Test("Default service id is stored in a separate file in this partition: save/load, partition isolation; deleting the stored default clears that key, and the effective default follows resolveDefaultSearchService")
    func defaultServiceIDPerPartition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-services-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemorySearchCredentials()
        let store = SearchServiceStore(directory: directory, credentials: credentials, scope: "uid-1")
        let other = SearchServiceStore(directory: directory, credentials: credentials, scope: "uid-2")
        #expect(await store.resolvedDefaultServiceID() == nil)

        for id in ["a", "b", "c"] {
            try await store.save(StoredSearchService(id: id, kind: .custom, name: id, address: "https://\(id).example", protocolID: "searxng"))
        }
        // Never set: the earliest added one
        #expect(await store.defaultServiceID() == nil)
        #expect(await store.resolvedDefaultServiceID() == "a")

        try await store.setDefaultServiceID("b")
        #expect(await store.defaultServiceID() == "b")
        #expect(await store.resolvedDefaultServiceID() == "b")
        #expect(await other.defaultServiceID() == nil)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // The deleted one is not the stored default: the key is untouched
        try await store.setDefaultServiceID("c")
        try await store.remove("b")
        #expect(await store.defaultServiceID() == "c")
        // Deleting the stored default: the key is cleared too, and the effective default falls to the earliest remaining
        try await store.remove("c")
        #expect(await store.defaultServiceID() == nil)
        #expect(await store.resolvedDefaultServiceID() == "a")
    }

    @Test("The per-search count is stored in the service record: an older record without the field counts as 5, and a value outside the allowed set counts as 5")
    func resultCountIsStoredPerService() async throws {
        let (store, _, directory) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var service = StoredSearchService(id: "p1", kind: .preset, serviceId: "tavily", regionId: "global", boundHost: "api.tavily.com")
        #expect(service.effectiveResultCount == 5)
        service.resultCount = 8
        try await store.save(service, key: "tvly-key-0001")
        #expect(await store.services().first?.resultCount == 8)
        #expect(await store.services().first?.effectiveResultCount == 8)
        service.resultCount = 7
        #expect(service.effectiveResultCount == 5)

        let legacy = #"[{"id":"x","kind":"custom","name":"NAS","address":"https://nas.example","protocolID":"searxng"}]"#
        let decoded = try JSONDecoder().decode([StoredSearchService].self, from: Data(legacy.utf8))
        #expect(decoded.first?.resultCount == nil)
        #expect(decoded.first?.effectiveResultCount == 5)
    }

    @Test("guest → account: the guest's effective default is carried over only if the account had no services; an account with existing services is untouched; the guest's default is cleared")
    func guestDefaultMigratesWhenAccountHasNone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-services-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemorySearchCredentials()
        let guest = SearchServiceStore(directory: directory, credentials: credentials, scope: "guest")
        let account = SearchServiceStore(directory: directory, credentials: credentials, scope: "uid-9")
        try await guest.save(StoredSearchService(id: "g1", kind: .custom, name: "a", address: "https://a.example", protocolID: "searxng"))
        try await guest.save(StoredSearchService(id: "g2", kind: .custom, name: "b", address: "https://b.example", protocolID: "searxng"))
        try await guest.setDefaultServiceID("g2")

        try await SearchServiceStore.migratePartition(from: "guest", to: "uid-9", directory: directory, credentials: credentials)

        #expect(await account.defaultServiceID() == "g2")
        #expect(await guest.defaultServiceID() == nil)

        // Account already has services (and never picked a default): the guest's default is not carried over
        let guest2 = SearchServiceStore(directory: directory, credentials: credentials, scope: "guest2")
        let account2 = SearchServiceStore(directory: directory, credentials: credentials, scope: "uid-10")
        try await account2.save(StoredSearchService(id: "a1", kind: .custom, name: "a", address: "https://a1.example", protocolID: "searxng"))
        try await guest2.save(StoredSearchService(id: "g3", kind: .custom, name: "c", address: "https://c.example", protocolID: "searxng"))
        try await guest2.setDefaultServiceID("g3")
        try await SearchServiceStore.migratePartition(from: "guest2", to: "uid-10", directory: directory, credentials: credentials)
        #expect(await account2.defaultServiceID() == nil)
        #expect(await account2.resolvedDefaultServiceID() == "a1")
    }

    @Test("A guest who only added a search service still counts as having data worth migrating, so sign-in takes the migration branch")
    @MainActor
    func guestSearchServicesCountAsSignificantData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-services-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await SearchServiceStore.hasServices(scope: "guest", directory: directory) == false)
        let guest = SearchServiceStore(directory: directory, credentials: InMemorySearchCredentials(), scope: "guest")
        try await guest.save(StoredSearchService(id: "g1", kind: .custom, name: "NAS", address: "https://nas.example", protocolID: "searxng"))
        #expect(await SearchServiceStore.hasServices(scope: "guest", directory: directory))
        #expect(await SearchServiceStore.hasServices(scope: "uid-1", directory: directory) == false)
    }
}
