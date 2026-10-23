import Foundation
import Testing
@testable import Oriveo

/// Lists read only the in-memory projection while it is non-empty. Writes change memory first and
/// reach the store later on the persist queue, so a list that unions in the store resurrects the
/// change that is still queued (a conversation moved out of a folder keeps showing there).
@Suite("ConversationMemoryProjection", .serialized)
struct ConversationMemoryProjectionTests {

    private struct Fixture {
        let state: AppState
        let uid: String
        let previousUID: String

        @MainActor
        func cleanUp() {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
    }

    @MainActor
    private static func makeFixture(
        _ prefix: String,
        conversations: [Conversation],
        folders: [Folder]
    ) throws -> Fixture {
        let previousUID = AppSessionStore.activeUID
        let uid = "\(prefix)-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let state = AppState(seedDemoData: false, sessionUID: uid)
        _ = try state.conversationRuntimeBridge.replaceAllConversations(conversations, uid: uid)
        state.folders = folders
        state.conversations = conversations
        return Fixture(state: state, uid: uid, previousUID: previousUID)
    }

    @MainActor
    private static func sectionIDs(_ state: AppState, earlierLimit: Int = 50) -> Set<UUID> {
        Set(state.homeConversationSections(earlierLimit: earlierLimit).flatMap { $0.conversations.map(\.id) })
    }

    @Test("moving a conversation out of a folder shows on home and leaves the folder before the store write runs")
    @MainActor
    func moveOutOfFolderBeforePersist() throws {
        let now = Date()
        let folder = TestFactories.makeFolder(name: "Work")
        // Two ages: one in the recent window, one in the "earlier" section.
        let recent = TestFactories.makeConversation(
            title: "Recent in folder",
            messages: [TestFactories.makeMessage(text: "a")],
            updatedAt: now.addingTimeInterval(-60),
            folderID: folder.id
        )
        let old = TestFactories.makeConversation(
            title: "Old in folder",
            messages: [TestFactories.makeMessage(text: "b")],
            updatedAt: now.addingTimeInterval(-40 * 86_400),
            folderID: folder.id
        )
        let stay = TestFactories.makeConversation(
            title: "Stays",
            messages: [TestFactories.makeMessage(text: "c")],
            updatedAt: now.addingTimeInterval(-30),
            folderID: folder.id
        )
        let fixture = try Self.makeFixture("memory-move-out", conversations: [recent, old, stay], folders: [folder])
        let state = fixture.state
        state.conversationManager.nowProvider = { now }
        #expect(state.folderManager.conversationCount(in: folder.id) == 3)

        let gate = state._testingBlockConversationPersistQueue()
        var released = false
        defer {
            if !released { gate.signal() }
            fixture.cleanUp()
        }

        state.folderManager.moveConversation(recent.id, to: nil)
        state.folderManager.moveConversation(old.id, to: nil)

        // Precondition: the store still has the folder assignment (the write is queued behind the gate).
        let stored = try state.conversationRuntimeBridge.fetchFolderAssignments(uid: fixture.uid)
        #expect(Set(stored.map(\.conversationID)) == [recent.id, old.id, stay.id])

        #expect(state.folderManager.conversations(in: folder.id).map(\.id) == [stay.id])
        #expect(state.folderManager.conversationCount(in: folder.id) == 1)
        let home = Self.sectionIDs(state)
        #expect(home.contains(recent.id))
        #expect(home.contains(old.id))
        #expect(!home.contains(stay.id))

        gate.signal()
        released = true
        state.flushConversationPersistQueue()
        #expect(state.folderManager.conversations(in: folder.id).map(\.id) == [stay.id])
    }

    @Test("a stale store row with equal metadata stamps does not pull a moved-out conversation back into the folder")
    @MainActor
    func equalStampsMemoryWins() throws {
        let folder = TestFactories.makeFolder(name: "Work")
        let inFolder = TestFactories.makeConversation(
            title: "A",
            messages: [TestFactories.makeMessage(text: "a")],
            folderID: folder.id
        )
        let fixture = try Self.makeFixture("memory-equal-stamps", conversations: [inFolder], folders: [folder])
        let state = fixture.state
        defer { fixture.cleanUp() }

        // Memory moved out without a metadata stamp; the store row (nil stamp) still has the folder.
        var movedOut = inFolder
        movedOut.folderID = nil
        state.conversations = [movedOut]

        #expect(state.folderManager.conversations(in: folder.id).isEmpty)
        #expect(state.folderManager.conversationCount(in: folder.id) == 0)
    }

    @Test("a conversation missing from memory is not brought back by the store in home, pinned and folder lists")
    @MainActor
    func memoryRemovalNotResurrectedByStore() throws {
        let now = Date()
        let folder = TestFactories.makeFolder(name: "Work")
        let keep = TestFactories.makeConversation(
            title: "Keep",
            messages: [TestFactories.makeMessage(text: "k")],
            updatedAt: now.addingTimeInterval(-10),
            folderID: folder.id
        )
        let gone = TestFactories.makeConversation(
            title: "Gone",
            messages: [TestFactories.makeMessage(text: "g")],
            updatedAt: now.addingTimeInterval(-20),
            folderID: folder.id
        )
        let goneHome = TestFactories.makeConversation(
            title: "Gone home",
            messages: [TestFactories.makeMessage(text: "h")],
            updatedAt: now.addingTimeInterval(-40 * 86_400)
        )
        let fixture = try Self.makeFixture(
            "memory-removal",
            conversations: [keep, gone, goneHome],
            folders: [folder]
        )
        let state = fixture.state
        state.conversationManager.nowProvider = { now }
        defer { fixture.cleanUp() }
        state.preferences.pinnedConversationIDs = [gone.id]

        // Memory lost two rows; the store still has them.
        state.conversations = [keep]

        #expect(Self.sectionIDs(state).isDisjoint(with: [gone.id, goneHome.id]))
        #expect(state.conversationManager.pinnedConversations.isEmpty)
        #expect(state.folderManager.conversations(in: folder.id).map(\.id) == [keep.id])
        #expect(state.folderManager.conversationCount(in: folder.id) == 1)
    }
}
