import Foundation
import GRDB

final class NoteStore: @unchecked Sendable {
    private let dbPool: DatabasePool

    nonisolated init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    nonisolated static let summaryBodyProjectionCharacters = NoteSummary.bodyProjectionCharacters

    nonisolated private static func summaryColumns(alias: String = "") -> String {
        let p = alias.isEmpty ? "" : "\(alias)."
        return """
            \(p)id, \(p)title, \(p)titleSource, \
            substr(\(p)body, 1, \(summaryBodyProjectionCharacters)) AS body, \
            \(p)tags, \(p)noteFolderID, \
            \(p)sourceConversationId, \(p)sourceMessageId, \(p)sourceModelName, \(p)sourceProviderKind, \
            \(p)sourceProviderName, \(p)captureKind, \(p)isPinned, \
            \(p)createdAt, \(p)updatedAt, \(p)deletedAt
            """
    }


    nonisolated func fetchNoteSummaries(includeDeleted: Bool) throws -> [NoteSummary] {
        try dbPool.read { db in
            let predicate = includeDeleted ? "deletedAt IS NOT NULL" : "deletedAt IS NULL"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.summaryColumns()) FROM note
                    WHERE \(predicate)
                    ORDER BY updatedAt DESC, createdAt DESC, id DESC
                    """
            )
            return rows.compactMap { RecordMappers.noteSummary(from: NoteRecord(row: $0)) }
        }
    }

    nonisolated func fetchNote(id: UUID) throws -> Note? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM note WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return RecordMappers.note(from: NoteRecord(row: row))
        }
    }

    nonisolated func fetchNoteAsync(id: UUID) async throws -> Note? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM note WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return RecordMappers.note(from: NoteRecord(row: row))
        }
    }

    nonisolated func fetchAllNotes() throws -> [Note] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM note ORDER BY updatedAt DESC, id DESC")
            return rows.compactMap { RecordMappers.note(from: NoteRecord(row: $0)) }
        }
    }

    nonisolated func fetchNoteCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0
        }
    }

    nonisolated func referenceCount(conversationID: UUID) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM note WHERE sourceConversationId = ? AND deletedAt IS NULL",
                arguments: [conversationID.uuidString]
            ) ?? 0
        }
    }

    nonisolated func referenceCount(conversationIDs: [UUID]) throws -> Int {
        guard !conversationIDs.isEmpty else { return 0 }
        return try dbPool.read { db in
            var total = 0
            let chunkSize = 500
            var offset = 0
            while offset < conversationIDs.count {
                let chunk = conversationIDs[offset..<min(offset + chunkSize, conversationIDs.count)]
                    .map(\.uuidString)
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                total += try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM note
                        WHERE sourceConversationId IN (\(placeholders)) AND deletedAt IS NULL
                        """,
                    arguments: StatementArguments(chunk)
                ) ?? 0
                offset += chunkSize
            }
            return total
        }
    }


    nonisolated func upsertNote(_ note: Note) throws {
        try upsertNotes([note])
    }

    nonisolated func upsertNotes(_ notes: [Note]) throws {
        guard !notes.isEmpty else { return }
        try dbPool.write { db in
            for note in notes {
                try Self.upsert(note, in: db)
            }
        }
    }

    nonisolated private static func upsert(_ note: Note, in db: Database) throws {
        let cols = NoteColumnValues(from: note)
        try db.execute(sql: noteUpsertSQL, arguments: StatementArguments(cols.arguments))
        try rebuildNoteSearchIndex(
            db: db,
            noteID: cols.id,
            title: note.title,
            body: note.body,
            userNote: note.userNote ?? "",
            tagsText: note.tags.joined(separator: " ")
        )
    }

    nonisolated func softDeleteNote(id: UUID, deletedAt: Date, updatedAt: Date) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE note SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [deletedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, id.uuidString]
            )
        }
    }

    nonisolated func restoreNote(id: UUID, updatedAt: Date) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE note SET deletedAt = NULL, updatedAt = ? WHERE id = ?",
                arguments: [updatedAt.timeIntervalSince1970, id.uuidString]
            )
        }
    }

    nonisolated func emptyTrash(noteIDs: [UUID]) throws {
        guard !noteIDs.isEmpty else { return }
        let idStrings = noteIDs.map(\.uuidString)
        try dbPool.write { db in
            let chunkSize = 500
            var offset = 0
            while offset < idStrings.count {
                let chunk = Array(idStrings[offset..<min(offset + chunkSize, idStrings.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                if try db.tableExists("note_search_index") {
                    try db.execute(
                        sql: "DELETE FROM note_search_index WHERE noteID IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                }
                try db.execute(
                    sql: "DELETE FROM note WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                offset += chunkSize
            }
        }
    }

    nonisolated func deleteNoteHard(id: UUID) throws {
        try emptyTrash(noteIDs: [id])
    }

    nonisolated func replaceAllNotes(_ notes: [Note]) throws {
        try dbPool.write { db in
            if try db.tableExists("note_search_index") {
                try? db.execute(sql: "DELETE FROM note_search_index")
            }
            try db.execute(sql: "DELETE FROM note")
            for note in notes {
                try Self.upsert(note, in: db)
            }
        }
    }


    nonisolated func fetchNoteFolders(includeDeleted: Bool) throws -> [NoteFolder] {
        try dbPool.read { db in
            let predicate = includeDeleted ? "" : "WHERE deletedAt IS NULL"
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM note_folder \(predicate) ORDER BY sortOrder ASC, createdAt ASC, id ASC"
            )
            return rows.compactMap { RecordMappers.noteFolder(from: NoteFolderRecord(row: $0)) }
        }
    }

    nonisolated func fetchAllNoteFolders() throws -> [NoteFolder] {
        try fetchNoteFolders(includeDeleted: true)
    }

    nonisolated func fetchNoteFolderCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_folder WHERE deletedAt IS NULL") ?? 0
        }
    }

    nonisolated func fetchMaxFolderSortOrder() throws -> Int? {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM note_folder WHERE deletedAt IS NULL")
        }
    }

    nonisolated func upsertNoteFolder(_ folder: NoteFolder) throws {
        try upsertNoteFolders([folder])
    }

    nonisolated func upsertNoteFolders(_ folders: [NoteFolder]) throws {
        guard !folders.isEmpty else { return }
        try dbPool.write { db in
            for folder in folders {
                let cols = NoteFolderColumnValues(from: folder)
                try db.execute(sql: Self.noteFolderUpsertSQL, arguments: StatementArguments(cols.arguments))
            }
        }
    }

    @discardableResult
    nonisolated func softDeleteNoteFolder(id: UUID, deletedAt: Date, updatedAt: Date) throws -> [UUID] {
        try dbPool.write { db in
            let affected = try String.fetchAll(
                db,
                sql: "SELECT id FROM note WHERE noteFolderID = ?",
                arguments: [id.uuidString]
            ).compactMap(UUID.init(uuidString:))

            try db.execute(
                sql: "UPDATE note SET noteFolderID = NULL, updatedAt = ? WHERE noteFolderID = ?",
                arguments: [updatedAt.timeIntervalSince1970, id.uuidString]
            )
            try db.execute(
                sql: "UPDATE note_folder SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [deletedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, id.uuidString]
            )
            return affected
        }
    }

    @discardableResult
    nonisolated func clearNoteFolderReference(folderID: UUID, updatedAt: Date) throws -> [UUID] {
        try dbPool.write { db in
            let affected = try String.fetchAll(
                db,
                sql: "SELECT id FROM note WHERE noteFolderID = ?",
                arguments: [folderID.uuidString]
            ).compactMap(UUID.init(uuidString:))
            try db.execute(
                sql: "UPDATE note SET noteFolderID = NULL, updatedAt = ? WHERE noteFolderID = ?",
                arguments: [updatedAt.timeIntervalSince1970, folderID.uuidString]
            )
            return affected
        }
    }

    nonisolated func deleteNoteFolderHard(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM note_folder WHERE id = ?", arguments: [id.uuidString])
        }
    }

    nonisolated func replaceAllNoteFolders(_ folders: [NoteFolder]) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM note_folder")
            for folder in folders {
                let cols = NoteFolderColumnValues(from: folder)
                try db.execute(sql: Self.noteFolderUpsertSQL, arguments: StatementArguments(cols.arguments))
            }
        }
    }


    nonisolated func searchNotes(query: String, includeDeleted: Bool) async throws -> [NoteSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try fetchNoteSummaries(includeDeleted: includeDeleted)
        }
        return try await dbPool.read { db in
            let likeQuery = "%\(trimmed)%"
            let deletedPredicate = includeDeleted ? "n.deletedAt IS NOT NULL" : "n.deletedAt IS NULL"
            let summaryCols = Self.summaryColumns(alias: "n")
            let hasFTS = try db.tableExists("note_search_index")
            if hasFTS {
                let sql = """
                    SELECT \(summaryCols)
                    FROM note n
                    JOIN note_search_index si ON si.noteID = n.id
                    WHERE (si.title LIKE ? OR si.body LIKE ? OR si.userNote LIKE ? OR si.tagsText LIKE ?)
                      AND \(deletedPredicate)
                    ORDER BY n.updatedAt DESC, n.createdAt DESC, n.id DESC
                    LIMIT 100
                    """
                let rows = try Row.fetchAll(
                    db,
                    sql: sql,
                    arguments: StatementArguments([likeQuery, likeQuery, likeQuery, likeQuery])
                )
                return rows.compactMap { RecordMappers.noteSummary(from: NoteRecord(row: $0)) }
            }
            let sql = """
                SELECT \(summaryCols)
                FROM note n
                WHERE (n.title LIKE ? COLLATE NOCASE OR n.body LIKE ? COLLATE NOCASE OR n.userNote LIKE ? COLLATE NOCASE)
                  AND \(deletedPredicate)
                ORDER BY n.updatedAt DESC, n.createdAt DESC, n.id DESC
                LIMIT 100
                """
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments([likeQuery, likeQuery, likeQuery])
            )
            return rows.compactMap { RecordMappers.noteSummary(from: NoteRecord(row: $0)) }
        }
    }

    nonisolated func fetchRecallCandidates(
        terms: [String],
        recentLimit: Int,
        totalLimit: Int
    ) async throws -> [NoteRecallCandidate] {
        guard totalLimit > 0 else { return [] }
        return try await dbPool.read { db in
            var candidates: [NoteRecallCandidate] = []
            var seen = Set<UUID>()

            let searchableTerms = terms.filter { $0.count >= 3 }
            let ftsLimit = totalLimit - min(recentLimit, totalLimit)
            if !searchableTerms.isEmpty,
               ftsLimit > 0,
               try db.tableExists("note_search_index") {
                let matchQuery = searchableTerms
                    .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                    .joined(separator: " OR ")
                let matchedRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT \(Self.recallCandidateColumns)
                        FROM note n
                        JOIN note_search_index si ON si.noteID = n.id
                        WHERE note_search_index MATCH ? AND n.deletedAt IS NULL
                        ORDER BY bm25(note_search_index, 0.0, 4.0, 2.0, 0.0, 8.0),
                                 n.updatedAt DESC, n.createdAt DESC, n.id DESC
                        LIMIT ?
                        """,
                    arguments: StatementArguments(
                        Self.recallProjectionArguments + [matchQuery, ftsLimit]
                    )
                )
                for row in matchedRows {
                    guard let candidate = Self.recallCandidate(row),
                          seen.insert(candidate.id).inserted else { continue }
                    candidates.append(candidate)
                }
            }

            let recentRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.recallCandidateColumns) FROM note n
                    WHERE n.deletedAt IS NULL
                    ORDER BY n.updatedAt DESC, n.createdAt DESC, n.id DESC
                    LIMIT ?
                    """,
                arguments: StatementArguments(
                    Self.recallProjectionArguments + [totalLimit]
                )
            )
            for row in recentRows {
                guard candidates.count < totalLimit,
                      let candidate = Self.recallCandidate(row),
                      seen.insert(candidate.id).inserted else { continue }
                candidates.append(candidate)
            }
            return candidates
        }
    }

    nonisolated private static let recallCandidateColumns = """
        n.id,
        substr(n.title, 1, ?) AS title,
        substr(n.body, 1, ?) AS body,
        substr(n.tags, 1, ?) AS tags,
        substr(n.sourceModelName, 1, ?) AS sourceModelName,
        n.sourceProviderKind,
        substr(n.sourceProviderName, 1, ?) AS sourceProviderName,
        n.captureKind,
        n.updatedAt
        """

    nonisolated private static var recallProjectionArguments: [DatabaseValueConvertible?] {
        [
            NoteRecallCandidate.maxTitleCharacters,
            NoteRecallCandidate.maxBodyCharacters,
            NoteRecallCandidate.maxTagJSONCharacters + 1,
            NoteRecallCandidate.maxSourceCharacters,
            NoteRecallCandidate.maxSourceCharacters
        ]
    }

    nonisolated private static func recallCandidate(_ row: Row) -> NoteRecallCandidate? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let tagsJSON: String = row["tags"]
        let tags = tagsJSON.count > NoteRecallCandidate.maxTagJSONCharacters
            ? []
            : RecordMappers.decodeTags(tagsJSON)
                .prefix(NoteRecallCandidate.maxTags)
                .map { String($0.prefix(NoteRecallCandidate.maxTagCharacters)) }
        return NoteRecallCandidate(
            id: id,
            title: row["title"],
            body: row["body"],
            tags: tags,
            sourceModelName: row["sourceModelName"],
            sourceProviderKind: (row["sourceProviderKind"] as String?).flatMap(ProviderKind.init(rawValue:)),
            sourceProviderName: row["sourceProviderName"],
            captureKind: NoteCaptureKind.decoded(row["captureKind"]),
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"])
        )
    }


    nonisolated static func rebuildNoteSearchIndex(
        db: Database,
        noteID: String,
        title: String,
        body: String,
        userNote: String,
        tagsText: String
    ) throws {
        guard try db.tableExists("note_search_index") else { return }
        try? db.execute(sql: "DELETE FROM note_search_index WHERE noteID = ?", arguments: [noteID])
        try? db.execute(
            sql: "INSERT INTO note_search_index(noteID, title, body, userNote, tagsText) VALUES (?, ?, ?, ?, ?)",
            arguments: [noteID, title, body, userNote, tagsText]
        )
    }

    nonisolated static func removeFromNoteSearchIndex(db: Database, noteID: String) throws {
        guard try db.tableExists("note_search_index") else { return }
        try? db.execute(sql: "DELETE FROM note_search_index WHERE noteID = ?", arguments: [noteID])
    }


    private struct NoteColumnValues {
        let id: String
        let title: String
        let titleSource: String
        let body: String
        let bodySnapshot: String?
        let userNote: String?
        let tags: String
        let noteFolderID: String?
        let sourceConversationId: String?
        let sourceMessageId: String?
        let sourceModelID: String?
        let sourceModelName: String?
        let sourceProviderKind: String?
        let sourceProviderName: String?
        let sourcePrompt: String?
        let captureKind: String
        let provenance: String?
        let isPinned: Bool
        let createdAt: Double
        let updatedAt: Double
        let deletedAt: Double?

        nonisolated init(from note: Note) {
            id = note.id.uuidString
            title = note.title
            titleSource = note.titleSource.rawValue
            body = note.body
            bodySnapshot = note.bodySnapshot
            userNote = note.userNote
            tags = RecordMappers.encodeTags(note.tags)
            noteFolderID = note.noteFolderID?.uuidString
            sourceConversationId = note.sourceConversationId?.uuidString
            sourceMessageId = note.sourceMessageId?.uuidString
            sourceModelID = note.sourceModelID
            sourceModelName = note.sourceModelName
            sourceProviderKind = note.sourceProviderKind?.rawValue
            sourceProviderName = note.sourceProviderName
            sourcePrompt = note.sourcePrompt
            captureKind = note.captureKind.rawValue
            provenance = RecordMappers.encodeProvenance(note.provenance)
            isPinned = note.isPinned
            createdAt = note.createdAt.timeIntervalSince1970
            updatedAt = note.updatedAt.timeIntervalSince1970
            deletedAt = note.deletedAt?.timeIntervalSince1970
        }

        nonisolated var arguments: [DatabaseValueConvertible?] {
            [id, title, titleSource, body, bodySnapshot, userNote, tags, noteFolderID,
             sourceConversationId, sourceMessageId, sourceModelID, sourceModelName,
             sourceProviderKind, sourceProviderName, sourcePrompt, captureKind, provenance,
             isPinned, createdAt, updatedAt, deletedAt]
        }
    }

    nonisolated private static let noteUpsertSQL = """
        INSERT INTO note (
            id, title, titleSource, body, bodySnapshot, userNote, tags, noteFolderID,
            sourceConversationId, sourceMessageId, sourceModelID, sourceModelName,
            sourceProviderKind, sourceProviderName, sourcePrompt, captureKind, provenance,
            isPinned, createdAt, updatedAt, deletedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            titleSource = excluded.titleSource,
            body = excluded.body,
            bodySnapshot = excluded.bodySnapshot,
            userNote = excluded.userNote,
            tags = excluded.tags,
            noteFolderID = excluded.noteFolderID,
            sourceConversationId = excluded.sourceConversationId,
            sourceMessageId = excluded.sourceMessageId,
            sourceModelID = excluded.sourceModelID,
            sourceModelName = excluded.sourceModelName,
            sourceProviderKind = excluded.sourceProviderKind,
            sourceProviderName = excluded.sourceProviderName,
            sourcePrompt = excluded.sourcePrompt,
            captureKind = excluded.captureKind,
            provenance = excluded.provenance,
            isPinned = excluded.isPinned,
            createdAt = excluded.createdAt,
            updatedAt = excluded.updatedAt,
            deletedAt = excluded.deletedAt
        """

    private struct NoteFolderColumnValues {
        let id: String
        let name: String
        let sortOrder: Int
        let colorTag: String?
        let createdAt: Double
        let updatedAt: Double
        let deletedAt: Double?

        nonisolated init(from folder: NoteFolder) {
            id = folder.id.uuidString
            name = folder.name
            sortOrder = folder.sortOrder
            colorTag = folder.colorTag
            createdAt = folder.createdAt.timeIntervalSince1970
            updatedAt = folder.updatedAt.timeIntervalSince1970
            deletedAt = folder.deletedAt?.timeIntervalSince1970
        }

        nonisolated var arguments: [DatabaseValueConvertible?] {
            [id, name, sortOrder, colorTag, createdAt, updatedAt, deletedAt]
        }
    }

    nonisolated private static let noteFolderUpsertSQL = """
        INSERT INTO note_folder (
            id, name, sortOrder, colorTag, createdAt, updatedAt, deletedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            sortOrder = excluded.sortOrder,
            colorTag = excluded.colorTag,
            createdAt = excluded.createdAt,
            updatedAt = excluded.updatedAt,
            deletedAt = excluded.deletedAt
        """
}
