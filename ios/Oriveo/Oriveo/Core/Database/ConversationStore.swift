import Foundation
import GRDB

final class ConversationStore: @unchecked Sendable {
    nonisolated private static let visibleUngroupedConversationWhereClause =
        "(isDraft = 0 OR messageCount > 0)"
    nonisolated private static let visibleConversationWhereClauseWithAlias =
        "(c.folderID IS NOT NULL OR c.isDraft = 0 OR c.messageCount > 0)"

    private let dbPool: DatabasePool
    private let attachmentFileStore: AttachmentFileStore
    private let continuationOrphanSweep: (() throws -> Void)?

    nonisolated init(
        dbPool: DatabasePool,
        attachmentFileStore: AttachmentFileStore,
        continuationOrphanSweep: (() throws -> Void)? = nil
    ) {
        self.dbPool = dbPool
        self.attachmentFileStore = attachmentFileStore
        self.continuationOrphanSweep = continuationOrphanSweep
    }

    nonisolated func fetchConversationList() throws -> [ConversationSummary] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM conversation
                    ORDER BY updatedAt DESC, createdAt DESC, id DESC
                    """
            )
            return rows.compactMap { row in
                RecordMappers.summary(from: ConversationRecord(row: row))
            }
        }
    }

    nonisolated func fetchConversationSummary(id: UUID) throws -> ConversationSummary? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversation WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return nil
            }
            return RecordMappers.summary(from: ConversationRecord(row: row))
        }
    }

    nonisolated func fetchConversationSummaries(ids: [UUID]) throws -> [ConversationSummary] {
        guard !ids.isEmpty else { return [] }
        return try dbPool.read { db in
            try Self.fetchConversationSummaries(db: db, ids: ids)
        }
    }

    nonisolated func fetchUngroupedRecentConversationSummaries(
        recentStart: Date
    ) throws -> [ConversationSummary] {
        try dbPool.read { db in
            try Self.fetchUngroupedRecentConversationSummaries(
                db: db,
                recentStart: recentStart
            )
        }
    }

    nonisolated func fetchUngroupedEarlierConversationSummaries(
        recentStart: Date,
        limit: Int
    ) throws -> [ConversationSummary] {
        try dbPool.read { db in
            try Self.fetchUngroupedEarlierConversationSummaries(
                db: db,
                recentStart: recentStart,
                limit: limit
            )
        }
    }

    nonisolated func fetchUngroupedEarlierConversationCount(
        recentStart: Date
    ) throws -> Int {
        try dbPool.read { db in
            try Self.fetchUngroupedEarlierConversationCount(
                db: db,
                recentStart: recentStart
            )
        }
    }

    nonisolated func fetchConversationThread(
        id: UUID,
        hydrateFilePayloads: Bool = false
    ) throws -> ConversationThread? {
        try dbPool.read { db in
            guard let summary = try Self.fetchConversationSummary(db: db, id: id) else {
                return nil
            }
            let messages = try Self.fetchMessages(
                db: db,
                conversationID: id,
                hydrateFilePayloads: hydrateFilePayloads,
                attachmentFileStore: attachmentFileStore
            )
            return ConversationThread(summary: summary, messages: messages)
        }
    }

    nonisolated func fetchAllConversations(hydrateFilePayloads: Bool) throws -> [Conversation] {
        try dbPool.read { db in
            let summaries = try Self.fetchConversationSummaries(db: db)
            return try summaries.map { summary in
                let thread = try Self.fetchConversationThread(
                    db: db,
                    summary: summary,
                    hydrateFilePayloads: hydrateFilePayloads,
                    attachmentFileStore: attachmentFileStore
                )
                return RecordMappers.conversation(from: thread)
            }
        }
    }

    nonisolated func fetchMessages(
        for conversationID: UUID,
        hydrateFilePayloads: Bool = false
    ) throws -> [ChatMessage] {
        try dbPool.read { db in
            try Self.fetchMessages(
                db: db,
                conversationID: conversationID,
                hydrateFilePayloads: hydrateFilePayloads,
                attachmentFileStore: attachmentFileStore
            )
        }
    }

    nonisolated func fetchFolderAssignments() throws -> [ConversationFolderAssignment] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, folderID, metadataUpdatedAt FROM conversation
                    WHERE folderID IS NOT NULL
                    """
            )
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let folderIDString: String = row["folderID"],
                      let folderID = UUID(uuidString: folderIDString) else { return nil }
                let metadataUpdatedAt: Double? = row["metadataUpdatedAt"]
                return ConversationFolderAssignment(
                    conversationID: id,
                    folderID: folderID,
                    metadataUpdatedAt: metadataUpdatedAt.map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }

    nonisolated func fetchConversationCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation") ?? 0
        }
    }

    nonisolated func fetchConversationIDs(in folderID: UUID) throws -> [UUID] {
        try dbPool.read { db in
            let rawIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM conversation WHERE folderID = ?",
                arguments: [folderID.uuidString]
            )
            return rawIDs.compactMap(UUID.init(uuidString:))
        }
    }

    nonisolated func hasGeneratingMessage(convID: UUID) throws -> Bool {
        try dbPool.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message WHERE conversationID = ? AND state = ?",
                arguments: [convID.uuidString, ChatMessageState.generating.rawValue]
            ) ?? 0
            return count > 0
        }
    }

    nonisolated func replaceAllConversations(_ conversations: [Conversation]) throws {
        var referencedFileIDs = Set<String>()

        try dbPool.write { db in
            let inheritedFileRefs = try Self.allAttachmentFileRefs(db: db)

            if try db.tableExists("search_index") {
                try? db.execute(sql: "DELETE FROM search_index")
            }
            try db.execute(sql: "DELETE FROM conversation")

            for conversation in conversations {
                try insert(
                    conversation: conversation,
                    into: db,
                    inheritedFileRefs: inheritedFileRefs,
                    referencedFileIDs: &referencedFileIDs
                )
            }
        }
        try continuationOrphanSweep?()
        attachmentFileStore.prune(keeping: referencedFileIDs)
    }

    nonisolated func insertConversation(_ summary: ConversationSummary) throws {
        let cols = ConversationColumnValues(from: summary)
        try dbPool.write { db in
            try db.execute(sql: Self.conversationUpsertSQL, arguments: StatementArguments(cols.arguments))
        }
    }

    nonisolated func upsertConversation(_ conversation: Conversation) throws {
        try upsertConversations([conversation])
    }

    nonisolated func upsertConversations(_ conversations: [Conversation]) throws {
        guard !conversations.isEmpty else { return }

        let prepared = conversations.map(deriveConversationForMutationWrite)
        var referencedFileIDs = Set<String>()

        try dbPool.write { db in
            for conversation in prepared {
                try upsertConversation(
                    conversation,
                    into: db,
                    referencedFileIDs: &referencedFileIDs
                )
            }
        }
        try continuationOrphanSweep?()
    }

    nonisolated func upsertHydratedMessages(_ messages: [ChatMessage], conversationID: UUID) throws {
        guard messages.isEmpty == false else { return }
        var referencedFileIDs = Set<String>()

        try dbPool.write { db in
            guard let summary = try Self.fetchConversationSummary(db: db, id: conversationID) else { return }
            let existing = try Self.fetchMessages(
                db: db,
                conversationID: conversationID,
                hydrateFilePayloads: false,
                attachmentFileStore: attachmentFileStore
            )
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for message in messages {
                byID[message.id] = message
            }
            let mergedMessages = byID.values.sorted { lhs, rhs in
                let lhsDate = lhs.createdAt ?? .distantPast
                let rhsDate = rhs.createdAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }

            try upsertMessageRows(
                mergedMessages,
                conversationID: conversationID,
                into: db,
                referencedFileIDs: &referencedFileIDs
            )
            try Self.rebuildSearchIndex(
                db: db,
                conversationID: conversationID.uuidString,
                title: summary.title,
                messages: mergedMessages
            )
        }
    }

    nonisolated func deleteConversation(id: UUID, enqueueForSync: Bool = true) throws {
        try dbPool.write { db in
            try Self.removeFromSearchIndex(db: db, conversationID: id.uuidString)
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id.uuidString])
            if enqueueForSync {
                try Self.enqueuePendingDeletions(db: db, ids: [id.uuidString])
            }
        }
        try continuationOrphanSweep?()
        try pruneAttachmentFilesToDatabase()
    }

    nonisolated func deleteConversations(ids: [UUID], enqueueForSync: Bool = true) throws {
        guard !ids.isEmpty else { return }
        let idStrings = ids.map(\.uuidString)
        try dbPool.write { db in
            let chunkSize = 500
            var offset = 0
            while offset < idStrings.count {
                let chunk = Array(idStrings[offset..<min(offset + chunkSize, idStrings.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                if try db.tableExists("search_index") {
                    try db.execute(
                        sql: "DELETE FROM search_index WHERE conversationID IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                }
                try db.execute(
                    sql: "DELETE FROM conversation WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                if enqueueForSync {
                    try Self.enqueuePendingDeletions(db: db, ids: chunk)
                }
                offset += chunkSize
            }
        }
        try continuationOrphanSweep?()
        try pruneAttachmentFilesToDatabase()
    }


    nonisolated private static func enqueuePendingDeletions(db: Database, ids: [String]) throws {
        let now = Date().timeIntervalSince1970
        for id in ids {
            try db.execute(
                sql: """
                INSERT INTO pending_conversation_deletion (conversationID, enqueuedAt) VALUES (?, ?)
                ON CONFLICT(conversationID) DO UPDATE SET enqueuedAt = excluded.enqueuedAt
                """,
                arguments: [id, now]
            )
        }
    }

    nonisolated func pendingDeletionIDs() throws -> [UUID] {
        try dbPool.read { db in
            try String
                .fetchAll(db, sql: "SELECT conversationID FROM pending_conversation_deletion ORDER BY enqueuedAt")
                .compactMap(UUID.init(uuidString:))
        }
    }

    nonisolated func clearPendingDeletions(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let idStrings = ids.map(\.uuidString)
        try dbPool.write { db in
            let chunkSize = 500
            var offset = 0
            while offset < idStrings.count {
                let chunk = Array(idStrings[offset..<min(offset + chunkSize, idStrings.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM pending_conversation_deletion WHERE conversationID IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                offset += chunkSize
            }
        }
    }

    nonisolated func updateTitle(id: UUID, title: String, hasCustomTitle: Bool) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversation
                    SET title = ?, hasCustomTitle = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [title, hasCustomTitle, Date().timeIntervalSince1970, id.uuidString]
            )
        }
    }

    nonisolated func updateDraft(id: UUID, draftText: String, isDraft: Bool) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversation
                    SET draftText = ?, isDraft = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [draftText, isDraft, Date().timeIntervalSince1970, id.uuidString]
            )
        }
    }

    nonisolated func updateCost(id: UUID, cost: Double) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE conversation SET estimatedCost = ? WHERE id = ?",
                arguments: [cost, id.uuidString]
            )
        }
    }

    nonisolated func updateModel(
        id: UUID,
        providerID: UUID,
        providerKind: ProviderKind,
        modelID: String,
        metadataUpdatedAt: Date? = nil
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversation
                    SET providerID = ?, providerKind = ?, modelID = ?, metadataUpdatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [
                    providerID.uuidString,
                    providerKind.rawValue,
                    modelID,
                    metadataUpdatedAt?.timeIntervalSince1970,
                    id.uuidString
                ]
            )
        }
    }

    nonisolated func setUseMemory(id: UUID, useMemory: Bool) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE conversation SET useMemory = ? WHERE id = ?",
                arguments: [useMemory, id.uuidString]
            )
        }
    }

    nonisolated func moveToFolder(id: UUID, folderID: UUID?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversation
                    SET folderID = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [folderID?.uuidString, Date().timeIntervalSince1970, id.uuidString]
            )
        }
    }

    nonisolated func search(query: String) async throws -> [ConversationSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let list = try await dbPool.read { db in
                try Self.fetchConversationSummaries(db: db)
            }
            return list.filter { $0.isVisibleInConversationList }
        }
        return try await dbPool.read { db in
            try Self.searchConversations(db: db, query: trimmed, folderID: nil)
        }
    }

    nonisolated func searchInFolder(folderID: UUID, query: String) async throws -> [ConversationSummary] {
        try searchInFolderSync(folderID: folderID, query: query)
    }

    nonisolated func searchInFolderSync(folderID: UUID, query: String) throws -> [ConversationSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT *
                        FROM conversation
                        WHERE folderID = ?
                        ORDER BY updatedAt DESC, createdAt DESC, id DESC
                        """,
                    arguments: [folderID.uuidString]
                )
                return rows.compactMap { row in
                    RecordMappers.summary(from: ConversationRecord(row: row))
                }
            }
        }

        return try dbPool.read { db in
            try Self.searchConversations(db: db, query: trimmed, folderID: folderID)
        }
    }

    nonisolated static func fetchConversationSummaries(db: Database) throws -> [ConversationSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM conversation
                ORDER BY updatedAt DESC, createdAt DESC, id DESC
                """
        )
        return rows.compactMap { row in
            RecordMappers.summary(from: ConversationRecord(row: row))
        }
    }

    nonisolated static func fetchConversationSummaries(
        db: Database,
        ids: [UUID]
    ) throws -> [ConversationSummary] {
        guard !ids.isEmpty else { return [] }
        var summaries: [ConversationSummary] = []
        summaries.reserveCapacity(ids.count)
        let chunkSize = 500
        var offset = 0
        while offset < ids.count {
            let chunk = ids[offset..<min(offset + chunkSize, ids.count)].map(\.uuidString)
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversation WHERE id IN (\(placeholders))",
                arguments: StatementArguments(chunk)
            )
            summaries += rows.compactMap { RecordMappers.summary(from: ConversationRecord(row: $0)) }
            offset += chunkSize
        }
        return summaries
    }

    nonisolated static func fetchConversationSummary(db: Database, id: UUID) throws -> ConversationSummary? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM conversation WHERE id = ?",
            arguments: [id.uuidString]
        ) else {
            return nil
        }
        return RecordMappers.summary(from: ConversationRecord(row: row))
    }

    nonisolated static func fetchUngroupedRecentConversationSummaries(
        db: Database,
        recentStart: Date
    ) throws -> [ConversationSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT *
                FROM conversation
                WHERE folderID IS NULL
                  AND \(Self.visibleUngroupedConversationWhereClause)
                  AND updatedAt >= ?
                ORDER BY updatedAt DESC, createdAt DESC, id DESC
                """,
            arguments: [recentStart.timeIntervalSince1970]
        )
        return rows.compactMap { row in
            RecordMappers.summary(from: ConversationRecord(row: row))
        }
    }

    nonisolated static func fetchUngroupedEarlierConversationSummaries(
        db: Database,
        recentStart: Date,
        limit: Int
    ) throws -> [ConversationSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT *
                FROM conversation
                WHERE folderID IS NULL
                  AND \(Self.visibleUngroupedConversationWhereClause)
                  AND updatedAt < ?
                ORDER BY updatedAt DESC, createdAt DESC, id DESC
                LIMIT ?
                """,
            arguments: [recentStart.timeIntervalSince1970, limit]
        )
        return rows.compactMap { row in
            RecordMappers.summary(from: ConversationRecord(row: row))
        }
    }

    nonisolated static func fetchUngroupedEarlierConversationCount(
        db: Database,
        recentStart: Date
    ) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM conversation
                WHERE folderID IS NULL
                  AND \(Self.visibleUngroupedConversationWhereClause)
                  AND updatedAt < ?
                """,
            arguments: [recentStart.timeIntervalSince1970]
        ) ?? 0
    }

    nonisolated static func fetchConversationThread(
        db: Database,
        summary: ConversationSummary,
        hydrateFilePayloads: Bool,
        attachmentFileStore: AttachmentFileStore
    ) throws -> ConversationThread {
        let messageRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE conversationID = ?
                ORDER BY sortOrder ASC, id ASC
                """,
            arguments: [summary.id.uuidString]
        )
        let messageRecords = messageRows.map(MessageRecord.init(row:))
        let messageIDs = messageRecords.map(\.id)
        let attachments = try fetchAttachments(
            db: db,
            messageIDs: messageIDs
        )
        let thread = RecordMappers.thread(
            from: summary,
            messageRecords: messageRecords,
            attachmentRecordsByMessageID: attachments,
            hydrateFilePayloads: hydrateFilePayloads,
            attachmentFileStore: attachmentFileStore
        )
        return thread
    }

    nonisolated static func fetchMessages(
        db: Database,
        conversationID: UUID,
        hydrateFilePayloads: Bool,
        attachmentFileStore: AttachmentFileStore
    ) throws -> [ChatMessage] {
        guard let summary = try fetchConversationSummary(db: db, id: conversationID) else { return [] }
        return try fetchConversationThread(
            db: db,
            summary: summary,
            hydrateFilePayloads: hydrateFilePayloads,
            attachmentFileStore: attachmentFileStore
        ).messages
    }

    nonisolated static func fetchRecentMessages(
        db: Database,
        conversationID: UUID,
        limit: Int,
        attachmentFileStore: AttachmentFileStore
    ) throws -> (messages: [ChatMessage], totalCount: Int) {
        let totalCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM message WHERE conversationID = ?",
            arguments: [conversationID.uuidString]
        ) ?? 0

        let offset = max(0, totalCount - limit)
        let messageRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE conversationID = ?
                ORDER BY sortOrder ASC, id ASC
                LIMIT ? OFFSET ?
                """,
            arguments: [conversationID.uuidString, limit, offset]
        )
        let messageRecords = messageRows.map(MessageRecord.init(row:))
        let messageIDs = messageRecords.map(\.id)
        let attachments = try fetchAttachments(db: db, messageIDs: messageIDs)

        let messages = messageRecords.compactMap { record -> ChatMessage? in
            RecordMappers.message(
                from: record,
                attachmentRecords: attachments[record.id] ?? [],
                hydrateFilePayloads: false,
                attachmentFileStore: attachmentFileStore
            )
        }
        return (messages, totalCount)
    }


    nonisolated struct MessageBoundary: Sendable, Equatable {
        let sortOrder: Int
        let id: String
    }

    nonisolated static func fetchMessageBoundary(
        db: Database,
        conversationID: UUID,
        messageID: UUID
    ) throws -> MessageBoundary? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT sortOrder, id FROM message
                WHERE conversationID = ? AND id = ?
                """,
            arguments: [conversationID.uuidString, messageID.uuidString]
        )
        guard let row else { return nil }
        return MessageBoundary(sortOrder: row["sortOrder"], id: row["id"])
    }

    nonisolated struct MessageWindow: Sendable {
        let messages: [ChatMessage]
        let earliestBoundary: MessageBoundary?
        let latestBoundary: MessageBoundary?
        let hasMoreAbove: Bool
        let hasMoreBelow: Bool
    }

    nonisolated static func fetchLatestMessageWindow(
        db: Database,
        conversationID: UUID,
        limit: Int,
        attachmentFileStore: AttachmentFileStore
    ) throws -> MessageWindow {
        let descRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE conversationID = ?
                ORDER BY sortOrder DESC, id DESC
                LIMIT ?
                """,
            arguments: [conversationID.uuidString, limit]
        )
        let ascRows = Array(descRows.reversed())
        let hydrated = try hydrateMessages(
            db: db,
            rows: ascRows,
            attachmentFileStore: attachmentFileStore
        )
        let hasMoreAbove = try existsBefore(
            db: db,
            conversationID: conversationID,
            boundary: hydrated.earliest
        )
        return MessageWindow(
            messages: hydrated.messages,
            earliestBoundary: hydrated.earliest,
            latestBoundary: hydrated.latest,
            hasMoreAbove: hasMoreAbove,
            hasMoreBelow: false
        )
    }

    nonisolated static func fetchMessageWindowAround(
        db: Database,
        conversationID: UUID,
        anchor: MessageBoundary,
        before: Int,
        after: Int,
        attachmentFileStore: AttachmentFileStore
    ) throws -> MessageWindow {
        let beforeDescRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE conversationID = ?
                  AND (sortOrder < ? OR (sortOrder = ? AND id <= ?))
                ORDER BY sortOrder DESC, id DESC
                LIMIT ?
                """,
            arguments: [conversationID.uuidString, anchor.sortOrder, anchor.sortOrder, anchor.id, before + 1]
        )
        let afterAscRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE conversationID = ?
                  AND (sortOrder > ? OR (sortOrder = ? AND id > ?))
                ORDER BY sortOrder ASC, id ASC
                LIMIT ?
                """,
            arguments: [conversationID.uuidString, anchor.sortOrder, anchor.sortOrder, anchor.id, after]
        )
        let combinedRows = Array(beforeDescRows.reversed()) + afterAscRows
        let hydrated = try hydrateMessages(
            db: db,
            rows: combinedRows,
            attachmentFileStore: attachmentFileStore
        )
        let hasMoreAbove = try existsBefore(
            db: db,
            conversationID: conversationID,
            boundary: hydrated.earliest
        )
        let hasMoreBelow = try existsAfter(
            db: db,
            conversationID: conversationID,
            boundary: hydrated.latest
        )
        return MessageWindow(
            messages: hydrated.messages,
            earliestBoundary: hydrated.earliest,
            latestBoundary: hydrated.latest,
            hasMoreAbove: hasMoreAbove,
            hasMoreBelow: hasMoreBelow
        )
    }

    nonisolated static func fetchMessagesBefore(
        db: Database,
        conversationID: UUID,
        boundary: MessageBoundary,
        limit: Int,
        attachmentFileStore: AttachmentFileStore
    ) throws -> (messages: [ChatMessage], earliestBoundary: MessageBoundary?, hasMoreAbove: Bool) {
        let descRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE conversationID = ?
                  AND (sortOrder < ? OR (sortOrder = ? AND id < ?))
                ORDER BY sortOrder DESC, id DESC
                LIMIT ?
                """,
            arguments: [conversationID.uuidString, boundary.sortOrder, boundary.sortOrder, boundary.id, limit]
        )
        let ascRows = Array(descRows.reversed())
        let hydrated = try hydrateMessages(
            db: db,
            rows: ascRows,
            attachmentFileStore: attachmentFileStore
        )
        let hasMoreAbove = try existsBefore(
            db: db,
            conversationID: conversationID,
            boundary: hydrated.earliest
        )
        return (hydrated.messages, hydrated.earliest, hasMoreAbove)
    }

    nonisolated static func fetchMessagesAfter(
        db: Database,
        conversationID: UUID,
        boundary: MessageBoundary,
        limit: Int,
        attachmentFileStore: AttachmentFileStore
    ) throws -> (messages: [ChatMessage], latestBoundary: MessageBoundary?, hasMoreBelow: Bool) {
        let ascRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM message
                WHERE conversationID = ?
                  AND (sortOrder > ? OR (sortOrder = ? AND id > ?))
                ORDER BY sortOrder ASC, id ASC
                LIMIT ?
                """,
            arguments: [conversationID.uuidString, boundary.sortOrder, boundary.sortOrder, boundary.id, limit]
        )
        let hydrated = try hydrateMessages(
            db: db,
            rows: ascRows,
            attachmentFileStore: attachmentFileStore
        )
        let hasMoreBelow = try existsAfter(
            db: db,
            conversationID: conversationID,
            boundary: hydrated.latest
        )
        return (hydrated.messages, hydrated.latest, hasMoreBelow)
    }

    nonisolated static func fetchSearchMatchMessageID(
        db: Database,
        conversationID: UUID,
        query: String
    ) throws -> UUID? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let likePattern = "%" + trimmed + "%"
        let idString = try String.fetchOne(
            db,
            sql: """
                SELECT id FROM message
                WHERE conversationID = ?
                  AND text LIKE ? COLLATE NOCASE
                ORDER BY sortOrder ASC, id ASC
                LIMIT 1
                """,
            arguments: [conversationID.uuidString, likePattern]
        )
        return idString.flatMap(UUID.init(uuidString:))
    }

    nonisolated private static func hydrateMessages(
        db: Database,
        rows: [Row],
        attachmentFileStore: AttachmentFileStore
    ) throws -> (messages: [ChatMessage], earliest: MessageBoundary?, latest: MessageBoundary?) {
        let messageRecords = rows.map(MessageRecord.init(row:))
        let messageIDs = messageRecords.map(\.id)
        let attachments = try fetchAttachments(db: db, messageIDs: messageIDs)
        var messages: [ChatMessage] = []
        messages.reserveCapacity(messageRecords.count)
        var earliestRecord: MessageRecord?
        var latestRecord: MessageRecord?
        for record in messageRecords {
            guard let m = RecordMappers.message(
                from: record,
                attachmentRecords: attachments[record.id] ?? [],
                hydrateFilePayloads: false,
                attachmentFileStore: attachmentFileStore
            ) else { continue }
            messages.append(m)
            if earliestRecord == nil { earliestRecord = record }
            latestRecord = record
        }
        let earliest = earliestRecord.map { MessageBoundary(sortOrder: $0.sortOrder, id: $0.id) }
        let latest = latestRecord.map { MessageBoundary(sortOrder: $0.sortOrder, id: $0.id) }
        return (messages, earliest, latest)
    }

    nonisolated private static func existsBefore(
        db: Database,
        conversationID: UUID,
        boundary: MessageBoundary?
    ) throws -> Bool {
        guard let boundary else { return false }
        return try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM message
                    WHERE conversationID = ?
                      AND (sortOrder < ? OR (sortOrder = ? AND id < ?))
                )
                """,
            arguments: [conversationID.uuidString, boundary.sortOrder, boundary.sortOrder, boundary.id]
        ) ?? false
    }

    nonisolated private static func existsAfter(
        db: Database,
        conversationID: UUID,
        boundary: MessageBoundary?
    ) throws -> Bool {
        guard let boundary else { return false }
        return try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM message
                    WHERE conversationID = ?
                      AND (sortOrder > ? OR (sortOrder = ? AND id > ?))
                )
                """,
            arguments: [conversationID.uuidString, boundary.sortOrder, boundary.sortOrder, boundary.id]
        ) ?? false
    }

    nonisolated private static func fetchAttachments(
        db: Database,
        messageIDs: [String]
    ) throws -> [String: [AttachmentRecord]] {
        guard !messageIDs.isEmpty else { return [:] }
        var rows: [Row] = []
        let chunkSize = 500
        var offset = 0
        while offset < messageIDs.count {
            let chunk = Array(messageIDs[offset..<min(offset + chunkSize, messageIDs.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT id, messageID, kind, fileName, mimeType, localFileID,
                       localImageID, thumbnailBase64, sortOrder,
                       extractedTotalLines, extractedTruncated, extractedSizeBytes,
                       extractionErrorCode, originalFileID
                FROM attachment
                WHERE messageID IN (\(placeholders))
                ORDER BY sortOrder ASC, id ASC
                """
            rows += try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk))
            offset += chunkSize
        }
        return Dictionary(grouping: rows.map(AttachmentRecord.init(row:)), by: \.messageID)
    }


    nonisolated private static func searchConversations(
        db: Database,
        query: String,
        folderID: UUID?
    ) throws -> [ConversationSummary] {
        let hasFTS = try db.tableExists("search_index")

        if hasFTS {
            let likeQuery = "%\(query)%"
            let sql: String
            var args: [DatabaseValueConvertible?]
            if let folderID {
                sql = """
                    SELECT c.*
                    FROM conversation c
                    JOIN search_index si ON si.conversationID = c.id
                    WHERE (si.title LIKE ? OR si.messageText LIKE ?)
                      AND c.folderID = ?
                    ORDER BY c.updatedAt DESC, c.createdAt DESC, c.id DESC
                    LIMIT 50
                    """
                args = [likeQuery, likeQuery, folderID.uuidString]
            } else {
                sql = """
                    SELECT c.*
                    FROM conversation c
                    JOIN search_index si ON si.conversationID = c.id
                    WHERE (si.title LIKE ? OR si.messageText LIKE ?)
                      AND \(Self.visibleConversationWhereClauseWithAlias)
                    ORDER BY c.updatedAt DESC, c.createdAt DESC, c.id DESC
                    LIMIT 50
                    """
                args = [likeQuery, likeQuery]
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { RecordMappers.summary(from: ConversationRecord(row: $0)) }
        }

        let likeQuery = "%\(query)%"
        let sql: String
        var args: [DatabaseValueConvertible?]
        if let folderID {
            sql = """
                SELECT DISTINCT c.*
                FROM conversation c
                LEFT JOIN message m ON m.conversationID = c.id
                WHERE c.folderID = ?
                  AND (c.title LIKE ? COLLATE NOCASE OR m.text LIKE ? COLLATE NOCASE)
                ORDER BY c.updatedAt DESC, c.createdAt DESC, c.id DESC
                LIMIT 50
                """
            args = [folderID.uuidString, likeQuery, likeQuery]
        } else {
            sql = """
                SELECT DISTINCT c.*
                FROM conversation c
                LEFT JOIN message m ON m.conversationID = c.id
                WHERE \(Self.visibleConversationWhereClauseWithAlias)
                  AND (c.title LIKE ? COLLATE NOCASE OR m.text LIKE ? COLLATE NOCASE)
                ORDER BY c.updatedAt DESC, c.createdAt DESC, c.id DESC
                LIMIT 50
                """
            args = [likeQuery, likeQuery]
        }

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return rows.compactMap { RecordMappers.summary(from: ConversationRecord(row: $0)) }
    }

    nonisolated static func rebuildSearchIndex(
        db: Database,
        conversationID: String,
        title: String,
        messages: [ChatMessage]
    ) throws {
        guard try db.tableExists("search_index") else { return }
        try? db.execute(
            sql: "DELETE FROM search_index WHERE conversationID = ?",
            arguments: [conversationID]
        )
        let messageText = messages.map(\.text).joined(separator: " ")
        try? db.execute(
            sql: "INSERT INTO search_index(conversationID, title, messageText) VALUES (?, ?, ?)",
            arguments: [conversationID, title, messageText]
        )
    }

    nonisolated static func removeFromSearchIndex(db: Database, conversationID: String) throws {
        guard try db.tableExists("search_index") else { return }
        try? db.execute(
            sql: "DELETE FROM search_index WHERE conversationID = ?",
            arguments: [conversationID]
        )
    }

    nonisolated private func deriveConversationForMutationWrite(_ conversation: Conversation) -> Conversation {
        var derived = conversation
        ConversationListMetadata.apply(to: &derived)
        let deliveredCosts = derived.messages
            .filter { $0.state == .delivered && $0.estimatedCost > CostFormatter.costEpsilon }
            .map(\.estimatedCost)
        if deliveredCosts.isEmpty {
            derived.estimatedCost = conversation.estimatedCost > CostFormatter.costEpsilon
                ? conversation.estimatedCost
                : 0
        } else {
            derived.estimatedCost = deliveredCosts.reduce(0, +)
        }
        derived.isDraft = derived.messages.isEmpty && conversation.isDraft
        return derived
    }


    private struct ConversationColumnValues {
        let id: String
        let title: String
        let hasCustomTitle: Bool
        let providerID: String
        let providerKind: String
        let modelID: String
        let previewText: String
        let messageCount: Int
        let remoteMessageCount: Int
        let estimatedCost: Double
        let isDraft: Bool
        let draftText: String
        let createdAt: Double
        let updatedAt: Double
        let folderID: String?
        let useMemory: Bool
        let skillId: String?
        let metadataUpdatedAt: Double?
        let messagesHydratedAt: Double?
        let messagesStale: Bool
        let deletedAt: Double?
        let isConflictCopy: Bool
        let originalConversationId: String?
        let pinnedNoteIds: String?

        nonisolated init(from summary: ConversationSummary) {
            id = summary.id.uuidString
            title = summary.title
            hasCustomTitle = summary.hasCustomTitle
            providerID = summary.providerID.uuidString
            providerKind = summary.providerKind.rawValue
            modelID = summary.modelID
            previewText = summary.previewText
            messageCount = summary.messageCount
            remoteMessageCount = summary.remoteMessageCount
            estimatedCost = summary.estimatedCost
            isDraft = summary.isDraft
            draftText = summary.draftText
            createdAt = summary.createdAt.timeIntervalSince1970
            updatedAt = summary.updatedAt.timeIntervalSince1970
            folderID = summary.folderID?.uuidString
            useMemory = summary.useMemory
            skillId = summary.skillId?.uuidString
            metadataUpdatedAt = summary.metadataUpdatedAt?.timeIntervalSince1970
            messagesHydratedAt = summary.messagesHydratedAt?.timeIntervalSince1970
            messagesStale = summary.messagesStale
            deletedAt = summary.deletedAt?.timeIntervalSince1970
            isConflictCopy = summary.isConflictCopy
            originalConversationId = summary.originalConversationId?.uuidString
            pinnedNoteIds = RecordMappers.encodePinnedNoteIds(summary.pinnedNoteIds)
        }

        nonisolated init(
            from conversation: Conversation,
            messagesHydratedAt: Double? = nil,
            messagesStale: Bool = false
        ) {
            id = conversation.id.uuidString
            title = conversation.title
            hasCustomTitle = conversation.hasCustomTitle
            providerID = conversation.providerID.uuidString
            providerKind = conversation.providerKind.rawValue
            modelID = conversation.modelID
            previewText = conversation.previewText
            messageCount = conversation.messages.count
            remoteMessageCount = conversation.messageCountOverride ?? conversation.messages.count
            estimatedCost = conversation.estimatedCost
            isDraft = conversation.isDraft
            draftText = conversation.draftText
            createdAt = conversation.createdAt.timeIntervalSince1970
            updatedAt = conversation.updatedAt.timeIntervalSince1970
            folderID = conversation.folderID?.uuidString
            useMemory = conversation.useMemory
            skillId = conversation.skillId?.uuidString
            metadataUpdatedAt = conversation.metadataUpdatedAt?.timeIntervalSince1970
            self.messagesHydratedAt = messagesHydratedAt
            self.messagesStale = messagesStale
            deletedAt = conversation.deletedAt?.timeIntervalSince1970
            isConflictCopy = conversation.isConflictCopy
            originalConversationId = conversation.originalConversationId?.uuidString
            pinnedNoteIds = RecordMappers.encodePinnedNoteIds(conversation.pinnedNoteIds)
        }

        nonisolated var arguments: [DatabaseValueConvertible?] {
            [id, title, hasCustomTitle, providerID, providerKind, modelID, previewText, messageCount,
             remoteMessageCount,
             estimatedCost, isDraft, draftText, createdAt, updatedAt, folderID,
             useMemory, skillId, metadataUpdatedAt, messagesHydratedAt, messagesStale,
             deletedAt, isConflictCopy, originalConversationId, pinnedNoteIds]
        }
    }

    nonisolated private static let conversationUpsertSQL = """
        INSERT INTO conversation (
            id, title, hasCustomTitle, providerID, providerKind, modelID, previewText, messageCount,
            remoteMessageCount,
            estimatedCost, isDraft, draftText, createdAt, updatedAt, folderID,
            useMemory, skillId, metadataUpdatedAt, messagesHydratedAt, messagesStale,
            deletedAt, isConflictCopy, originalConversationId, pinnedNoteIds
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            hasCustomTitle = excluded.hasCustomTitle,
            providerID = excluded.providerID,
            providerKind = excluded.providerKind,
            modelID = excluded.modelID,
            previewText = excluded.previewText,
            messageCount = excluded.messageCount,
            remoteMessageCount = excluded.remoteMessageCount,
            estimatedCost = excluded.estimatedCost,
            isDraft = excluded.isDraft,
            draftText = excluded.draftText,
            createdAt = excluded.createdAt,
            updatedAt = excluded.updatedAt,
            folderID = excluded.folderID,
            useMemory = excluded.useMemory,
            skillId = excluded.skillId,
            metadataUpdatedAt = excluded.metadataUpdatedAt,
            messagesHydratedAt = excluded.messagesHydratedAt,
            messagesStale = excluded.messagesStale,
            deletedAt = excluded.deletedAt,
            isConflictCopy = excluded.isConflictCopy,
            originalConversationId = excluded.originalConversationId,
            pinnedNoteIds = excluded.pinnedNoteIds
        """

    nonisolated private static let conversationInsertSQL = """
        INSERT INTO conversation (
            id, title, hasCustomTitle, providerID, providerKind, modelID, previewText, messageCount,
            remoteMessageCount,
            estimatedCost, isDraft, draftText, createdAt, updatedAt, folderID,
            useMemory, skillId, metadataUpdatedAt, messagesHydratedAt, messagesStale,
            deletedAt, isConflictCopy, originalConversationId, pinnedNoteIds
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """


    nonisolated private struct AttachmentFileRefs {
        let localFileID: String?
        let originalFileID: String?
    }

    nonisolated private static func attachmentFileRefs(
        db: Database,
        messageID: String
    ) throws -> [String: AttachmentFileRefs] {
        try attachmentFileRefs(
            db: db,
            sql: "SELECT id, localFileID, originalFileID FROM attachment WHERE messageID = ?",
            arguments: [messageID]
        )
    }

    nonisolated private static func allAttachmentFileRefs(db: Database) throws -> [String: AttachmentFileRefs] {
        try attachmentFileRefs(
            db: db,
            sql: "SELECT id, localFileID, originalFileID FROM attachment",
            arguments: []
        )
    }

    nonisolated private static func attachmentFileRefs(
        db: Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> [String: AttachmentFileRefs] {
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        var refs: [String: AttachmentFileRefs] = [:]
        for row in rows {
            guard let id = row["id"] as String? else { continue }
            refs[id] = AttachmentFileRefs(
                localFileID: row["localFileID"] as String?,
                originalFileID: row["originalFileID"] as String?
            )
        }
        return refs
    }

    nonisolated private func resolveSidecarFileID(
        payload: String?,
        canonicalID: String,
        inheritedID: String?
    ) throws -> String? {
        if let payload, !payload.isEmpty {
            if attachmentFileStore.exists(id: canonicalID) { return canonicalID }
            return try attachmentFileStore.saveBase64(payload, for: canonicalID)
        }
        guard let inheritedID, attachmentFileStore.exists(id: inheritedID) else { return nil }
        return inheritedID
    }

    nonisolated private func resolveSidecarFileIDs(
        for attachment: Attachment,
        inherited: AttachmentFileRefs?,
        referencedFileIDs: inout Set<String>
    ) throws -> (localFileID: String?, originalFileID: String?) {
        guard attachment.kind == .file else { return (nil, nil) }

        let localFileID = try resolveSidecarFileID(
            payload: attachment.base64Data,
            canonicalID: attachment.id.uuidString,
            inheritedID: inherited?.localFileID
        )
        let originalFileID = try resolveSidecarFileID(
            payload: attachment.originalBase64Data,
            canonicalID: "\(attachment.id.uuidString)-orig",
            inheritedID: inherited?.originalFileID
        )

        if let localFileID { referencedFileIDs.insert(localFileID) }
        if let originalFileID { referencedFileIDs.insert(originalFileID) }
        return (localFileID, originalFileID)
    }

    nonisolated private func pruneAttachmentFilesToDatabase() throws {
        let referencedFileIDs = try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT localFileID, originalFileID
                    FROM attachment
                    WHERE localFileID IS NOT NULL OR originalFileID IS NOT NULL
                    """
            )
            var ids = Set<String>()
            for row in rows {
                if let localFileID = row["localFileID"] as String? { ids.insert(localFileID) }
                if let originalFileID = row["originalFileID"] as String? { ids.insert(originalFileID) }
            }
            return ids
        }
        attachmentFileStore.prune(keeping: referencedFileIDs)
    }

    nonisolated private func upsertMessageRows(
        _ messages: [ChatMessage],
        conversationID: UUID,
        into db: Database,
        referencedFileIDs: inout Set<String>
    ) throws {
        let convIDString = conversationID.uuidString
        for (messageSortOrder, message) in messages.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO message (
                        id, conversationID, role, text, quoteContext, providerID, providerKind, providerName,
                        modelID, modelName, servedModelID, estimatedCost, state,
                        errorTitle, errorDetail, createdAt, sortOrder, citations,
                        reasoningText, reasoningDurationMs,
                        cachedInputTokens, cacheCreation5mTokens, cacheCreation1hTokens, costSource,
                        inputTokens, outputTokens, cacheCreationInputTokens,
                        capabilityExecution, unhandledToolCalls
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        text = excluded.text,
                        quoteContext = excluded.quoteContext,
                        estimatedCost = excluded.estimatedCost,
                        state = excluded.state,
                        errorTitle = excluded.errorTitle,
                        errorDetail = excluded.errorDetail,
                        sortOrder = excluded.sortOrder,
                        servedModelID = excluded.servedModelID,
                        citations = excluded.citations,
                        reasoningText = excluded.reasoningText,
                        reasoningDurationMs = excluded.reasoningDurationMs,
                        cachedInputTokens = excluded.cachedInputTokens,
                        cacheCreation5mTokens = excluded.cacheCreation5mTokens,
                        cacheCreation1hTokens = excluded.cacheCreation1hTokens,
                        costSource = excluded.costSource,
                        inputTokens = excluded.inputTokens,
                        outputTokens = excluded.outputTokens,
                        cacheCreationInputTokens = excluded.cacheCreationInputTokens,
                        capabilityExecution = excluded.capabilityExecution,
                        unhandledToolCalls = excluded.unhandledToolCalls
                    """,
                arguments: [
                    message.id.uuidString,
                    convIDString,
                    message.role.rawValue,
                    message.text,
                    RecordMappers.encodeQuoteContext(message.quoteContext),
                    message.providerID?.uuidString,
                    message.providerKind.rawValue,
                    message.providerName,
                    message.modelID,
                    message.modelName,
                    message.servedModelID,
                    message.estimatedCost,
                    message.state.rawValue,
                    message.errorTitle,
                    message.errorDetail,
                    message.createdAt?.timeIntervalSince1970,
                    messageSortOrder,
                    RecordMappers.encodeCitations(message.citations),
                    message.reasoningText,
                    message.reasoningDurationMs,
                    message.cachedInputTokens,
                    message.cacheCreation5mTokens,
                    message.cacheCreation1hTokens,
                    message.costSource?.rawValue,
                    message.inputTokens,
                    message.outputTokens,
                    message.cacheCreationInputTokens,
                    RecordMappers.encodeCapabilityExecution(message.capabilityExecution),
                    RecordMappers.encodeUnhandledToolCalls(message.unhandledToolCalls),
                ]
            )

            let attachments = message.attachments ?? []
            let newAttachmentIDs = Set(attachments.map { $0.id.uuidString })
            let inheritedFileRefs = try Self.attachmentFileRefs(db: db, messageID: message.id.uuidString)
            let attachmentsToDelete = inheritedFileRefs.keys.filter { !newAttachmentIDs.contains($0) }
            if !attachmentsToDelete.isEmpty {
                let placeholders = attachmentsToDelete.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM attachment WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(attachmentsToDelete)
                )
            }

            for (sortOrder, attachment) in attachments.enumerated() {
                let (localFileID, originalFileID) = try resolveSidecarFileIDs(
                    for: attachment,
                    inherited: inheritedFileRefs[attachment.id.uuidString],
                    referencedFileIDs: &referencedFileIDs
                )

                try db.execute(
                    sql: """
                        INSERT INTO attachment (
                            id, messageID, kind, fileName, mimeType, localFileID,
                            localImageID, thumbnailBase64, sortOrder,
                            extractedTotalLines, extractedTruncated, extractedSizeBytes,
                            extractionErrorCode, originalFileID
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            localFileID = excluded.localFileID,
                            localImageID = excluded.localImageID,
                            thumbnailBase64 = excluded.thumbnailBase64,
                            sortOrder = excluded.sortOrder,
                            extractedTotalLines = excluded.extractedTotalLines,
                            extractedTruncated = excluded.extractedTruncated,
                            extractedSizeBytes = excluded.extractedSizeBytes,
                            extractionErrorCode = excluded.extractionErrorCode,
                            originalFileID = excluded.originalFileID
                        """,
                    arguments: [
                        attachment.id.uuidString,
                        message.id.uuidString,
                        attachment.kind.rawValue,
                        attachment.fileName,
                        attachment.mimeType,
                        localFileID,
                        attachment.localImageID,
                        attachment.thumbnailBase64,
                        sortOrder,
                        attachment.extractedTotalLines,
                        attachment.extractedTruncated.map { $0 ? 1 : 0 },
                        attachment.extractedSizeBytes,
                        attachment.extractionErrorCode,
                        originalFileID
                    ]
                )
            }
        }
    }

    nonisolated private func upsertConversation(
        _ conversation: Conversation,
        into db: Database,
        referencedFileIDs: inout Set<String>
    ) throws {
        let convIDString = conversation.id.uuidString

        let cols = ConversationColumnValues(
            from: conversation,
            messagesHydratedAt: Date().timeIntervalSince1970,
            messagesStale: false
        )
        try db.execute(sql: Self.conversationUpsertSQL, arguments: StatementArguments(cols.arguments))

        let newMessageIDs = Set(conversation.messages.map { $0.id.uuidString })
        let existingMessageIDs = try String.fetchAll(
            db,
            sql: "SELECT id FROM message WHERE conversationID = ?",
            arguments: [convIDString]
        )
        let toDelete = existingMessageIDs.filter { !newMessageIDs.contains($0) }
        if !toDelete.isEmpty {
            let placeholders = toDelete.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM message WHERE id IN (\(placeholders))",
                arguments: StatementArguments(toDelete)
            )
        }

        for (messageSortOrder, message) in conversation.messages.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO message (
                        id, conversationID, role, text, quoteContext, providerID, providerKind, providerName,
                        modelID, modelName, servedModelID, estimatedCost, state,
                        errorTitle, errorDetail, createdAt, sortOrder, citations,
                        reasoningText, reasoningDurationMs,
                        cachedInputTokens, cacheCreation5mTokens, cacheCreation1hTokens, costSource,
                        inputTokens, outputTokens, cacheCreationInputTokens,
                        capabilityExecution, unhandledToolCalls
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        text = excluded.text,
                        quoteContext = excluded.quoteContext,
                        estimatedCost = excluded.estimatedCost,
                        state = excluded.state,
                        errorTitle = excluded.errorTitle,
                        errorDetail = excluded.errorDetail,
                        sortOrder = excluded.sortOrder,
                        servedModelID = excluded.servedModelID,
                        citations = excluded.citations,
                        reasoningText = excluded.reasoningText,
                        reasoningDurationMs = excluded.reasoningDurationMs,
                        cachedInputTokens = excluded.cachedInputTokens,
                        cacheCreation5mTokens = excluded.cacheCreation5mTokens,
                        cacheCreation1hTokens = excluded.cacheCreation1hTokens,
                        costSource = excluded.costSource,
                        inputTokens = excluded.inputTokens,
                        outputTokens = excluded.outputTokens,
                        cacheCreationInputTokens = excluded.cacheCreationInputTokens,
                        capabilityExecution = excluded.capabilityExecution,
                        unhandledToolCalls = excluded.unhandledToolCalls
                    """,
                arguments: [
                    message.id.uuidString,
                    convIDString,
                    message.role.rawValue,
                    message.text,
                    RecordMappers.encodeQuoteContext(message.quoteContext),
                    message.providerID?.uuidString,
                    message.providerKind.rawValue,
                    message.providerName,
                    message.modelID,
                    message.modelName,
                    message.servedModelID,
                    message.estimatedCost,
                    message.state.rawValue,
                    message.errorTitle,
                    message.errorDetail,
                    message.createdAt?.timeIntervalSince1970,
                    messageSortOrder,
                    RecordMappers.encodeCitations(message.citations),
                    message.reasoningText,
                    message.reasoningDurationMs,
                    message.cachedInputTokens,
                    message.cacheCreation5mTokens,
                    message.cacheCreation1hTokens,
                    message.costSource?.rawValue,
                    message.inputTokens,
                    message.outputTokens,
                    message.cacheCreationInputTokens,
                    RecordMappers.encodeCapabilityExecution(message.capabilityExecution),
                    RecordMappers.encodeUnhandledToolCalls(message.unhandledToolCalls),
                ]
            )

            let attachments = message.attachments ?? []
            let newAttachmentIDs = Set(attachments.map { $0.id.uuidString })
            let inheritedFileRefs = try Self.attachmentFileRefs(db: db, messageID: message.id.uuidString)
            let attachmentsToDelete = inheritedFileRefs.keys.filter { !newAttachmentIDs.contains($0) }
            if !attachmentsToDelete.isEmpty {
                let placeholders = attachmentsToDelete.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM attachment WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(attachmentsToDelete)
                )
            }

            for (sortOrder, attachment) in attachments.enumerated() {
                let (localFileID, originalFileID) = try resolveSidecarFileIDs(
                    for: attachment,
                    inherited: inheritedFileRefs[attachment.id.uuidString],
                    referencedFileIDs: &referencedFileIDs
                )

                try db.execute(
                    sql: """
                        INSERT INTO attachment (
                            id, messageID, kind, fileName, mimeType, localFileID,
                            localImageID, thumbnailBase64, sortOrder,
                            extractedTotalLines, extractedTruncated, extractedSizeBytes,
                            extractionErrorCode, originalFileID
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            localFileID = excluded.localFileID,
                            localImageID = excluded.localImageID,
                            thumbnailBase64 = excluded.thumbnailBase64,
                            sortOrder = excluded.sortOrder,
                            extractedTotalLines = excluded.extractedTotalLines,
                            extractedTruncated = excluded.extractedTruncated,
                            extractedSizeBytes = excluded.extractedSizeBytes,
                            extractionErrorCode = excluded.extractionErrorCode,
                            originalFileID = excluded.originalFileID
                        """,
                    arguments: [
                        attachment.id.uuidString,
                        message.id.uuidString,
                        attachment.kind.rawValue,
                        attachment.fileName,
                        attachment.mimeType,
                        localFileID,
                        attachment.localImageID,
                        attachment.thumbnailBase64,
                        sortOrder,
                        attachment.extractedTotalLines,
                        attachment.extractedTruncated.map { $0 ? 1 : 0 },
                        attachment.extractedSizeBytes,
                        attachment.extractionErrorCode,
                        originalFileID
                    ]
                )
            }
        }

        try Self.rebuildSearchIndex(
            db: db,
            conversationID: convIDString,
            title: conversation.title,
            messages: conversation.messages
        )
    }

    nonisolated private func insert(
        conversation: Conversation,
        into db: Database,
        inheritedFileRefs: [String: AttachmentFileRefs],
        referencedFileIDs: inout Set<String>
    ) throws {
        let cols = ConversationColumnValues(
            from: conversation,
            messagesHydratedAt: Date().timeIntervalSince1970,
            messagesStale: false
        )
        try db.execute(sql: Self.conversationInsertSQL, arguments: StatementArguments(cols.arguments))

        for (messageSortOrder, message) in conversation.messages.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO message (
                        id, conversationID, role, text, quoteContext, providerID, providerKind, providerName,
                        modelID, modelName, servedModelID, estimatedCost, state,
                        errorTitle, errorDetail, createdAt, sortOrder, citations,
                        reasoningText, reasoningDurationMs,
                        cachedInputTokens, cacheCreation5mTokens, cacheCreation1hTokens, costSource,
                        inputTokens, outputTokens, cacheCreationInputTokens,
                        capabilityExecution, unhandledToolCalls
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    message.id.uuidString,
                    conversation.id.uuidString,
                    message.role.rawValue,
                    message.text,
                    RecordMappers.encodeQuoteContext(message.quoteContext),
                    message.providerID?.uuidString,
                    message.providerKind.rawValue,
                    message.providerName,
                    message.modelID,
                    message.modelName,
                    message.servedModelID,
                    message.estimatedCost,
                    message.state.rawValue,
                    message.errorTitle,
                    message.errorDetail,
                    message.createdAt?.timeIntervalSince1970,
                    messageSortOrder,
                    RecordMappers.encodeCitations(message.citations),
                    message.reasoningText,
                    message.reasoningDurationMs,
                    message.cachedInputTokens,
                    message.cacheCreation5mTokens,
                    message.cacheCreation1hTokens,
                    message.costSource?.rawValue,
                    message.inputTokens,
                    message.outputTokens,
                    message.cacheCreationInputTokens,
                    RecordMappers.encodeCapabilityExecution(message.capabilityExecution),
                    RecordMappers.encodeUnhandledToolCalls(message.unhandledToolCalls),
                ]
            )

            for (sortOrder, attachment) in (message.attachments ?? []).enumerated() {
                let (localFileID, originalFileID) = try resolveSidecarFileIDs(
                    for: attachment,
                    inherited: inheritedFileRefs[attachment.id.uuidString],
                    referencedFileIDs: &referencedFileIDs
                )

                try db.execute(
                    sql: """
                        INSERT INTO attachment (
                            id, messageID, kind, fileName, mimeType, localFileID,
                            localImageID, thumbnailBase64, sortOrder,
                            extractedTotalLines, extractedTruncated, extractedSizeBytes,
                            extractionErrorCode, originalFileID
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        attachment.id.uuidString,
                        message.id.uuidString,
                        attachment.kind.rawValue,
                        attachment.fileName,
                        attachment.mimeType,
                        localFileID,
                        attachment.localImageID,
                        attachment.thumbnailBase64,
                        sortOrder,
                        attachment.extractedTotalLines,
                        attachment.extractedTruncated.map { $0 ? 1 : 0 },
                        attachment.extractedSizeBytes,
                        attachment.extractionErrorCode,
                        originalFileID
                    ]
                )
            }
        }

        try Self.rebuildSearchIndex(
            db: db,
            conversationID: conversation.id.uuidString,
            title: conversation.title,
            messages: conversation.messages
        )
    }
}
