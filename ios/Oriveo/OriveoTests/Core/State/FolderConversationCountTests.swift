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

    /// An expanded folder row (and the folder detail page) reads the list on every body evaluation,
    /// and that cache is also invalidated by conversationsVersion. The list renders only title,
    /// preview and count, so it must not read and decode every stored conversation's messages.
    @Test("an expanded folder list reads the summary projection, so re-reading does not grow with message volume")
    @MainActor
    func expandedListDoesNotMaterializeMessages() throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "folder-list-cost-\(UUID().uuidString)"
        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        DatabaseManager.shared.close()

        // A heavy user: 300 conversations with 30 messages each, 40 of them in the folder.
        let folder = TestFactories.makeFolder(name: "Work")
        let body = String(repeating: "A reasonably long paragraph of chat text. ", count: 10)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let seeded = (0..<300).map { index in
            TestFactories.makeConversation(
                title: "Conversation \(index)",
                messages: (0..<30).map { messageIndex in
                    TestFactories.makeMessage(
                        role: messageIndex.isMultiple(of: 2) ? .user : .assistant,
                        text: "\(index)-\(messageIndex) \(body)"
                    )
                },
                updatedAt: base.addingTimeInterval(TimeInterval(index)),
                folderID: index < 40 ? folder.id : nil
            )
        }

        let state = AppState(sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations(seeded, uid: uid)
        state.folders = [folder]

        // Conversations that are in the store but not in memory: list entries carry no messages,
        // and the count still comes from the stored message count.
        state.conversations = []
        let fromDatabase = state.folderManager.conversations(in: folder.id)
        #expect(fromDatabase.count == 40)
        #expect(fromDatabase.allSatisfy { $0.messages.isEmpty && $0.displayMessageCount == 30 })
        #expect(fromDatabase.map(\.title) == seeded.prefix(40).reversed().map(\.title))

        // The shape in the app: memory holds every conversation, and each change (send, finalize,
        // rename) invalidates the cache and re-reads.
        state.conversations = seeded
        _ = state.folderManager.conversations(in: folder.id)
        var slowest: TimeInterval = 0
        var total: TimeInterval = 0
        for round in 0..<5 {
            state.conversations[0].title = "Renamed \(round)"
            let start = Date()
            let listed = state.folderManager.conversations(in: folder.id)
            let elapsed = Date().timeIntervalSince(start)
            slowest = max(slowest, elapsed)
            total += elapsed
            #expect(listed.count == 40)
        }
        print("""
        [HANG-COST] expanded folder list (300 conversations x 30 messages, 40 in folder) \
        re-read after a conversation change: max \(String(format: "%.0f", slowest * 1000))ms, 5 reads total \(String(format: "%.0f", total * 1000))ms
        """)
    }
}
