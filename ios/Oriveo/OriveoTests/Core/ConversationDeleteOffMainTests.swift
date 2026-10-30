import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Deleting a conversation never waits for the write lock on the main thread: memory changes first, the row
/// delete is queued on the persist queue, and a failed delete is read back from the database.
@MainActor
@Suite("Conversation delete: no synchronous main-thread write", .serialized)
struct ConversationDeleteOffMainTests {
    private struct Fixture {
        let state: AppState
        let uid: String
        let store: ConversationStore
        let cleanUp: () -> Void
    }

    private static func makeFixture(_ prefix: String) throws -> Fixture {
        DatabaseManager.shared.close()
        let uid = "\(prefix)-\(UUID().uuidString)"
        let state = AppState(seedDemoData: false, sessionUID: uid)
        let store = ConversationStore(
            dbPool: try DatabaseManager.shared.openIfNeeded(for: uid),
            attachmentFileStore: AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        )
        return Fixture(state: state, uid: uid, store: store, cleanUp: {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        })
    }

    private static func seed(_ fixture: Fixture, _ conversations: [Conversation]) throws {
        try fixture.store.replaceAllConversations(conversations)
        fixture.state.conversations = conversations
    }

    private static func storedIDs(_ fixture: Fixture) throws -> Set<UUID> {
        Set(try fixture.store.fetchConversationList().map(\.id))
    }

    @Test("Memory drops the conversation at once while the database row is deleted only when the queued write runs")
    func memoryFirstThenQueuedDelete() async throws {
        let fixture = try Self.makeFixture("delete-offmain-order")
        let doomed = TestFactories.makeConversation(title: "Doomed", hasCustomTitle: true)
        let keep = TestFactories.makeConversation(title: "Keep", hasCustomTitle: true)
        try Self.seed(fixture, [doomed, keep])

        let gate = fixture.state._testingBlockConversationPersistQueue()
        var released = false
        defer {
            if !released { gate.signal() }
            fixture.cleanUp()
        }
        let committed = fixture.state.deleteConversationProjection(id: doomed.id)
        #expect(fixture.state.conversations.map(\.id) == [keep.id], "memory drops it at once")
        #expect(try Self.storedIDs(fixture).contains(doomed.id), "the queued write has not run yet")

        gate.signal()
        released = true
        #expect(await committed.value)
        #expect(try Self.storedIDs(fixture) == [keep.id])
    }

    @Test("A failed delete is read back from the database so memory and the database agree")
    func failedDeleteIsReadBack() async throws {
        let fixture = try Self.makeFixture("delete-offmain-failure")
        defer { fixture.cleanUp() }
        let doomed = TestFactories.makeConversation(title: "Doomed", hasCustomTitle: true)
        let keep = TestFactories.makeConversation(title: "Keep", hasCustomTitle: true)
        try Self.seed(fixture, [doomed, keep])

        struct Injected: Error {}
        fixture.state._testingConversationDeleteFailure = Injected()
        let committed = fixture.state.deleteConversationProjections(ids: [doomed.id])
        #expect(!fixture.state.conversations.contains { $0.id == doomed.id })
        #expect(await committed.value == false)
        #expect(fixture.state.conversations.contains { $0.id == doomed.id }, "restored from the database")
        #expect(try Self.storedIDs(fixture) == [doomed.id, keep.id])
    }
}
