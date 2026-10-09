import Foundation
import Testing
@testable import Oriveo

@Suite("ConversationColdStartLoad", .serialized)
struct ConversationColdStartLoadTests {

    @Test("loadLegacyProjection does not write a recovery snapshot on the calling thread, but the snapshot still lands on disk")
    @MainActor
    func loadLegacyProjectionDefersRecoverySnapshotWrite() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "coldstart-recovery-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let bridge = ConversationRuntimeBridge()
        let conversation = TestFactories.makeConversation(
            title: "Cold Start",
            messages: [TestFactories.makeMessage(text: "hello")]
        )
        _ = try bridge.replaceAllConversations([conversation], uid: uid)

        let snapshotURL = AppSessionStore.recoverySnapshotPath(for: uid)
        try? FileManager.default.removeItem(at: snapshotURL)

        let loaded = try bridge.loadLegacyProjection(uid: uid, hydrateFilePayloads: false)
        #expect(loaded.map(\.id) == [conversation.id])

        try await waitUntil { FileManager.default.fileExists(atPath: snapshotURL.path) }
        let recovered = bridge.loadRecoveryProjection(snapshot: nil, uid: uid)
        #expect(recovered.map(\.id) == [conversation.id])
    }

    @Test("an async snapshot write on the read path must not last-write-win over a later explicit persist")
    @MainActor
    func deferredRecoveryWriteNeverClobbersALaterExplicitWrite() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "coldstart-recovery-order-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let bridge = ConversationRuntimeBridge()
        let snapshotURL = AppSessionStore.recoverySnapshotPath(for: uid)

        for _ in 0..<20 {
            try? FileManager.default.removeItem(at: snapshotURL)
            let conversation = TestFactories.makeConversation(
                title: "Newest",
                messages: [TestFactories.makeMessage(text: "newest")]
            )

            let loaded = try bridge.loadLegacyProjection(uid: uid, hydrateFilePayloads: false)
            #expect(loaded.isEmpty)
            try bridge.persistRecoveryProjectionOnly([conversation], for: uid)

            let recovered = bridge.loadRecoveryProjection(snapshot: nil, uid: uid)
            #expect(recovered.map(\.id) == [conversation.id])
        }
    }

    @Test("bind reuses the already-loaded in-memory projection instead of re-reading the whole table")
    @MainActor
    func bindReusesAlreadyLoadedProjection() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "coldstart-bind-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let inDatabaseOnly = TestFactories.makeConversation(
            title: "OnlyInDatabase",
            messages: [TestFactories.makeMessage(text: "db")]
        )
        let inMemory = TestFactories.makeConversation(
            title: "AlreadyLoaded",
            messages: [TestFactories.makeMessage(text: "mem")]
        )

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations([inDatabaseOnly], uid: uid)
        state.conversations = [inMemory]

        let manager = ConversationManager()
        manager.bind(to: state)
        #expect(manager.recentConversations.map(\.id) == [inMemory.id])
    }

    @Test("bind still falls back to the database when the in-memory mirror is empty")
    @MainActor
    func bindFallsBackToDatabaseWhenMemoryIsEmpty() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "coldstart-bind-empty-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let stored = TestFactories.makeConversation(
            title: "OnlyInDatabase",
            messages: [TestFactories.makeMessage(text: "db")]
        )

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations([stored], uid: uid)
        state.conversations = []

        let manager = ConversationManager()
        manager.bind(to: state)
        #expect(manager.recentConversations.map(\.id) == [stored.id])
    }

    @Test("cache rebuild uses the authoritative projection and does not hydrate attachment bytes")
    @MainActor
    func cacheRebuildProjectionSkipsAttachmentHydration() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "coldstart-hydrate-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let attachment = TestFactories.makeFileAttachment(
            base64Data: Data("cold-start-sidecar".utf8).base64EncodedString()
        )
        let stored = TestFactories.makeConversation(
            title: "WithAttachment",
            messages: [TestFactories.makeMessage(role: .assistant, text: "body", attachments: [attachment])]
        )

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations([stored], uid: uid)
        state.conversations = []

        let manager = ConversationManager()
        manager.bind(to: state)

        let rebuilt = try #require(manager.recentConversations.first)
        #expect(rebuilt.id == stored.id)
        #expect(rebuilt.messages.isEmpty, "cache rebuild uses the summary projection and does not load message bodies")
        #expect(rebuilt.displayMessageCount == 1)

        let hydrated = try state.authoritativeConversationProjection(for: uid, hydrateFilePayloads: true)
        #expect(hydrated.first?.messages.first?.attachments?.first?.base64Data == attachment.base64Data)
    }

    @Test("editing a user message with attachments puts the text and original attachments back in the composer as independent copies that can be sent again")
    @MainActor
    func editUserMessageRestoresItsAttachments() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "coldstart-edit-att-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let body = Data("report body".utf8).base64EncodedString()
        var file = TestFactories.makeFileAttachment(base64Data: body)
        let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])
        let imageKey = UUID().uuidString
        let image = Attachment(
            id: UUID(), kind: .image, fileName: "image.jpg", mimeType: "image/jpeg",
            localImageID: imageKey
        )
        // An image with no original on this device: putting it back could not be sent anyway.
        let remoteOnly = Attachment(
            id: UUID(), kind: .image, fileName: "remote.jpg", mimeType: "image/jpeg"
        )
        let user = TestFactories.makeMessage(
            role: .user, text: "summarize this", state: .delivered, attachments: [file, image, remoteOnly]
        )
        let assistant = TestFactories.makeMessage(role: .assistant, text: "ok", state: .delivered)
        let conversation = TestFactories.makeConversation(title: "Editable", messages: [user, assistant])
        _ = try ConversationRuntimeBridge().replaceAllConversations([conversation], uid: uid)

        let state = AppState(sessionUID: uid)
        ImageStore.save(imageData: imageBytes, for: imageKey, partitionUID: uid)
        // The thread in memory comes from a projection that does not read file payloads: editing has to read the payload back itself.
        #expect(state.hydrateConversationMessagesIfNeeded(id: conversation.id, hydrateFilePayloads: false))
        #expect(state.conversations.first { $0.id == conversation.id }?
            .messages.first?.attachments?.first?.base64Data == nil)

        let draft = try #require(state.beginEditingUserMessage(messageID: user.id, in: conversation.id))
        #expect(draft.text == "summarize this")
        #expect(draft.attachments.map(\.fileName) == [file.fileName, "image.jpg"])

        let restoredFile = try #require(draft.attachments.first)
        #expect(restoredFile.kind == .file)
        #expect(restoredFile.base64Data == body)
        #expect(restoredFile.id != file.id)

        let restoredImage = try #require(draft.attachments.last)
        #expect(restoredImage.id != image.id)
        let newKey = try #require(restoredImage.localImageID)
        #expect(newKey != imageKey)
        #expect(ImageStore.loadImageData(for: newKey, partitionUID: uid) == imageBytes)

        // Files put back pass the send check as usual, and their body makes it into the request.
        let plan = AttachmentDelivery.plan(
            userText: draft.text, attachments: draft.attachments,
            transport: AttachmentTransport.openAIChat.profile, model: nil
        )
        #expect(plan.skipped.isEmpty)
        #expect(plan.injectedText.contains("report body"))

        let afterEdit = try #require(state.conversations.first { $0.id == conversation.id })
        #expect(afterEdit.messages.isEmpty)
        // The old entry point still returns only the text.
        #expect(state.editUserMessage(messageID: user.id, in: conversation.id) == nil)
    }

    @Test("Editing a user message after a summary load hydrates the thread instead of failing silently")
    @MainActor
    func editUserMessageAfterSummaryLoadHydratesThread() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "coldstart-edit-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let user = TestFactories.makeMessage(role: .user, text: "please edit me", state: .delivered)
        let assistant = TestFactories.makeMessage(role: .assistant, text: "ok", state: .delivered)
        let conversation = TestFactories.makeConversation(
            title: "Editable",
            messages: [user, assistant]
        )
        _ = try ConversationRuntimeBridge().replaceAllConversations([conversation], uid: uid)

        let state = AppState(sessionUID: uid)
        let listed = try #require(state.conversations.first { $0.id == conversation.id })
        #expect(listed.messages.isEmpty)
        #expect(listed.displayMessageCount == 2)

        let restored = state.editUserMessage(messageID: user.id, in: conversation.id)
        #expect(restored == "please edit me")
        let afterEdit = try #require(state.conversations.first { $0.id == conversation.id })
        #expect(afterEdit.messages.isEmpty, "Edit truncates that message and everything after it")
        #expect(afterEdit.draftText == "please edit me")
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        intervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while condition() == false {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }
}
