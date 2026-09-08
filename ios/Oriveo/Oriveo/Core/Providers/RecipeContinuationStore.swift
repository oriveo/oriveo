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

    /// Same store over a pool whose schema is already prepared. The shared local-only pool runs
    /// `prepareSchema` once at creation, so per-call stores must not repeat that write.
    private init(preparedPool: DatabasePool, parentPool: DatabasePool?) {
        dbPool = preparedPool
        self.parentPool = parentPool
    }

    convenience init() throws {
        let uid = AppSessionStore.activeUID
        let parentPool = try DatabaseManager.shared.openCurrent()
        self.init(preparedPool: try Self.localOnlyPool(for: uid), parentPool: parentPool)
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
        let store = RecipeContinuationStore(
            preparedPool: try localOnlyPool(for: uid),
            parentPool: parentPool
        )
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

    /// The local-only sidecar pool, opened at most once per uid.
    ///
    /// `purgeOrphans` runs after **every** conversation write, so opening a fresh `DatabasePool`
    /// per call meant opening a new SQLite connection per write. That has two consequences:
    ///
    /// - The previous pool is released by ARC, so a new connection routinely opens while the old
    ///   one is still alive. Reopening the same WAL file that way invites `SQLITE_BUSY_RECOVERY`
    ///   (extended code 261) out of GRDB's connection-time `SELECT * FROM sqlite_master LIMIT 1`.
    /// - The pool used `Configuration()` defaults, i.e. `busyMode == .immediate`, so it never
    ///   waited for the lock. The busy timeout in `DatabaseSchema.makeConfiguration()` never
    ///   applied here, which is why the primary database's timeout did not cover this path.
    ///
    /// Caching also drops the redundant `CREATE TABLE IF NOT EXISTS` write that ran on every call.
    private static let poolLock = NSLock()
    nonisolated(unsafe) private static var cachedPoolUID: String?
    nonisolated(unsafe) private static var cachedPool: DatabasePool?
    #if DEBUG
    /// DEBUG only: how many local-only pools were actually opened, for the reuse regression test.
    nonisolated(unsafe) private static var poolOpenCount = 0
    #endif

    private static func localOnlyPool(for uid: String) throws -> DatabasePool {
        poolLock.lock()
        defer { poolLock.unlock() }

        if cachedPoolUID == uid, let cachedPool {
            return cachedPool
        }

        let directory = AppSessionStore.userDir(for: uid).appendingPathComponent("LocalOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("recipe-continuation.sqlite").path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        try prepareSchema(in: pool)
        #if DEBUG
        poolOpenCount += 1
        #endif
        cachedPoolUID = uid
        cachedPool = pool
        return pool
    }

    /// Drop the cached pool on logout / uid switch. Mirrors `DatabaseManager.close()`: the
    /// reference is released and the connection closes with the pool, rather than calling
    /// `close()` while an observation may still hold it.
    static func closeLocalOnlyPool() {
        poolLock.lock()
        cachedPoolUID = nil
        cachedPool = nil
        poolLock.unlock()
    }

    #if DEBUG
    static func resetLocalOnlyPoolForTesting() {
        poolLock.lock()
        cachedPoolUID = nil
        cachedPool = nil
        poolOpenCount = 0
        poolLock.unlock()
    }

    static var localOnlyPoolOpenCountForTesting: Int {
        poolLock.lock()
        defer { poolLock.unlock() }
        return poolOpenCount
    }

    /// Exercises the production accessor so tests assert on the pool callers actually get.
    static func localOnlyPoolForTesting(for uid: String) throws -> DatabasePool {
        try localOnlyPool(for: uid)
    }
    #endif

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
