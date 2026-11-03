import Foundation
import Testing
@testable import Oriveo

@Suite("ImmediateSessionPersist", .serialized)
struct ImmediateSessionPersistTests {

    @Test("when the sync API returns, both the snapshot and the recovery projection are already on disk")
    @MainActor
    func synchronousVariantIsDurableOnReturn() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "persist-sync-\(UUID().uuidString)"
        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        defer {
            await TestPartitionCleanup.remove(uid)
            AppSessionStore.switchToUser(previousUID)
        }
        let conversation = TestFactories.makeConversation(
            title: "Sync Persist",
            messages: [TestFactories.makeMessage(text: "hi")]
        )
        _ = try state.conversationRuntimeBridge.replaceAllConversations([conversation], uid: uid)
        state.conversations = [conversation]

        state.persistSessionNow()

        #expect(FileManager.default.fileExists(atPath: AppSessionStore.snapshotPath(for: uid).path))
        #expect(FileManager.default.fileExists(atPath: AppSessionStore.recoverySnapshotPath(for: uid).path))
    }

    @Test("async persist contents match the sync API")
    @MainActor
    func asyncVariantPersistsSameContent() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "persist-async-\(UUID().uuidString)"
        DatabaseManager.shared.close()

        let conversation = TestFactories.makeConversation(
            title: "Async Persist",
            messages: [TestFactories.makeMessage(text: "hi")]
        )
        let state = AppState(sessionUID: uid)
        defer {
            await TestPartitionCleanup.remove(uid)
            AppSessionStore.switchToUser(previousUID)
        }
        _ = try state.conversationRuntimeBridge.replaceAllConversations([conversation], uid: uid)
        state.conversations = [conversation]

        await state.persistSessionNowOffMainThread()

        #expect(FileManager.default.fileExists(atPath: AppSessionStore.snapshotPath(for: uid).path))
        let recovered = state.conversationRuntimeBridge.loadRecoveryProjection(snapshot: nil, uid: uid)
        #expect(recovered.map(\.id) == [conversation.id])
    }

    @Test("an explicit partition parameter lands in that partition, not the currently bound one")
    @MainActor
    func explicitPartitionIsHonoured() async throws {
        let previousUID = AppSessionStore.activeUID
        let boundUID = "persist-bound-\(UUID().uuidString)"
        let targetUID = "persist-target-\(UUID().uuidString)"
        DatabaseManager.shared.close()

        let state = AppState(sessionUID: boundUID)
        defer {
            await TestPartitionCleanup.remove(boundUID, targetUID)
            AppSessionStore.switchToUser(previousUID)
        }
        state.conversations = [TestFactories.makeConversation(title: "Explicit Partition")]
        try? FileManager.default.removeItem(at: AppSessionStore.snapshotPath(for: targetUID))

        await state.persistSessionNowOffMainThread(for: targetUID)
        #expect(FileManager.default.fileExists(atPath: AppSessionStore.snapshotPath(for: targetUID).path))
    }
}
