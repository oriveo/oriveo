import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Persistence: v35_context_checkpoint creates the context_checkpoint table;
/// overwrite on save, keep 8 per conversation, latestValid verifies the digest and picks one by concurrency arbitration, invalidate removes the affected checkpoint and the ones after it.
@Suite("Context checkpoint persistence v35")
struct ContextCompactionStoreTests {

    private static let lastBeforeCheckpoint = "v34_context_stop_reason_ledger"

    private func history(_ count: Int) -> [ContextCheckpoint.CoveredMessage] {
        (0..<count).map { ContextCheckpoint.CoveredMessage(id: "m\($0)", text: "text \($0)") }
    }

    private func record(
        conversationId: String,
        coversTo: String,
        history: [ContextCheckpoint.CoveredMessage],
        createdAt: Int64,
        checkpointId: String? = nil,
        kind: ContextCheckpointRecord.Kind = .summary,
        summary: String? = "## Goal",
        digest: String? = nil
    ) -> ContextCheckpointRecord {
        let index = history.firstIndex { $0.id == coversTo } ?? (history.count - 1)
        return ContextCheckpointRecord(
            conversationId: conversationId,
            checkpointId: checkpointId ?? ContextCheckpoint.checkpointId(conversationId: conversationId, coversTo: coversTo),
            kind: kind,
            coversFrom: history.first?.id ?? coversTo,
            coversTo: coversTo,
            coversDigest: digest ?? ContextCheckpoint.coversDigest(Array(history[0...index])),
            messagesCovered: index + 1,
            userMessageIds: ["m0"],
            text: "<oriveo-context-checkpoint/>",
            summary: summary,
            language: summary == nil ? nil : "en",
            model: "gpt-x",
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: createdAt,
            cost: summary == nil ? nil : 0.0123
        )
    }

    @Test func migration_creates_checkpoint_table() throws {
        let database = try McpTestDatabase.make(upTo: Self.lastBeforeCheckpoint)
        defer { database.cleanUp() }
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        try database.pool.read { (db: Database) throws -> Void in
            #expect(try !db.tableExists("context_checkpoint"))
        }

        try database.migrateToLatest()

        try database.pool.read { (db: Database) throws -> Void in
            #expect(try db.tableExists("context_checkpoint"))
        }
        let store = ContextCompactionStore(dbPool: database.pool)
        let saved = record(conversationId: conversation, coversTo: "m2", history: history(4), createdAt: 10)
        try store.save(saved)
        #expect(try store.list(conversationId: conversation) == [saved])
    }

    /// deleteAll only deletes this conversation's checkpoints and returns their ids; contextCheckpointsDidChange is posted when anything is added or removed.
    @Test func delete_all_returns_ids_and_notifies() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let other = try database.insertConversation(messageCount: 0).conversation.uuidString
        let first = record(conversationId: conversation, coversTo: "m1", history: history(4), createdAt: 1)
        let second = record(conversationId: conversation, coversTo: "m2", history: history(4), createdAt: 2)
        let kept = record(conversationId: other, coversTo: "m1", history: history(4), createdAt: 3)
        let posted = NotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: .contextCheckpointsDidChange, object: nil, queue: nil
        ) { note in
            posted.append(note.userInfo?[ContextCompactionStore.conversationIdKey] as? String)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try store.save(first)
        try store.save(second)
        try store.save(kept)
        let removed = try store.deleteAll(conversationId: conversation)
        let none = try store.deleteAll(conversationId: conversation)

        #expect(removed == [first.checkpointId, second.checkpointId])
        #expect(none.isEmpty)
        #expect(try store.list(conversationId: conversation).isEmpty)
        #expect(try store.list(conversationId: other) == [kept])
        #expect(posted.values.filter { $0 == conversation }.count == 3)
        #expect(posted.values.filter { $0 == other }.count == 1)
    }

    @Test func save_and_list_roundtrip() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let summary = record(conversationId: conversation, coversTo: "m1", history: history(4), createdAt: 20)
        let fallback = record(
            conversationId: conversation, coversTo: "m2", history: history(4), createdAt: 10, kind: .fallback, summary: nil
        )
        try store.save(summary)
        try store.save(fallback)

        let listed = try store.list(conversationId: conversation)
        #expect(listed == [fallback, summary])
        #expect(listed[0].summary == nil)
        #expect(listed[0].language == nil)
        #expect(listed[0].cost == nil)
        #expect(listed[1].userMessageIds == ["m0"])
        let rawIds = try database.pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT userMessageIds FROM context_checkpoint WHERE checkpointId = ?", arguments: [summary.checkpointId]
            )
        }
        #expect(rawIds == "[\"m0\"]")
    }

    @Test func overwrite_same_checkpoint_id() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let first = record(conversationId: conversation, coversTo: "m1", history: history(3), createdAt: 1, kind: .fallback, summary: nil)
        var second = record(conversationId: conversation, coversTo: "m1", history: history(3), createdAt: 2)
        second.text = "replaced"
        #expect(first.checkpointId == second.checkpointId)

        try store.save(first)
        try store.save(second)

        #expect(try store.list(conversationId: conversation) == [second])
    }

    @Test func trim_keeps_newest_8() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let other = try database.insertConversation(messageCount: 0).conversation.uuidString
        let messages = history(12)
        try store.save(record(conversationId: other, coversTo: "m0", history: messages, createdAt: 0))
        // The write order differs from the createdAt order, to confirm that the oldest createdAt is trimmed rather than the earliest written.
        for i in [5, 0, 9, 3, 1, 7, 2, 8, 4, 6] {
            try store.save(record(conversationId: conversation, coversTo: "m\(i)", history: messages, createdAt: Int64(100 + i)))
        }

        let kept = try store.list(conversationId: conversation)
        #expect(kept.count == ContextCompactionStore.capacityPerConversation)
        #expect(kept.map(\.createdAt) == (2...9).map { Int64(100 + $0) })
        #expect(try store.list(conversationId: other).count == 1)
    }

    @Test func latest_valid_skips_stale() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let messages = history(6)
        let valid = record(conversationId: conversation, coversTo: "m1", history: messages, createdAt: 1)
        // Entries whose digest does not match (the covered text has changed) or whose coversTo is not in the history are skipped.
        let staleDigest = record(conversationId: conversation, coversTo: "m3", history: messages, createdAt: 2, digest: "deadbeef")
        let missing = record(conversationId: conversation, coversTo: "gone", history: messages, createdAt: 3)
        try store.save(valid)
        try store.save(staleDigest)
        try store.save(missing)

        #expect(try store.latestValid(conversationId: conversation, history: messages) == valid)
        // Skipped, not deleted.
        #expect(try store.list(conversationId: conversation).count == 3)

        var edited = messages
        edited[0].text = "edited"
        #expect(try store.latestValid(conversationId: conversation, history: edited) == nil)
        #expect(try store.latestValid(conversationId: conversation, history: []) == nil)
    }

    @Test func latest_valid_prefers_later_covers_to() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let messages = history(6)
        let earlier = record(conversationId: conversation, coversTo: "m1", history: messages, createdAt: 50)
        let later = record(conversationId: conversation, coversTo: "m3", history: messages, createdAt: 10)
        try store.save(earlier)
        try store.save(later)
        #expect(try store.latestValid(conversationId: conversation, history: messages) == later)

        // Same coversTo: the earlier createdAt wins; if still tied, the smaller checkpointId in lexicographic order.
        let tieOld = record(conversationId: conversation, coversTo: "m4", history: messages, createdAt: 5, checkpointId: "b")
        let tieNew = record(conversationId: conversation, coversTo: "m4", history: messages, createdAt: 6, checkpointId: "a")
        try store.save(tieNew)
        try store.save(tieOld)
        #expect(try store.latestValid(conversationId: conversation, history: messages)?.checkpointId == "b")
        let tieSame = record(conversationId: conversation, coversTo: "m4", history: messages, createdAt: 5, checkpointId: "0")
        try store.save(tieSame)
        #expect(try store.latestValid(conversationId: conversation, history: messages)?.checkpointId == "0")
    }

    @Test func invalidate_drops_covering_and_later() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let messages = history(8)
        let ids = messages.map(\.id)
        let atOne = record(conversationId: conversation, coversTo: "m1", history: messages, createdAt: 1)
        let atThree = record(conversationId: conversation, coversTo: "m3", history: messages, createdAt: 2)
        let atFive = record(conversationId: conversation, coversTo: "m5", history: messages, createdAt: 3)
        let orphan = record(conversationId: conversation, coversTo: "gone", history: messages, createdAt: 4)
        for item in [atOne, atThree, atFive, orphan] { try store.save(item) }

        // The affected set takes the smallest index m3: everything whose coversTo is at m3 or later is deleted, and entries whose coversTo is not in the history stay untouched.
        let removed = try store.invalidate(conversationId: conversation, historyIds: ids, affectedIds: ["m6", "m3", "unknown"])

        #expect(Set(removed) == Set([atThree.checkpointId, atFive.checkpointId]))
        #expect(Set(try store.list(conversationId: conversation).map(\.checkpointId)) == Set([atOne.checkpointId, orphan.checkpointId]))
    }

    @Test func invalidate_keeps_before_branch() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let messages = history(8)
        let ids = messages.map(\.id)
        let atTwo = record(conversationId: conversation, coversTo: "m2", history: messages, createdAt: 1)
        let atFour = record(conversationId: conversation, coversTo: "m4", history: messages, createdAt: 2)
        try store.save(atTwo)
        try store.save(atFour)

        #expect(try store.invalidate(conversationId: conversation, historyIds: ids, affectedIds: ["m5", "m7"]).isEmpty)
        #expect(try store.invalidate(conversationId: conversation, historyIds: ids, affectedIds: ["unknown"]).isEmpty)
        #expect(try store.invalidate(conversationId: conversation, historyIds: ids, affectedIds: []).isEmpty)
        #expect(try store.list(conversationId: conversation) == [atTwo, atFour])
    }

    @Test func delete_conversation_cascades() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let doomed = try database.insertConversation(messageCount: 0).conversation.uuidString
        let survivor = try database.insertConversation(messageCount: 0).conversation.uuidString
        let messages = history(4)
        try store.save(record(conversationId: doomed, coversTo: "m1", history: messages, createdAt: 1))
        try store.save(record(conversationId: doomed, coversTo: "m2", history: messages, createdAt: 2))
        let kept = record(conversationId: survivor, coversTo: "m1", history: messages, createdAt: 3)
        try store.save(kept)

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [doomed])
        }

        let rows = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM context_checkpoint WHERE conversationId = ?", arguments: [doomed])
        }
        #expect(rows == 0)
        #expect(try store.list(conversationId: survivor) == [kept])
    }

    /// Edit-and-resend takes the pre-edit history before truncating: checkpoints covering the truncated part are deleted and earlier ones are kept.
    @MainActor
    @Test func edit_resend_invalidates_covering_checkpoints() async throws {
        let ids = (0..<4).map { _ in UUID() }
        let roles: [ChatRole] = [.user, .assistant, .user, .assistant]
        let state = AppState(seedDemoData: false, sessionUID: "context-checkpoint-\(UUID().uuidString)")
        let conversation = TestFactories.makeConversation(
            messages: zip(ids, roles).map { TestFactories.makeMessage(id: $0, role: $1, text: "text") }
        )
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let messages = ids.map { ContextCheckpoint.CoveredMessage(id: $0.uuidString, text: "text") }
        let conversationId = conversation.id.uuidString
        let kept = record(conversationId: conversationId, coversTo: ids[1].uuidString, history: messages, createdAt: 1)
        let dropped = record(conversationId: conversationId, coversTo: ids[3].uuidString, history: messages, createdAt: 2)
        try store.save(kept)
        try store.save(dropped)

        _ = state.beginEditingUserMessage(messageID: ids[2], in: conversation.id)
        // The invalidation write is queued off the main thread; wait for it to land before asserting.
        await state.waitForCheckpointInvalidations()

        #expect(try store.list(conversationId: conversationId) == [kept])
    }

    /// Editing from an assistant bubble: truncate to before its prompting user message, and delete the checkpoints covering the truncated part.
    @MainActor
    @Test func edit_from_assistant_invalidates_checkpoints() async throws {
        let fixture = try makeTruncationFixture(providerSession: nil)
        _ = fixture.state.beginEditingPromptingMessage(for: fixture.ids[3], in: fixture.conversationID)
        await fixture.state.waitForCheckpointInvalidations()
        #expect(try fixture.store.list(conversationId: fixture.conversationID.uuidString) == [fixture.kept])
    }

    /// Retrying a non-failed message falls back to regenerate: the replaced assistant message and the checkpoints after it are deleted.
    @MainActor
    @Test func retry_fallback_regenerate_invalidates_checkpoints() async throws {
        let fixture = try makeTruncationFixture(providerSession: Self.stubSession())
        await fixture.state.retryMessage(messageID: fixture.ids[3], in: fixture.conversationID)
        let remaining = fixture.state.conversations.first { $0.id == fixture.conversationID }?.messages.map(\.id) ?? []
        #expect(!remaining.contains(fixture.ids[3]))
        #expect(try fixture.store.list(conversationId: fixture.conversationID.uuidString) == [fixture.kept])
    }

    /// Continuing an empty interrupted message falls back to regenerate: the replaced assistant message and the checkpoints after it are deleted.
    @MainActor
    @Test func continue_fallback_regenerate_invalidates_checkpoints() async throws {
        let fixture = try makeTruncationFixture(providerSession: Self.stubSession(), lastAssistantText: "")
        await fixture.state.continueMessage(messageID: fixture.ids[3], in: fixture.conversationID)
        await fixture.state.waitForCheckpointInvalidations()
        let remaining = fixture.state.conversations.first { $0.id == fixture.conversationID }?.messages.map(\.id) ?? []
        #expect(!remaining.contains(fixture.ids[3]))
        #expect(try fixture.store.list(conversationId: fixture.conversationID.uuidString) == [fixture.kept])
    }

    private struct TruncationFixture {
        let state: AppState
        let conversationID: UUID
        let ids: [UUID]
        let store: ContextCompactionStore
        let kept: ContextCheckpointRecord
    }

    /// [user, assistant, user, assistant]: kept covers up to ids[1], and the other covers up to ids[3].
    @MainActor
    private func makeTruncationFixture(
        providerSession: URLSession?,
        lastAssistantText: String = "text"
    ) throws -> TruncationFixture {
        let ids = (0..<4).map { _ in UUID() }
        let roles: [ChatRole] = [.user, .assistant, .user, .assistant]
        let providerID = UUID()
        let modelID = "relay-model"
        let model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        let provider = Provider(
            id: providerID,
            kind: .relay,
            status: .connected,
            models: [model],
            catalogModels: [],
            apiKey: "relay-key",
            apiKeyPreview: "...key",
            baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        let sessionUID = "context-checkpoint-\(UUID().uuidString)"
        let state = providerSession.map {
            AppState(seedDemoData: false, sessionUID: sessionUID, providerSession: $0)
        } ?? AppState(seedDemoData: false, sessionUID: sessionUID)
        let messages = zip(ids, roles).map { id, role -> ChatMessage in
            let text = id == ids[3] ? lastAssistantText : "text"
            var message = TestFactories.makeMessage(id: id, role: role, text: text)
            message.providerID = providerID
            message.providerKind = .relay
            message.modelID = modelID
            return message
        }
        let conversation = TestFactories.makeConversation(
            providerID: providerID, providerKind: .relay, modelID: modelID, messages: messages
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)
        state.flushConversationPersistQueue()
        let store = try #require(ContextCompactionStore.forPartition(state.sessionPartitionUID))
        let covered = ids.map { ContextCheckpoint.CoveredMessage(id: $0.uuidString, text: "text") }
        let conversationId = conversation.id.uuidString
        let kept = record(conversationId: conversationId, coversTo: ids[1].uuidString, history: covered, createdAt: 1)
        let dropped = record(conversationId: conversationId, coversTo: ids[3].uuidString, history: covered, createdAt: 2)
        try store.save(kept)
        try store.save(dropped)
        return TruncationFixture(state: state, conversationID: conversation.id, ids: ids, store: store, kept: kept)
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckpointStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Shared helper: removed ids are handed to the deletion callback; nothing is called back when nothing was removed.
    @Test func invalidate_and_propagate_hands_removed_ids_to_remote() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let messages = history(6)
        let ids = messages.map(\.id)
        let atOne = record(conversationId: conversation, coversTo: "m1", history: messages, createdAt: 1)
        let atFour = record(conversationId: conversation, coversTo: "m4", history: messages, createdAt: 2)
        try store.save(atOne)
        try store.save(atFour)

        var handed: [[String]] = []
        store.invalidateAndPropagate(conversationId: conversation, historyIds: ids, affectedIds: ["unknown"]) { handed.append($0) }
        #expect(handed.isEmpty)
        store.invalidateAndPropagate(conversationId: conversation, historyIds: ids, affectedIds: ["m3", "m4", "m5"]) { handed.append($0) }
        #expect(handed == [[atFour.checkpointId]])
        #expect(try store.list(conversationId: conversation) == [atOne])
    }

    // MARK: - Backup

    private func insertConversation(id: String, into database: McpTestDatabase) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation (id, providerID, providerKind, modelID, createdAt, updatedAt)
                    VALUES (?, 'provider-1', 'openAI', 'gpt-x', 1, 1)
                    """,
                arguments: [id]
            )
        }
    }

    @Test func backup_roundtrip_includes_checkpoints() throws {
        let source = try McpTestDatabase.make()
        defer { source.cleanUp() }
        let sourceStore = ContextCompactionStore(dbPool: source.pool)
        let kept = try source.insertConversation(messageCount: 0).conversation.uuidString
        let orphan = try source.insertConversation(messageCount: 0).conversation.uuidString
        let summary = record(conversationId: kept, coversTo: "m1", history: history(4), createdAt: 20)
        let fallback = record(
            conversationId: kept, coversTo: "m2", history: history(4), createdAt: 30, kind: .fallback, summary: nil
        )
        let orphanRow = record(conversationId: orphan, coversTo: "m1", history: history(4), createdAt: 40)
        try sourceStore.save(summary)
        try sourceStore.save(fallback)
        try sourceStore.save(orphanRow)

        let exported = try #require(try BackupService.backupCheckpoints(store: sourceStore))
        #expect(exported.count == 3)
        let data = BackupData(
            providers: [], conversations: [], preferences: nil, lastUsedModelRef: nil, checkpoints: exported
        )
        let encoded = try CanonicalJSON.encode(data)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try #require(json["checkpoints"] as? [[String: Any]])
        let fallbackJSON = try #require(rows.first { ($0["kind"] as? String) == "fallback" })
        #expect(fallbackJSON["conversationId"] as? String == kept)
        #expect(fallbackJSON["createdAt"] as? Int == 30)
        #expect(fallbackJSON["summary"] == nil)
        #expect(fallbackJSON["language"] == nil)
        #expect(fallbackJSON["cost"] == nil)
        #expect(Set(fallbackJSON.keys) == [
            "conversationId", "checkpointId", "kind", "coversFrom", "coversTo", "coversDigest", "messagesCovered",
            "userMessageIds", "text", "model", "packerVersion", "createdAt",
        ])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackupData.self, from: encoded)
        #expect(try CanonicalJSON.encode(decoded) == encoded)

        // The target database only has the kept conversation: orphan rows are discarded; rows with an existing primary key are overwritten.
        let target = try McpTestDatabase.make()
        defer { target.cleanUp() }
        try insertConversation(id: kept, into: target)
        let targetStore = ContextCompactionStore(dbPool: target.pool)
        var stale = summary
        stale.text = "stale"
        try targetStore.save(stale)

        let imported = try BackupService.importCheckpoints(decoded.checkpoints, store: targetStore)
        #expect(imported == 2)
        #expect(try targetStore.list(conversationId: kept) == [summary, fallback])
        #expect(try targetStore.list(conversationId: orphan).isEmpty)

    }

    @Test func legacy_backup_imports() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(BackupData.self, from: Data(#"{"providers":[],"conversations":[]}"#.utf8))
        #expect(legacy.checkpoints == nil)
        let reencoded = try CanonicalJSON.encode(legacy)
        #expect(!String(decoding: reencoded, as: UTF8.self).contains("checkpoints"))

        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = ContextCompactionStore(dbPool: database.pool)
        let conversation = try database.insertConversation(messageCount: 0).conversation.uuidString
        let local = record(conversationId: conversation, coversTo: "m1", history: history(4), createdAt: 10)
        try store.save(local)

        #expect(try BackupService.importCheckpoints(legacy.checkpoints, store: store) == 0)
        #expect(try store.list(conversationId: conversation) == [local])
    }
}

/// The real send behind the regenerate fallback: any request gets an empty SSE stream.
private final class CheckpointStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://relay.invalid")!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Notification callbacks may arrive on any thread, so recording takes a lock.
private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []

    func append(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(value)
    }

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
