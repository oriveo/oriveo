import Foundation
import GRDB
import OriveoProviderKit
import Testing
@testable import Oriveo

// The conversation instructions local column (default "") and conflict detection.
// Assertions come from the production path: ConversationStore upsert (the full SQL and the metadata-only SQL) -> GRDB -> the Conversation / Summary read back.

@Suite("ConversationInstructions", .serialized)
struct ConversationInstructionsTests {
    @Test("instructions_persist_roundtrip")
    func instructionsPersistRoundtrip() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        // Full upsert -> read the thread -> Conversation.
        let message = TestFactories.makeMessage(role: .user, text: "hello")
        var conversation = TestFactories.makeConversation(messages: [message])
        conversation.instructions = ConversationInstructions.normalize("  Reply in Arabic.\n")
        try harness.store.upsertConversation(conversation)
        let thread = try #require(try harness.store.fetchConversationThread(id: conversation.id))
        #expect(thread.summary.instructions == "  Reply in Arabic.\n")
        #expect(RecordMappers.conversation(from: thread).instructions == "  Reply in Arabic.\n")
        let listed = try #require(try harness.store.fetchConversationSummary(id: conversation.id))
        let legacy = ConversationProjectionBuilder.buildLegacyConversation(summary: listed, messages: [])
        #expect(legacy.instructions == "  Reply in Arabic.\n")

        // The metadata-only SQL (messages not loaded) must also write this column and leave the message rows alone.
        var projection = legacy
        projection.instructions = "Use metric units."
        try harness.store.upsertConversation(projection)
        let updated = try #require(try harness.store.fetchConversationThread(id: conversation.id))
        #expect(updated.summary.instructions == "Use metric units.")
        #expect(updated.messages.map(\.id) == [message.id])

        // Clearing writes back "".
        projection.instructions = ""
        try harness.store.upsertConversation(projection)
        #expect(try harness.store.fetchConversationSummary(id: conversation.id)?.instructions == "")
    }

    @Test("instructions_persist_roundtrip: v35 rows migrate to empty")
    func v35RowsMigrateToEmpty() throws {
        let database = try McpTestDatabase.make(upTo: "v35_context_checkpoint")
        defer { database.cleanUp() }
        // Fill only the required columns of v35; providerID must be a valid UUID, otherwise the read path drops the row as dirty data.
        let conversationID = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation (id, providerID, providerKind, modelID, createdAt, updatedAt)
                    VALUES (?, ?, 'openAI', 'gpt-x', 1, 1)
                    """,
                arguments: [conversationID.uuidString, UUID().uuidString]
            )
        }
        try database.migrateToLatest()

        let store = ConversationStore(
            dbPool: database.pool,
            attachmentFileStore: AttachmentFileStore(
                rootDirectory: database.directory.appendingPathComponent("Files", isDirectory: true)
            )
        )
        let summary = try #require(try store.fetchConversationSummary(id: conversationID))
        #expect(summary.instructions == "")
        let raw = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT instructions FROM conversation WHERE id = ?",
                                arguments: [conversationID.uuidString])
        }
        #expect(raw == "")
    }

    @Test("content_equal_compares_instructions")
    func contentEqualComparesInstructions() {
        let base = TestFactories.makeConversation()
        var other = base
        #expect(base.isContentEqual(to: other))
        other.instructions = "Reply in Arabic."
        #expect(!base.isContentEqual(to: other))
        var same = base
        same.instructions = "Reply in Arabic."
        #expect(same.isContentEqual(to: other))
    }

    // MARK: - Settings and normalization

    @Test("set_instructions_normalizes")
    @MainActor
    func setInstructionsNormalizes() throws {
        let uid = "instructions-set-\(UUID().uuidString)"
        let state = AppState(seedDemoData: false, sessionUID: uid)
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        // Custom title: keeps the projection from recomputing the fixture title from the first user message, so we can assert that setting instructions leaves the title alone
        let conversation = TestFactories.makeConversation(hasCustomTitle: true, messages: [TestFactories.makeMessage()])
        state.replaceConversationProjection([conversation])
        let before = try #require(state.conversation(for: conversation.id))

        // Normalization: the original text is not trimmed.
        #expect(state.conversationManager.setInstructions(id: conversation.id, text: "  Reply in Arabic.\n"))
        let after = try #require(state.conversation(for: conversation.id))
        #expect(after.instructions == "  Reply in Arabic.\n")
        #expect(after.updatedAt == before.updatedAt)
        #expect(after.title == before.title)

        // An unchanged value is not written.
        #expect(!state.conversationManager.setInstructions(id: conversation.id, text: "  Reply in Arabic.\n"))
        // All whitespace -> "".
        #expect(state.conversationManager.setInstructions(id: conversation.id, text: " \n\t"))
        #expect(state.conversation(for: conversation.id)?.instructions == "")
        // Overlong text is truncated to the first 8000 code points.
        let long = String(repeating: "😀", count: ConversationInstructions.maxCodePoints + 5)
        #expect(state.conversationManager.setInstructions(id: conversation.id, text: long))
        #expect(state.conversation(for: conversation.id)?.instructions.unicodeScalars.count
            == ConversationInstructions.maxCodePoints)
    }

    // The backup DTO carries optional instructions: empty is written as nil and import normalizes.
    private func backupCodec() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (enc, dec)
    }

    @Test("backup_roundtrip_keeps_instructions")
    func backupRoundtripKeepsInstructions() throws {
        let (enc, dec) = backupCodec()
        var conversation = TestFactories.makeConversation()
        conversation.instructions = "  Reply in Arabic.\n"
        let data = try enc.encode(BackupConversation(from: conversation))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["instructions"] as? String == "  Reply in Arabic.\n")
        let restored = try dec.decode(BackupConversation.self, from: data).toConversation()
        #expect(restored.instructions == "  Reply in Arabic.\n")

        // Empty instructions do not write the key.
        conversation.instructions = ""
        let emptyData = try enc.encode(BackupConversation(from: conversation))
        let emptyJSON = try #require(try JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        #expect(emptyJSON["instructions"] == nil)
        #expect(try dec.decode(BackupConversation.self, from: emptyData).toConversation().instructions == "")
    }

    @Test("old_backup_defaults_empty")
    func oldBackupDefaultsEmpty() throws {
        let (enc, dec) = backupCodec()
        let data = try enc.encode(BackupConversation(from: TestFactories.makeConversation()))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "instructions")
        let legacy = try dec.decode(BackupConversation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.instructions == nil)
        #expect(legacy.toConversation().instructions == "")

        // Import normalizes: all whitespace -> "", overlong text is truncated to the limit.
        json["instructions"] = " \t\n"
        let blank = try dec.decode(BackupConversation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(blank.toConversation().instructions == "")
        json["instructions"] = String(repeating: "a", count: ConversationInstructions.maxCodePoints + 5)
        let long = try dec.decode(BackupConversation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(long.toConversation().instructions.unicodeScalars.count == ConversationInstructions.maxCodePoints)
    }

    @Test("backup_merge_takes_instructions_with_title")
    func backupMergeTakesInstructionsWithTitle() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var local = TestFactories.makeConversation(title: "Local", updatedAt: base)
        local.instructions = "Local rule."

        // Backup is newer -> title and instructions both come from the backup side (an empty backup value also overwrites).
        var newer = TestFactories.makeConversation(id: local.id, title: "Backup", updatedAt: base.addingTimeInterval(60))
        newer.instructions = ""
        var merged = local
        BackupService.applyMergeMetadata(from: BackupConversation(from: newer), localUpdatedAt: local.updatedAt, into: &merged)
        #expect(merged.title == "Backup")
        #expect(merged.instructions == "")

        // Backup is older -> both stay local.
        var older = TestFactories.makeConversation(id: local.id, title: "Old", updatedAt: base.addingTimeInterval(-60))
        older.instructions = "Old rule."
        merged = local
        BackupService.applyMergeMetadata(from: BackupConversation(from: older), localUpdatedAt: local.updatedAt, into: &merged)
        #expect(merged.title == "Local")
        #expect(merged.instructions == "Local rule.")
    }
}
