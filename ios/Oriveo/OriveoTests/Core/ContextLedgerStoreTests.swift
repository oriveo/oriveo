import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Persistence: v34_context_stop_reason_ledger adds a nullable stopReason to message,
/// and creates the two Ledger tables, the ρ calibration table and the manifest table.
@Suite("Context Ledger and stopReason persistence v34")
struct ContextLedgerStoreTests {

    private static let lastBeforeLedger = "v30_add_message_recovery_action"

    private func makeStores(_ database: McpTestDatabase) -> (ConversationStore, ContextLedgerStore) {
        let files = AttachmentFileStore(rootDirectory: database.directory.appendingPathComponent("Files", isDirectory: true))
        return (
            ConversationStore(dbPool: database.pool, attachmentFileStore: files),
            ContextLedgerStore(dbPool: database.pool)
        )
    }

    private func manifest(conversationId: String, requestId: String, createdAt: Int64) -> ContextManifest {
        ContextManifest(
            requestId: requestId,
            conversationId: conversationId,
            purpose: .chat,
            transport: "openai_chat",
            model: "gpt-x",
            W: 128_000,
            O: 4_096,
            B: nil,
            basis: .estimated,
            estimatedInput: 1_234,
            observedInput: 1_300,
            segments: [ContextManifestSegment(kind: .memory, tokens: 200, items: 3, omitted: 1)],
            checkpointId: nil,
            tailFrom: "msg-1",
            unansweredMerged: 0,
            reminder: false,
            stopReason: .length,
            createdAt: createdAt
        )
    }

    @Test func migration_adds_stop_reason_and_ledger() throws {
        let database = try McpTestDatabase.make(upTo: Self.lastBeforeLedger)
        defer { database.cleanUp() }
        let ids = try database.insertConversation()
        try database.pool.read { (db: Database) throws -> Void in
            #expect(try !db.tableExists("context_rho_calibration"))
            #expect(try !db.tableExists("context_manifest"))
            #expect(try !db.columns(in: "message").map(\.name).contains("stopReason"))
        }

        try database.migrateToLatest()

        try database.pool.read { (db: Database) throws -> Void in
            #expect(try db.tableExists("context_rho_calibration"))
            #expect(try db.tableExists("context_manifest"))
            #expect(try db.columns(in: "message").map(\.name).contains("stopReason"))
            let raw = try String?.fetchOne(
                db, sql: "SELECT stopReason FROM message WHERE id = ?", arguments: [ids.messages[0].uuidString]
            )
            #expect(raw == .some(nil))
        }
        // Old rows written before the migration are read through the production mapping: stopReason is nil.
        let row = try #require(try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM message WHERE id = ?", arguments: [ids.messages[0].uuidString])
        })
        let files = AttachmentFileStore(rootDirectory: database.directory.appendingPathComponent("Files", isDirectory: true))
        let message = try #require(RecordMappers.message(
            from: MessageRecord(row: row), attachmentRecords: [], hydrateFilePayloads: false, attachmentFileStore: files
        ))
        #expect(message.id == ids.messages[0])
        #expect(message.stopReason == nil)
    }

    @Test func legacy_null_reads_null() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let (store, _) = makeStores(database)
        let legacyMessage = TestFactories.makeMessage(role: .assistant, text: "old", estimatedCost: 0)
        let futureMessage = TestFactories.makeMessage(role: .assistant, text: "new", estimatedCost: 0)
        let conversation = TestFactories.makeConversation(title: "Legacy", messages: [legacyMessage, futureMessage])
        try store.upsertConversation(conversation)
        try database.pool.write { db in
            try db.execute(sql: "UPDATE message SET stopReason = NULL WHERE id = ?", arguments: [legacyMessage.id.uuidString])
            try db.execute(
                sql: "UPDATE message SET stopReason = 'some_future_reason' WHERE id = ?",
                arguments: [futureMessage.id.uuidString]
            )
        }
        let messages = try store.fetchMessages(for: conversation.id)
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        // Old rows with NULL read as nil (no backfill); unrecognized strings read as unknown.
        let legacy = try #require(byID[legacyMessage.id])
        #expect(legacy.stopReason == nil)
        let future = try #require(byID[futureMessage.id])
        #expect(future.stopReason == .unknown)
    }

    @Test func stop_reason_roundtrip() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let (store, _) = makeStores(database)
        var truncated = TestFactories.makeMessage(role: .assistant, text: "partial", estimatedCost: 0)
        truncated.stopReason = .contextWindowExceeded
        var stopped = TestFactories.makeMessage(role: .assistant, text: "done", estimatedCost: 0)
        stopped.stopReason = .stop
        let plain = TestFactories.makeMessage(role: .user, text: "q", estimatedCost: 0)
        let conversation = TestFactories.makeConversation(title: "Stop reason", messages: [plain, truncated, stopped])

        try store.upsertConversation(conversation)
        let raw = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT stopReason FROM message WHERE id = ?", arguments: [truncated.id.uuidString])
        }
        // Store the fixture's raw string.
        #expect(raw == "context_window_exceeded")

        let stored = try store.fetchMessages(for: conversation.id)
        let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        #expect(byID[truncated.id]?.stopReason == .contextWindowExceeded)
        #expect(byID[stopped.id]?.stopReason == .stop)
        #expect(byID[plain.id]?.stopReason == nil)

        // Incremental updates write this column too.
        var updated = conversation
        updated.messages[1].stopReason = .interrupted
        try store.upsertHydratedMessages(updated.messages, conversationID: conversation.id)
        let again = try store.fetchMessages(for: conversation.id)
        #expect(again.first { $0.id == truncated.id }?.stopReason == .interrupted)
    }

    @Test func rho_table_roundtrip() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let (_, ledger) = makeStores(database)
        #expect(try ledger.loadRhoTable() == RhoCalibrationTable())

        let keyA = RhoCalibrationKey(transportInstanceId: "openai-1", modelId: "gpt-x")
        let keyB = RhoCalibrationKey(transportInstanceId: "openai-1", modelId: "gpt-y")
        let seeded = RhoCalibration()
            .recordingSample(observedInput: 300, mediaTokens: 0, textBytes: 1_000)
            .recordingSample(observedInput: 310, mediaTokens: 0, textBytes: 1_000)
            .recordingSample(observedInput: 290, mediaTokens: 0, textBytes: 1_000)
            .recordingSample(observedInput: 420, mediaTokens: 20, textBytes: 1_000)
        let partial = RhoCalibration().recordingSample(observedInput: 100, mediaTokens: 0, textBytes: 400)
        try ledger.saveRho(keyA, partial)
        try ledger.saveRho(keyA, seeded)
        try ledger.saveRho(keyB, partial.recordingOverflowMiss())

        let table = try ledger.loadRhoTable()
        #expect(table.entries.count == 2)
        // Same key overwrites; the Double and the seed array are restored bit for bit.
        #expect(table.calibration(for: keyA) == seeded)
        #expect(table.calibration(for: keyB) == partial.recordingOverflowMiss())
        #expect(table.calibration(for: keyA).seeds.count == 3)
    }

    @Test func manifest_keeps_latest_50() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let (_, ledger) = makeStores(database)
        let first = try database.insertConversation(messageCount: 0).conversation.uuidString
        let second = try database.insertConversation(messageCount: 0).conversation.uuidString

        for index in 0..<55 {
            try ledger.appendManifest(manifest(conversationId: first, requestId: "req-\(index)", createdAt: 1_000 + Int64(index)))
        }
        try ledger.appendManifest(manifest(conversationId: second, requestId: "other", createdAt: 1))

        let kept = try ledger.manifests(conversationId: first)
        #expect(kept.count == ContextManifestLog.capacityPerConversation)
        // Old -> new: the earliest 5 are trimmed.
        #expect(kept.first?.requestId == "req-5")
        #expect(kept.last?.requestId == "req-54")
        #expect(kept.last == manifest(conversationId: first, requestId: "req-54", createdAt: 1_054))
        // Trimming only applies to this conversation.
        #expect(try ledger.manifests(conversationId: second).map(\.requestId) == ["other"])
    }

    @Test func manifest_deleted_with_conversation() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let (_, ledger) = makeStores(database)
        let doomed = try database.insertConversation(messageCount: 0).conversation.uuidString
        let survivor = try database.insertConversation(messageCount: 0).conversation.uuidString
        try ledger.appendManifest(manifest(conversationId: doomed, requestId: "a", createdAt: 1))
        try ledger.appendManifest(manifest(conversationId: doomed, requestId: "b", createdAt: 2))
        try ledger.appendManifest(manifest(conversationId: survivor, requestId: "c", createdAt: 3))

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [doomed])
        }

        #expect(try ledger.manifests(conversationId: doomed).isEmpty)
        let rows = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM context_manifest WHERE conversationId = ?", arguments: [doomed])
        }
        #expect(rows == 0)
        #expect(try ledger.manifests(conversationId: survivor).map(\.requestId) == ["c"])
    }

    @Test func manifest_cleared_with_all_conversations() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let (store, ledger) = makeStores(database)
        let rhoKey = RhoCalibrationKey(transportInstanceId: "openai-1", modelId: "gpt-x")
        let rho = RhoCalibration().recordingSample(observedInput: 100, mediaTokens: 0, textBytes: 400)
        try ledger.saveRho(rhoKey, rho)

        // Overwriting import / rewrite based on the passed-in set: passing an empty set clears all conversations.
        let replaced = try database.insertConversation(messageCount: 0).conversation.uuidString
        try ledger.appendManifest(manifest(conversationId: replaced, requestId: "r", createdAt: 1))
        try store.replaceAllConversations([])
        #expect(try ledger.manifests(conversationId: replaced).isEmpty)

        // The ρ table is not cleared along with the conversations.
        #expect(try ledger.loadRhoTable().calibration(for: rhoKey) == rho)
    }
}
