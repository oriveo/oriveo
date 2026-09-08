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

    @Test("The pool reopens after close and rebinds on a uid switch")
    func sidecarPoolRebindsOnCloseAndUIDSwitch() throws {
        try withTemporaryUID { uid, _ in
            // Assert on pool identity rather than the open count: without caching the count also
            // happens to increment once per call, so a count-based check would pass either way.
            let first = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
            let sameSession = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
            #expect(first === sameSession, "The same uid must reuse one sidecar connection")

            // Logout / partition switch: the cache must drop, or the previous partition's
            // connection stays open.
            RecipeContinuationStore.closeLocalOnlyPool()
            let afterClose = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
            #expect(first !== afterClose, "closeLocalOnlyPool must force a reopen")

            let otherPool = try RecipeContinuationStore.localOnlyPoolForTesting(for: "\(uid)-other")
            #expect(afterClose !== otherPool, "A different uid must get its own sidecar")

            let backToOriginal = try RecipeContinuationStore.localOnlyPoolForTesting(for: uid)
            #expect(backToOriginal !== otherPool, "Switching back must not hand out the other partition's connection")
        }
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
