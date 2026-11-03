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
    /// Partitions whose pre-open failed: a later main-thread request throws `DatabaseUnavailable` directly (no leak record, no reopen); cleared on a successful pre-open or on `close()`.
    private var failedOpenUIDs: Set<String> = []
    /// Serial queue for the first database open (connect + migration): the main thread never opens the database.
    private let openQueue = DispatchQueue(label: "com.oriveo.database-open", qos: .userInitiated)

    /// The main thread asked for a partition that was not prepared yet: it does not open the database (callers treat it as
    /// "database not available yet") and the current partition is opened in the background instead.
    struct NotPreparedOnMainThread: Error, Equatable {
        let uid: String
    }

    /// The pre-open the main thread needs has failed (database cannot open): callers treat it as "database unavailable"; a formal retry goes through pre-open (the retry button / next cold start).
    struct DatabaseUnavailable: Error, Equatable {
        let uid: String
    }

    /// In the test process the main thread's first open stays synchronous (unit tests build AppState and read/write the database right away, without changing hundreds of tests); always false in production.
    /// The production "zero opens on the main thread" guarantee is locked by a dedicated test that turns this off.
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
    /// - Parameters: file / function: the direct caller, a low-cardinality fingerprint for a main-thread miss.
    func openIfNeeded(for uid: String, file: String = #fileID, function: String = #function) throws -> DatabasePool {
        #if DEBUG
        DatabaseIOErrorDiagnostics.noteRequestedUID(uid)
        #endif
        if let pool = openedPool(for: uid) { return pool }
        if Thread.isMainThread {
            guard Self.allowsMainThreadFirstOpen else {
                // Pre-open already failed: this is not a leak path, so no miss is recorded and nothing reopens in the background (a reopen would only be an incidental retry; formal retries go through prepare).
                if hasFailedOpen(uid) { throw DatabaseUnavailable(uid: uid) }
                let caller = "\((file as NSString).lastPathComponent):\(function)"
                MainActor.assumeIsolated { DatabaseOpenDiagnostics.reportNotPreparedOnMain(caller: caller) }
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
        if let pool = pinnedPool(for: uid) {
            recordPrepareOutcome(uid: uid, failed: false)
            return pool
        }
        return try await withCheckedThrowingContinuation { continuation in
            openQueue.async {
                let result = Result { try self.open(uid: uid, pin: true) }
                self.recordPrepareOutcome(uid: uid, failed: (try? result.get()) == nil)
                // The local database for sidecar continuation is also pre-opened here: its first open (connect) often lands on the main thread's send path. A failure to open does not affect the main database; it opens when needed.
                if case .success = result { RecipeContinuationStore.prewarmLocalOnlyPool(for: uid) }
                continuation.resume(with: result)
            }
        }
    }

    private func recordPrepareOutcome(uid: String, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if failed { failedOpenUIDs.insert(uid) } else { failedOpenUIDs.remove(uid) }
    }

    private func hasFailedOpen(_ uid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failedOpenUIDs.contains(uid)
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
        // A non-pinned lookup (e.g. a queued write of the previous partition) reuses a retiring pool that has not
        // closed yet instead of opening another connection; it is not put back into a slot and closes with its
        // retirement. A pinned prepare always opens a fresh pool.
        if !pin, let retiring = retiringPool(for: uid, store: .main) { return retiring }
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

    /// Closes every partition this manager holds. References are dropped synchronously (later lookups never see
    /// the old pools); the real `pool.close()` runs asynchronously on `queue`, after the writes already enqueued
    /// there, or on this manager's own serial queue when `queue` is nil. Never on the main thread, never inside an
    /// access block of the pool. `queue` must be a serial queue. Await `waitForRetiredPools(uid:)` for the close.
    /// - Parameter barrier: local writes that must land before the close (e.g. write tails captured at detach time).
    ///   The close is enqueued on `queue` once it returns, or after `closeBarrierTimeout` (reported as a close failure).
    func close(after queue: DispatchQueue? = nil, barrier: (@Sendable () async -> Void)? = nil) {
        lock.lock()
        var retiring: [(uid: String, pool: DatabasePool)] = []
        if let currentUID, let currentPool { retiring.append((currentUID, currentPool)) }
        if let secondaryUID, let secondaryPool { retiring.append((secondaryUID, secondaryPool)) }
        currentUID = nil
        currentPool = nil
        secondaryUID = nil
        secondaryPool = nil
        failedOpenUIDs.removeAll()
        registerRetiredLocked(retiring, store: .main)
        lock.unlock()
        scheduleClose(retiring, store: .main, after: queue, barrier: barrier)
    }

    /// Which store a retired pool belongs to (low-cardinality diagnostic tag).
    enum RetiredStore: String, Sendable {
        case main
        case continuationSidecar = "continuation_sidecar"
    }

    /// Retires a pool owned by another store of the same partition (e.g. the continuation sidecar) through the
    /// same mechanism as `close(after:)`: the caller has already dropped its own reference.
    func retire(
        _ pool: DatabasePool, uid: String, store: RetiredStore, after queue: DispatchQueue? = nil,
        barrier: (@Sendable () async -> Void)? = nil
    ) {
        lock.lock()
        registerRetiredLocked([(uid, pool)], store: store)
        lock.unlock()
        scheduleClose([(uid, pool)], store: store, after: queue, barrier: barrier)
    }

    /// A retired pool of `uid` / `store` whose close has not run yet (nil when none). Non-pinned lookups reuse it.
    func retiringPool(for uid: String, store: RetiredStore) -> DatabasePool? {
        lock.lock()
        defer { lock.unlock() }
        return retiredPools[uid]?.last(where: { $0.store == store && $0.pool != nil })?.pool
    }

    /// Returns once every retired pool of `uid` finished its real close (succeeded or failed).
    func waitForRetiredPools(uid: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !enqueueRetiredPoolWaiter(uid: uid, continuation) { continuation.resume() }
        }
    }

    /// Whether `uid` still has a connection open in this manager: an opened pool, a retired pool whose close has
    /// not run yet, or one whose close failed (that connection stays open).
    func hasOpenConnections(uid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if currentUID == uid, currentPool != nil { return true }
        if secondaryUID == uid, secondaryPool != nil { return true }
        return !(retiredPools[uid]?.isEmpty ?? true)
    }

    /// A pool whose references were dropped, waiting for (or having failed) its real close.
    private struct RetiredPool {
        let store: RetiredStore
        /// Strong until the close finished; dropped (nil) when the close failed for good: the connection stays open.
        var pool: DatabasePool?
        var closeFailed: Bool { pool == nil }
    }

    /// Guarded by `lock`.
    private var retiredPools: [String: [RetiredPool]] = [:]
    /// Guarded by `lock`.
    private var retiredPoolWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Upper bound for a close barrier; past it the close runs anyway and is reported as a close failure.
    private static let closeBarrierTimeout: TimeInterval = 10

    private func registerRetiredLocked(_ pools: [(uid: String, pool: DatabasePool)], store: RetiredStore) {
        for entry in pools { retiredPools[entry.uid, default: []].append(RetiredPool(store: store, pool: entry.pool)) }
    }

    /// Returns false when nothing of `uid` is pending (the caller resumes immediately).
    private func enqueueRetiredPoolWaiter(uid: String, _ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard retiredPools[uid]?.contains(where: { !$0.closeFailed }) == true else { return false }
        retiredPoolWaiters[uid, default: []].append(continuation)
        return true
    }

    /// Identifies a retired pool without retaining it: the pool itself stays owned by `retiredPools` only.
    private struct RetiredKey: Sendable {
        let uid: String
        let id: ObjectIdentifier
    }

    private func scheduleClose(
        _ pools: [(uid: String, pool: DatabasePool)], store: RetiredStore, after queue: DispatchQueue?,
        barrier: (@Sendable () async -> Void)?
    ) {
        guard !pools.isEmpty else { return }
        let keys = pools.map { RetiredKey(uid: $0.uid, id: ObjectIdentifier($0.pool)) }
        let target = queue ?? openQueue
        guard let barrier else {
            enqueueClose(keys, store: store, on: target, isRetry: false)
            return
        }
        let once = CloseBarrierOnce()
        let proceed: @Sendable (Bool) -> Void = { timedOut in
            guard once.claim() else { return }
            if timedOut { Self.reportCloseFailure(store: store, resultCode: "barrier_timeout") }
            self.enqueueClose(keys, store: store, on: target, isRetry: false)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.closeBarrierTimeout) { proceed(true) }
        Task.detached(priority: .userInitiated) {
            await barrier()
            proceed(false)
        }
    }

    /// Closes the keyed pools on `queue`. A failed close is retried once on the same queue (behind whatever was
    /// enqueued meanwhile); a second failure is final.
    private func enqueueClose(_ keys: [RetiredKey], store: RetiredStore, on queue: DispatchQueue, isRetry: Bool) {
        queue.async {
            var failed: [RetiredKey] = []
            for key in keys {
                guard let failure = self.closeRetiredPool(key) else {
                    self.finishRetirement(key, store: store, failure: nil)
                    continue
                }
                if isRetry { self.finishRetirement(key, store: store, failure: failure) } else { failed.append(key) }
            }
            if !failed.isEmpty { self.enqueueClose(failed, store: store, on: queue, isRetry: true) }
        }
    }

    /// Runs the real close; the pool is only borrowed for the call, so no strong reference outlives it here.
    private func closeRetiredPool(_ key: RetiredKey) -> (any Error)? {
        guard let pool = retiredPool(key) else { return nil }
        do {
            try pool.close()
            return nil
        } catch {
            return error
        }
    }

    private func retiredPool(_ key: RetiredKey) -> DatabasePool? {
        lock.lock()
        defer { lock.unlock() }
        return retiredPools[key.uid]?.first(where: { $0.pool.map { ObjectIdentifier($0) } == key.id })?.pool
    }

    private func finishRetirement(_ key: RetiredKey, store: RetiredStore, failure: (any Error)?) {
        lock.lock()
        var entries = retiredPools[key.uid] ?? []
        var released: DatabasePool?
        if let index = entries.firstIndex(where: { $0.pool.map { ObjectIdentifier($0) } == key.id }) {
            released = entries[index].pool
            if failure == nil { entries.remove(at: index) } else { entries[index].pool = nil }
        }
        retiredPools[key.uid] = entries.isEmpty ? nil : entries
        var waiters: [CheckedContinuation<Void, Never>] = []
        if !entries.contains(where: { !$0.closeFailed }) {
            waiters = retiredPoolWaiters.removeValue(forKey: key.uid) ?? []
        }
        lock.unlock()
        // Drop the last strong reference outside the lock and before waking waiters.
        if released != nil { released = nil }
        waiters.forEach { $0.resume() }
    }

    #if DEBUG
    /// Test seam: forgets the failed closes of `uid` once the test itself released what kept them open.
    func forgetFailedClosesForTesting(uid: String) {
        lock.lock()
        retiredPools[uid]?.removeAll(where: \.closeFailed)
        if retiredPools[uid]?.isEmpty == true { retiredPools[uid] = nil }
        lock.unlock()
    }
    #endif

    /// Where close failures are reported. Tests swap in a recording sink.
    @MainActor static var closeDiagnosticsSink: ObservabilitySink = Observability.sink

    /// A close barrier that timed out keeps the connection open until the close runs; surface it once as a registered issue.
    private static func reportCloseFailure(store: RetiredStore, resultCode: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let issue = DiagnosticIssue.databaseCloseFailed
                let tags = ["db.store": store.rawValue, "db.result_code": resultCode]
                closeDiagnosticsSink.issue(
                    name: issue.rawValue, level: issue.level, fingerprint: issue.fingerprint(tags: tags), context: tags
                )
            }
        }
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

/// Lets exactly one of the barrier completion and its timeout proceed with the close.
private final class CloseBarrierOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
