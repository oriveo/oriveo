import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Connection lifetime and busy configuration for the continuation sidecar.
///
/// `purgeOrphans` runs after **every** conversation write. Opening a fresh `DatabasePool` per
/// call meant a new SQLite connection per write, on a pool that used GRDB's default
/// `Configuration()` — `busyMode == .immediate`, so it never waited for the lock, and the primary
/// database's busy timeout did not apply. Repeatedly reopening the same WAL file that way runs
/// into `SQLITE_BUSY_RECOVERY` (extended code 261) from GRDB's connection-time
/// `SELECT * FROM sqlite_master LIMIT 1`.
@Suite("Continuation sidecar pool reuse and busy configuration", .serialized)
struct RecipeContinuationSidecarPoolTests {

    /// A parent database holding only the `message` table, which
    /// `purgeMissingParentMessages` reads.
    private func makeParentPool(in directory: URL) throws -> DatabasePool {
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("parent.sqlite").path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS message(id TEXT PRIMARY KEY NOT NULL)")
        }
        return pool
    }

    private func withTemporaryUID<T>(_ body: (String, URL) throws -> T) rethrows -> T {
        let previousUID = AppSessionStore.activeUID
        let uid = "sidecar-pool-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-sidecar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        RecipeContinuationStore.resetLocalOnlyPoolForTesting()
        defer {
            RecipeContinuationStore.resetLocalOnlyPoolForTesting()
            AppSessionStore.activeUID = previousUID
            try? FileManager.default.removeItem(at: directory)
        }
        AppSessionStore.activeUID = uid
        return try body(uid, directory)
    }

    @Test("Repeated purgeOrphans calls open a single sidecar connection")
    func sidecarPoolIsReusedAcrossPurges() throws {
        try withTemporaryUID { uid, directory in
            let parentPool = try makeParentPool(in: directory)
            defer { try? parentPool.close() }

            for _ in 0..<25 {
                try RecipeContinuationStore.purgeOrphans(for: uid, parentPool: parentPool)
            }

            #expect(
                RecipeContinuationStore.localOnlyPoolOpenCountForTesting == 1,
                "The sidecar connection must be reused; opening one per conversation write is what invites SQLITE_BUSY_RECOVERY"
            )
        }
    }

    @Test("Reopening the sidecar with the same uid after the partition is deleted does not reuse a connection to the deleted file, and purgeOrphans reports no disk I/O")
    @MainActor
    func partitionCleanupDropsCachedSidecarPool() async throws {
        let uid = "sidecar-wipe-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        RecipeContinuationStore.resetLocalOnlyPoolForTesting()
        defer {
            RecipeContinuationStore.resetLocalOnlyPoolForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let parentPool = try makeParentPool(in: directory)
        defer { try? parentPool.close() }

        try RecipeContinuationStore.purgeOrphans(for: uid, parentPool: parentPool)
        #expect(RecipeContinuationStore.localOnlyPoolOpenCountForTesting == 1)

        // Same uid runs one pipeline, the partition is deleted, then the next pipeline starts.
        await TestPartitionCleanup.remove(uid)
        try RecipeContinuationStore.purgeOrphans(for: uid, parentPool: parentPool)

        #expect(
            RecipeContinuationStore.localOnlyPoolOpenCountForTesting == 2,
            "Deleting the partition must drop the cached sidecar connection; reusing it would write to the deleted file (6922 vnode unlinked)"
        )
        await TestPartitionCleanup.remove(uid)
    }

    @Test("Opening the sidecar and an empty purge do not write: the first write creates the table (opens often run on the main-thread send path)")
    func sidecarOpenAndEmptyPurgeDoNotWrite() async throws {
        let uid = "sidecar-lazy-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        RecipeContinuationStore.resetLocalOnlyPoolForTesting()
        defer {
            RecipeContinuationStore.resetLocalOnlyPoolForTesting()
            try? FileManager.default.removeItem(at: directory)
            await TestPartitionCleanup.remove(uid)
        }
        let parentPool = try makeParentPool(in: directory)
        defer { try? parentPool.close() }
        let pool = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        #expect(try await pool.read { try $0.tableExists("message_recipe_continuation") } == false, "Opening must not create the table")

        try RecipeContinuationStore.purgeOrphans(for: uid, parentPool: parentPool)
        #expect(try await pool.read { try $0.tableExists("message_recipe_continuation") } == false, "Nothing to delete means no write")
    }

    @Test("closeLocalOnlyPool: a departing uid reuses the retiring sidecar, an active partition and a finished close reopen")
    func sidecarPoolRebindsOnCloseAndUIDSwitch() async throws {
        let previousUID = AppSessionStore.activeUID
        let uid = "sidecar-pool-\(UUID().uuidString)"
        let otherUID = "\(uid)-other"
        RecipeContinuationStore.resetLocalOnlyPoolForTesting()
        AppSessionStore.activeUID = uid
        let gate = DispatchSemaphore(value: 0)
        let closeQueue = DispatchQueue(label: "sidecar-pool-test.close")
        closeQueue.async { gate.wait() }
        var gateOpen = false
        defer { if !gateOpen { gate.signal() } }

        // Identity, not the open count: without a cache the count would also grow by one per call.
        let first = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        let sameSession = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        #expect(first === sameSession, "the same uid must reuse one sidecar connection")

        // Close held behind a blocked serial queue: the retiring sidecar has not closed yet.
        RecipeContinuationStore.closeLocalOnlyPool(after: closeQueue)
        let departing = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        #expect(departing === first, "a departing uid reuses its retiring sidecar instead of opening another connection")

        // The uid becomes the manager's active partition again: no reuse of the retiring sidecar.
        _ = try DatabaseManager.shared.openIfNeeded(for: uid)
        let active = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        #expect(active !== first, "an active partition never reuses a retiring sidecar")

        gate.signal()
        gateOpen = true
        RecipeContinuationStore.closeLocalOnlyPool()
        DatabaseManager.shared.close()
        await DatabaseManager.shared.waitForRetiredPools(uid: uid)
        let afterClose = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        #expect(afterClose !== first && afterClose !== active, "once the retired close finished, reopening opens a fresh pool")

        let otherPool = try RecipeContinuationStore.localOnlyPoolForTesting(for: otherUID)
        #expect(afterClose !== otherPool, "different uids must not share a sidecar connection")
        let backToOriginal = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
        #expect(backToOriginal !== otherPool, "switching back must not get the other partition's connection")

        RecipeContinuationStore.closeLocalOnlyPool()
        await DatabaseManager.shared.waitForRetiredPools(uid: otherUID)
        RecipeContinuationStore.resetLocalOnlyPoolForTesting()
        AppSessionStore.activeUID = previousUID
        await TestPartitionCleanup.remove(uid, otherUID)
    }

    @Test("The sidecar pool carries the shared busy timeout")
    func sidecarPoolUsesSharedConfiguration() throws {
        try withTemporaryUID { uid, _ in
            let pool = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
            guard case .timeout(let seconds) = pool.configuration.busyMode else {
                Issue.record("expected busyMode.timeout, got \(String(describing: pool.configuration.busyMode))")
                return
            }
            #expect(seconds == 5, "The sidecar must share the busy timeout from DatabaseSchema.makeConfiguration()")
        }
    }

    @Test("A contended sidecar write waits for the lock instead of failing with SQLITE_BUSY")
    func sidecarWriteWaitsForContendedLock() throws {
        try withTemporaryUID { uid, directory in
            let parentPool = try makeParentPool(in: directory)
            defer { try? parentPool.close() }

            // Create the sidecar file first, then hold its write lock from a second connection.
            let sidecar = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
            let contender = try DatabasePool(
                path: sidecar.path,
                configuration: DatabaseSchema.makeConfiguration()
            )
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let holderFinished = DispatchSemaphore(value: 0)
            defer {
                release.signal()
                _ = holderFinished.wait(timeout: .now() + 2)
                try? contender.close()
            }

            DispatchQueue.global(qos: .userInitiated).async {
                defer { holderFinished.signal() }
                do {
                    try contender.write { db in
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO message_recipe_continuation(messageID, kind, stateJSON, interrupted, launchToken, updatedAt) VALUES ('contended', 'k', '{}', 0, 'other-launch', 1)"
                        )
                        started.signal()
                        release.wait()
                    }
                } catch {
                    started.signal()
                }
            }
            #expect(started.wait(timeout: .now() + 2) == .success)

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                release.signal()
            }

            // purgeOrphans writes internally (clearing rows from other launches). With the default
            // .immediate busy mode this threw right away.
            #expect(throws: Never.self) {
                try RecipeContinuationStore.purgeOrphans(for: uid, parentPool: parentPool)
            }
        }
    }
}
