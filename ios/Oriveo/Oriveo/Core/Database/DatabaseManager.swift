import Foundation
import GRDB

nonisolated final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private let lock = NSLock()
    /// Serializes first opens; the main thread (production) never takes it.
    private let openLock = NSLock()
    /// The session partition's database (pinned by `prepare(for:)`).
    private var currentUID: String?
    private var currentPool: DatabasePool?
    /// A non-current partition reopened by uid in the background (a write queued before a partition change): it never replaces the current database.
    private var secondaryUID: String?
    private var secondaryPool: DatabasePool?
    /// Queue for first opens (connection + migrations): the main thread never opens a database.
    private let openQueue = DispatchQueue(label: "com.oriveo.database-open", qos: .userInitiated)

    /// The main thread asked for a partition that was not prepared yet: it does not open the database (callers treat it as
    /// "database not available yet") and the current partition is opened in the background instead.
    struct NotPreparedOnMainThread: Error, Equatable {
        let uid: String
    }

    /// In the test host the first open on the main thread stays synchronous (unit tests build an AppState and read the
    /// database at once, which would otherwise need hundreds of tests changed); always false in production. The
    /// "main thread never opens" behaviour is locked by a dedicated test that turns this off.
    nonisolated(unsafe) static var allowsMainThreadFirstOpen: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    #if DEBUG
    /// Called when the main thread asks for an unprepared partition: asserts by default so a stray entry point shows up at once
    /// in development and tests; tests replace it to collect the calls.
    nonisolated(unsafe) static var mainThreadMissHandler: ((String) -> Void)? = { uid in
        assertionFailure("The main thread asked for an unprepared partition database \(uid): the first open must happen in the background (DatabaseManager.prepare); make the caller wait for it")
    }
    /// Test seam: an artificial delay before the first-open migrations (simulates a slow migration of a large database).
    nonisolated(unsafe) static var migrationDelayForTesting: TimeInterval = 0
    #endif

    private init() {
        #if DEBUG
        DatabaseIOErrorDiagnostics.install()
        #endif
    }

    func openCurrent() throws -> DatabasePool {
        try openIfNeeded(for: AppSessionStore.activeUID)
    }

    /// Returns the database if it is already open (no write). If not: a background thread opens it as before; the main
    /// thread (production) does not open it and throws `NotPreparedOnMainThread`.
    func openIfNeeded(for uid: String) throws -> DatabasePool {
        #if DEBUG
        DatabaseIOErrorDiagnostics.noteRequestedUID(uid)
        #endif
        if let pool = openedPool(for: uid) { return pool }
        if Thread.isMainThread {
            guard Self.allowsMainThreadFirstOpen else {
                #if DEBUG
                Self.mainThreadMissHandler?(uid)
                #endif
                if uid == AppSessionStore.activeUID { Task { _ = try? await self.prepare(for: uid) } }
                throw NotPreparedOnMainThread(uid: uid)
            }
            // The test host's synchronous entry keeps the old semantics: opening a partition makes it the current one.
            #if DEBUG
            return try MainThreadDatabaseWriteGuard.exemptingTestHarnessOpen { try self.open(uid: uid, pin: true) }
            #else
            return try open(uid: uid, pin: true)
            #endif
        }
        return try open(uid: uid, pin: false)
    }

    /// Opens the partition database in the background (connection + migrations) and pins it as the current partition.
    /// Called at launch; until it is ready the UI shows nothing that could touch the database.
    func prepare(for uid: String) async throws -> DatabasePool {
        if let pool = pinnedPool(for: uid) { return pool }
        return try await withCheckedThrowingContinuation { continuation in
            openQueue.async {
                let result = Result { try self.open(uid: uid, pin: true) }
                // The continuation sidecar's local database is prewarmed here too: its first open (connecting) often lands on
                // the main-thread send path. A failure does not affect the main database; it opens on first use instead.
                if case .success = result { RecipeContinuationStore.prewarmLocalOnlyPool(for: uid) }
                continuation.resume(with: result)
            }
        }
    }

    /// The partition's database is already open (does not open it).
    func openedPool(for uid: String) -> DatabasePool? {
        lock.lock()
        defer { lock.unlock() }
        if currentUID == uid, let currentPool { return currentPool }
        if secondaryUID == uid, let secondaryPool { return secondaryPool }
        return nil
    }

    private func pinnedPool(for uid: String) -> DatabasePool? {
        lock.lock()
        defer { lock.unlock() }
        if currentUID == uid, let currentPool { return currentPool }
        if secondaryUID == uid, let pool = secondaryPool {
            swap(&currentUID, &secondaryUID)
            swap(&currentPool, &secondaryPool)
            return pool
        }
        return nil
    }

    /// - Parameter pin: true = pin it as the current partition (the previous one becomes secondary); false = become current
    ///   when there is none, otherwise go into the secondary slot.
    /// Connecting and migrating do not hold `lock` (the main thread only takes it briefly to look at the cache, so a slow
    /// migration never stalls it); `openLock` allows only one open at a time.
    private func open(uid: String, pin: Bool) throws -> DatabasePool {
        openLock.lock()
        defer { openLock.unlock() }
        if let pool = pin ? pinnedPool(for: uid) : openedPool(for: uid) { return pool }
        let pool = try makePool(uid: uid)
        lock.lock()
        defer { lock.unlock() }
        if pin || currentPool == nil {
            if currentPool != nil {
                secondaryUID = currentUID
                secondaryPool = currentPool
            }
            currentUID = uid
            currentPool = pool
        } else {
            secondaryUID = uid
            secondaryPool = pool
        }
        return pool
    }

    /// Connection + migrations (the only place that starts a first-open write).
    private func makePool(uid: String) throws -> DatabasePool {
        let userDirectory = AppSessionStore.userDir(for: uid)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        let databaseURL = AppSessionStore.databasePath(for: uid)
        try Self.throwIfExistingFileIsNotSQLite(databaseURL)

        let pool = try DatabasePool(
            path: databaseURL.path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        #if DEBUG
        if Self.migrationDelayForTesting > 0 { Thread.sleep(forTimeInterval: Self.migrationDelayForTesting) }
        #endif
        let attachmentFileStore = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        try DatabaseSchema.makeMigrator(attachmentFileStore: attachmentFileStore).migrate(pool)
        return pool
    }

    /// The currently open partition database (no open, no migration); nil when none is open.
    func openedPool() -> DatabasePool? {
        lock.lock()
        defer { lock.unlock() }
        return currentPool
    }

    /// WAL checkpoint on the given instance (fixed by the caller where the work is queued): it never reopens by the
    /// active uid, so a checkpoint queued before a partition change still lands in the partition it was queued for.
    static func checkpoint(_ pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    func close() {
        lock.lock()
        currentUID = nil
        currentPool = nil
        secondaryUID = nil
        secondaryPool = nil
        lock.unlock()
    }

    /// replaceAll and similar paths must fail loudly when the file exists but is not SQLite,
    /// instead of letting GRDB treat the garbage as an empty database.
    private static func throwIfExistingFileIsNotSQLite(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = handle.readData(ofLength: 16)
        guard prefix.isEmpty || prefix.starts(with: Data("SQLite format 3".utf8)) else {
            throw DatabaseError(resultCode: .SQLITE_NOTADB)
        }
    }

    func hasDatabase(for uid: String) -> Bool {
        let path = AppSessionStore.databasePath(for: uid).path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? UInt64
        else {
            return false
        }
        return size > 0
    }
}
