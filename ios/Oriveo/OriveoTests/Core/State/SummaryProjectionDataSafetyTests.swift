import Foundation
import Testing
@testable import Oriveo

/// Cold-start memory is a summary projection (`messagesAreLoaded == false`, empty `messages`).
/// Every assertion here reads the database: checking memory alone is exactly how writes that
/// wiped stored messages went unnoticed.
@Suite("SummaryProjectionDataSafety", .serialized)
@MainActor
struct SummaryProjectionDataSafetyTests {

    // MARK: - Store

    @Test("replacing everything with summary projections keeps messages, attachment sidecars and the body index")
    func replaceAllWithSummariesKeepsMessagesAndSidecars() async throws {
        try await withIsolatedUID("summary-replace") { uid in
            let bridge = ConversationRuntimeBridge()
            let attachment = TestFactories.makeFileAttachment()
            let conversation = TestFactories.makeConversation(
                title: "Keep me",
                messages: [
                    TestFactories.makeMessage(role: .user, text: "needle question", attachments: [attachment]),
                    TestFactories.makeMessage(role: .assistant, text: "answer", state: .delivered)
                ]
            )
            _ = try bridge.replaceAllConversations([conversation], uid: uid)

            let summaries = try bridge.fetchConversationSummaryProjection(uid: uid)
            #expect(summaries.allSatisfy { !$0.messagesAreLoaded && $0.messages.isEmpty })
            _ = try bridge.replaceAllConversations(summaries, uid: uid)

            let stored = try #require(try bridge.fetchConversationProjection(id: conversation.id, uid: uid))
            #expect(stored.messages.map(\.text) == ["needle question", "answer"])
            #expect(stored.messages.first?.attachments?.first?.base64Data == attachment.base64Data)
            let hits = try await makeStore(uid: uid).search(query: "needle")
            #expect(hits.map(\.id) == [conversation.id])
        }
    }

    @Test("replacing everything deletes conversations outside the set together with their messages")
    func replaceAllRemovesAbsentConversations() throws {
        try withIsolatedUIDSync("summary-replace-remove") { uid in
            let bridge = ConversationRuntimeBridge()
            let kept = TestFactories.makeConversation(title: "Kept", messages: [TestFactories.makeMessage(text: "k")])
            let removed = TestFactories.makeConversation(title: "Removed", messages: [TestFactories.makeMessage(text: "r")])
            _ = try bridge.replaceAllConversations([kept, removed], uid: uid)

            let summaries = try bridge.fetchConversationSummaryProjection(uid: uid).filter { $0.id == kept.id }
            _ = try bridge.replaceAllConversations(summaries, uid: uid)

            let all = try bridge.fetchConversationProjection(uid: uid, hydrateFilePayloads: false)
            #expect(all.map(\.id) == [kept.id])
            #expect(all.first?.messages.map(\.text) == ["k"])
        }
    }

    @Test("truncating to zero messages deletes rows only when ids are passed; an empty array alone deletes nothing")
    func explicitDeletionIsRequiredToEmptyThread() throws {
        try withIsolatedUIDSync("summary-explicit-delete") { uid in
            let bridge = ConversationRuntimeBridge()
            let user = TestFactories.makeMessage(role: .user, text: "q")
            let assistant = TestFactories.makeMessage(role: .assistant, text: "a")
            var conversation = TestFactories.makeConversation(messages: [user, assistant])
            _ = try bridge.replaceAllConversations([conversation], uid: uid)

            conversation.messages = []
            try bridge.upsertConversationWithoutReadback(conversation, uid: uid)
            #expect(try bridge.fetchConversationProjection(id: conversation.id, uid: uid)?.messages.count == 2)

            try bridge.upsertConversationWithoutReadback(
                conversation,
                uid: uid,
                deletingMessageIDs: [user.id, assistant.id]
            )
            let summary = try #require(try makeStore(uid: uid).fetchConversationSummary(id: conversation.id))
            #expect(try bridge.fetchConversationProjection(id: conversation.id, uid: uid)?.messages.isEmpty == true)
            #expect(summary.messageCount == 0)
        }
    }

    @Test("writing an unloaded conversation that carries messages only adds and updates, other stored messages stay")
    func unloadedConversationWriteIsAdditive() throws {
        try withIsolatedUIDSync("summary-additive") { uid in
            let bridge = ConversationRuntimeBridge()
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            let old = TestFactories.makeMessage(role: .user, text: "old", createdAt: base)
            let conversation = TestFactories.makeConversation(messages: [old])
            _ = try bridge.replaceAllConversations([conversation], uid: uid)

            var summary = try #require(try bridge.fetchConversationSummaryProjection(uid: uid).first)
            summary.messages = [TestFactories.makeMessage(role: .assistant, text: "new", createdAt: base.addingTimeInterval(1))]
            try bridge.upsertConversationWithoutReadback(summary, uid: uid)

            #expect(try bridge.fetchConversationProjection(id: conversation.id, uid: uid)?.messages.map(\.text) == ["old", "new"])
            #expect(try makeStore(uid: uid).fetchConversationSummary(id: conversation.id)?.messageCount == 2)
        }
    }

    @Test("a renamed summary projection is found by its new title")
    func renamingSummaryUpdatesSearchTitle() async throws {
        try await withIsolatedUID("summary-rename") { uid in
            let bridge = ConversationRuntimeBridge()
            let conversation = TestFactories.makeConversation(
                title: "Old title",
                hasCustomTitle: true,
                messages: [TestFactories.makeMessage(text: "body")]
            )
            _ = try bridge.replaceAllConversations([conversation], uid: uid)

            var summary = try #require(try bridge.fetchConversationSummaryProjection(uid: uid).first)
            summary.title = "Zebra renamed"
            try bridge.upsertConversationWithoutReadback(summary, uid: uid)

            let store = try makeStore(uid: uid)
            #expect(try await store.search(query: "Zebra").map(\.id) == [conversation.id])
            #expect(try await store.search(query: "body").map(\.id) == [conversation.id])
        }
    }

    @Test("merging hydrated message rows keeps the local messageCount column in step")
    func hydratedMessagesUpdateLocalCount() throws {
        try withIsolatedUIDSync("summary-backfill-count") { uid in
            let bridge = ConversationRuntimeBridge()
            let conversation = TestFactories.makeConversation(messages: [TestFactories.makeMessage(text: "one")])
            _ = try bridge.replaceAllConversations([conversation], uid: uid)
            let store = try makeStore(uid: uid)
            try store.upsertHydratedMessages(
                [TestFactories.makeMessage(role: .assistant, text: "two")],
                conversationID: conversation.id
            )
            #expect(try store.fetchConversationSummary(id: conversation.id)?.messageCount == 2)
        }
    }

    // MARK: - Cold-start merge

    @Test("cold start keeps messages when updatedAt ties")
    func tiedUpdatedAtColdStartKeepsMessages() throws {
        try withIsolatedUIDSync("summary-tie") { uid in
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            var low = TestFactories.makeConversation(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                title: "Low",
                messages: [TestFactories.makeMessage(text: "l1", createdAt: base)],
                createdAt: base,
                updatedAt: base
            )
            var high = TestFactories.makeConversation(
                id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!,
                title: "High",
                messages: [TestFactories.makeMessage(text: "h1", createdAt: base)],
                createdAt: base,
                updatedAt: base
            )
            low.updatedAt = base
            high.updatedAt = base
            _ = try ConversationRuntimeBridge().replaceAllConversations([low, high], uid: uid)
            try? FileManager.default.removeItem(at: AppSessionStore.recoverySnapshotPath(for: uid))

            let state = AppState(sessionUID: uid)
            state.persistSessionNow(for: uid)

            let stored = try ConversationRuntimeBridge().fetchConversationProjection(uid: uid, hydrateFilePayloads: false)
            #expect(stored.count == 2)
            #expect(stored.allSatisfy { $0.messages.count == 1 })
            #expect(state.conversations.allSatisfy { !$0.messagesAreLoaded })
        }
    }

    @Test("a recovery snapshot holding a conversation missing from the database does not wipe other messages on cold start")
    func recoverySnapshotWithExtraConversationKeepsOthers() throws {
        try withIsolatedUIDSync("summary-extra-recovered") { uid in
            let bridge = ConversationRuntimeBridge()
            let kept = TestFactories.makeConversation(
                title: "Kept",
                messages: [
                    TestFactories.makeMessage(role: .user, text: "a1"),
                    TestFactories.makeMessage(role: .assistant, text: "a2")
                ]
            )
            let gone = TestFactories.makeConversation(title: "Gone", messages: [TestFactories.makeMessage(text: "g1")])
            _ = try bridge.replaceAllConversations([kept], uid: uid)
            try bridge.persistRecoveryProjectionOnly([gone, kept], for: uid)

            let state = AppState(sessionUID: uid)
            state.persistSessionNow(for: uid)

            let keptStored = try #require(try bridge.fetchConversationProjection(id: kept.id, uid: uid))
            #expect(keptStored.messages.map(\.text) == ["a1", "a2"])
            #expect(state.conversations.allSatisfy { !$0.messagesAreLoaded })
        }
    }

    @Test("replacing the projection with summaries keeps the stored messages")
    func replaceProjectionWithSummariesKeepsDatabaseMessages() throws {
        try withIsolatedUIDSync("summary-projection-replace") { uid in
            let bridge = ConversationRuntimeBridge()
            let first = TestFactories.makeConversation(title: "First", messages: [TestFactories.makeMessage(text: "f")])
            let second = TestFactories.makeConversation(title: "Second", messages: [TestFactories.makeMessage(text: "s")])
            _ = try bridge.replaceAllConversations([first, second], uid: uid)

            let state = AppState(sessionUID: uid)
            var local = state.conversations
            let index = try #require(local.firstIndex { $0.id == first.id })
            local[index].title = "Renamed"
            state.replaceConversationProjection(local)
            state.persistSessionNow(for: uid)

            let stored = try bridge.fetchConversationProjection(uid: uid, hydrateFilePayloads: false)
            #expect(stored.first { $0.id == first.id }?.title == "Renamed")
            #expect(stored.first { $0.id == first.id }?.messages.map(\.text) == ["f"])
            #expect(stored.first { $0.id == second.id }?.messages.map(\.text) == ["s"])
        }
    }

    @Test("replacing with summaries and reading back keeps memory as summaries instead of loading every body")
    func replaceProjectionOrThrowKeepsSummaries() throws {
        try withIsolatedUIDSync("summary-replace-throw") { uid in
            let bridge = ConversationRuntimeBridge()
            let conversation = TestFactories.makeConversation(messages: [TestFactories.makeMessage(text: "x")])
            _ = try bridge.replaceAllConversations([conversation], uid: uid)

            let state = AppState(sessionUID: uid)
            try state.replaceConversationProjectionOrThrow(state.conversations)

            #expect(try bridge.fetchConversationProjection(id: conversation.id, uid: uid)?.messages.map(\.text) == ["x"])
            #expect(state.conversations.first?.messagesAreLoaded == false)
        }
    }

    // MARK: - Editing and hydration

    @Test("editing the first user message after a summary load deletes the stored messages, and sending still works")
    func editingFirstMessageAfterSummaryLoadDeletesRows() throws {
        try withIsolatedUIDSync("summary-edit-first") { uid in
            let bridge = ConversationRuntimeBridge()
            let user = TestFactories.makeMessage(role: .user, text: "please edit me")
            let assistant = TestFactories.makeMessage(role: .assistant, text: "ok")
            let conversation = TestFactories.makeConversation(title: "Editable", messages: [user, assistant])
            _ = try bridge.replaceAllConversations([conversation], uid: uid)

            let state = AppState(sessionUID: uid)
            #expect(state.editUserMessage(messageID: user.id, in: conversation.id) == "please edit me")
            state.persistSessionNow(for: uid)

            #expect(try bridge.fetchConversationProjection(id: conversation.id, uid: uid)?.messages.isEmpty == true)
            #expect(
                state.hydrateConversationMessagesIfNeeded(id: conversation.id),
                "A truncated thread must not be treated as missing history that blocks sending"
            )

            // After a restart it must not look like missing history either.
            DatabaseManager.shared.close()
            let restarted = AppState(sessionUID: uid)
            #expect(restarted.hydrateConversationMessagesIfNeeded(id: conversation.id))
            #expect(restarted.conversation(for: conversation.id)?.messages.isEmpty == true)
        }
    }

    @Test("hydration fills in messages only and keeps newer in-memory metadata")
    func hydrateKeepsInMemoryMetadata() throws {
        try withIsolatedUIDSync("summary-hydrate-metadata") { uid in
            let bridge = ConversationRuntimeBridge()
            let conversation = TestFactories.makeConversation(title: "Stored", messages: [TestFactories.makeMessage(text: "m")])
            _ = try bridge.replaceAllConversations([conversation], uid: uid)

            let state = AppState(sessionUID: uid)
            let index = try #require(state.conversations.firstIndex { $0.id == conversation.id })
            state.conversations[index].title = "Renamed in memory"

            #expect(state.hydrateConversationMessagesIfNeeded(id: conversation.id))
            let hydrated = try #require(state.conversation(for: conversation.id))
            #expect(hydrated.title == "Renamed in memory")
            #expect(hydrated.messagesAreLoaded)
            #expect(hydrated.messages.map(\.text) == ["m"])
        }
    }

    // MARK: - Deletion and export

    @Test("deleting a summary-projection conversation removes its on-device images")
    func deletingSummaryConversationCleansImages() throws {
        try withIsolatedUIDSync("summary-delete-images") { uid in
            AppSessionStore.switchToUser(uid)
            let localImageID = UUID().uuidString
            ImageStore.save(imageData: Data([0xFF, 0xD8, 0xFF]), for: localImageID, partitionUID: uid)
            let attachment = TestFactories.makeImageAttachment(localImageID: localImageID)
            let conversation = TestFactories.makeConversation(
                messages: [TestFactories.makeMessage(role: .user, text: "img", attachments: [attachment])]
            )
            _ = try ConversationRuntimeBridge().replaceAllConversations([conversation], uid: uid)

            let state = AppState(sessionUID: uid)
            #expect(state.conversations.first?.messagesAreLoaded == false)
            #expect(ImageStore.imageExists(for: localImageID, partitionUID: uid))

            let manager = ConversationManager()
            manager.bind(to: state)
            manager.deleteConversation(id: conversation.id)

            #expect(!ImageStore.imageExists(for: localImageID, partitionUID: uid))
        }
    }

    @Test("the recovery snapshot refuses summary projections")
    func recoverySnapshotRefusesSummaries() throws {
        try withIsolatedUIDSync("summary-snapshot-refuse") { uid in
            let bridge = ConversationRuntimeBridge()
            let conversation = TestFactories.makeConversation(messages: [TestFactories.makeMessage(text: "full")])
            _ = try bridge.replaceAllConversations([conversation], uid: uid)
            try bridge.persistRecoveryProjectionOnly([conversation], for: uid)

            let summaries = try bridge.fetchConversationSummaryProjection(uid: uid)
            try bridge.persistRecoveryProjectionOnly(summaries, for: uid)

            let recovered = bridge.loadRecoveryProjection(snapshot: nil, uid: uid)
            #expect(recovered.first?.messages.map(\.text) == ["full"])
        }
    }

    @Test("entering the background skips the full snapshot dump when nothing was written, and dumps after a write")
    func lifecycleDumpSkipsWhenUnchanged() throws {
        try withIsolatedUIDSync("summary-dump-skip") { uid in
            let bridge = ConversationRuntimeBridge()
            let conversation = TestFactories.makeConversation(messages: [TestFactories.makeMessage(text: "v1")])
            _ = try bridge.replaceAllConversations([conversation], uid: uid)
            try bridge.persistRecoveryProjectionFromDatabase(uid: uid)
            let url = AppSessionStore.recoverySnapshotPath(for: uid)
            let firstDate = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)

            Thread.sleep(forTimeInterval: 1.1)
            try bridge.persistRecoveryProjectionFromDatabase(uid: uid, skipIfUnchanged: true)
            let unchangedDate = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            #expect(unchangedDate == firstDate)

            var updated = conversation
            updated.messages.append(TestFactories.makeMessage(role: .assistant, text: "v2"))
            try bridge.upsertConversationWithoutReadback(updated, uid: uid)
            try bridge.persistRecoveryProjectionFromDatabase(uid: uid, skipIfUnchanged: true)
            #expect(bridge.loadRecoveryProjection(snapshot: nil, uid: uid).first?.messages.count == 2)
        }
    }

    // MARK: - Helpers

    private func withIsolatedUIDSync(_ prefix: String, _ body: (String) throws -> Void) throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "\(prefix)-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        try body(uid)
    }

    private func withIsolatedUID(_ prefix: String, _ body: (String) async throws -> Void) async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "\(prefix)-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        try await body(uid)
    }

    private func makeStore(uid: String) throws -> ConversationStore {
        ConversationStore(
            dbPool: try DatabaseManager.shared.openIfNeeded(for: uid),
            attachmentFileStore: AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        )
    }
}
