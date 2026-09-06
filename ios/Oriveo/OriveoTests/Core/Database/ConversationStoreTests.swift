import Foundation
import GRDB
import Testing
@testable import Oriveo

@Suite("ConversationStore", .serialized)
struct ConversationStoreTests {

    @Test("Recipe Continuation Production Deletion Sweep")
    func recipeContinuationProductionDeletionSweep() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }
        let (store, continuation) = try harness.makeStoreWithContinuationSweep()

        let first = TestFactories.makeMessage(role: .assistant, text: "first")
        let second = TestFactories.makeMessage(role: .assistant, text: "second")
        var conversation = TestFactories.makeConversation(messages: [first, second])
        try store.upsertConversation(conversation)
        try continuation.save(messageID: first.id, kind: "previous_id", state: ["previousResponseId": .string("first")])
        try store.deleteConversation(id: conversation.id, enqueueForSync: false)
        #expect(try continuation.load(messageID: first.id) == nil)

        let bulkMessage = TestFactories.makeMessage(role: .assistant, text: "bulk")
        let bulkConversation = TestFactories.makeConversation(messages: [bulkMessage])
        try store.upsertConversation(bulkConversation)
        try continuation.save(messageID: bulkMessage.id, kind: "previous_id", state: ["previousResponseId": .string("bulk")])
        try store.deleteConversations(ids: [bulkConversation.id], enqueueForSync: false)
        #expect(try continuation.load(messageID: bulkMessage.id) == nil)

        try store.upsertConversation(conversation)
        try continuation.save(messageID: second.id, kind: "previous_id", state: ["previousResponseId": .string("second")])
        conversation.messages = [first]
        try store.upsertConversation(conversation)
        #expect(try continuation.load(messageID: second.id) == nil)
        #expect(try continuation.load(messageID: first.id) == nil,
                "only explicitly saved local state should exist; mutation must not fabricate sidecars")
    }

    @Test("Recipe Continuation Replace All Lifecycle")
    func recipeContinuationReplaceAllLifecycle() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }
        let message = TestFactories.makeMessage(role: .assistant, text: "answer")
        let conversation = TestFactories.makeConversation(messages: [message])
        try harness.store.upsertConversation(conversation)
        let continuation = try harness.makeContinuationStore()
        #expect(try harness.dbPool.read { db in try db.tableExists("message_recipe_continuation") } == false,
                "primary conversation database must not retain opaque continuation state")
        let localOnlyDirectory = harness.rootURL.appendingPathComponent("LocalOnly", isDirectory: true)
        #expect(try localOnlyDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try continuation.save(
            messageID: message.id, kind: "previous_id",
            state: ["previousResponseId": .string("resp_fixture")]
        )

        // replaceAll is used by merge/cold-start projection replacement. It must preserve only
        // local sidecars whose message IDs survive; nothing is serialized into Conversation.
        try harness.store.replaceAllConversations([conversation])
        if case let .string(id)? = try continuation.load(messageID: message.id)?.state["previousResponseId"] {
            #expect(id == "resp_fixture")
        } else {
            Issue.record("replaceAll lost local continuation sidecar for surviving message")
        }
        let encoded = try JSONEncoder().encode(conversation)
        #expect(String(decoding: encoded, as: UTF8.self).contains("resp_fixture") == false)

        // A disappeared message is deleted through the FK lifecycle, not resurrected by replace.
        var removed = conversation
        removed.messages = []
        try harness.store.replaceAllConversations([removed])
        #expect(try continuation.load(messageID: message.id) == nil)

        // A persisted state from another launch is intentionally a clean restart.
        try harness.store.upsertConversation(conversation)
        try continuation.save(
            messageID: message.id, kind: "previous_id",
            state: ["previousResponseId": .string("resp_fixture")]
        )
        try continuation.dbPoolForTesting.write { db in
            try db.execute(
                sql: "UPDATE message_recipe_continuation SET launchToken = ? WHERE messageID = ?",
                arguments: ["previous-process", message.id.uuidString]
            )
        }
        #expect(try continuation.load(messageID: message.id) == nil)
        #expect(try continuation.dbPoolForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_recipe_continuation")
        } == 0, "foreign launch sidecars must be physically purged, not merely ignored")
    }

    @Test("Recipe Continuation Orphan Sweep Batches Large Sets")
    func recipeContinuationOrphanSweepBatchesLargeSets() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }
        let continuation = try harness.makeContinuationStore()
        for _ in 0..<1_001 {
            try continuation.save(
                messageID: UUID(), kind: "previous_id",
                state: ["previousResponseId": .string("opaque")]
            )
        }
        try continuation.purgeMissingParentMessages()
        #expect(try continuation.dbPoolForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_recipe_continuation")
        } == 0)
    }

    @Test("explicit continuation ACK deletes only the consumed sidecar revision")
    func recipeContinuationCompareAndDeleteAcknowledgement() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }
        let message = TestFactories.makeMessage(role: .assistant, text: "partial")
        try harness.store.upsertConversation(TestFactories.makeConversation(messages: [message]))
        let continuation = try harness.makeContinuationStore()
        try continuation.save(
            messageID: message.id, kind: "previous_id",
            state: ["previousResponseId": .string("old")]
        )
        let oldSnapshot = try continuation.load(messageID: message.id)
        let old = try #require(oldSnapshot)
        let token = RecipeContinuationStore.ConsumptionToken(messageID: message.id, revision: old.revision)

        // A successful explicit request with no newly completed protocol leg consumes the old
        // snapshot, so a second Continue cannot replay it again.
        #expect(try continuation.discard(token))
        #expect(try continuation.load(messageID: message.id) == nil)

        try continuation.save(
            messageID: message.id, kind: "previous_id",
            state: ["previousResponseId": .string("old")]
        )
        let consumedSnapshot = try continuation.load(messageID: message.id)
        let consumed = try #require(consumedSnapshot)
        let consumedToken = RecipeContinuationStore.ConsumptionToken(
            messageID: message.id, revision: consumed.revision
        )
        // Same state, written immediately after the old token was captured, is still a new
        // producer leg. A wall-clock timestamp alone can collide here and let old ACK delete it.
        try continuation.save(
            messageID: message.id, kind: "previous_id",
            state: ["previousResponseId": .string("old")]
        )
        let sameValueNewer = try #require(try continuation.load(messageID: message.id))
        #expect(sameValueNewer.revision > consumed.revision)
        #expect(try continuation.discard(consumedToken) == false)
        #expect(try continuation.load(messageID: message.id)?.revision == sameValueNewer.revision)

        let newestToken = RecipeContinuationStore.ConsumptionToken(
            messageID: message.id, revision: sameValueNewer.revision
        )
        // A completed response producer writes a newer state for the same assistant message.
        // Compare-and-delete must leave that new leg intact.
        try continuation.dbPoolForTesting.write { db in
            try db.execute(
                sql: "UPDATE message_recipe_continuation SET stateJSON = ?, updatedAt = ? WHERE messageID = ?",
                arguments: ["{\"previousResponseId\":\"new\"}", sameValueNewer.revision + 1, message.id.uuidString]
            )
        }
        #expect(try continuation.discard(newestToken) == false)
        if case let .string(id)? = try continuation.load(messageID: message.id)?.state["previousResponseId"] {
            #expect(id == "new")
        } else {
            Issue.record("new continuation producer was deleted by an old explicit ACK")
        }
    }

    @Test("Message Token Usage Roundtrip")
    func messageTokenUsageRoundtrip() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        var message = TestFactories.makeMessage(role: .assistant, text: "answer")
        message.inputTokens = 210
        message.outputTokens = 30
        message.cachedInputTokens = 80
        message.cacheCreationInputTokens = 0
        let conversation = TestFactories.makeConversation(messages: [message])

        try harness.store.upsertConversation(conversation)

        let restored = try #require(try harness.store.fetchMessages(for: conversation.id).first)
        #expect(restored.inputTokens == 210)
        #expect(restored.outputTokens == 30)
        #expect(restored.cachedInputTokens == 80)
        #expect(restored.cacheCreationInputTokens == 0)
    }

    @Test("Quote Context Roundtrip")
    func quoteContextRoundtrip() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        var message = TestFactories.makeMessage(role: .user, text: "Please explain")
        message.quoteContext = try QuoteContext.capture(
            sourceMessageID: UUID(),
            sourceRole: .assistant,
            contentKind: .code,
            leadingText: "let ",
            selectedText: "answer = 42",
            trailingText: "\nprint(answer)"
        ).get()
        let conversation = TestFactories.makeConversation(messages: [message])
        try harness.store.upsertConversation(conversation)

        let restored = try #require(try harness.store.fetchMessages(for: conversation.id).first)
        #expect(restored.text == "Please explain")
        #expect(restored.quoteContext == message.quoteContext)
    }

    @Test("Roundtrip With File Attachments")
    func roundtripWithFileAttachments() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let providerID = UUID()
        let fileAttachment = TestFactories.makeFileAttachment(
            base64Data: Data("phase1-file".utf8).base64EncodedString()
        )
        let message = TestFactories.makeMessage(
            role: .assistant,
            providerKind: .openAI,
            attachments: [fileAttachment]
        )
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            messages: [message]
        )

        try harness.store.replaceAllConversations([conversation])

        let sidecarURL = harness.filesURL.appendingPathComponent("\(fileAttachment.id.uuidString).bin")
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))

        let hydrated = try harness.store.fetchAllConversations(hydrateFilePayloads: true)
        #expect(hydrated.count == 1)
        #expect(hydrated[0].messages.count == 1)
        #expect(hydrated[0].messages[0].attachments?.first?.base64Data == fileAttachment.base64Data)

        let metadataOnly = try harness.store.fetchMessages(for: conversation.id, hydrateFilePayloads: false)
        #expect(metadataOnly.first?.attachments?.first?.base64Data == nil)
    }

    @Test("Writing Back Non Hydrated Projection Keeps Sidecar Reference")
    func writingBackNonHydratedProjectionKeepsSidecarReference() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let fileAttachment = TestFactories.makeFileAttachment(
            base64Data: Data("extracted-text".utf8).base64EncodedString(),
            originalBase64Data: Data("original-bytes".utf8).base64EncodedString()
        )
        let conversation = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(role: .user, text: "body", attachments: [fileAttachment])]
        )
        try harness.store.replaceAllConversations([conversation])

        let nonHydrated = try harness.store.fetchAllConversations(hydrateFilePayloads: false)
        #expect(nonHydrated.first?.messages.first?.attachments?.first?.base64Data == nil)

        try harness.store.upsertConversations(nonHydrated)
        let afterUpsert = try harness.store.fetchAllConversations(hydrateFilePayloads: true)
        #expect(afterUpsert.first?.messages.first?.attachments?.first?.base64Data == fileAttachment.base64Data)
        #expect(afterUpsert.first?.messages.first?.attachments?.first?.originalBase64Data
                == fileAttachment.originalBase64Data)

        try harness.store.replaceAllConversations(nonHydrated)
        let sidecarURL = harness.filesURL.appendingPathComponent("\(fileAttachment.id.uuidString).bin")
        let originalSidecarURL = harness.filesURL.appendingPathComponent("\(fileAttachment.id.uuidString)-orig.bin")
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        #expect(FileManager.default.fileExists(atPath: originalSidecarURL.path))
        let afterReplace = try harness.store.fetchAllConversations(hydrateFilePayloads: true)
        #expect(afterReplace.first?.messages.first?.attachments?.first?.base64Data == fileAttachment.base64Data)
        #expect(afterReplace.first?.messages.first?.attachments?.first?.originalBase64Data
                == fileAttachment.originalBase64Data)
    }

    @Test("Summaries By IDs Skip Message And Attachment IO")
    func summariesByIDsSkipMessageAndAttachmentIO() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let fileAttachment = TestFactories.makeFileAttachment(
            base64Data: Data("pinned-sidecar-payload".utf8).base64EncodedString()
        )
        let pinned = TestFactories.makeConversation(
            title: "Pinned",
            messages: [TestFactories.makeMessage(role: .assistant, text: "body", attachments: [fileAttachment])]
        )
        let other = TestFactories.makeConversation(
            title: "Other",
            messages: [TestFactories.makeMessage(role: .assistant, text: "other")]
        )
        try harness.store.replaceAllConversations([pinned, other])

        let hydrated = try harness.store.fetchAllConversations(hydrateFilePayloads: true)
        #expect(
            hydrated.first(where: { $0.id == pinned.id })?
                .messages.first?.attachments?.first?.base64Data == fileAttachment.base64Data
        )

        let summaries = try harness.store.fetchConversationSummaries(ids: [pinned.id])
        #expect(summaries.count == 1)
        #expect(summaries.first?.id == pinned.id)
        #expect(summaries.first?.title == "Pinned")
        #expect(summaries.first?.messageCount == 1)

        let projections = summaries.map {
            ConversationProjectionBuilder.buildLegacyConversation(summary: $0, messages: [])
        }
        #expect(projections.first?.messages.isEmpty == true)
        #expect(projections.first?.displayMessageCount == 1)

        #expect(try harness.store.fetchConversationSummaries(ids: []).isEmpty)
        #expect(try harness.store.fetchConversationSummaries(ids: [UUID()]).isEmpty)
    }

    @Test("Migration Offloads Original Base64 To File")
    func migrationOffloadsOriginalBase64ToFile() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-db-migration-v9-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        let fileStore = AttachmentFileStore(rootDirectory: filesURL)

        let dbPool = try DatabasePool(
            path: rootURL.appendingPathComponent(DatabaseSchema.fileName).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let migrator = DatabaseSchema.makeMigrator(attachmentFileStore: fileStore)
        try migrator.migrate(dbPool, upTo: "v8_add_pinned_notes")

        let convID = UUID().uuidString
        let msgID = UUID().uuidString
        let attID = UUID().uuidString
        let originalBase64 = Data("legacy-inline-original-bytes".utf8).base64EncodedString()
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation (id, title, providerID, providerKind, modelID, createdAt, updatedAt)
                    VALUES (?, '', ?, 'openAI', 'gpt-4o', 1, 1)
                    """,
                arguments: [convID, UUID().uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO message (id, conversationID, role, text, providerKind, providerName, modelName, state)
                    VALUES (?, ?, 'user', 'legacy message', 'openAI', 'OpenAI', 'GPT-4o', 'delivered')
                    """,
                arguments: [msgID, convID]
            )
            try db.execute(
                sql: """
                    INSERT INTO attachment (id, messageID, kind, fileName, mimeType, sortOrder, originalBase64Data)
                    VALUES (?, ?, 'file', 'report.pdf', 'application/pdf', 0, ?)
                    """,
                arguments: [attID, msgID, originalBase64]
            )
        }

        try migrator.migrate(dbPool)

        let (migratedFileID, migratedInlineValue) = try await dbPool.read { db in
            let row = try #require(try Row.fetchOne(
                db,
                sql: "SELECT originalFileID, originalBase64Data FROM attachment WHERE id = ?",
                arguments: [attID]
            ))
            return (row["originalFileID"] as String?, row["originalBase64Data"] as String?)
        }
        #expect(migratedInlineValue == nil)
        let fileID = try #require(migratedFileID)
        #expect(fileStore.exists(id: fileID))
        #expect(fileStore.loadBase64(for: fileID) == originalBase64)

        let store = ConversationStore(dbPool: dbPool, attachmentFileStore: fileStore)
        let hydrated = try store.fetchMessages(
            for: try #require(UUID(uuidString: convID)),
            hydrateFilePayloads: true
        )
        #expect(hydrated.first?.attachments?.first?.originalBase64Data == originalBase64)
    }

    @Test("Fetch Attachments Ignores Legacy Original Base64 Column")
    func fetchAttachmentsIgnoresLegacyOriginalBase64Column() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let originalBytes = Data("native-route-original-bytes".utf8).base64EncodedString()
        let attachment = TestFactories.makeFileAttachment(
            base64Data: Data("extracted-text".utf8).base64EncodedString(),
            originalBase64Data: originalBytes
        )
        let conversation = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(attachments: [attachment])]
        )
        try harness.store.replaceAllConversations([conversation])

        try harness.dbPool.write { db in
            try db.execute(
                sql: "UPDATE attachment SET originalBase64Data = ? WHERE id = ?",
                arguments: ["leaked-legacy-inline-blob", attachment.id.uuidString]
            )
        }

        let hydrated = try harness.store.fetchMessages(for: conversation.id, hydrateFilePayloads: true)
        #expect(
            hydrated.first?.attachments?.first?.originalBase64Data == originalBytes,
            "hydrate must come from the originalFileID pointer file, not a dirty leftover column"
        )

        let notHydrated = try harness.store.fetchMessages(for: conversation.id, hydrateFilePayloads: false)
        #expect(notHydrated.first?.attachments?.first?.originalBase64Data == nil)
        #expect(notHydrated.first?.attachments?.first?.base64Data == nil)
    }

    @Test("Upsert Conversation Persists Original Base64 To File")
    func upsertConversationPersistsOriginalBase64ToFile() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let originalBytes = Data("office-native-original-bytes".utf8).base64EncodedString()
        let attachment = TestFactories.makeFileAttachment(
            fileName: "report.docx",
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            base64Data: Data("extracted-text".utf8).base64EncodedString(),
            originalBase64Data: originalBytes
        )
        let conversation = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(attachments: [attachment])]
        )

        try harness.store.upsertConversation(conversation)

        let origSidecarURL = harness.filesURL.appendingPathComponent("\(attachment.id.uuidString)-orig.bin")
        #expect(FileManager.default.fileExists(atPath: origSidecarURL.path))

        let hydrated = try harness.store.fetchAllConversations(hydrateFilePayloads: true)
        #expect(hydrated.first?.messages.first?.attachments?.first?.originalBase64Data == originalBytes)

        try harness.store.deleteConversation(id: conversation.id)
        #expect(!FileManager.default.fileExists(atPath: origSidecarURL.path))
    }

    @Test("Cascade Delete Removes Rows And Files")
    func cascadeDeleteRemovesRowsAndFiles() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let attachment = TestFactories.makeFileAttachment(
            base64Data: Data("delete-me".utf8).base64EncodedString()
        )
        let conversation = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(attachments: [attachment])]
        )

        try harness.store.replaceAllConversations([conversation])
        try harness.store.deleteConversation(id: conversation.id)

        let counts = try harness.dbPool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment") ?? -1
            )
        }

        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        #expect(counts.2 == 0)
        #expect(!FileManager.default.fileExists(
            atPath: harness.filesURL.appendingPathComponent("\(attachment.id.uuidString).bin").path
        ))
    }

    @Test("Search Matches Title Or Message Body")
    func searchMatchesTitleOrMessageBody() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let titleMatch = TestFactories.makeConversation(title: "Alpha Chat")
        let messageMatch = TestFactories.makeConversation(
            title: "Beta Chat",
            messages: [TestFactories.makeMessage(text: "contains gamma keyword")]
        )
        try harness.store.replaceAllConversations([titleMatch, messageMatch])

        let titleResults = try await harness.store.search(query: "alpha")
        #expect(Set(titleResults.map(\.id)) == [titleMatch.id])

        let messageResults = try await harness.store.search(query: "gamma")
        #expect(Set(messageResults.map(\.id)) == [messageMatch.id])
    }

    @Test("Search Matches CJKSubstrings")
    func searchMatchesCJKSubstrings() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conversation = TestFactories.makeConversation(
            title: "りょこうけいかく",
            messages: [TestFactories.makeMessage(text: "あしたのてんきはとてもよいのでやまのぼりにいく")]
        )
        try harness.store.replaceAllConversations([conversation])

        let threeChar = try await harness.store.search(query: "てんき")
        #expect(Set(threeChar.map(\.id)) == [conversation.id])

        let twoChar = try await harness.store.search(query: "やま")
        #expect(Set(twoChar.map(\.id)) == [conversation.id])

        let titleHit = try await harness.store.search(query: "けいかく")
        #expect(Set(titleHit.map(\.id)) == [conversation.id])

        let miss = try await harness.store.search(query: "じてんしゃ")
        #expect(miss.isEmpty)
    }

    @Test("Search Index Replaced On Upsert")
    func searchIndexReplacedOnUpsert() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        var conversation = TestFactories.makeConversation(
            title: "Edit Target",
            messages: [TestFactories.makeMessage(text: "obsoletekeyword in old body")]
        )
        try harness.store.upsertConversation(conversation)
        let beforeEdit = try await harness.store.search(query: "obsoletekeyword")
        #expect(Set(beforeEdit.map(\.id)) == [conversation.id])

        conversation.messages = [TestFactories.makeMessage(text: "freshkeyword replaces everything")]
        try harness.store.upsertConversation(conversation)

        let staleHit = try await harness.store.search(query: "obsoletekeyword")
        #expect(staleHit.isEmpty)
        let freshHit = try await harness.store.search(query: "freshkeyword")
        #expect(Set(freshHit.map(\.id)) == [conversation.id])
    }

    @Test("Migration Backfills Existing Rows")
    func migrationBackfillsExistingRows() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-db-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let dbPool = try DatabasePool(
            path: rootURL.appendingPathComponent(DatabaseSchema.fileName).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let migrator = DatabaseSchema.makeMigrator(
            attachmentFileStore: AttachmentFileStore(rootDirectory: rootURL)
        )
        try migrator.migrate(dbPool, upTo: "v5_add_attachment_extraction_meta")
        let convID = UUID().uuidString
        try await dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation (id, title, providerID, providerKind, modelID, createdAt, updatedAt)
                    VALUES (?, 'Historical session title', ?, 'openAI', 'gpt-4o', 1, 1)
                    """,
                arguments: [convID, UUID().uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO message (id, conversationID, role, text, providerKind, providerName, modelName, state)
                    VALUES (?, ?, 'user', 'performance optimization discussion written before migration', 'openAI', 'OpenAI', 'GPT-4o', 'delivered')
                    """,
                arguments: [UUID().uuidString, convID]
            )
        }

        try migrator.migrate(dbPool)

        let store = ConversationStore(
            dbPool: dbPool,
            attachmentFileStore: AttachmentFileStore(rootDirectory: rootURL)
        )
        let titleHit = try await store.search(query: "Historical session")
        #expect(titleHit.map(\.id.uuidString) == [convID])
        let bodyHit = try await store.search(query: "performance optimization")
        #expect(bodyHit.map(\.id.uuidString) == [convID])
    }

    @Test("Fetch Home Conversation Buckets")
    func fetchHomeConversationBuckets() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let recent = TestFactories.makeConversation(
            title: "Recent",
            updatedAt: now.addingTimeInterval(-2 * 86_400)
        )
        let earlier1 = TestFactories.makeConversation(
            title: "Earlier 1",
            updatedAt: now.addingTimeInterval(-12 * 86_400)
        )
        let earlier2 = TestFactories.makeConversation(
            title: "Earlier 2",
            updatedAt: now.addingTimeInterval(-13 * 86_400)
        )
        let recentStart = Calendar.current.date(
            byAdding: .day,
            value: -7,
            to: Calendar.current.startOfDay(for: now)
        ) ?? now

        try harness.store.replaceAllConversations([recent, earlier1, earlier2])

        let recentRows = try harness.store.fetchUngroupedRecentConversationSummaries(recentStart: recentStart)
        let earlierRows = try harness.store.fetchUngroupedEarlierConversationSummaries(
            recentStart: recentStart,
            limit: 1
        )
        let earlierCount = try harness.store.fetchUngroupedEarlierConversationCount(recentStart: recentStart)

        #expect(recentRows.map(\.title) == ["Recent"])
        #expect(earlierRows.count == 1)
        #expect(earlierCount == 2)
    }

    @Test("Replace All Preserves Order And Metadata")
    func replaceAllPreservesOrderAndMetadata() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let first = TestFactories.makeMessage(
            role: .assistant,
            text: "generating-like",
            state: .generating,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let second = TestFactories.makeMessage(
            role: .user,
            text: "older delivered",
            state: .delivered,
            createdAt: Date(timeIntervalSince1970: 10)
        )

        var conversation = TestFactories.makeConversation(
            title: "Pinned Title",
            hasCustomTitle: true,
            previewText: "Pinned Preview",
            estimatedCost: 42,
            messages: [first, second]
        )
        conversation.updatedAt = Date(timeIntervalSince1970: 30)

        try harness.store.replaceAllConversations([conversation])

        let restored = try #require(harness.store.fetchAllConversations(hydrateFilePayloads: true).first)
        #expect(restored.title == "Pinned Title")
        #expect(restored.hasCustomTitle == true)
        #expect(restored.previewText == "Pinned Preview")
        #expect(restored.estimatedCost == 42)
        #expect(restored.messages.map(\.id) == [first.id, second.id])
    }

    @Test("Upsert Conversation Recomputes Derived Summary")
    func upsertConversationRecomputesDerivedSummary() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let providerID = UUID()
        let untouched = TestFactories.makeConversation(
            title: "Untouched",
            providerID: providerID,
            messages: [TestFactories.makeMessage(text: "keep me", estimatedCost: 0.2)]
        )

        let originalTarget = TestFactories.makeConversation(
            title: "Original",
            providerID: providerID,
            messages: [
                TestFactories.makeMessage(
                    role: .user,
                    text: "hello world from the user",
                    estimatedCost: 0.1
                )
            ]
        )

        try harness.store.replaceAllConversations([untouched, originalTarget])

        let deliveredAssistant = TestFactories.makeMessage(
            role: .assistant,
            text: "final assistant reply",
            estimatedCost: 0.35
        )
        let generatingAssistant = TestFactories.makeMessage(
            role: .assistant,
            text: "working",
            estimatedCost: 0.9,
            state: .generating
        )

        var updatedTarget = originalTarget
        updatedTarget.title = "Stale Title"
        updatedTarget.previewText = "Stale Preview"
        updatedTarget.estimatedCost = 999
        updatedTarget.messages = [originalTarget.messages[0], deliveredAssistant, generatingAssistant]
        updatedTarget.updatedAt = Date(timeIntervalSince1970: 1234)

        try harness.store.upsertConversation(updatedTarget)

        let restoredUntouched = try #require(try harness.store.fetchConversationThread(id: untouched.id))
        #expect(restoredUntouched.summary.title == "Untouched")
        #expect(restoredUntouched.messages.map(\.text) == ["keep me"])

        let restoredTarget = try #require(try harness.store.fetchConversationThread(id: originalTarget.id))
        #expect(restoredTarget.summary.messageCount == 3)
        #expect(restoredTarget.summary.previewText == "final assistant reply")
        #expect(restoredTarget.summary.title == "hello world from the user")
        #expect(abs(restoredTarget.summary.estimatedCost - 0.45) < 0.000_001)
        #expect(restoredTarget.messages.map(\.text) == [
            "hello world from the user",
            "final assistant reply",
            "working"
        ])
    }

    @Test("Upsert Conversation Preserves Conversation Estimated Cost Without Delivered Message Costs")
    func upsertConversationPreservesConversationEstimatedCostWithoutDeliveredMessageCosts() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conversation = TestFactories.makeConversation(
            title: "Imported Summary Cost",
            estimatedCost: 2.5
        )

        try harness.store.upsertConversation(conversation)

        let restored = try #require(try harness.store.fetchConversationThread(id: conversation.id))
        #expect(restored.summary.title == "Imported Summary Cost")
        #expect(abs(restored.summary.estimatedCost - 2.5) < 0.000_001)
    }

    @Test("MessageObservation: only tracks the current conversation")
    @MainActor
    func messageObservationTracksOnlyObservedConversation() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let observed = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(text: "one")]
        )
        let other = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(text: "other")]
        )
        try harness.store.replaceAllConversations([observed, other])

        let observation = MessageObservation(attachmentFileStore: harness.fileStore)
        observation.observe(conversationID: observed.id, in: harness.dbPool)

        await waitUntil { observation.messages.map(\.text) == ["one"] }
        #expect(observation.messages.map(\.text) == ["one"])

        var updatedOther = other
        updatedOther.messages.append(TestFactories.makeMessage(text: "other-2"))
        try harness.store.replaceAllConversations([observed, updatedOther])

        await waitUntil { observation.messages.map(\.text) == ["one"] }
        #expect(observation.messages.map(\.text) == ["one"])

        var updatedObserved = observed
        updatedObserved.messages.append(TestFactories.makeMessage(text: "two"))
        try harness.store.replaceAllConversations([updatedObserved, updatedOther])

        await waitUntil { observation.messages.map(\.text) == ["one", "two"] }
        #expect(observation.messages.map(\.text) == ["one", "two"])
    }

    @Test("CurrentConversationObservation: observe completes initial summary bootstrap")
    @MainActor
    func currentConversationObservationHydratesImmediately() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let observed = TestFactories.makeConversation(
            title: "Observed",
            messages: [TestFactories.makeMessage(text: "hello")]
        )
        try harness.store.replaceAllConversations([observed])

        let observation = CurrentConversationObservation()
        observation.observe(conversationID: observed.id, in: harness.dbPool)

        for _ in 0..<50 {
            if observation.hasLoadedInitialValue { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(observation.hasLoadedInitialValue == true)
        #expect(observation.summary?.id == observed.id)
        #expect(observation.summary?.title == "Observed")
        #expect(observation.summary?.previewText == "hello")
        #expect(observation.summary?.messageCount == 1)
    }

    @Test("CurrentConversationObservation: initial summary read failure is not disguised as a missing conversation")
    @MainActor
    func currentConversationObservationDoesNotMarkLoadCompleteAfterInitialFailure() async throws {
        let harness = try BrokenSchemaHarness()
        defer { harness.cleanup() }

        let observation = CurrentConversationObservation()
        observation.observe(conversationID: UUID(), in: harness.dbPool)

        await waitUntil { observation.initialLoadFailed }

        #expect(observation.hasLoadedInitialValue == false)
        #expect(observation.initialLoadFailed == true)
        #expect(observation.summary == nil)
    }

    @Test("MessageObservation: observe completes initial message bootstrap")
    @MainActor
    func messageObservationHydratesImmediately() async throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let observed = TestFactories.makeConversation(
            messages: [
                TestFactories.makeMessage(role: .user, text: "one"),
                TestFactories.makeMessage(role: .assistant, text: "two")
            ]
        )
        try harness.store.replaceAllConversations([observed])

        let observation = MessageObservation(attachmentFileStore: harness.fileStore)
        observation.observe(conversationID: observed.id, in: harness.dbPool)

        await waitUntil { !observation.messages.isEmpty }

        #expect(observation.revision > 0)
        #expect(observation.messages.map(\.text) == ["one", "two"])
    }

    @Test("MessageObservation: initial message read failure exposes the failure state")
    @MainActor
    func messageObservationMarksInitialLoadFailure() async throws {
        let harness = try BrokenSchemaHarness()
        defer { harness.cleanup() }

        let observation = MessageObservation(attachmentFileStore: AttachmentFileStore(rootDirectory: harness.rootURL))
        observation.observe(conversationID: UUID(), in: harness.dbPool)

        await waitUntil { observation.initialLoadFailed }

        #expect(observation.initialLoadFailed == true)
        #expect(observation.messages.isEmpty)
        #expect(observation.revision == 0)
    }


    @Test("Insert Conversation Preserves Existing Messages")
    func insertConversationPreservesExistingMessages() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let providerID = UUID()
        let message = TestFactories.makeMessage(role: .user, text: "preserved", providerKind: .openAI)
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            messages: [message]
        )

        try harness.store.replaceAllConversations([conversation])

        var updatedSummary = try harness.store.fetchConversationSummary(id: conversation.id)!
        updatedSummary.title = "Updated Title"
        try harness.store.insertConversation(updatedSummary)

        let messages = try harness.store.fetchMessages(for: conversation.id)
        #expect(messages.count == 1)
        #expect(messages[0].text == "preserved")

        let refreshed = try harness.store.fetchConversationSummary(id: conversation.id)
        #expect(refreshed?.title == "Updated Title")
    }

    @Test("Upsert Hydrated Messages Preserves Summary Metadata")
    func upsertHydratedMessagesPreservesSummaryMetadata() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let conversationID = UUID()
        let providerID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_999)
        let metadataOnlySummary = ConversationSummary(
            id: conversationID,
            title: "Original title",
            hasCustomTitle: true,
            providerID: providerID,
            providerKind: .openAI,
            modelID: "gpt-4o",
            previewText: "Original latest preview",
            messageCount: 200,
            estimatedCost: 2.5,
            isDraft: false,
            draftText: "",
            createdAt: createdAt,
            updatedAt: updatedAt,
            folderID: nil,
            useMemory: true,
            skillId: nil,
            messagesHydratedAt: nil,
            messagesStale: true,
            deletedAt: nil,
            isConflictCopy: false,
            originalConversationId: nil,
            pinnedNoteIds: []
        )
        try harness.store.insertConversation(metadataOnlySummary)

        let partialWindow = [
            TestFactories.makeMessage(role: .user, text: "old before", createdAt: Date(timeIntervalSince1970: 10)),
            TestFactories.makeMessage(role: .assistant, text: "old anchor", createdAt: Date(timeIntervalSince1970: 11)),
            TestFactories.makeMessage(role: .user, text: "old after", createdAt: Date(timeIntervalSince1970: 12))
        ]
        try harness.store.upsertHydratedMessages(partialWindow, conversationID: conversationID)

        let refreshed = try #require(try harness.store.fetchConversationSummary(id: conversationID))
        #expect(refreshed.title == "Original title")
        #expect(refreshed.previewText == "Original latest preview")
        #expect(refreshed.messageCount == 200)
        #expect(refreshed.messagesHydratedAt == nil)
        #expect(refreshed.messagesStale == true)
        #expect(refreshed.updatedAt == updatedAt)

        let messages = try harness.store.fetchMessages(for: conversationID)
        #expect(messages.map(\.text) == ["old before", "old anchor", "old after"])
    }


    @Test("Upsert Conversation Incremental Message Update")
    func upsertConversationIncrementalMessageUpdate() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let providerID = UUID()
        let msg1 = TestFactories.makeMessage(role: .user, text: "hello", providerKind: .openAI)
        let msg2 = TestFactories.makeMessage(role: .assistant, text: "original response", providerKind: .openAI, state: .generating)
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            messages: [msg1, msg2]
        )

        try harness.store.upsertConversation(conversation)

        var updated = conversation
        updated.messages[1].text = "completed response"
        updated.messages[1].state = .delivered
        try harness.store.upsertConversation(updated)

        let messages = try harness.store.fetchMessages(for: conversation.id)
        #expect(messages.count == 2)
        #expect(messages[0].text == "hello")
        #expect(messages[1].text == "completed response")
        #expect(messages[1].state == .delivered)
    }

    @Test("Upsert Conversation Appends New Message")
    func upsertConversationAppendsNewMessage() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let providerID = UUID()
        let msg1 = TestFactories.makeMessage(role: .user, text: "q1", providerKind: .openAI)
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            messages: [msg1]
        )

        try harness.store.upsertConversation(conversation)

        var updated = conversation
        let msg2 = TestFactories.makeMessage(role: .assistant, text: "a1", providerKind: .openAI)
        updated.messages.append(msg2)
        try harness.store.upsertConversation(updated)

        let messages = try harness.store.fetchMessages(for: conversation.id)
        #expect(messages.count == 2)
        #expect(messages[0].text == "q1")
        #expect(messages[1].text == "a1")
    }

    @Test("Upsert Conversation Removes Deleted Messages")
    func upsertConversationRemovesDeletedMessages() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let providerID = UUID()
        let msg1 = TestFactories.makeMessage(role: .user, text: "keep", providerKind: .openAI)
        let msg2 = TestFactories.makeMessage(role: .assistant, text: "remove", providerKind: .openAI)
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            messages: [msg1, msg2]
        )

        try harness.store.upsertConversation(conversation)

        var updated = conversation
        updated.messages.removeAll { $0.id == msg2.id }
        try harness.store.upsertConversation(updated)

        let messages = try harness.store.fetchMessages(for: conversation.id)
        #expect(messages.count == 1)
        #expect(messages[0].text == "keep")
    }


    @Test("Batched Attachment Fetch Returns Correct Results")
    func batchedAttachmentFetchReturnsCorrectResults() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        let providerID = UUID()
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            let att = TestFactories.makeFileAttachment(
                base64Data: Data("file-\(i)".utf8).base64EncodedString()
            )
            let msg = TestFactories.makeMessage(
                role: i.isMultiple(of: 2) ? .user : .assistant,
                text: "msg-\(i)",
                providerKind: .openAI,
                attachments: [att]
            )
            messages.append(msg)
        }

        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            messages: messages
        )

        try harness.store.replaceAllConversations([conversation])

        let hydrated = try harness.store.fetchAllConversations(hydrateFilePayloads: true)
        #expect(hydrated.count == 1)
        #expect(hydrated[0].messages.count == 10)
        for (i, msg) in hydrated[0].messages.enumerated() {
            #expect(msg.attachments?.count == 1)
            #expect(msg.attachments?.first?.base64Data != nil)
        }
    }

    @Test("Attachment File Store Exists Check")
    func attachmentFileStoreExistsCheck() throws {
        let harness = try TestHarness()
        defer { harness.cleanup() }

        #expect(harness.fileStore.exists(id: "nonexistent") == false)

        let savedID = try harness.fileStore.saveBase64(
            Data("test".utf8).base64EncodedString(),
            for: "test-file"
        )
        #expect(harness.fileStore.exists(id: savedID) == true)
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int(timeoutNanoseconds)))
    while condition() == false && ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

struct TestHarness {
    let rootURL: URL
    let filesURL: URL
    let dbPool: DatabasePool
    let fileStore: AttachmentFileStore
    let store: ConversationStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-db-tests-\(UUID().uuidString)", isDirectory: true)
        filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)

        fileStore = AttachmentFileStore(rootDirectory: filesURL)
        dbPool = try DatabasePool(
            path: rootURL.appendingPathComponent(DatabaseSchema.fileName).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        try DatabaseSchema.makeMigrator(attachmentFileStore: fileStore).migrate(dbPool)
        store = ConversationStore(dbPool: dbPool, attachmentFileStore: fileStore)
    }

    func cleanup() {
        // DatabasePool keeps WAL descriptors alive until explicitly closed.  Removing the
        // temporary directory first corrupts the simulator's SQLite view and can mask a real
        // sidecar lifecycle failure behind vnode-unlinked warnings.
        try? dbPool.close()
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeContinuationStore() throws -> RecipeContinuationStore {
        let directory = rootURL.appendingPathComponent("LocalOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        let sidecarPool = try DatabasePool(path: directory.appendingPathComponent("recipe-continuation.sqlite").path)
        return try RecipeContinuationStore(dbPool: sidecarPool, parentPool: dbPool)
    }

    func makeStoreWithContinuationSweep() throws -> (ConversationStore, RecipeContinuationStore) {
        let continuation = try makeContinuationStore()
        let store = ConversationStore(
            dbPool: dbPool,
            attachmentFileStore: fileStore,
            continuationOrphanSweep: { try continuation.purgeMissingParentMessages() }
        )
        return (store, continuation)
    }
}

private struct BrokenSchemaHarness {
    let rootURL: URL
    let dbPool: DatabasePool

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-db-broken-schema-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        dbPool = try DatabasePool(
            path: rootURL.appendingPathComponent(DatabaseSchema.fileName).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
    }

    func cleanup() {
        try? dbPool.close()
        try? FileManager.default.removeItem(at: rootURL)
    }
}
