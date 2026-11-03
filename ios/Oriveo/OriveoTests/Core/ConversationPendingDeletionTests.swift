import Foundation
import GRDB
import Testing
@testable import Oriveo

/// The deletion journal.
///
/// A conversation row is hard-deleted, so without a record of it nothing downstream can tell
/// "the user deleted this" apart from "the database lost it". Cold start needs that distinction:
/// it merges the recovery snapshot back in, and a snapshot that missed its post-delete refresh
/// still lists the deleted conversation.
@Suite("ConversationDeletionJournal", .serialized)
struct ConversationPendingDeletionTests {

    @Test("Deleting a conversation records it in the journal")
    func deleteRecordsInJournal() async throws {
        let uid = makeUID()
        defer { await cleanup(uid) }
        let (store, dbPool) = try makeStore(uid: uid)
        defer { try? dbPool.close() }
        let conv = TestFactories.makeConversation(title: "To Delete")
        try store.replaceAllConversations([conv])

        try store.deleteConversation(id: conv.id)

        #expect(try store.fetchConversationCount() == 0)
        #expect(try store.deletedConversationIDs() == [conv.id])
    }

    @Test("Batch delete records every conversation")
    func batchDeleteRecordsAll() async throws {
        let uid = makeUID()
        defer { await cleanup(uid) }
        let (store, dbPool) = try makeStore(uid: uid)
        defer { try? dbPool.close() }
        let convs = (0..<3).map { TestFactories.makeConversation(title: "Chat \($0)") }
        try store.replaceAllConversations(convs)

        try store.deleteConversations(ids: convs.map(\.id))

        #expect(try store.fetchConversationCount() == 0)
        #expect(try store.deletedConversationIDs() == Set(convs.map(\.id)))
    }

    @Test("Deleting the same id twice is idempotent")
    func repeatedDeleteIsIdempotent() async throws {
        let uid = makeUID()
        defer { await cleanup(uid) }
        let (store, dbPool) = try makeStore(uid: uid)
        defer { try? dbPool.close() }
        let conv = TestFactories.makeConversation(title: "Dup")
        try store.replaceAllConversations([conv])

        try store.deleteConversation(id: conv.id)
        try store.deleteConversation(id: conv.id)

        #expect(try store.deletedConversationIDs() == [conv.id])
    }

    /// A local rewrite is not a deletion. Recording one would tell cold start that every
    /// conversation the rewrite happened to drop must never come back.
    @Test("Replacing the whole table records nothing")
    func replaceAllRecordsNothing() async throws {
        let uid = makeUID()
        defer { await cleanup(uid) }
        let (store, dbPool) = try makeStore(uid: uid)
        defer { try? dbPool.close() }
        let old = (0..<2).map { TestFactories.makeConversation(title: "Old \($0)") }
        try store.replaceAllConversations(old)

        try store.replaceAllConversations([TestFactories.makeConversation(title: "New")])

        #expect(try store.deletedConversationIDs().isEmpty)
    }

    @Test("Pruning only drops rows past the retention window")
    func pruneOnlyDropsExpiredRows() async throws {
        let uid = makeUID()
        defer { await cleanup(uid) }
        let (store, dbPool) = try makeStore(uid: uid)
        defer { try? dbPool.close() }
        let conv = TestFactories.makeConversation(title: "Old Deletion")
        try store.replaceAllConversations([conv])
        try store.deleteConversation(id: conv.id)

        try store.pruneDeletionJournal(now: Date())
        #expect(try store.deletedConversationIDs() == [conv.id])

        let beyondRetention = Date().addingTimeInterval(ConversationStore.deletionJournalRetention + 60)
        try store.pruneDeletionJournal(now: beyondRetention)
        #expect(try store.deletedConversationIDs().isEmpty)
    }

    // MARK: - Helpers

    private func makeUID() -> String { "deletion-journal-\(UUID().uuidString)" }

    private func makeStore(uid: String) throws -> (ConversationStore, DatabasePool) {
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
        return (ConversationStore(dbPool: dbPool, attachmentFileStore: attachmentFileStore), dbPool)
    }

    private func cleanup(_ uid: String) async {
        await TestPartitionCleanup.remove(uid)
    }
}
