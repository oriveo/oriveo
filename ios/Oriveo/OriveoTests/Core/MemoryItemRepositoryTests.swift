import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The memory_item table (v37), repository write operations, and legacy field migration / flow-back / dual write.
@Suite("Memory item repository v37", .serialized)
@MainActor
struct MemoryItemRepositoryTests {

    /// One device: a standalone database (temporary directory) plus in-memory preferences; the legacy field dual write goes through the production `applyingMemoryLegacy`.
    @MainActor
    final class Device {
        let database: McpTestDatabase
        var preferences: AppPreference
        var writes = 0
        var repository: MemoryItemRepository!

        init(uid: String, deviceId: String, preferences: AppPreference) throws {
            database = try McpTestDatabase.make()
            self.preferences = preferences
            repository = MemoryItemRepository(
                uid: uid,
                store: MemoryItemStore(dbPool: database.pool),
                bridge: MemoryLegacyPrefsBridge(
                    read: { [unowned self] in self.preferences.memoryLegacyPrefs },
                    write: { [unowned self] compiled in
                        self.writes += 1
                        self.preferences = self.preferences.applyingMemoryLegacy(compiled, now: Date())
                    }
                ),
                deviceId: deviceId,
                migrationScope: "memory-items-test-\(UUID().uuidString)"
            )
        }
    }

    private static let legacyText = "  I live in Berlin.\n\nPrefer short answers.  "

    private func prefs(_ text: String, digest: String? = nil, antiForget: String = "") -> AppPreference {
        AppPreference(
            theme: .dark,
            language: .system,
            memoryText: text,
            memoryAntiForgetEnabled: !antiForget.isEmpty,
            memoryAntiForgetText: antiForget,
            memoryUpdatedAt: Date(timeIntervalSince1970: 1_760_000_000),
            memoryTextDigest: digest
        )
    }

    @Test func migrationDiffZero() async throws {
        let device = try Device(uid: "u1", deviceId: "device-a", preferences: prefs(Self.legacyText, antiForget: "Never forget tests"))
        try await device.database.pool.read { (db: Database) throws -> Void in
            #expect(try db.tableExists(MemoryItemStore.table))
            #expect(try db.columns(in: MemoryItemStore.table).map(\.name).contains("syncState"))
        }

        try await device.repository.reconcileLegacy()

        let items = device.repository.list()
        #expect(items.map(\.id).sorted() == [
            MemoryItems.legacyMemoryTextId(uid: "u1"), MemoryItems.legacyAntiForgetId(uid: "u1"),
        ].sorted())
        let memoryItem = try #require(items.first { $0.id == MemoryItems.legacyMemoryTextId(uid: "u1") })
        #expect(memoryItem.content == Self.legacyText)
        #expect(memoryItem.source.type == .migration)
        #expect(device.repository.syncState(id: memoryItem.id) == .pending)
        // After migration, the memoryText compiled back is byte-identical to the original: no difference in the legacy fields, only the digest is added, and timestamps are untouched
        #expect(device.preferences.memoryText == Self.legacyText)
        #expect(device.preferences.memoryTextDigest == MemoryItems.sha256Hex(Self.legacyText))
        #expect(device.preferences.memoryUpdatedAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(device.preferences.memoryAntiForgetText == "Never forget tests")
        #expect(device.repository.isMigrated)
    }

    @Test func migrationIdempotentTwoDevices() async throws {
        let deviceA = try Device(uid: "u1", deviceId: "device-a", preferences: prefs(Self.legacyText))
        let deviceB = try Device(uid: "u1", deviceId: "device-b", preferences: prefs(Self.legacyText))

        try await deviceA.repository.reconcileLegacy()
        try await deviceB.repository.reconcileLegacy()
        let itemA = try #require(deviceA.repository.list().first)
        let itemB = try #require(deviceB.repository.list().first)
        // Multi-device migration: both id and mutationId are deterministic, so the same item is composed on every device with create-if-absent semantics
        #expect(itemA.id == itemB.id)
        #expect(itemA.mutationId == itemB.mutationId)
        #expect(itemA.content == itemB.content)

        // Run it again: nothing is added or changed and the legacy fields are not written again
        let writesBefore = deviceA.writes
        try await deviceA.repository.reconcileLegacy()
        #expect(deviceA.repository.allItems() == [itemA])
        #expect(deviceA.writes == writesBefore)

        // A third device receives the legacy fields after A's dual write (the digest matches memoryText): it only marks them migrated and creates nothing
        let deviceC = try Device(uid: "u1", deviceId: "device-c", preferences: deviceA.preferences)
        try await deviceC.repository.reconcileLegacy()
        #expect(deviceC.repository.allItems().isEmpty)
        #expect(deviceC.writes == 0)
        #expect(deviceC.repository.isMigrated)
    }

    @Test func dualWriteCompile() async throws {
        let device = try Device(uid: "u1", deviceId: "device-a", preferences: prefs("Alpha"))
        try await device.repository.reconcileLegacy()

        let beta = try device.repository.create(kind: .preference, content: "Beta")
        #expect(device.preferences.memoryText == "Alpha\n\nBeta")
        #expect(device.preferences.memoryTextDigest == MemoryItems.sha256Hex("Alpha\n\nBeta"))
        #expect(device.preferences.memoryUpdatedAt != Date(timeIntervalSince1970: 1_760_000_000))

        try device.repository.setPinned(id: beta.id, pinned: true)
        #expect(device.preferences.memoryText == "Beta\n\nAlpha")

        try device.repository.setStatus(id: beta.id, status: .paused)
        #expect(device.preferences.memoryText == "Alpha")
        #expect(device.preferences.memoryAntiForgetText.isEmpty)

        // Nothing is written when the compiled result is unchanged
        let writesBefore = device.writes
        try device.repository.update(id: beta.id, content: "Beta 2")
        #expect(device.writes == writesBefore)

        // The digest stays in the same group as memoryText
        #expect(device.preferences.memoryText == "Alpha")
        #expect(device.preferences.memoryTextDigest == MemoryItems.sha256Hex("Alpha"))
    }

    @Test func oldClientEditFlowsBack() async throws {
        let device = try Device(uid: "u1", deviceId: "device-a", preferences: prefs("Alpha"))
        try await device.repository.reconcileLegacy()
        let legacyId = MemoryItems.legacyMemoryTextId(uid: "u1")
        let migrated = try #require(device.repository.list().first)

        // An old client edits memoryText: the digest is left as it was (the old client does not know it)
        var remote = device.preferences
        remote.memoryText = "Alpha edited  "
        remote.memoryUpdatedAt = Date(timeIntervalSince1970: 1_760_600_000)
        #expect(remote.memoryText == "Alpha edited  ")
        device.preferences = remote
        try await device.repository.reconcileLegacy()

        let edited = try #require(device.repository.list().first)
        #expect(edited.id == legacyId)
        #expect(edited.content == "Alpha edited  ")
        #expect(edited.mutationId != migrated.mutationId)
        #expect(edited.baseRevision == edited.revision)
        #expect(device.repository.syncState(id: legacyId) == .pending)
        #expect(device.preferences.memoryTextDigest == MemoryItems.sha256Hex("Alpha edited  "))

        // An old client clears it: a tombstone is written
        device.preferences.memoryText = ""
        try await device.repository.reconcileLegacy()
        #expect(device.repository.list().isEmpty)
        #expect(device.repository.allItems().first?.status == .deleted)
        #expect(device.preferences.memoryTextDigest == MemoryItems.sha256Hex(""))
    }

    @Test func deleteWritesTombstone() async throws {
        let device = try Device(uid: "u1", deviceId: "device-a", preferences: prefs(""))
        try await device.repository.reconcileLegacy()
        let created = try device.repository.create(content: "Gamma")
        #expect(device.preferences.memoryText == "Gamma")

        let tombstone = try #require(try device.repository.remove(id: created.id))
        let stored = try #require(device.repository.allItems().first { $0.id == created.id })
        #expect(stored == tombstone)
        #expect(stored.status == .deleted)
        #expect(stored.content.isEmpty)
        #expect(stored.deletedAt.flatMap(MemoryItems.instant) != nil)
        #expect(stored.createdAt == created.createdAt)
        #expect(stored.mutationId != created.mutationId)
        #expect(stored.baseRevision == stored.revision)
        #expect(device.repository.syncState(id: created.id) == .pending)
        #expect(device.repository.list().isEmpty)
        #expect(try device.repository.remove(id: created.id) == nil)

        // An empty compiled result is dual-written as well
        #expect(device.preferences.memoryText.isEmpty)
        #expect(device.preferences.memoryTextDigest == MemoryItems.sha256Hex(""))
    }

    @Test func editMarksPending() throws {
        let device = try Device(uid: "u1", deviceId: "device-a", preferences: prefs(""))
        let created = try device.repository.create(kind: .instruction, content: "Use metric units")
        #expect(created.id == created.id.lowercased())
        #expect(created.mutationId == created.mutationId.lowercased())
        #expect(created.deviceId == "device-a")
        #expect(created.createdAt.flatMap(MemoryItems.instant) != nil)
        try device.repository.store.setSyncState(.synced, id: created.id)
        #expect(device.repository.syncState(id: created.id) == .synced)

        let edited = try #require(try device.repository.update(id: created.id, content: "Use SI units"))
        #expect(edited.content == "Use SI units")
        #expect(edited.mutationId != created.mutationId)
        #expect(edited.mutationId == edited.mutationId.lowercased())
        #expect(edited.baseRevision == edited.revision)
        #expect(edited.deviceId == "device-a")
        #expect(edited.createdAt == created.createdAt)
        #expect(device.repository.syncState(id: created.id) == .pending)
        #expect(device.repository.list() == [edited])
    }

    // MARK: L3 writes (occurredAt, conflicts, resolution)

    @Test func l3CreateSetsOccurredAtNow() throws {
        let device = try Device(uid: "u1", deviceId: "device-a", preferences: prefs(""))
        let semantic = try device.repository.create(kind: .fact, content: "Lives in Berlin")
        #expect(semantic.layer == .semantic)
        #expect(semantic.occurredAt == nil)

        let manual = try device.repository.create(kind: .decision, content: "Chose the blue logo", layer: .episodic)
        #expect(manual.layer == .episodic)
        #expect(manual.occurredAt != nil)
        #expect(manual.occurredAt == manual.createdAt)
        #expect(manual.occurredAt.flatMap(MemoryItems.instant) != nil)

        // A draft confirmed from a candidate: the layer is decided by the final kind (event -> episodic), and occurredAt defaults to now when absent
        let draftJSON = """
            {"layer":"episodic","kind":"event","status":"active","content":"Shipped v2.3 on October 3",
             "scope":{"type":"global","id":null},
             "source":{"type":"conversation","conversationId":"c1","messageIds":["m1"],"observedAtMs":1792137600000},
             "sensitivity":"normal","confidence":0.8}
            """
        let draft = try JSONDecoder().decode(MemoryItemDraft.self, from: Data(draftJSON.utf8))
        let accepted = try device.repository.store.item(id: try MemoryItemWriter(
            store: device.repository.store, deviceId: "device-a", timestamp: "2026-10-17T00:00:00.000Z"
        ).create(draft: draft).id)
        #expect(accepted?.layer == .episodic)
        #expect(accepted?.occurredAt == "2026-10-17T00:00:00.000Z")
        #expect(accepted?.source.observedAt == "2026-10-16T08:00:00Z")
    }

    @Test func l3ConflictMarksBothAndResolves() throws {
        let device = try Device(uid: "u1", deviceId: "device-a", preferences: prefs(""))
        let older = try device.repository.create(
            kind: .decision, content: "Decided the saga ends in 1453 in Constantinople", layer: .episodic
        )
        #expect(older.status == .active)
        // Different kind or semantic layer with the same text: neither counts as a conflict
        _ = try device.repository.create(kind: .event, content: "Decided the saga ends in 1460 in Constantinople", layer: .episodic)
        _ = try device.repository.create(kind: .decision, content: "Decided the saga ends in 1460 in Constantinople")
        #expect(try device.repository.store.item(id: older.id)?.status == .active)

        let newer = try device.repository.create(
            kind: .decision, content: "Decided the saga ends in 1460 in Constantinople", layer: .episodic
        )
        #expect(newer.status == .conflicted)
        #expect(newer.conflictGroupId == older.id)
        let storedOlder = try #require(try device.repository.store.item(id: older.id))
        #expect(storedOlder.status == .conflicted)
        #expect(storedOlder.conflictGroupId == older.id)
        #expect(storedOlder.mutationId != older.mutationId)
        #expect(try device.repository.store.item(id: newer.id)?.status == .conflicted)

        let resolved = try #require(try device.repository.resolveL3Conflict(
            newerId: newer.id, olderId: older.id, resolution: .useNew
        ))
        #expect(resolved.map(\.id) == [newer.id, older.id])
        let finalNewer = try #require(try device.repository.store.item(id: newer.id))
        let finalOlder = try #require(try device.repository.store.item(id: older.id))
        #expect(finalNewer.status == .active)
        #expect(finalNewer.conflictGroupId == nil)
        #expect(finalNewer.supersedes == [older.id])
        #expect(finalOlder.status == .superseded)
        #expect(finalOlder.conflictGroupId == nil)
        #expect(device.repository.syncState(id: newer.id) == .pending)
        // Resolution does not delete items
        #expect(device.repository.list().contains { $0.id == older.id })
        #expect(try device.repository.resolveL3Conflict(newerId: newer.id, olderId: "missing", resolution: .keepBoth) == nil)
    }

    /// Editing L3 text locally does not bump the revision: the recall index cache must still be rebuilt accordingly, and the recall results change with it.
    @Test func l3EditRebuildsRecallIndex() async throws {
        let device = try Device(uid: "u1", deviceId: "device-a", preferences: prefs(""))
        let item = try device.repository.create(kind: .decision, content: "Chose the blue logo", layer: .episodic)
        let cache = MemoryRecallIndexCache()
        let context = MemoryRecallContext(conversationId: "c1", folderId: nil, nowMs: 1_792_195_200_000)
        let before = await cache.recall(items: device.repository.list(), query: "chose the blue logo", context: context)
        #expect(before.map(\.id) == [item.id])

        let edited = try #require(try device.repository.update(id: item.id, content: "Picked Venice for the epilogue"))
        #expect(edited.revision == item.revision)
        let stale = await cache.recall(items: device.repository.list(), query: "chose the blue logo", context: context)
        #expect(stale.isEmpty)
        let fresh = await cache.recall(items: device.repository.list(), query: "picked venice for the epilogue", context: context)
        #expect(fresh.map(\.text) == ["Picked Venice for the epilogue"])
    }

    /// The database connection observed by the item cache is replaced (DatabaseManager keeps the connections of only two partitions: if other partitions is opened elsewhere first, opening this one again yields a new connection),
    /// and GRDB's observation cannot see writes made through the new connection; the cache must follow the writer's connection and refresh, rather than staying on the old value.
    @Test func cacheFollowsWriterAfterPoolReopened() async throws {
        let uid = "memory-cache-reopen-\(UUID().uuidString)"
        let other = "memory-cache-other-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: other))
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: other + "-2"))
        }
        let cache = MemoryItemsCache()
        cache.bind(uid: uid)
        let observedPool = try DatabaseManager.shared.openIfNeeded(for: uid)
        // Two other partitions take DatabaseManager's connection slots (current + secondary), so reopening this partition yields a different DatabasePool.
        _ = try DatabaseManager.shared.openIfNeeded(for: other)
        _ = try DatabaseManager.shared.openIfNeeded(for: other + "-2")
        let store = try #require(MemoryItemStore.forPartition(uid))
        #expect(try DatabaseManager.shared.openIfNeeded(for: uid) !== observedPool)

        let item = MemoryItem(
            id: "mem-reopen", layer: .semantic, kind: .fact, status: .active, content: "Reopened pool",
            scope: .global, mutationId: "mut-reopen", deviceId: "device-test", createdAt: "2026-01-01T00:00:00Z"
        )
        try store.upsert([item], syncState: .synced)

        let deadline = ContinuousClock.now + .seconds(2)
        while cache.items.map(\.id) != [item.id], ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(cache.items.map(\.content) == ["Reopened pool"])
    }
}
