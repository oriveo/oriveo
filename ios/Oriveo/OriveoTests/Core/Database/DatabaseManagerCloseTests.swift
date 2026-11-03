import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Closing a partition must really close its SQLite connections: the references are dropped synchronously,
/// `pool.close()` runs off the main thread after the writes already queued on the given serial queue,
/// and callers can await the actual close.
@Suite("DatabaseManager close really closes connections", .serialized, .sharedProcessState)
struct DatabaseManagerCloseTests {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private static func makeUID() -> String { "db-close-\(UUID().uuidString)" }

    /// Opens the partition off the main thread (no sidecar prewarm) as the current pool.
    private static func openPool(_ uid: String) async throws -> DatabasePool {
        DatabaseManager.shared.close()
        return try await Task.detached { try DatabaseManager.shared.openIfNeeded(for: uid) }.value
    }

    private static func barrier(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    private static func readThrows(_ pool: DatabasePool) async -> Bool {
        do {
            _ = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT 1") }
            return false
        } catch {
            return true
        }
    }

    @Test("a pool still retained by a caller is closed once retired pools are drained")
    func closeActuallyClosesRetainedPool() async throws {
        let uid = Self.makeUID()
        defer { await TestPartitionCleanup.remove(uid) }
        let pool = try await Self.openPool(uid)
        #expect(await !Self.readThrows(pool), "the freshly opened pool must be readable")

        DatabaseManager.shared.close()
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)

        #expect(DatabaseManager.shared.openedPool(for: uid) == nil)
        #expect(await Self.readThrows(pool), "reading a closed pool must throw instead of silently using a live connection")
    }

    @Test("writes already queued on the serial queue succeed before the pool is closed")
    func queuedWritesLandBeforeClose() async throws {
        let uid = Self.makeUID()
        defer { await TestPartitionCleanup.remove(uid) }
        let pool = try await Self.openPool(uid)
        let queue = DispatchQueue(label: "test.database-close-order")
        let gate = DispatchSemaphore(value: 0)
        var released = false
        defer { if !released { gate.signal() } }
        queue.async { gate.wait() }
        let writeResult = Box<Result<Void, any Error>?>(nil)
        queue.async {
            writeResult.value = Result {
                try pool.write { db in
                    try db.execute(sql: "CREATE TABLE close_order_probe (x INTEGER)")
                    try db.execute(sql: "INSERT INTO close_order_probe (x) VALUES (1)")
                }
            }
        }

        DatabaseManager.shared.close(after: queue)
        gate.signal()
        released = true
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)
        await Self.barrier(queue)

        let result = try #require(writeResult.value, "the queued write must have run")
        #expect(throws: Never.self) { try result.get() }
        #expect(await Self.readThrows(pool), "the pool must be closed after the queued write")
        let reopened = try DatabaseQueue(path: AppSessionStore.databasePath(for: uid).path)
        let count = try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM close_order_probe") }
        #expect(count == 1)
        try reopened.close()
    }

    @Test("hasOpenConnections stays true until the real close finished")
    func hasOpenConnectionsTracksPendingClose() async throws {
        let uid = Self.makeUID()
        defer { await TestPartitionCleanup.remove(uid) }
        _ = try await Self.openPool(uid)
        #expect(DatabaseManager.shared.hasOpenConnections(uid: uid))

        let queue = DispatchQueue(label: "test.database-close-pending")
        let gate = DispatchSemaphore(value: 0)
        var released = false
        defer { if !released { gate.signal() } }
        queue.async { gate.wait() }

        DatabaseManager.shared.close(after: queue)
        #expect(DatabaseManager.shared.openedPool(for: uid) == nil, "references are dropped synchronously")
        #expect(DatabaseManager.shared.hasOpenConnections(uid: uid), "the connection is still open while the close is queued")

        gate.signal()
        released = true
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)
        #expect(!DatabaseManager.shared.hasOpenConnections(uid: uid))
    }

    @Test("closeLocalOnlyPool really closes the continuation sidecar")
    func closeLocalOnlyPoolClosesSidecar() async throws {
        let uid = Self.makeUID()
        defer { await TestPartitionCleanup.remove(uid) }
        RecipeContinuationStore.closeLocalOnlyPool()
        let sidecar = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        #expect(await !Self.readThrows(sidecar))

        RecipeContinuationStore.closeLocalOnlyPool()
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)

        #expect(await Self.readThrows(sidecar), "the sidecar pool must be closed, not just dropped")
        #expect(!DatabaseManager.shared.hasOpenConnections(uid: uid))
        let reopened = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        #expect(reopened !== sidecar)
        RecipeContinuationStore.closeLocalOnlyPool()
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)
    }

    @Test("removing a partition while its uid still has an open connection records a diagnostic once per uid")
    func partitionRemovalWithOpenConnectionIsReported() async throws {
        let uid = Self.makeUID()
        let otherUID = Self.makeUID()
        let sink = RecordingObservabilitySink()
        PartitionRemovalDiagnostics.sink = sink
        defer {
            PartitionRemovalDiagnostics.sink = Observability.sink
            await TestPartitionCleanup.remove(uid, otherUID)
        }
        let issueName = DiagnosticIssue.databasePartitionRemovedWhileOpen.rawValue
        let pool = try await Self.openPool(uid)
        #expect(DatabaseManager.shared.hasOpenConnections(uid: uid))

        #expect(AppSessionStore.reportIfConnectionsStillOpen(uid: uid))
        #expect(AppSessionStore.reportIfConnectionsStillOpen(uid: uid), "the connection is still open on the second removal")
        #expect(sink.issues.filter { $0.name == issueName }.count == 1, "deduplicated per uid")
        #expect(sink.issues.first { $0.name == issueName }?.fingerprint == [issueName, "account"])
        #expect(PartitionRemovalDiagnostics.hasReportedForTesting(uid: uid))
        #expect(await !Self.readThrows(pool), "the diagnostic must not touch the open connection")

        _ = try await Self.openPool(otherUID)
        #expect(AppSessionStore.reportIfConnectionsStillOpen(uid: otherUID))
        #expect(sink.issues.filter { $0.name == issueName }.count == 2, "another uid is reported again, not once per process")
    }

    @Test("closing and awaiting the real close before removing a partition records no diagnostic")
    func partitionRemovalAfterCloseIsNotReported() async throws {
        let uid = Self.makeUID()
        let sink = RecordingObservabilitySink()
        PartitionRemovalDiagnostics.sink = sink
        defer {
            PartitionRemovalDiagnostics.sink = Observability.sink
            await TestPartitionCleanup.remove(uid)
        }
        _ = try await Self.openPool(uid)
        DatabaseManager.shared.close()
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)

        #expect(!AppSessionStore.reportIfConnectionsStillOpen(uid: uid))
        await TestPartitionCleanup.clear(uid)

        #expect(!PartitionRemovalDiagnostics.hasReportedForTesting(uid: uid))
        #expect(!sink.issues.contains { $0.name == DiagnosticIssue.databasePartitionRemovedWhileOpen.rawValue })
        #expect(FileManager.default.fileExists(atPath: AppSessionStore.userDir(for: uid).path), "clearPartition recreates the empty partition")
    }

    @Test("a non-pinned lookup of a retiring uid reuses the retiring pool without re-slotting it, and it closes with the retirement")
    func nonPinnedLookupReusesRetiringPool() async throws {
        let uid = Self.makeUID()
        defer { await TestPartitionCleanup.remove(uid) }
        let pool = try await Self.openPool(uid)
        let queue = DispatchQueue(label: "test.database-close-reuse")
        let gate = DispatchSemaphore(value: 0)
        var released = false
        defer { if !released { gate.signal() } }
        queue.async { gate.wait() }

        DatabaseManager.shared.close(after: queue)
        let reused = try await Task.detached { try DatabaseManager.shared.openIfNeeded(for: uid) }.value
        let reslotted = DatabaseManager.shared.openedPool(for: uid)
        gate.signal()
        released = true
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)

        #expect(reused === pool, "a retiring pool that has not closed yet is handed out instead of opening another connection")
        #expect(reslotted == nil, "the reused pool is not put back into a slot")
        #expect(await Self.readThrows(reused), "the reused pool closes with its retirement")
        #expect(!DatabaseManager.shared.hasOpenConnections(uid: uid))
        if reused !== pool {
            DatabaseManager.shared.close()
            await DatabaseManager.shared.waitForRetiredPools(uid: uid)
        }
    }

    @Test("a pinned prepare of a retiring uid opens a fresh pool")
    func pinnedPrepareOpensFreshPoolForRetiringUID() async throws {
        let uid = Self.makeUID()
        defer { await TestPartitionCleanup.remove(uid) }
        let pool = try await Self.openPool(uid)
        let queue = DispatchQueue(label: "test.database-close-pinned")
        let gate = DispatchSemaphore(value: 0)
        var released = false
        defer { if !released { gate.signal() } }
        queue.async { gate.wait() }

        DatabaseManager.shared.close(after: queue)
        let pinned = try await DatabaseManager.shared.prepare(for: uid)
        #expect(pinned !== pool, "a pinned prepare never reuses a retiring pool")
        #expect(DatabaseManager.shared.openedPool(for: uid) === pinned)

        gate.signal()
        released = true
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)
        #expect(await Self.readThrows(pool))
        #expect(await !Self.readThrows(pinned))

        DatabaseManager.shared.close()
        RecipeContinuationStore.closeLocalOnlyPool()
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)
    }

    @Test("a close failing with BUSY is retried once, then reported and released while the uid still reports open connections")
    @MainActor
    func failedCloseIsRetriedReportedAndReleased() async throws {
        let uid = Self.makeUID()
        let sink = RecordingObservabilitySink()
        let previousSink = DatabaseManager.closeDiagnosticsSink
        DatabaseManager.closeDiagnosticsSink = sink
        let held = Box<Statement?>(nil)
        defer {
            DatabaseManager.closeDiagnosticsSink = previousSink
            held.value = nil
        }
        let weakPool = Box<WeakPool>(WeakPool())
        try await Self.openPoolHoldingStatement(uid, statement: held, weakPool: weakPool)
        #expect(weakPool.value.pool != nil)

        DatabaseManager.shared.close()
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)

        let issueName = DiagnosticIssue.databaseCloseFailed.rawValue
        #expect(sink.issues.filter { $0.name == issueName }.count == 1, "one diagnostic after the retry failed too")
        #expect(weakPool.value.pool == nil, "the manager drops its strong reference after the retry failed")
        #expect(DatabaseManager.shared.hasOpenConnections(uid: uid), "the connection whose close failed still counts as open")
        held.value = nil
        // Finalizing the statement let the dropped connection close; clear its bookkeeping before removing the partition.
        DatabaseManager.shared.forgetFailedClosesForTesting(uid: uid)
        await TestPartitionCleanup.remove(uid)
    }

    private struct WeakPool {
        weak var pool: DatabasePool?
    }

    /// Opens the partition and keeps a live statement on its writer, so `sqlite3_close` fails with BUSY.
    /// Only weak references to the pool survive this call.
    private static func openPoolHoldingStatement(_ uid: String, statement: Box<Statement?>, weakPool: Box<WeakPool>) async throws {
        let pool = try await openPool(uid)
        try await pool.writeWithoutTransaction { db in
            statement.value = try db.makeStatement(sql: "SELECT 1")
        }
        weakPool.value = WeakPool(pool: pool)
    }
}
