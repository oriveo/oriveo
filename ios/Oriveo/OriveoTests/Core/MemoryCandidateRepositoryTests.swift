import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The memory_candidate table (v39) and the candidate repository's generate / accept / reject / pending.
@Suite("Memory candidate repository v39", .serialized)
@MainActor
struct MemoryCandidateRepositoryTests {

    /// One partition: a standalone database (temporary directory) plus in-memory preferences; the item repository and candidate repository share the database, and the counts of dual writes and change notifications are recorded.
    /// When partition is true no temporary database is used; the partition database for that uid is opened through DatabaseManager (the same forPartition path as AppState).
    @MainActor
    final class Device {
        let database: McpTestDatabase?
        var preferences: AppPreference
        var legacyWrites = 0
        var localChanges = 0
        var items: MemoryItemRepository!
        var candidates: MemoryCandidateRepository!

        init(uid: String, partition: Bool = false) throws {
            database = partition ? nil : try McpTestDatabase.make()
            preferences = AppPreference(
                theme: .dark,
                language: .system,
                memoryText: "",
                memoryAntiForgetEnabled: false,
                memoryAntiForgetText: "",
                memoryUpdatedAt: Date(timeIntervalSince1970: 1_760_000_000),
                memoryTextDigest: nil
            )
            let bridge = MemoryLegacyPrefsBridge(
                read: { [unowned self] in self.preferences.memoryLegacyPrefs },
                write: { [unowned self] compiled in
                    self.legacyWrites += 1
                    self.preferences = self.preferences.applyingMemoryLegacy(compiled, now: Date())
                }
            )
            if let database {
                items = MemoryItemRepository(
                    uid: uid,
                    store: MemoryItemStore(dbPool: database.pool),
                    bridge: bridge,
                    deviceId: "device-a",
                    migrationScope: "memory-candidates-test-\(UUID().uuidString)"
                )
                items.onLocalChange = { [unowned self] in self.localChanges += 1 }
                candidates = MemoryCandidateRepository(
                    store: MemoryCandidateStore(dbPool: database.pool),
                    items: items
                )
            } else {
                items = try #require(MemoryItemRepository.forPartition(uid, bridge: bridge))
                items.onLocalChange = { [unowned self] in self.localChanges += 1 }
                candidates = try #require(MemoryCandidateRepository.forPartition(uid, items: items))
            }
        }

        /// Creates another candidate repository instance on the same partition (AppState creates a new one on every call).
        func twinCandidates() throws -> MemoryCandidateRepository {
            let pool = try #require(database).pool
            return MemoryCandidateRepository(store: MemoryCandidateStore(dbPool: pool), items: items)
        }

        func generate(
            _ text: String,
            messageId: String = MemoryCandidateRepositoryTests.messageA,
            folderId: String? = nil,
            useMemory: Bool = true,
            nowMs: Int64 = MemoryCandidateRepositoryTests.now
        ) async throws -> MemoryCandidate? {
            try await candidates.generate(
                text: text,
                messageId: messageId,
                conversationId: MemoryCandidateRepositoryTests.conversation,
                folderId: folderId,
                useMemory: useMemory,
                nowMs: nowMs
            )
        }

        /// All candidate rows in the database (without a sweep).
        func storedRows() throws -> [MemoryCandidate] {
            try candidates.store.all()
        }
    }

    nonisolated static let conversation = "3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d"
    nonisolated static let folder = "8a7b6c5d-4e3f-4a2b-8c1d-0e9f8a7b6c5d"
    nonisolated static let messageA = "0b1c2d3e-4f50-4617-8899-aabbccddeeff"
    nonisolated static let messageB = "1c2d3e4f-5061-4728-99aa-bbccddeeff00"
    nonisolated static let messageC = "2d3e4f50-6172-4839-aabb-ccddeeff0011"
    nonisolated static let messageD = "3e4f5061-7283-494a-bbcc-ddeeff001122"
    /// 2026-10-16T08:00:00.123Z
    nonisolated static let now: Int64 = 1_792_137_600_123
    nonisolated static let ttl: Int64 = 2_592_000_000

    private static let explicitText = "\u{8BB0}\u{4F4F}\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}"
    private static let implicitText = "\u{4EE5}\u{540E}\u{6240}\u{6709}\u{5BF9}\u{8BDD}\u{90FD}\u{7528}\u{7B80}\u{4F53}\u{4E2D}\u{6587}\u{56DE}\u{590D}\u{6211}"
    private static let folderMarkerText = "\u{8BB0}\u{4F4F}\u{FF0C}\u{8FD9}\u{4E2A}\u{9879}\u{76EE}\u{91CC}\u{7684}\u{4EE3}\u{7801}\u{90FD}\u{7528} Kotlin \u{5199}"
    private static let typeScriptText = "Remember that I use TypeScript"

    @Test func generate_creates_pending_for_explicit_remember() async throws {
        let device = try Device(uid: "u1")
        try await #require(device.database).pool.read { (db: Database) throws -> Void in
            #expect(try db.tableExists(MemoryCandidateStore.table))
            #expect(try db.columns(in: MemoryCandidateStore.table).map(\.name).sorted() == ["id", "payload", "status"])
        }

        let candidate = try #require(try await device.generate(Self.explicitText))

        #expect(candidate.status == .pending)
        #expect(candidate.content == "\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}")
        #expect(candidate.proposedKind == .preference)
        #expect(candidate.scope == .global)
        #expect(candidate.confidence == 1)
        #expect(candidate.source.conversationId == Self.conversation)
        #expect(candidate.source.messageIds == [Self.messageA])
        #expect(candidate.source.observedAtMs == Self.now)
        #expect(candidate.createdAtMs == Self.now)
        #expect(candidate.expiresAtMs == Self.now + Self.ttl)
        #expect(try device.storedRows() == [candidate])
        #expect(try await device.candidates.pending(nowMs: Self.now + 1) == [candidate])
        // Candidates do not touch the item table
        #expect(device.items.allItems().isEmpty)
        #expect(device.localChanges == 0)
    }

    @Test func generate_skips_no_suggestion() async throws {
        let device = try Device(uid: "u1")

        #expect(try await device.generate("\u{8BB0}\u{4F4F}\u{4E86}") == nil)
        #expect(try await device.generate("From now on, keep answers concise", messageId: Self.messageB) == nil)
        #expect(try await device.generate("\u{8BB0}\u{4F4F}\u{6211}\u{7684}\u{5BC6}\u{7801}\u{662F} hunter2", messageId: Self.messageC) == nil)

        #expect(try device.storedRows().isEmpty)
    }

    @Test func generate_skips_when_use_memory_off() async throws {
        let device = try Device(uid: "u1")

        #expect(try await device.generate(Self.explicitText, useMemory: false) == nil)

        #expect(try device.storedRows().isEmpty)
        // The same sentence is generated as usual while memory is on
        #expect(try await device.generate(Self.explicitText) != nil)
    }

    /// Clears only the partition keys this test wrote and leaves the host's other preferences alone.
    private static func removeAutoSuggestPref(uid: String) {
        UserDefaults.standard.removeObject(forKey: "oriveo.preferences.memoryAutoSuggestEnabled.\(uid)")
    }

    @Test func auto_suggest_pref_defaults_on_and_persists_per_account() throws {
        let uidA = "memory-auto-suggest-a-\(UUID().uuidString)"
        let uidB = "memory-auto-suggest-b-\(UUID().uuidString)"
        defer {
            Self.removeAutoSuggestPref(uid: uidA)
            Self.removeAutoSuggestPref(uid: uidB)
        }
        let accountA = try Device(uid: uidA)
        let accountB = try Device(uid: uidB)

        #expect(accountA.candidates.autoSuggestEnabled())
        #expect(accountB.candidates.autoSuggestEnabled())

        accountA.candidates.setAutoSuggestEnabled(false)

        #expect(!accountA.candidates.autoSuggestEnabled())
        // Another account is unaffected
        #expect(accountB.candidates.autoSuggestEnabled())
        // A repository instance newly created on the same partition reads the same preference (AppState creates a new one each time)
        #expect(try !accountA.twinCandidates().autoSuggestEnabled())
        #expect(!AppPreferencesStore.memoryAutoSuggestEnabled(uid: uidA))

        accountA.candidates.setAutoSuggestEnabled(true)
        #expect(accountA.candidates.autoSuggestEnabled())
    }

    @Test func generate_skips_implicit_when_auto_suggest_off() async throws {
        let uid = "memory-auto-suggest-\(UUID().uuidString)"
        defer { Self.removeAutoSuggestPref(uid: uid) }
        let device = try Device(uid: uid)
        // A pending item generated while the switch was on is not deleted after the switch is turned off
        let earlier = try #require(try await device.generate(Self.typeScriptText, messageId: Self.messageD))

        device.candidates.setAutoSuggestEnabled(false)

        #expect(try await device.generate(Self.implicitText, messageId: Self.messageB, folderId: Self.folder) == nil)
        // An explicit "remember" still creates a pending item
        let explicit = try #require(try await device.generate(Self.explicitText))
        #expect(explicit.status == .pending)
        #expect(explicit.content == "\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}")
        let rows = try device.storedRows()
        #expect(Set(rows.map(\.id)) == [earlier.id, explicit.id])
        #expect(rows.allSatisfy { $0.status == .pending })
        #expect(rows.first { $0.id == explicit.id } == explicit)

        // After turning it on, the same implicit sentence is generated as usual
        device.candidates.setAutoSuggestEnabled(true)
        let implicit = try #require(try await device.generate(Self.implicitText, messageId: Self.messageC, folderId: Self.folder))
        #expect(try device.storedRows().contains(implicit))
    }

    @Test func generate_skips_duplicate_active() async throws {
        let device = try Device(uid: "u1")
        let existing = try await device.items.create(kind: .fact, content: "  i  use   TYPESCRIPT ")

        #expect(try await device.generate(Self.typeScriptText) == nil)

        // A paused item also counts as existing
        try await device.items.setStatus(id: existing.id, status: .paused)
        #expect(try await device.generate(Self.typeScriptText, messageId: Self.messageB) == nil)
        #expect(try device.storedRows().isEmpty)

        // Once deleted it no longer counts
        try await device.items.remove(id: existing.id)
        let candidate = try #require(try await device.generate(Self.typeScriptText, messageId: Self.messageC))
        #expect(candidate.content == "I use TypeScript")
    }

    @Test func generate_same_message_idempotent() async throws {
        let device = try Device(uid: "u1")

        let first = try #require(try await device.generate(Self.explicitText))
        let again = try await device.generate(Self.explicitText, nowMs: Self.now + 1_000)

        #expect(again == nil)
        #expect(try device.storedRows() == [first])
        // Another message says the same sentence: with one already pending, it is not duplicated
        #expect(try await device.generate(Self.explicitText, messageId: Self.messageB, nowMs: Self.now + 2_000) == nil)
        #expect(try device.storedRows() == [first])
    }

    @Test func generate_in_folder_scopes_folder() async throws {
        let device = try Device(uid: "u1")

        let explicit = try #require(try await device.generate(Self.explicitText, folderId: Self.folder))
        #expect(explicit.scope == MemoryScope(type: .folder, id: Self.folder))

        let marker = try #require(try await device.generate(Self.folderMarkerText, messageId: Self.messageB, folderId: Self.folder))
        #expect(marker.scope == MemoryScope(type: .folder, id: Self.folder))

        // "From now on in all conversations" is global and does not follow the folder
        let global = try #require(try await device.generate(Self.implicitText, messageId: Self.messageC, folderId: Self.folder))
        #expect(global.scope == .global)

        // Outside a folder, "this project" falls back to this conversation
        let other = try Device(uid: "u1")
        let conversationScoped = try #require(try await other.generate(Self.folderMarkerText))
        #expect(conversationScoped.scope == MemoryScope(type: .conversation, id: Self.conversation))
    }

    @Test func reject_keeps_fingerprint_only_and_blocks_regeneration() async throws {
        let device = try Device(uid: "u1")
        let candidate = try #require(try await device.generate(Self.explicitText))
        let rejectedAt = Self.now + 1_000

        let rejected = try await device.candidates.reject(id: candidate.id, nowMs: rejectedAt)

        #expect(rejected.status == .rejected)
        #expect(rejected.content.isEmpty)
        #expect(rejected.source.conversationId == nil)
        #expect(rejected.source.messageIds.isEmpty)
        #expect(rejected.source.observedAtMs == nil)
        #expect(rejected.fingerprint == candidate.fingerprint)
        #expect(rejected.resolvedAtMs == rejectedAt)
        #expect(rejected.expiresAtMs == rejectedAt + Self.ttl)
        #expect(try device.storedRows() == [rejected])
        #expect(try await device.candidates.pending(nowMs: rejectedAt + 1).isEmpty)

        // During the rejection period, the same sentence in another message is not proposed again
        #expect(try await device.generate(Self.explicitText, messageId: Self.messageB, nowMs: rejectedAt + 2) == nil)
        await #expect(throws: MemoryCandidateFailure(error: .notPending)) {
            try await device.candidates.reject(id: candidate.id, nowMs: rejectedAt + 3)
        }
        await #expect(throws: MemoryCandidateFailure(error: .notPending)) {
            try await device.candidates.reject(id: "missing", nowMs: rejectedAt + 3)
        }

        // After the rejection expires the row is swept and it can be proposed again
        let later = rejectedAt + Self.ttl
        #expect(try await device.candidates.pending(nowMs: later).isEmpty)
        #expect(try device.storedRows().isEmpty)
        #expect(try await device.generate(Self.explicitText, messageId: Self.messageB, nowMs: later) != nil)
    }

    @Test func accept_creates_item_and_removes_candidate() async throws {
        let device = try Device(uid: "u1")
        let implicit = try #require(try await device.generate(Self.implicitText, folderId: Self.folder))
        let scoped = try #require(try await device.generate(Self.explicitText, messageId: Self.messageB, folderId: Self.folder))

        let returned = try await device.candidates.accept(id: implicit.id, edit: nil, nowMs: Self.now + 5_000)

        let item = try #require(device.items.allItems().first { $0.id == returned.id })
        #expect(item == returned)
        #expect(item.id != implicit.id)
        #expect(item.content == "\u{4EE5}\u{540E}\u{6240}\u{6709}\u{5BF9}\u{8BDD}\u{90FD}\u{7528}\u{7B80}\u{4F53}\u{4E2D}\u{6587}\u{56DE}\u{590D}\u{6211}")
        #expect(item.kind == .instruction)
        #expect(item.layer == .semantic)
        #expect(item.status == .active)
        #expect(item.scope == .global)
        #expect(item.sensitivity == .normal)
        #expect(item.confidence == 0.8)
        #expect(item.source.type == .conversation)
        #expect(item.source.conversationId == Self.conversation)
        #expect(item.source.messageIds == [Self.messageA])
        #expect(item.source.observedAt == "2026-10-16T08:00:00Z")
        #expect(item.deviceId == "device-a")
        #expect(device.items.syncState(id: item.id) == .pending)
        #expect(device.localChanges == 1)
        // The candidate row is deleted and no accepted record remains
        #expect(try device.storedRows() == [scoped])
        await #expect(throws: MemoryCandidateFailure(error: .notPending)) {
            try await device.candidates.accept(id: implicit.id, edit: nil, nowMs: Self.now + 6_000)
        }

        let folderItem = try await device.candidates.accept(id: scoped.id, edit: nil, nowMs: Self.now + 7_000)
        let storedFolderItem = try #require(device.items.allItems().first { $0.id == folderItem.id })
        #expect(storedFolderItem.scope == MemoryScope(type: .folder, id: Self.folder))
        #expect(storedFolderItem.confidence == 1)
        #expect(storedFolderItem.source.messageIds == [Self.messageB])
        #expect(device.items.syncState(id: storedFolderItem.id) == .pending)
        #expect(try device.storedRows().isEmpty)
        #expect(try await device.candidates.pending(nowMs: Self.now + 8_000).isEmpty)
    }

    @Test func accept_edited_content_confidence_one() async throws {
        let device = try Device(uid: "u1")
        let candidate = try #require(try await device.generate(Self.implicitText))
        #expect(candidate.confidence == 0.8)

        // Edited to blank: an error occurs and the candidate stays pending
        await #expect(throws: MemoryCandidateFailure(error: .empty)) {
            try await device.candidates.accept(id: candidate.id, edit: MemoryCandidateEdit(content: "   "), nowMs: Self.now + 1)
        }
        #expect(try device.storedRows() == [candidate])

        let returned = try await device.candidates.accept(
            id: candidate.id,
            edit: MemoryCandidateEdit(content: "  \u{4EE5}\u{540E}\u{90FD}\u{7528}\u{7B80}\u{4F53}\u{4E2D}\u{6587}\u{56DE}\u{590D}  ", kind: .preference),
            nowMs: Self.now + 2
        )

        let item = try #require(device.items.allItems().first { $0.id == returned.id })
        #expect(item.content == "\u{4EE5}\u{540E}\u{90FD}\u{7528}\u{7B80}\u{4F53}\u{4E2D}\u{6587}\u{56DE}\u{590D}")
        #expect(item.kind == .preference)
        #expect(item.confidence == 1)
        #expect(try device.storedRows().isEmpty)
    }

    @Test func accept_concurrent_same_id_creates_one_item() async throws {
        let device = try Device(uid: "u1")
        let twin = try device.twinCandidates()
        let candidate = try #require(try await device.generate(Self.explicitText))

        let first = Task { try await device.candidates.accept(id: candidate.id, edit: nil, nowMs: Self.now + 1) }
        let second = Task { try await twin.accept(id: candidate.id, edit: nil, nowMs: Self.now + 1) }
        let outcomes = [await first.result, await second.result]

        let created = outcomes.compactMap { try? $0.get() }
        let failures = outcomes.compactMap { outcome -> MemoryCandidateFailure? in
            guard case .failure(let error) = outcome else { return nil }
            return error as? MemoryCandidateFailure
        }
        #expect(created.count == 1)
        #expect(failures == [MemoryCandidateFailure(error: .notPending)])
        #expect(device.items.allItems().map(\.id) == created.map(\.id))
        #expect(device.localChanges == 1)
        #expect(try device.storedRows().isEmpty)
    }

    @Test func accept_expired_errors_and_purges() async throws {
        let device = try Device(uid: "u1")
        let candidate = try #require(try await device.generate(Self.explicitText))

        await #expect(throws: MemoryCandidateFailure(error: .expired)) {
            try await device.candidates.accept(id: candidate.id, edit: nil, nowMs: candidate.expiresAtMs)
        }

        #expect(try device.storedRows().isEmpty)
        #expect(device.items.allItems().isEmpty)
        #expect(device.localChanges == 0)
        await #expect(throws: MemoryCandidateFailure(error: .notPending)) {
            try await device.candidates.accept(id: candidate.id, edit: nil, nowMs: candidate.expiresAtMs)
        }
    }

    /// Deleting the candidate fails (a database trigger blocks the delete): creating the item rolls back too, leaving no item and the candidate pending; after the block is lifted, confirming again yields exactly one item.
    @Test func accept_rolls_back_when_candidate_delete_fails() async throws {
        let device = try Device(uid: "u1")
        let pool = try #require(device.database).pool
        let candidate = try #require(try await device.generate(Self.explicitText))
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER block_candidate_delete BEFORE DELETE ON \(MemoryCandidateStore.table)
                BEGIN SELECT RAISE(ABORT, 'candidate delete blocked'); END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await device.candidates.accept(id: candidate.id, edit: nil, nowMs: Self.now + 1_000)
        }
        #expect(device.items.allItems().isEmpty)
        #expect(try device.items.store.all().isEmpty)
        #expect(try device.storedRows() == [candidate])
        #expect(try device.storedRows().first?.status == .pending)
        #expect(device.localChanges == 0)

        try await pool.write { db in try db.execute(sql: "DROP TRIGGER block_candidate_delete") }
        let item = try await device.candidates.accept(id: candidate.id, edit: nil, nowMs: Self.now + 2_000)
        #expect(device.items.allItems().map(\.id) == [item.id])
        #expect(try device.storedRows().isEmpty)
        #expect(device.localChanges == 1)
    }

    @Test func pending_sweeps_expired_and_superseded() async throws {
        let device = try Device(uid: "u1")
        let first = try #require(try await device.generate(Self.explicitText))
        let second = try #require(try await device.generate(Self.typeScriptText, messageId: Self.messageB, nowMs: Self.now + 10))
        let third = try #require(try await device.generate(Self.folderMarkerText, messageId: Self.messageC, nowMs: Self.now + 20))
        let fourth = try #require(try await device.generate(Self.implicitText, messageId: Self.messageD, nowMs: Self.now + 20))
        let latest = [third, fourth].sorted { $0.id < $1.id }

        // createdAtMs descending, ties by id ascending
        #expect(try await device.candidates.pending(nowMs: Self.now + 30) == latest + [second, first])

        // second's content already has an item (added elsewhere) -> superseded; first has expired -> expired; both rows are deleted
        try await device.items.create(kind: .fact, content: second.content)
        let swept = try await device.candidates.pending(nowMs: first.expiresAtMs)

        #expect(swept == latest)
        #expect(Set(try device.storedRows().map(\.id)) == Set(latest.map(\.id)))
    }

    @Test func sweep_purges_unreadable_rows() async throws {
        let device = try Device(uid: "u1")
        let pool = try #require(device.database).pool
        let candidate = try #require(try await device.generate(Self.explicitText))
        try await pool.write { (db: Database) throws -> Void in
            for (id, payload) in [("broken-json", "{not json"), ("broken-shape", "{}")] {
                try db.execute(
                    sql: "INSERT INTO \(MemoryCandidateStore.table) (id, status, payload) VALUES (?, ?, ?)",
                    arguments: [id, MemoryCandidateStatus.pending.rawValue, payload]
                )
            }
        }
        func storedIds() async throws -> [String] {
            try await pool.read { (db: Database) throws -> [String] in
                try String.fetchAll(db, sql: "SELECT id FROM \(MemoryCandidateStore.table) ORDER BY id ASC")
            }
        }
        #expect(try await storedIds() == ["broken-json", "broken-shape", candidate.id].sorted())

        #expect(try await device.candidates.pending(nowMs: Self.now + 1) == [candidate])

        #expect(try await storedIds() == [candidate.id])
    }

    @Test func candidates_partitioned_by_account() async throws {
        // Two accounts each go through forPartition: DatabaseManager opens a separate partition database per uid
        let accountA = try Device(uid: "memory-candidate-a-\(UUID().uuidString)", partition: true)
        let accountB = try Device(uid: "memory-candidate-b-\(UUID().uuidString)", partition: true)

        let candidate = try #require(try await accountA.generate(Self.explicitText))

        #expect(try await accountB.candidates.pending(nowMs: Self.now + 1).isEmpty)
        await #expect(throws: MemoryCandidateFailure(error: .notPending)) {
            try await accountB.candidates.reject(id: candidate.id, nowMs: Self.now + 1)
        }
        // It is absent from the other account's own records: the same sentence in the same message is generated as usual
        let other = try #require(try await accountB.generate(Self.explicitText))
        #expect(other.id == candidate.id)
        #expect(try await accountA.candidates.pending(nowMs: Self.now + 2) == [candidate])
    }

    @Test func no_candidate_becomes_active_without_accept() async throws {
        let device = try Device(uid: "u1")
        let kept = try #require(try await device.generate(Self.explicitText))
        let rejected = try #require(try await device.generate(Self.typeScriptText, messageId: Self.messageB))
        _ = try await device.generate(Self.implicitText, messageId: Self.messageC)

        _ = try await device.candidates.reject(id: rejected.id, nowMs: Self.now + 1)
        _ = try await device.candidates.pending(nowMs: Self.now + 2)
        _ = try await device.candidates.pending(nowMs: kept.expiresAtMs)

        #expect(device.items.allItems().isEmpty)
        #expect(device.localChanges == 0)
        #expect(device.legacyWrites == 0)
        #expect(device.preferences.memoryText == "")
    }

    // MARK: propose_memory

    private static func proposeArguments(
        _ proposition: String,
        kind: String = "preference",
        scope: String = "unspecified",
        quote: String
    ) throws -> String {
        let object: [String: Any] = ["proposition": proposition, "kind": kind, "scope": scope, "sourceQuote": quote]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func propose(
        _ device: Device,
        _ arguments: String,
        userText: String = MemoryCandidateRepositoryTests.explicitText,
        priorInTurn: Int = 0,
        messageId: String = MemoryCandidateRepositoryTests.messageA,
        folderId: String? = nil,
        nowMs: Int64 = MemoryCandidateRepositoryTests.now
    ) async throws -> MemoryCandidate? {
        try await device.candidates.propose(
            argumentsJSON: arguments,
            priorInTurn: priorInTurn,
            userText: userText,
            messageId: messageId,
            conversationId: Self.conversation,
            folderId: folderId,
            nowMs: nowMs
        ).candidate
    }

    @Test func propose_creates_pending_from_tool_call() async throws {
        let device = try Device(uid: "u1")
        let arguments = try Self.proposeArguments("\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}", quote: "\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}")

        let candidate = try #require(try await propose(device, arguments))

        #expect(candidate.status == .pending)
        #expect(candidate.content == "\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}")
        #expect(candidate.proposedKind == .preference)
        #expect(candidate.scope == .global)
        #expect(candidate.confidence == 0.8)
        #expect(candidate.source.messageIds == [Self.messageA])
        #expect(candidate.createdAtMs == Self.now)
        #expect(candidate.expiresAtMs == Self.now + Self.ttl)
        #expect(try device.storedRows() == [candidate])
        #expect(try await device.candidates.pending(nowMs: Self.now + 1) == [candidate])
        // Candidates do not touch the item table
        #expect(device.items.allItems().isEmpty)
        #expect(device.localChanges == 0)
    }

    @Test func propose_skips_write_nothing() async throws {
        let device = try Device(uid: "u1")
        let valid = try Self.proposeArguments("\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}", quote: "\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}")

        // The quote is not in this turn's user message
        #expect(try await propose(device, try Self.proposeArguments("\u{7528}\u{6237}\u{559C}\u{6B22}\u{6674}\u{5929}", quote: "\u{6211}\u{559C}\u{6B22}\u{6674}\u{5929}")) == nil)
        // The arguments cannot be parsed / the kind is unknown
        #expect(try await propose(device, "{\"proposition\": \"\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}\"") == nil)
        #expect(try await propose(device, try Self.proposeArguments("\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}", kind: "opinion", quote: "\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}")) == nil)
        // This turn has already used its 3 calls
        #expect(try await propose(device, valid, priorInTurn: 3) == nil)
        // The message contains a secret
        #expect(try await propose(device, valid, userText: "\u{8BB0}\u{4F4F}\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}\u{FF0C}\u{6211}\u{7684}\u{5BC6}\u{7801}\u{662F} hunter2") == nil)

        #expect(try device.storedRows().isEmpty)
        #expect(try await propose(device, valid, priorInTurn: 2) != nil)
    }

    @Test func propose_shares_storage_with_generate() async throws {
        let device = try Device(uid: "u1")
        let arguments = try Self.proposeArguments("\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}", quote: "\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}")

        // The same sentence in the same message: both paths collide on one id and no second row is written
        let generated = try #require(try await device.generate(Self.explicitText))
        #expect(try await propose(device, arguments, nowMs: Self.now + 1_000) == nil)
        #expect(try device.storedRows() == [generated])
        // Another message: with one already pending, it is not duplicated
        #expect(try await propose(device, arguments, messageId: Self.messageB, nowMs: Self.now + 2_000) == nil)

        // Not proposed again during the rejection period
        _ = try await device.candidates.reject(id: generated.id, nowMs: Self.now + 3_000)
        #expect(try await propose(device, arguments, messageId: Self.messageC, nowMs: Self.now + 4_000) == nil)
    }

    @Test func propose_skips_duplicate_active_and_scopes_folder() async throws {
        let device = try Device(uid: "u1")
        _ = try await device.items.create(kind: .fact, content: "  i  use   TYPESCRIPT ")
        let typeScript = try Self.proposeArguments("I use TypeScript", kind: "fact", quote: "I use TypeScript")

        #expect(try await propose(device, typeScript, userText: Self.typeScriptText) == nil)

        let arguments = try Self.proposeArguments("\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}", quote: "\u{6211}\u{504F}\u{597D}\u{7B80}\u{6D01}\u{56DE}\u{7B54}")
        let scoped = try #require(try await propose(device, arguments, folderId: Self.folder))
        #expect(scoped.scope == MemoryScope(type: .folder, id: Self.folder))
        #expect(try device.storedRows() == [scoped])
    }

    // MARK: propose_memory projections (the fixture projections match encodeTools of the four ToolAdapters on this platform)

    private static func proposeFixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/memory-propose.v3.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func propose_tool_projections_match_fixture() throws {
        let projections = try #require(try Self.proposeFixture()["projections"] as? [String: Any])
        let definition = try JSONDecoder().decode(ToolLoopToolDefinition.self, from: Data(MemoryPropose.toolJSON.utf8))
        let adapters: [(String, any ToolProtocolAdapter)] = [
            ("openai_chat", OpenAIChatToolAdapter()),
            ("openai_responses", OpenAIResponsesToolAdapter()),
            ("anthropic_messages", AnthropicToolAdapter()),
            ("gemini_generate", GeminiToolAdapter()),
        ]
        #expect(Set(projections.keys) == Set(adapters.map(\.0)))
        for (key, adapter) in adapters {
            let expected = try #require(projections[key] as? NSArray, "\(key)")
            let actual = try adapter.encodeTools([definition]) as NSArray
            #expect(actual.isEqual(expected), "\(key): \(actual)")
        }
    }
}
