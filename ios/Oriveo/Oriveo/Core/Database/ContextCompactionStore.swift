import Foundation
import GRDB
import OriveoProviderKit

/// One context checkpoint. Primary key (conversationId, checkpointId).
nonisolated struct ContextCheckpointRecord: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case summary
        case fallback
    }

    var conversationId: String
    var checkpointId: String
    var kind: Kind
    var coversFrom: String
    var coversTo: String
    var coversDigest: String
    var messagesCovered: Int
    var userMessageIds: [String]
    /// The full checkpoint text.
    var text: String
    var summary: String?
    var language: String?
    var model: String
    var packerVersion: String
    /// Milliseconds.
    var createdAt: Int64
    var cost: Double?
}

extension Notification.Name {
    /// Checkpoint rows of a conversation were added or removed (save / deleteAll / invalidate / import); userInfo[conversationIdKey] is the conversation id.
    nonisolated static let contextCheckpointsDidChange = Notification.Name("ContextCompactionStore.contextCheckpointsDidChange")
}

/// Reads and writes the context_checkpoint table: overwrite on write, keep the newest 8 per conversation, cascade-delete with the conversation;
/// latestValid / invalidate rely only on the digest and concurrency resolution of ProviderKit `ContextCheckpoint`.
final class ContextCompactionStore: @unchecked Sendable {
    nonisolated static let table = "context_checkpoint"
    nonisolated static let capacityPerConversation = 8

    nonisolated static let conversationIdKey = "conversationId"

    private let dbPool: DatabasePool

    nonisolated init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Creates the table (`v35_context_checkpoint`).
    nonisolated static func createTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE \(table) (
                conversationId TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                checkpointId TEXT NOT NULL,
                kind TEXT NOT NULL,
                coversFrom TEXT NOT NULL,
                coversTo TEXT NOT NULL,
                coversDigest TEXT NOT NULL,
                messagesCovered INTEGER NOT NULL,
                userMessageIds TEXT NOT NULL,
                text TEXT NOT NULL,
                summary TEXT,
                language TEXT,
                model TEXT NOT NULL,
                packerVersion TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                cost REAL,
                PRIMARY KEY (conversationId, checkpointId)
            )
            """)
        try db.execute(sql: """
            CREATE INDEX idx_context_checkpoint_conversation_created
            ON \(table)(conversationId, createdAt)
            """)
    }

    /// The store of the partition the conversation lives in; nil when the database cannot be opened.
    nonisolated static func forPartition(_ uid: String) -> ContextCompactionStore? {
        #if DEBUG
        if let pool = shotsPool { return ContextCompactionStore(dbPool: pool) }
        #endif
        return (try? DatabaseManager.shared.openIfNeeded(for: uid)).map { ContextCompactionStore(dbPool: $0) }
    }

    #if DEBUG
    /// Screenshots only: an isolated partition for the context pages (a standalone database in a temp directory, see ContextShots); when set, the real partition database is not opened.
    nonisolated(unsafe) static var shotsPool: DatabasePool?
    #endif

    /// Overwrites the same (conversationId, checkpointId); in the same transaction trims this conversation to the 8 rows with the newest createdAt.
    nonisolated func save(_ record: ContextCheckpointRecord) throws {
        try dbPool.write { db in
            try Self.upsert(record, in: db)
            try Self.trim(conversationId: record.conversationId, in: db)
        }
        Self.postChange(conversationId: record.conversationId)
    }

    /// Deletes all checkpoints of this conversation and returns the deleted checkpointIds.
    @discardableResult
    nonisolated func deleteAll(conversationId: String) throws -> [String] {
        let removed = try dbPool.write { db -> [String] in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT checkpointId FROM \(Self.table) WHERE conversationId = ? ORDER BY createdAt ASC, rowid ASC",
                arguments: [conversationId]
            )
            try db.execute(sql: "DELETE FROM \(Self.table) WHERE conversationId = ?", arguments: [conversationId])
            return ids
        }
        if !removed.isEmpty { Self.postChange(conversationId: conversationId) }
        return removed
    }

    /// Regenerating first deletes the latestValid row; returns the checkpointIds actually deleted.
    @discardableResult
    nonisolated func delete(conversationId: String, checkpointId: String) throws -> [String] {
        let deleted = try dbPool.write { db -> Bool in
            try db.execute(
                sql: "DELETE FROM \(Self.table) WHERE conversationId = ? AND checkpointId = ?",
                arguments: [conversationId, checkpointId]
            )
            return db.changesCount > 0
        }
        guard deleted else { return [] }
        Self.postChange(conversationId: conversationId)
        return [checkpointId]
    }

    private nonisolated static func postChange(conversationId: String) {
        NotificationCenter.default.post(
            name: .contextCheckpointsDidChange,
            object: nil,
            userInfo: [conversationIdKey: conversationId]
        )
    }

    /// The whole table (for backup export), ordered by conversationId and createdAt; corrupt rows are skipped.
    nonisolated func listAll() throws -> [ContextCheckpointRecord] {
        let rows = try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(Self.table) ORDER BY conversationId ASC, createdAt ASC, rowid ASC"
            )
        }
        return rows.compactMap(Self.record(from:))
    }

    /// Backup import: accepts only rows of conversations that exist in the conversation table, upserts by primary key,
    /// and trims the affected conversations to 8 rows in the same transaction. Returns the number of rows written.
    @discardableResult
    nonisolated func importRecords(_ records: [ContextCheckpointRecord]) throws -> Int {
        guard !records.isEmpty else { return 0 }
        let (written, touched) = try dbPool.write { db -> (Int, [String]) in
            var existing: [String: Bool] = [:]
            var touched: [String] = []
            var written = 0
            for record in records {
                let exists: Bool
                if let cached = existing[record.conversationId] {
                    exists = cached
                } else {
                    exists = try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM conversation WHERE id = ?)",
                        arguments: [record.conversationId]
                    ) ?? false
                    existing[record.conversationId] = exists
                    if exists { touched.append(record.conversationId) }
                }
                guard exists else { continue }
                try Self.upsert(record, in: db)
                written += 1
            }
            for conversationId in touched {
                try Self.trim(conversationId: conversationId, in: db)
            }
            return (written, touched)
        }
        for conversationId in touched {
            Self.postChange(conversationId: conversationId)
        }
        return written
    }

    private nonisolated static func upsert(_ record: ContextCheckpointRecord, in db: Database) throws {
        let userMessageIds = String(decoding: try JSONEncoder().encode(record.userMessageIds), as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO \(table) (
                    conversationId, checkpointId, kind, coversFrom, coversTo, coversDigest, messagesCovered,
                    userMessageIds, text, summary, language, model, packerVersion, createdAt, cost
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(conversationId, checkpointId) DO UPDATE SET
                    kind = excluded.kind, coversFrom = excluded.coversFrom, coversTo = excluded.coversTo,
                    coversDigest = excluded.coversDigest, messagesCovered = excluded.messagesCovered,
                    userMessageIds = excluded.userMessageIds, text = excluded.text, summary = excluded.summary,
                    language = excluded.language, model = excluded.model, packerVersion = excluded.packerVersion,
                    createdAt = excluded.createdAt, cost = excluded.cost
                """,
            arguments: [
                record.conversationId, record.checkpointId, record.kind.rawValue, record.coversFrom,
                record.coversTo, record.coversDigest, record.messagesCovered, userMessageIds, record.text,
                record.summary, record.language, record.model, record.packerVersion, record.createdAt,
                record.cost,
            ]
        )
    }

    private nonisolated static func trim(conversationId: String, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM \(table)
                WHERE conversationId = ? AND rowid NOT IN (
                    SELECT rowid FROM \(table)
                    WHERE conversationId = ?
                    ORDER BY createdAt DESC, rowid DESC
                    LIMIT ?
                )
                """,
            arguments: [conversationId, conversationId, capacityPerConversation]
        )
    }

    /// All checkpoints of this conversation, createdAt oldest to newest; rows with a corrupt kind or userMessageIds are skipped.
    nonisolated func list(conversationId: String) throws -> [ContextCheckpointRecord] {
        let rows = try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(Self.table) WHERE conversationId = ? ORDER BY createdAt ASC, rowid ASC",
                arguments: [conversationId]
            )
        }
        return rows.compactMap(Self.record(from:))
    }

    /// Rows whose coversTo is not in the history or whose digest does not match are skipped (not deleted); of the rest, one is chosen by resolveConcurrency.
    nonisolated func latestValid(
        conversationId: String,
        history: [ContextCheckpoint.CoveredMessage]
    ) throws -> ContextCheckpointRecord? {
        var byId: [String: ContextCheckpointRecord] = [:]
        var winner: ContextCheckpoint.Claim?
        for record in try list(conversationId: conversationId) {
            guard let index = history.firstIndex(where: { $0.id == record.coversTo }),
                  ContextCheckpoint.coversDigest(Array(history[0...index])) == record.coversDigest
            else { continue }
            byId[record.checkpointId] = record
            let claim = ContextCheckpoint.Claim(
                checkpointId: record.checkpointId, coversToIndex: index, createdAtMillis: record.createdAt
            )
            winner = winner.map { ContextCheckpoint.resolveConcurrency($0, claim) } ?? claim
        }
        return winner.flatMap { byId[$0.checkpointId] }
    }

    /// k = the smallest index of affectedIds within historyIds; deletes rows whose coversTo index is >= k;
    /// rows whose coversTo is not in historyIds are left alone. Returns the deleted checkpointIds.
    /// The synchronous variant is for background callers and tests; main-thread callers use `invalidateAndPropagateAsync`.
    @discardableResult
    nonisolated func invalidate(conversationId: String, historyIds: [String], affectedIds: [String]) throws -> [String] {
        guard let plan = Self.invalidationPlan(historyIds: historyIds, affectedIds: affectedIds) else { return [] }
        let removed = try dbPool.write { db in
            try Self.deleteInvalidated(db: db, conversationId: conversationId, plan: plan)
        }
        if !removed.isEmpty { Self.postChange(conversationId: conversationId) }
        return removed
    }

    /// Shared invalidation hook: after invalidate, the deleted ids are handed to the remote-delete callback
    /// (local edits / regeneration pass a remote delete; for removed remote messages pass nil and nothing is written back). Failures are only logged and never block the caller.
    @discardableResult
    nonisolated func invalidateAndPropagate(
        conversationId: String,
        historyIds: [String],
        affectedIds: [String],
        deleteRemote: (([String]) -> Void)? = nil
    ) -> [String] {
        let removed: [String]
        do {
            removed = try invalidate(conversationId: conversationId, historyIds: historyIds, affectedIds: affectedIds)
        } catch {
            print("[ContextCompactionStore] invalidate failed: \(error.localizedDescription)")
            return []
        }
        if !removed.isEmpty { deleteRemote?(removed) }
        return removed
    }

    /// Same as `invalidateAndPropagate`, but the write is queued on the GRDB writer and awaited without
    /// occupying the calling thread: the write lock can be held by a whole-table write for seconds, and waiting
    /// for it synchronously on the main thread is an app hang. Returns the deleted checkpointIds, empty on failure.
    nonisolated func invalidateAndPropagateAsync(
        conversationId: String,
        historyIds: [String],
        affectedIds: [String]
    ) async -> [String] {
        guard let plan = Self.invalidationPlan(historyIds: historyIds, affectedIds: affectedIds) else { return [] }
        do {
            let removed = try await dbPool.write { db in
                try Self.deleteInvalidated(db: db, conversationId: conversationId, plan: plan)
            }
            if !removed.isEmpty { Self.postChange(conversationId: conversationId) }
            return removed
        } catch {
            print("[ContextCompactionStore] invalidate failed: \(error.localizedDescription)")
            return []
        }
    }

    private nonisolated struct InvalidationPlan: Sendable {
        let indexById: [String: Int]
        let k: Int
    }

    private nonisolated static func invalidationPlan(historyIds: [String], affectedIds: [String]) -> InvalidationPlan? {
        var indexById: [String: Int] = [:]
        for (index, id) in historyIds.enumerated() where indexById[id] == nil {
            indexById[id] = index
        }
        guard let k = affectedIds.compactMap({ indexById[$0] }).min() else { return nil }
        return InvalidationPlan(indexById: indexById, k: k)
    }

    private nonisolated static func deleteInvalidated(
        db: Database,
        conversationId: String,
        plan: InvalidationPlan
    ) throws -> [String] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT checkpointId, coversTo FROM \(table) WHERE conversationId = ?",
            arguments: [conversationId]
        )
        var removed: [String] = []
        for row in rows {
            let coversTo: String = row["coversTo"]
            guard let index = plan.indexById[coversTo], index >= plan.k else { continue }
            let checkpointId: String = row["checkpointId"]
            try db.execute(
                sql: "DELETE FROM \(table) WHERE conversationId = ? AND checkpointId = ?",
                arguments: [conversationId, checkpointId]
            )
            removed.append(checkpointId)
        }
        return removed
    }

    private nonisolated static func record(from row: Row) -> ContextCheckpointRecord? {
        let kindRaw: String = row["kind"]
        let idsJSON: String = row["userMessageIds"]
        guard let kind = ContextCheckpointRecord.Kind(rawValue: kindRaw),
              let userMessageIds = try? JSONDecoder().decode([String].self, from: Data(idsJSON.utf8))
        else { return nil }
        return ContextCheckpointRecord(
            conversationId: row["conversationId"],
            checkpointId: row["checkpointId"],
            kind: kind,
            coversFrom: row["coversFrom"],
            coversTo: row["coversTo"],
            coversDigest: row["coversDigest"],
            messagesCovered: row["messagesCovered"],
            userMessageIds: userMessageIds,
            text: row["text"],
            summary: row["summary"],
            language: row["language"],
            model: row["model"],
            packerVersion: row["packerVersion"],
            createdAt: row["createdAt"],
            cost: row["cost"]
        )
    }
}
