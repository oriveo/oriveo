import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Backup export / import carries memorySchemaVersion + memoryItems (including tombstones); merge / replace / import-new-only follow the fixture;
/// an old backup without memoryItems migrates from its preferences; imported rows are always pending, and the legacy fields are dual-written once items change.
@Suite("Backup memory items", .serialized)
@MainActor
struct BackupMemoryItemsTests {

    /// One device: a standalone database + in-memory preferences, with dual-write going through the production `applyingMemoryLegacy`.
    @MainActor
    final class Device {
        let database: McpTestDatabase
        let store: MemoryItemStore
        var preferences: AppPreference
        var writes = 0
        var wakeups = 0
        var repository: MemoryItemRepository!

        init(uid: String = "u1", deviceId: String = "device-a", memoryText: String = "") throws {
            database = try McpTestDatabase.make()
            store = MemoryItemStore(dbPool: database.pool)
            preferences = AppPreference(theme: .dark, language: .system, memoryText: memoryText)
            repository = MemoryItemRepository(
                uid: uid,
                store: store,
                bridge: MemoryLegacyPrefsBridge(
                    read: { [unowned self] in self.preferences.memoryLegacyPrefs },
                    write: { [unowned self] compiled in
                        self.writes += 1
                        self.preferences = self.preferences.applyingMemoryLegacy(compiled, now: Date())
                    }
                ),
                deviceId: deviceId,
                migrationScope: "backup-memory-items-test-\(UUID().uuidString)"
            )
            repository.onLocalChange = { [unowned self] in self.wakeups += 1 }
        }
    }

    // MARK: Fixtures

    private static func backupCase(_ id: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/memory-items.v2.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                let cases = try #require(object["backupCases"] as? [[String: Any]])
                return try #require(cases.first { $0["id"] as? String == id })
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func items(_ object: Any?) throws -> [MemoryItem] {
        try decode([MemoryItem].self, from: try #require(object))
    }

    /// Round-trips the data section of a backup file through the production models (written with CanonicalJSON, read with JSONDecoder).
    private static func roundTrip(_ data: BackupData) throws -> BackupData {
        try JSONDecoder().decode(BackupData.self, from: CanonicalJSON.encode(data))
    }

    private static func backupData(json: [String: Any]) throws -> BackupData {
        var object = json
        object["providers"] = []
        object["conversations"] = []
        return try decode(BackupData.self, from: object)
    }

    private static func sorted(_ items: [MemoryItem]) -> [MemoryItem] {
        items.sorted { $0.id < $1.id }
    }

    // MARK: Cases

    @Test func roundTripReplace() async throws {
        let source = try Device()
        let kept = try source.repository.create(content: "Lives in Berlin")
        _ = try source.repository.create(kind: .instruction, content: "Answer briefly", pinned: true)
        let removed = try source.repository.create(content: "Old project")
        _ = try source.repository.remove(id: removed.id)

        let section = try #require(try BackupService.backupMemorySection(store: source.store))
        let exported = try Self.roundTrip(BackupData(
            providers: [], conversations: [], preferences: nil, lastUsedModelRef: nil,
            memorySchemaVersion: section.memorySchemaVersion, memoryItems: section.memoryItems
        ))
        #expect(exported.memorySchemaVersion == MemoryItems.schemaVersion)
        #expect(exported.memoryItems?.contains { $0.id == removed.id && $0.status == .deleted } == true)

        let target = try Device(uid: "u1", deviceId: "device-b")
        let stale = try target.repository.create(content: "Only on target")
        target.writes = 0
        target.wakeups = 0

        let changed = try await target.repository.importBackup(BackupService.memoryBackupInput(exported), mode: .replace)
        #expect(changed > 0)
        let restored = target.repository.allItems()
        #expect(Self.sorted(restored.filter { $0.id != stale.id }) == Self.sorted(source.repository.allItems()))
        #expect(restored.first { $0.id == stale.id }?.status == .deleted)
        #expect(restored.allSatisfy { target.repository.syncState(id: $0.id) == .pending })
        #expect(target.wakeups == 1)

        // Dual-write after import: the legacy fields are compiled from the backup items
        target.repository.dualWriteLegacy()
        #expect(target.writes == 1)
        #expect(target.preferences.memoryText.contains(kept.content))
        #expect(!target.preferences.memoryText.contains("Only on target"))
    }

    @Test func replaceTombstonesLocalOnlyItems() async throws {
        let fixture = try Self.backupCase("replace_tombstones_local_items_missing_from_backup")
        let input = try #require(fixture["input"] as? [String: Any])
        let expected = try #require(fixture["expected"] as? [String: Any])
        let device = try Device(deviceId: "device-z")
        let local = try Self.items(input["local"])
        try device.store.upsert(local, syncState: .synced)

        let backup = try Self.roundTrip(Self.backupData(json: try #require(input["backup"] as? [String: Any])))
        let changed = try await device.repository.importBackup(BackupService.memoryBackupInput(backup), mode: .replace)

        let after = device.repository.allItems()
        let byId = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        let expectedItems = try Self.items(expected["items"])
        let tombstonedIds = try #require(expected["tombstonedIds"] as? [String])
        // The backup items land as a whole and are pending
        for item in expectedItems {
            #expect(byId[item.id] == item)
            #expect(device.repository.syncState(id: item.id) == .pending)
        }
        // Alive locally but absent from the backup: a tombstone with a new mutationId, this device's deviceId and deletedAt filled in, pending
        for id in tombstonedIds {
            let original = try #require(local.first { $0.id == id })
            let tombstone = try #require(byId[id])
            #expect(tombstone.status == .deleted)
            #expect(tombstone.mutationId != original.mutationId)
            #expect(tombstone.deviceId == "device-z")
            #expect(tombstone.deletedAt != nil)
            #expect(device.repository.syncState(id: id) == .pending)
        }
        // Tombstoned locally but absent from the backup: kept as is, not pushed again
        let keptIds = Set(expectedItems.map(\.id)).union(tombstonedIds)
        let untouched = local.filter { !keptIds.contains($0.id) }
        #expect(!untouched.isEmpty)
        for item in untouched {
            #expect(byId[item.id] == item)
            #expect(device.repository.syncState(id: item.id) == .synced)
        }
        #expect(after.count == expectedItems.count + tombstonedIds.count + untouched.count)
        #expect(changed == expectedItems.count + tombstonedIds.count)
        #expect(device.wakeups == 1)
    }

    @Test func mergeKeepsNewerAndTombstones() async throws {
        let fixture = try Self.backupCase("merge_keeps_newer_and_tombstones")
        let input = try #require(fixture["input"] as? [String: Any])
        let expected = try #require(fixture["expected"] as? [String: Any])
        let device = try Device()
        let local = try Self.items(input["local"])
        try device.store.upsert(local, syncState: .synced)

        let backup = try Self.roundTrip(Self.backupData(json: try #require(input["backup"] as? [String: Any])))
        let changed = try await device.repository.importBackup(BackupService.memoryBackupInput(backup), mode: .merge)

        let merged = MemoryItems.listOrder(device.repository.allItems())
        #expect(merged == (try Self.items(expected["items"])))
        // Items newer locally and tombstones stay untouched (still synced); items newer in the backup and ones missing locally are written and pending
        let tombstoneId = "20000000-0000-4000-8000-000000000002"
        #expect(merged.first { $0.id == tombstoneId }?.status == .deleted)
        #expect(device.repository.syncState(id: tombstoneId) == .synced)
        #expect(device.repository.syncState(id: "20000000-0000-4000-8000-000000000001") == .synced)
        #expect(device.repository.syncState(id: "20000000-0000-4000-8000-000000000003") == .pending)
        #expect(device.repository.syncState(id: "20000000-0000-4000-8000-000000000004") == .pending)
        #expect(changed == 2)
    }

    @Test func legacyBackupMigrates() async throws {
        let fixture = try Self.backupCase("legacy_backup_migrates_preferences")
        let input = try #require(fixture["input"] as? [String: Any])
        let expected = try #require(fixture["expected"] as? [String: Any])
        let legacy = try #require((input["backup"] as? [String: Any])?["preferences"] as? [String: Any])
        let device = try Device(
            uid: try #require(input["uid"] as? String), deviceId: try #require(input["deviceId"] as? String)
        )

        // Old backup: only the memory fields in preferences, no memoryItems section
        let backup = try Self.roundTrip(BackupData(
            providers: [], conversations: [],
            preferences: BackupPreferences(
                theme: "dark", language: "english",
                memoryText: legacy["memoryText"] as? String,
                memoryAntiForgetEnabled: legacy["antiForgetEnabled"] as? Bool,
                memoryAntiForgetText: legacy["antiForgetText"] as? String,
                memoryUpdatedAt: legacy["memoryUpdatedAt"] as? String
            ),
            lastUsedModelRef: nil
        ))
        #expect(backup.memoryItems == nil)

        let changed = try await device.repository.importBackup(BackupService.memoryBackupInput(backup), mode: .merge)
        #expect(changed == 2)
        #expect(Self.sorted(device.repository.allItems()) == Self.sorted(try Self.items(expected["items"])))

        // Import once more: create-if-absent, no duplicates and no changes
        #expect(try await device.repository.importBackup(BackupService.memoryBackupInput(backup), mode: .merge) == 0)
        #expect(device.repository.allItems().count == 2)
    }

    /// A local restricted item (kept on this device, never uploaded) replaced by a newer normal version through import: it lands as normal and is set pending for the next upload.
    @Test("restricted_to_normal_via_import")
    func restricted_to_normal_via_import() async throws {
        let device = try Device()
        let restricted = MemoryItem(
            id: MemoryItemRepository.newId(), kind: .fact, content: "Secret", sensitivity: .restricted,
            mutationId: MemoryItemRepository.newId(), deviceId: "device-a"
        )
        // For restricted items the sync engine only marks them synced and writes nothing remotely
        try device.store.upsert([restricted], syncState: .synced)

        var normal = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(restricted)) as? [String: Any]
        )
        normal["sensitivity"] = "normal"
        normal["revision"] = restricted.revision + 1
        normal["mutationId"] = MemoryItemRepository.newId()
        let backup = try Self.roundTrip(Self.backupData(json: ["memorySchemaVersion": 2, "memoryItems": [normal]]))
        let changed = try await device.repository.importBackup(BackupService.memoryBackupInput(backup), mode: .merge)

        #expect(changed == 1)
        let stored = try #require(device.repository.allItems().first { $0.id == restricted.id })
        #expect(stored.sensitivity == .normal)
        #expect(stored.content == "Secret")
        #expect(stored.status == .active)
        #expect(device.repository.syncState(id: restricted.id) == .pending)
        #expect(device.wakeups == 1)
    }

    @Test func importedItemsPending() async throws {
        let fixture = try Self.backupCase("merge_keeps_newer_and_tombstones")
        let input = try #require(fixture["input"] as? [String: Any])
        let device = try Device()
        try device.store.upsert(try Self.items(input["local"]), syncState: .synced)
        let before = device.repository.allItems()

        // Import new only: only ids missing locally are added, tombstones count as existing, and a higher revision in the backup does not overwrite
        let backup = try Self.roundTrip(Self.backupData(json: try #require(input["backup"] as? [String: Any])))
        let changed = try await device.repository.importBackup(BackupService.memoryBackupInput(backup), mode: .newOnly)

        #expect(changed == 1)
        let after = device.repository.allItems()
        let addedId = "20000000-0000-4000-8000-000000000004"
        #expect(Self.sorted(after.filter { $0.id != addedId }) == Self.sorted(before))
        #expect(device.repository.syncState(id: addedId) == .pending)
        #expect(after.first { $0.id == "20000000-0000-4000-8000-000000000002" }?.status == .deleted)
        #expect(device.wakeups == 1)

        device.repository.dualWriteLegacy()
        #expect(device.writes == 1)
        #expect(device.preferences.memoryText.contains("Only in backup"))
        #expect(device.preferences.memoryTextDigest == MemoryItems.sha256Hex(device.preferences.memoryText))
    }

    /// After importing a backup with a memoryItems section (in any mode), this account is marked as migrated.
    @Test func importWithSectionMarksMigrated() async throws {
        let section = try #require(try Self.backupCase("export_section")["expected"] as? [String: Any])
        let backup = try Self.roundTrip(Self.backupData(json: section))
        #expect(backup.memoryItems != nil)
        for mode in [MemoryBackupImportMode.newOnly, .merge, .replace] {
            let device = try Device(memoryText: "Legacy line")
            #expect(!device.repository.isMigrated)
            _ = try await device.repository.importBackup(BackupService.memoryBackupInput(backup), mode: mode)
            #expect(device.repository.isMigrated, "\(mode)")
        }
    }

    /// Alive memory items alone can be exported; tombstones alone still count as no data.
    @Test func exportWithOnlyMemoryItems() async throws {
        let uid = "backup-memory-only-\(UUID().uuidString)"
        let store = try #require(MemoryItemStore.forPartition(uid))
        let removed = MemoryItem(
            id: "30000000-0000-4000-8000-000000000001", kind: .fact, content: "Old project",
            mutationId: "mut-1", deviceId: "device-a", createdAt: "2026-01-01T00:00:00Z"
        )
        try store.upsert([
            MemoryItems.tombstone(removed, mutationId: "mut-2", deviceId: "device-a", deletedAt: "2026-01-02T00:00:00Z")
        ], syncState: .synced)

        func export() async throws -> Data {
            try await BackupService.exportBackup(
                providers: [],
                conversations: [],
                preferences: AppPreference(theme: .system, language: .english),
                lastUsedModelRef: nil,
                includeKeys: false,
                password: nil,
                imagePartitionUID: uid
            )
        }

        do {
            _ = try await export()
            Issue.record("Should report noDataToExport when there are only tombstones")
        } catch BackupError.noDataToExport {
        }

        let live = MemoryItem(
            id: "30000000-0000-4000-8000-000000000002", kind: .fact, content: "Lives in Berlin",
            mutationId: "mut-3", deviceId: "device-a", createdAt: "2026-01-01T00:00:00Z"
        )
        try store.upsert([live], syncState: .synced)
        let (parsed, _) = try BackupService.parseBackup(from: try await export())
        let exported = try #require(parsed.data.memoryItems)
        #expect(exported.contains { $0.id == live.id && $0.status == .active })
        #expect(exported.contains { $0.id == removed.id && $0.status == .deleted }, "Tombstones go into the section as usual")
        #expect(parsed.data.conversations.isEmpty)
    }

    @Test func crossEndBackupDecodes() async throws {
        let fixture = try Self.backupCase("export_section")
        let section = try #require(fixture["expected"] as? [String: Any])

        // A section exported by another platform is decoded through the production models, imported, then exported again
        let incoming = try Self.roundTrip(Self.backupData(json: section))
        let device = try Device()
        _ = try await device.repository.importBackup(BackupService.memoryBackupInput(incoming), mode: .replace)
        let exported = try #require(try BackupService.backupMemorySection(store: device.store))
        let encoded = try CanonicalJSON.encode(BackupData(
            providers: [], conversations: [], preferences: nil, lastUsedModelRef: nil,
            memorySchemaVersion: exported.memorySchemaVersion, memoryItems: exported.memoryItems
        ))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["memorySchemaVersion"] as? Int == section["memorySchemaVersion"] as? Int)
        let actualItems = try #require(object["memoryItems"] as? [[String: Any]])
        let expectedItems = try #require(section["memoryItems"] as? [[String: Any]])
        #expect(actualItems.count == expectedItems.count)
        for (actual, expected) in zip(actualItems, expectedItems) {
            #expect(Set(actual.keys) == Set(expected.keys))
            for (key, value) in expected {
                #expect(NSDictionary(dictionary: [key: actual[key] ?? NSNull()]) == NSDictionary(dictionary: [key: value]), "\(key)")
            }
        }
    }
}
