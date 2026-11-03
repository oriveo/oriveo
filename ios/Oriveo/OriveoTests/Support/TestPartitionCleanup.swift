import Foundation
import os
import Testing
@testable import Oriveo

/// The single entry point for tests that delete a partition: wait for the AppStates bound to those partitions to drain
/// their in-flight reads and writes first, then close the database and remove the directory.
///
/// Calling `removeItem(userDir)` directly lets background reads and writes still in flight (send-task teardown, trailing
/// writes, the write queue, memory backflow and delete-ledger cleanup) hit the just-deleted database file (SQLite disk
/// I/O error; the iOS verdict is zero tolerance, and `[DiskIO]` lines fail the run too). Writes that resolve the database
/// by uid would also recreate the partition. In a test case, write `defer { await TestPartitionCleanup.remove(uid) }`
/// (the case must be async). The source-scan gate is `TestPartitionCleanupGateTests`.
@MainActor
enum TestPartitionCleanup {
    static func remove(_ uids: String...) async {
        await remove(uids)
    }

    static func remove(_ uids: [String]) async {
        await drain(uids)
        for uid in uids {
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
    }

    /// Same as `remove`, but goes through production `AppSessionStore.clearPartition`: it also clears the partition's
    /// Keychain keys and MCP credentials, and rebuilds an empty partition directory (use it when a case needs a clean
    /// partition at the start, or asserts that the keys were cleared).
    static func clear(_ uids: String...) async {
        await drain(uids)
        for uid in uids {
            AppSessionStore.clearPartition(for: uid)
        }
    }

    /// Drains and closes the database without removing the directory. Use it before a case overwrites the database file
    /// in place (simulating corruption or swapping the database), so old instances' background reads do not hit the swapped file.
    static func drain(_ uids: String...) async {
        await drain(uids)
    }

    private static func drain(_ uids: [String]) async {
        installCreationLabelProviderIfNeeded()
        let targets = Set(uids)
        let currentLabel = currentTestLabel()
        for entry in AppState.liveInstancesForTesting(boundTo: targets) {
            let state = entry.state
            let owner = "state=\(ObjectIdentifier(state)) uid=\(entry.uid) label=\(entry.creationLabel)"
            if let currentLabel, entry.creationLabel != currentLabel {
                writeDiagnostic("[TestPartitionCleanup] foreign live AppState uid=\(entry.uid) label=\(entry.creationLabel)")
            }
            await runStep("chatManager.waitForSendTasksForTesting", owner: owner) {
                await state.chatManager.waitForSendTasksForTesting()
            }
            // If the cold-start background database pre-open has not finished installing the session, it will queue
            // memory backflow and note reloads once it does: wait for it first, then drain.
            await runStep("waitForSessionStore", owner: owner) {
                await state.waitForSessionStore()
            }
            await runStep("drainPendingWrites", owner: owner) {
                await state.drainPendingWrites()
            }
        }
        let partitions = "uids=\(targets.sorted())"
        // Local AppStates declared after the defer are released before the defer runs: wait for the in-flight reads
        // their deinit leaves behind.
        for drain in AppState.takeReleasedDrainsForTesting(boundTo: targets) {
            await runStep("releasedDrain.value", owner: partitions) {
                await drain.value
            }
        }
        // Note mirror reloads (including reloads after a write lands, whose owning AppState was already released)
        // also read the database in the background.
        await runStep("NoteManager.waitForReloadsForTesting", owner: partitions) {
            await NoteManager.waitForReloadsForTesting(boundTo: targets)
        }
        // The recovery snapshot queued at cold start reads its full text from the database, on the global serial queue.
        await runStep("ConversationRuntimeBridge.waitForRecoverySnapshotsForTesting", owner: partitions) {
            await ConversationRuntimeBridge.waitForRecoverySnapshotsForTesting()
        }
        DatabaseManager.shared.close()
        // The continuation sidecar caches connections by uid in a static pool, so closing only the main database is not
        // enough: after the directory is removed, the next AppState for the same uid would reuse a connection pointing at
        // the deleted file, and purgeOrphans after the session flush would report disk I/O error (6922, vnode unlinked while in use).
        RecipeContinuationStore.closeLocalOnlyPool()
        // close() only drops references; the real pool.close() runs later off the main thread. Wait for it, so the
        // directory is never removed under a live connection.
        for uid in targets.sorted() {
            await runStep("DatabaseManager.waitForRetiredPools", owner: "uid=\(uid)") {
                await DatabaseManager.shared.waitForRetiredPools(uid: uid)
            }
            if DatabaseManager.shared.hasOpenConnections(uid: uid) {
                Issue.record("TestPartitionCleanup: uid \(uid) still has an open database connection after close; removing its partition anyway")
            }
        }
    }

    /// Per-step time limit for draining; normal drains finish in milliseconds, the process watchdog fires at 900s.
    static let defaultStepTimeout: Duration = .seconds(30)

    /// Awaits one drain step for at most `timeout`. On timeout the awaited work is not cancelled: an Issue naming
    /// the step and its owner is recorded and the drain continues, so a stuck step fails by name instead of hanging the run.
    @discardableResult
    static func runStep(
        _ step: String,
        owner: String,
        timeout: Duration = defaultStepTimeout,
        _ work: @escaping @MainActor @Sendable () async -> Void
    ) async -> Bool {
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                finish(false)
            }
            Task {
                await work()
                timer.cancel()
                finish(true)
            }
        }
        if !finished {
            Issue.record("TestPartitionCleanup drain timeout: step \(step) did not finish within \(timeout) (\(owner)); continuing")
        }
        return finished
    }

    /// Idempotently installs the AppState creation label provider (current Swift Testing test id).
    nonisolated static func installCreationLabelProviderIfNeeded() {
        guard AppState.creationLabelProviderForTesting == nil else { return }
        AppState.creationLabelProviderForTesting = { currentTestLabel() }
    }

    /// Label of the running Swift Testing test case; nil outside Swift Testing (XCTest, detached work).
    nonisolated static func currentTestLabel() -> String? {
        Test.current.map { String(describing: $0.id) }
    }

    private static func writeDiagnostic(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
