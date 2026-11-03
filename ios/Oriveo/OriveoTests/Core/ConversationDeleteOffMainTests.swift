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
        let cleanUp: () async -> Void
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
            await TestPartitionCleanup.remove(uid)
        })
    }

    private static func seed(_ fixture: Fixture, _ conversations: [Conversation]) throws {
        try fixture.store.replaceAllConversations(conversations)
        fixture.state.conversations = conversations
    }

    private static func storedIDs(_ fixture: Fixture) throws -> Set<UUID> {
        Set(try fixture.store.fetchConversationList().map(\.id))
    }

    /// Swaps the assertion for a collector; restores it afterwards.
    private func capturingViolations(_ body: () async throws -> Void) async rethrows -> [String] {
        var captured: [String] = []
        let previous = MainThreadDatabaseWriteGuard.violationHandler
        MainThreadDatabaseWriteGuard.violationHandler = { captured.append($0) }
        defer { MainThreadDatabaseWriteGuard.violationHandler = previous }
        try await body()
        MainThreadDatabaseWriteGuard.drain()
        return captured
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
            await fixture.cleanUp()
        }
        let committed = fixture.state.deleteConversationProjection(id: doomed.id)
        #expect(fixture.state.conversations.map(\.id) == [keep.id], "memory drops it at once")
        #expect(try Self.storedIDs(fixture).contains(doomed.id), "the queued write has not run yet")

        gate.signal()
        released = true
        #expect(await committed.value)
        #expect(try Self.storedIDs(fixture) == [keep.id])
    }

    @Test("A failed delete reads the conversation back from the store and leaves no in-flight deletion")
    func failedDeleteRestoresFromStore() async throws {
        let fixture = try Self.makeFixture("delete-offmain-fail")
        defer { await fixture.cleanUp() }
        let state = fixture.state
        let doomed = TestFactories.makeConversation(title: "Survivor", hasCustomTitle: true)
        try Self.seed(fixture, [doomed])

        struct Injected: Error {}
        fixture.state._testingConversationDeleteFailure = Injected()
        let committed = fixture.state.deleteConversationProjections(ids: [doomed.id])
        #expect(!fixture.state.conversations.contains { $0.id == doomed.id })
        #expect(await committed.value == false)
        #expect(state.conversations.map(\.id) == [doomed.id], "failed delete is read back from the store")
        #expect(try Self.storedIDs(fixture).contains(doomed.id))
    }

    @Test("Deleting conversations (single or batch) does not write to the database synchronously on the main thread, and the ledger has no matching legacy debt")
    func deleteDoesNotWriteOnMainThread() async throws {
        for key in [
            "ConversationStore.deleteConversation",
            "ConversationStore.deleteConversations",
        ] {
            #expect(!MainThreadDatabaseWriteAllowlist.mainThreadDebt.contains(key), "\(key)")
        }
        let fixture = try Self.makeFixture("delete-offmain-guard")
        defer { await fixture.cleanUp() }
        let state = fixture.state
        let one = TestFactories.makeConversation(title: "One", hasCustomTitle: true)
        let two = TestFactories.makeConversation(title: "Two", hasCustomTitle: true)
        let three = TestFactories.makeConversation(title: "Three", hasCustomTitle: true)
        try Self.seed(fixture, [one, two, three])

        var results: [Bool] = []
        let violations = await capturingViolations {
            state.deleteConversation(id: one.id)
            results.append(await state.deleteConversationProjections(ids: [two.id, three.id]).value)
            state.flushConversationPersistQueue()
        }
        #expect(violations.isEmpty, "\(violations)")
        #expect(results == [true])
        #expect(try Self.storedIDs(fixture).isEmpty)
    }
}
