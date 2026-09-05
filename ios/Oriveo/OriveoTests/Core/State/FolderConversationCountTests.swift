import Foundation
import Testing
@testable import Oriveo

@Suite("FolderConversationCount", .serialized)
struct FolderConversationCountTests {

    @Test("counts come from store membership and do not require messages in memory")
    @MainActor
    func countsComeFromDatabaseAssignments() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "folder-count-db-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let folder = TestFactories.makeFolder(name: "Work")
        let other = TestFactories.makeFolder(name: "Personal")
        let first = TestFactories.makeConversation(
            title: "A",
            messages: [TestFactories.makeMessage(text: "a")],
            folderID: folder.id
        )
        let second = TestFactories.makeConversation(
            title: "B",
            messages: [TestFactories.makeMessage(text: "b")],
            folderID: folder.id
        )
        let elsewhere = TestFactories.makeConversation(
            title: "C",
            messages: [TestFactories.makeMessage(text: "c")],
            folderID: other.id
        )
        let ungrouped = TestFactories.makeConversation(
            title: "D",
            messages: [TestFactories.makeMessage(text: "d")]
        )

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations(
            [first, second, elsewhere, ungrouped],
            uid: uid
        )
        state.folders = [folder, other]
        state.conversations = []

        #expect(state.folderManager.conversationCount(in: folder.id) == 2)
        #expect(state.folderManager.conversationCount(in: other.id) == 1)
        #expect(state.folderManager.conversationCount(in: UUID()) == 0)
    }

    @Test("a conversation just moved in memory is counted immediately, without waiting for background persist")
    @MainActor
    func inMemoryMoveCountsImmediately() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "folder-count-move-in-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let folder = TestFactories.makeFolder(name: "Work")
        let conversation = TestFactories.makeConversation(
            title: "A",
            messages: [TestFactories.makeMessage(text: "a")]
        )

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations([conversation], uid: uid)
        state.folders = [folder]
        state.conversations = []
        #expect(state.folderManager.conversationCount(in: folder.id) == 0)

        var moved = conversation
        moved.folderID = folder.id
        state.conversations = [moved]
        #expect(state.folderManager.conversationCount(in: folder.id) == 1)
    }

    @Test("a conversation just moved out of memory disappears from the count immediately")
    @MainActor
    func inMemoryMoveOutCountsImmediately() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "folder-count-move-out-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let folder = TestFactories.makeFolder(name: "Work")
        var conversation = TestFactories.makeConversation(
            title: "A",
            messages: [TestFactories.makeMessage(text: "a")],
            folderID: folder.id
        )
        conversation.metadataUpdatedAt = Date(timeIntervalSince1970: 1_000)

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations([conversation], uid: uid)
        state.folders = [folder]
        state.conversations = []
        #expect(state.folderManager.conversationCount(in: folder.id) == 1)

        var movedOut = conversation
        movedOut.folderID = nil
        movedOut.metadataUpdatedAt = Date(timeIntervalSince1970: 2_000)
        state.conversations = [movedOut]
        #expect(state.folderManager.conversationCount(in: folder.id) == 0)
    }

    @Test("the count matches the expanded list length")
    @MainActor
    func countMatchesExpandedList() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "folder-count-list-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        let folder = TestFactories.makeFolder(name: "Work")
        let conversations = (0..<3).map { index in
            TestFactories.makeConversation(
                title: "C\(index)",
                messages: [TestFactories.makeMessage(text: "m\(index)")],
                folderID: folder.id
            )
        }

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations(conversations, uid: uid)
        state.folders = [folder]
        state.conversations = []

        #expect(
            state.folderManager.conversationCount(in: folder.id)
                == state.folderManager.conversations(in: folder.id).count
        )
    }
}
