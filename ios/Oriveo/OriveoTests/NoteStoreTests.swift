import Foundation
import GRDB
import Testing
@testable import Oriveo

@Suite("NoteStore", .serialized)
struct NoteStoreTests {

    @Test("Migration Creates Tables")
    func migrationCreatesTables() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let (hasNote, hasFolder, hasIndex) = try h.dbPool.read { db in
            (try db.tableExists("note"),
             try db.tableExists("note_folder"),
             try db.tableExists("note_search_index"))
        }
        #expect(hasNote)
        #expect(hasFolder)
        #expect(hasIndex)
    }

    @Test("Upsert Fetch")
    func upsertFetch() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let note = NoteTestFactories.makeNote(
            title: "Hello", body: "Body", bodySnapshot: "Snap", tags: ["a", "b"],
            sourceModelName: "GPT-4", sourceProviderKind: .openAI, captureKind: .fullAnswer)
        try h.store.upsertNote(note)
        let fetched = try h.store.fetchNote(id: note.id)
        #expect(fetched?.title == "Hello")
        #expect(fetched?.bodySnapshot == "Snap")
        #expect(fetched?.tags == ["a", "b"])
        #expect(fetched?.sourceProviderKind == .openAI)
    }

    @Test("Soft Delete")
    func softDelete() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let note = NoteTestFactories.makeNote()
        try h.store.upsertNote(note)
        try h.store.softDeleteNote(id: note.id, deletedAt: Date(), updatedAt: Date())

        #expect(try h.store.fetchNoteSummaries(includeDeleted: false).isEmpty)
        #expect(try h.store.fetchNoteSummaries(includeDeleted: true).count == 1)
        let rowCount = try h.dbPool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? -1 }
        #expect(rowCount == 1)
    }

    @Test("Restore")
    func restore() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let note = NoteTestFactories.makeNote()
        try h.store.upsertNote(note)
        try h.store.softDeleteNote(id: note.id, deletedAt: Date(), updatedAt: Date())
        try h.store.restoreNote(id: note.id, updatedAt: Date())

        #expect(try h.store.fetchNoteSummaries(includeDeleted: false).count == 1)
        #expect(try h.store.fetchNoteSummaries(includeDeleted: true).isEmpty)
        #expect(try h.store.fetchNote(id: note.id)?.deletedAt == nil)
    }

    @Test("Empty Trash")
    func emptyTrash() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let note = NoteTestFactories.makeNote(title: "searchable")
        try h.store.upsertNote(note)
        try h.store.softDeleteNote(id: note.id, deletedAt: Date(), updatedAt: Date())
        try h.store.emptyTrash(noteIDs: [note.id])

        let counts = try h.dbPool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_search_index") ?? -1)
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
    }

    @Test("Delete Folder Cascade")
    func deleteFolderCascade() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let folder = NoteTestFactories.makeFolder()
        try h.store.upsertNoteFolder(folder)
        let n1 = NoteTestFactories.makeNote(noteFolderID: folder.id)
        let n2 = NoteTestFactories.makeNote(noteFolderID: folder.id, deletedAt: Date(timeIntervalSince1970: 1_700_000_100))
        try h.store.upsertNotes([n1, n2])

        let affected = try h.store.softDeleteNoteFolder(id: folder.id, deletedAt: Date(), updatedAt: Date())
        #expect(Set(affected) == Set([n1.id, n2.id]))
        #expect(try h.store.fetchNote(id: n1.id)?.noteFolderID == nil)
        #expect(try h.store.fetchNote(id: n2.id)?.noteFolderID == nil)
        #expect(try h.store.fetchNoteFolders(includeDeleted: false).isEmpty)
        #expect(try h.store.fetchNoteFolders(includeDeleted: true).count == 1)
    }

    @Test("Clear Folder Reference Includes Trash")
    func clearFolderReferenceIncludesTrash() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let folderID = UUID()
        let active = NoteTestFactories.makeNote(noteFolderID: folderID)
        let trashed = NoteTestFactories.makeNote(noteFolderID: folderID, deletedAt: Date(timeIntervalSince1970: 1_700_000_100))
        try h.store.upsertNotes([active, trashed])

        let affected = try h.store.clearNoteFolderReference(folderID: folderID, updatedAt: Date())

        #expect(Set(affected) == Set([active.id, trashed.id]))
        #expect(try h.store.fetchNote(id: active.id)?.noteFolderID == nil)
        #expect(try h.store.fetchNote(id: trashed.id)?.noteFolderID == nil)
    }

    @Test("Reference Count")
    func referenceCount() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let conv = UUID()
        try h.store.upsertNote(NoteTestFactories.makeNote(sourceConversationId: conv))
        try h.store.upsertNote(NoteTestFactories.makeNote(sourceConversationId: conv))
        let deleted = NoteTestFactories.makeNote(sourceConversationId: conv)
        try h.store.upsertNote(deleted)
        try h.store.softDeleteNote(id: deleted.id, deletedAt: Date(), updatedAt: Date())

        #expect(try h.store.referenceCount(conversationID: conv) == 2)
        #expect(try h.store.referenceCount(conversationID: UUID()) == 0)
    }

    @Test("Summary Includes Source Anchors")
    func summaryIncludesSourceAnchors() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        let conversationID = UUID()
        let messageID = UUID()
        let note = NoteTestFactories.makeNote(
            sourceConversationId: conversationID,
            sourceMessageId: messageID,
            captureKind: .fullAnswer
        )
        try h.store.upsertNote(note)

        let summary = try #require(h.store.fetchNoteSummaries(includeDeleted: false).first)

        #expect(summary.sourceConversationId == conversationID)
        #expect(summary.sourceMessageId == messageID)
    }

    @Test("Folder Ordering")
    func folderOrdering() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        try h.store.upsertNoteFolder(NoteTestFactories.makeFolder(name: "B", sortOrder: 2000))
        try h.store.upsertNoteFolder(NoteTestFactories.makeFolder(name: "A", sortOrder: 1000))
        let folders = try h.store.fetchNoteFolders(includeDeleted: false)
        #expect(folders.map(\.name) == ["A", "B"])
        #expect(try h.store.fetchMaxFolderSortOrder() == 2000)
    }

    @Test("Replace All")
    func replaceAll() throws {
        let h = try NoteStoreHarness()
        defer { h.cleanup() }
        try h.store.upsertNote(NoteTestFactories.makeNote(title: "old"))
        try h.store.replaceAllNotes([NoteTestFactories.makeNote(title: "new1"), NoteTestFactories.makeNote(title: "new2")])
        let all = try h.store.fetchAllNotes()
        #expect(all.count == 2)
        #expect(Set(all.map(\.title)) == Set(["new1", "new2"]))
    }
}
