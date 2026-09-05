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
        #expect(rebuilt.messages.first?.text == "body")
        #expect(rebuilt.messages.first?.attachments?.first?.base64Data == nil)

        let hydrated = try state.authoritativeConversationProjection(for: uid, hydrateFilePayloads: true)
        #expect(hydrated.first?.messages.first?.attachments?.first?.base64Data == attachment.base64Data)
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
