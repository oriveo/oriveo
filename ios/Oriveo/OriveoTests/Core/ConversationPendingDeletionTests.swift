import Foundation
import GRDB
import Testing
@testable import Oriveo

@Suite("ConversationPendingDeletion", .serialized)
struct ConversationPendingDeletionTests {

    @Test("Delete Enqueues Pending Deletion")
    func deleteEnqueuesPendingDeletion() throws {
        let uid = makeUID()
        defer { cleanup(uid) }
        let store = try makeStore(uid: uid)
        let conv = TestFactories.makeConversation(title: "To Delete")
        try store.replaceAllConversations([conv])

        try store.deleteConversation(id: conv.id)

        #expect(try store.fetchConversationCount() == 0)
        #expect(try store.pendingDeletionIDs() == [conv.id])
    }

    @Test("Batch Delete Enqueues All")
    func batchDeleteEnqueuesAll() throws {
        let uid = makeUID()
        defer { cleanup(uid) }
        let store = try makeStore(uid: uid)
        let convs = (0..<3).map { TestFactories.makeConversation(title: "Chat \($0)") }
        try store.replaceAllConversations(convs)

        try store.deleteConversations(ids: convs.map(\.id))

        #expect(try store.fetchConversationCount() == 0)
        #expect(Set(try store.pendingDeletionIDs()) == Set(convs.map(\.id)))
    }

    @Test("Repeated Enqueue Is Idempotent")
    func repeatedEnqueueIsIdempotent() throws {
        let uid = makeUID()
        defer { cleanup(uid) }
        let store = try makeStore(uid: uid)
        let conv = TestFactories.makeConversation(title: "Dup")
        try store.replaceAllConversations([conv])

        try store.deleteConversation(id: conv.id)
        try store.deleteConversation(id: conv.id)

        #expect(try store.pendingDeletionIDs() == [conv.id])
    }

    @Test("Ack Clears Queue")
    func ackClearsQueue() throws {
        let uid = makeUID()
        defer { cleanup(uid) }
        let store = try makeStore(uid: uid)
        let conv = TestFactories.makeConversation(title: "Acked")
        try store.replaceAllConversations([conv])
        try store.deleteConversation(id: conv.id)

        try store.clearPendingDeletions(ids: [conv.id])

        #expect(try store.pendingDeletionIDs().isEmpty)
    }

    @Test("Partial Ack Keeps Remainder")
    func partialAckKeepsRemainder() throws {
        let uid = makeUID()
        defer { cleanup(uid) }
        let store = try makeStore(uid: uid)
        let convs = (0..<3).map { TestFactories.makeConversation(title: "Chat \($0)") }
        try store.replaceAllConversations(convs)
        try store.deleteConversations(ids: convs.map(\.id))

        try store.clearPendingDeletions(ids: [convs[0].id])

        #expect(Set(try store.pendingDeletionIDs()) == Set([convs[1].id, convs[2].id]))
    }

    @Test("Guest Partition Does Not Enqueue")
    func guestPartitionDoesNotEnqueue() throws {
        let uid = makeUID()
        defer { cleanup(uid) }
        let store = try makeStore(uid: uid)
        let conv = TestFactories.makeConversation(title: "Guest Chat")
        try store.replaceAllConversations([conv])

        try store.deleteConversation(id: conv.id, enqueueForSync: false)

        #expect(try store.fetchConversationCount() == 0)
        #expect(try store.pendingDeletionIDs().isEmpty)
    }

    @Test("Replace All Does Not Enqueue")
    func replaceAllDoesNotEnqueue() throws {
        let uid = makeUID()
        defer { cleanup(uid) }
        let store = try makeStore(uid: uid)
        let old = (0..<2).map { TestFactories.makeConversation(title: "Old \($0)") }
        try store.replaceAllConversations(old)

        try store.replaceAllConversations([TestFactories.makeConversation(title: "New")])

        #expect(try store.pendingDeletionIDs().isEmpty)
    }

    // MARK: - Helpers

    private func makeUID() -> String { "pending-del-\(UUID().uuidString)" }

    private func makeStore(uid: String) throws -> ConversationStore {
        try FileManager.default.createDirectory(
            at: AppSessionStore.userDir(for: uid),
            withIntermediateDirectories: true
        )
        let dbPool = try DatabasePool(
            path: AppSessionStore.databasePath(for: uid).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let attachmentFileStore = AttachmentFileStore(
            rootDirectory: AppSessionStore.userDir(for: uid).appendingPathComponent("Files", isDirectory: true)
        )
        try DatabaseSchema.makeMigrator(attachmentFileStore: attachmentFileStore).migrate(dbPool)
        return ConversationStore(dbPool: dbPool, attachmentFileStore: attachmentFileStore)
    }

    private func cleanup(_ uid: String) {
        try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
    }
}
