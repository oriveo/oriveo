import Foundation
import GRDB

nonisolated final class RecipeContinuationStore: @unchecked Sendable {
    /// Deliberately process-local: opaque tool-loop state must never survive an app restart.
    /// A user may explicitly continue an interrupted stream in this launch, but we never resume it.
    private static let launchToken = UUID().uuidString
    private static let revisionLock = NSLock()
    /// SQLite stores this in the existing REAL column. Microsecond wall time stays below IEEE-754's
    /// exact-integer limit; the lock makes equal-clock writes strictly monotonic within a launch.
    nonisolated(unsafe) private static var lastRevision: Double = 0
    struct Snapshot: Codable, Sendable {
        let kind: String
        let state: [String: MetadataClient.JSONValue]
        let interrupted: Bool
        /// Strictly monotonic within a launch for compare-and-delete. It is intentionally not
        /// exported with the opaque payload.
        let revision: Double
    }

    struct ConsumptionToken: Sendable {
        let messageID: UUID
        let revision: Double
    }

    private let dbPool: DatabasePool
    /// The conversation database is consulted only to make deletion lifecycle observable; opaque
    /// state itself never enters that database or its backup/sync surface.
    private let parentPool: DatabasePool?

    // Test-only inspection of an injected local-only pool. Production callers have no reason to
    // access this opaque storage directly.
    var dbPoolForTesting: DatabasePool { dbPool }

    init(dbPool: DatabasePool, parentPool: DatabasePool? = nil) throws {
        self.dbPool = dbPool
        self.parentPool = parentPool
        try Self.prepareSchema(in: dbPool)
    }

    convenience init() throws {
        let uid = AppSessionStore.activeUID
        let parentPool = try DatabaseManager.shared.openCurrent()
        try self.init(dbPool: Self.openLocalOnlyPool(for: uid), parentPool: parentPool)
    }

    func load(messageID: UUID) throws -> Snapshot? {
        try purgeOtherLaunches()
        if let parentPool,
           try parentPool.read({ db in
               (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE id = ?", arguments: [messageID.uuidString]) ?? 0) == 0
           }) {
            // Deletion is a terminal lifecycle event. Clear the local row on first observation;
            // no stale opaque payload can be read, synced, backed up, or revived.
            try discard(messageID: messageID)
            return nil
        }
        return try dbPool.read { db -> Snapshot? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT kind, stateJSON, interrupted, launchToken, updatedAt FROM message_recipe_continuation WHERE messageID = ?",
                arguments: [messageID.uuidString]
            ), let kind: String = row["kind"], let raw: String = row["stateJSON"],
              let token: String = row["launchToken"], token == Self.launchToken,
              let revision: Double = row["updatedAt"],
              let data = raw.data(using: .utf8),
              let state = try? JSONDecoder().decode([String: MetadataClient.JSONValue].self, from: data) else {
                return nil
            }
            return .init(
                kind: kind, state: state,
                interrupted: (row["interrupted"] as Int? ?? 0) != 0,
                revision: revision
            )
        }
    }

    func save(messageID: UUID, kind: String, state: [String: MetadataClient.JSONValue], interrupted: Bool = false) throws {
        let raw = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO message_recipe_continuation(messageID, kind, stateJSON, interrupted, launchToken, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(messageID) DO UPDATE SET
                    kind = excluded.kind, stateJSON = excluded.stateJSON,
                    interrupted = excluded.interrupted, launchToken = excluded.launchToken,
                    updatedAt = excluded.updatedAt
                """, arguments: [messageID.uuidString, kind, raw, interrupted ? 1 : 0, Self.launchToken, Self.nextRevision()])
        }
    }

    func discard(messageID: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM message_recipe_continuation WHERE messageID = ?", arguments: [messageID.uuidString])
        }
    }

    /// A successful explicit continuation consumes only the precise snapshot that was sent.
    /// If that same response produced a new continuation state, `save` advances `updatedAt` and
    /// this DELETE becomes a no-op, preserving the next legitimate continuation leg.
    @discardableResult
    func discard(_ token: ConsumptionToken) throws -> Bool {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM message_recipe_continuation WHERE messageID = ? AND launchToken = ? AND updatedAt = ?",
                arguments: [token.messageID.uuidString, Self.launchToken, token.revision]
            )
            return db.changesCount == 1
        }
    }

    func markInterrupted(messageID: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE message_recipe_continuation SET interrupted = 1, updatedAt = ? WHERE messageID = ?", arguments: [Self.nextRevision(), messageID.uuidString])
        }
    }

    /// `replaceAll` atomically replaces the parent message set. Sidecars are intentionally in a
    /// separate no-backup database, so sweep orphaned IDs after that transaction instead of using
    /// a cross-database FK or copying opaque JSON back into the primary database.
    func purgeMissingParentMessages() throws {
        try purgeOtherLaunches()
        guard let parentPool else { return }
        let ids = try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT messageID FROM message_recipe_continuation")
        }
        guard !ids.isEmpty else { return }
        var missing: [String] = []
        for chunk in ids.chunked(into: 500) {
            let existing = try parentPool.read { db in
                try Set(String.fetchAll(
                    db,
                    sql: "SELECT id FROM message WHERE id IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")",
                    arguments: StatementArguments(chunk)
                ))
            }
            missing.append(contentsOf: chunk.filter { !existing.contains($0) })
        }
        guard !missing.isEmpty else { return }
        try dbPool.write { db in for chunk in missing.chunked(into: 500) {
            try db.execute(
                sql: "DELETE FROM message_recipe_continuation WHERE messageID IN (" + chunk.map { _ in "?" }.joined(separator: ",") + ")",
                arguments: StatementArguments(chunk)
            )
        }
        }
    }

    static func purgeCurrentOrphans() throws {
        let store = try RecipeContinuationStore()
        try store.purgeMissingParentMessages()
    }

    static func purgeOrphans(for uid: String, parentPool: DatabasePool) throws {
        let store = try RecipeContinuationStore(dbPool: openLocalOnlyPool(for: uid), parentPool: parentPool)
        try store.purgeMissingParentMessages()
    }

    private static func nextRevision() -> Double {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        // At 2026 epoch this is ~1.8e15, still exactly representable as an integer Double.
        let wallMicroseconds = (Date().timeIntervalSince1970 * 1_000_000).rounded(.down)
        lastRevision = max(wallMicroseconds, lastRevision + 1)
        return lastRevision
    }

    private func purgeOtherLaunches() throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM message_recipe_continuation WHERE launchToken != ?",
                arguments: [Self.launchToken]
            )
        }
    }

    private static func openLocalOnlyPool(for uid: String) throws -> DatabasePool {
        let directory = AppSessionStore.userDir(for: uid).appendingPathComponent("LocalOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        let pool = try DatabasePool(path: directory.appendingPathComponent("recipe-continuation.sqlite").path)
        try prepareSchema(in: pool)
        return pool
    }

    private static func prepareSchema(in pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS message_recipe_continuation (
                    messageID TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    stateJSON TEXT NOT NULL,
                    interrupted INTEGER NOT NULL DEFAULT 0,
                    launchToken TEXT NOT NULL,
                    updatedAt REAL NOT NULL
                )
                """)
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
