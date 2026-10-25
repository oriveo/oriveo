import os
import Testing
@testable import Oriveo

/// Process-wide shared state mutex trait. Tests that touch the `MetadataClient` shared
/// snapshot, view evaluation counters (`bodyEvaluationCount` / `contentChangeCount`), or
/// in-process singletons such as `ChatView` / `ChatMessageList` mark themselves with
/// `.sharedProcessState` and then run mutually exclusively across suites.
///
/// ## Why it exists
///
/// Swift Testing runs different suites in parallel within one process; `.serialized` only
/// orders cases inside a suite. The state above is a `static` snapshot or a global counter:
/// suite A has just called `loadForTesting(...)` to install a fixture when suite B's
/// `resetForTesting()` at entry wipes it, and counter assertions end up counting
/// evaluations from other suites. The symptom is "green alone, randomly red in a full run".
///
/// ## Semantics
///
/// - Applied as a suite trait and recursively delivered to every test case. The lock is held
///   per test case (each argument set of a parameterized test takes it once), not for the
///   whole suite, so one slow suite cannot starve the others.
/// - If the lock is already held (trait on both the suite and a `@Test`), the body runs
///   directly without re-acquiring, so it never deadlocks on itself.
/// - The lock is released when a case throws.
/// - XCTestCase does not honor traits: in `setUp()` call
///   `await SharedProcessStateLock.shared.acquire(holder: "xctest:\(name)")` and in
///   `tearDown()` call `release()`.
/// - Exit reset: `MetadataClient.shared.resetForTesting()` runs before the lock is released;
///   the convention of resetting on entry is unchanged.
/// - Write gate: the first acquire installs `writeDecision` on
///   `MetadataClient.debugSharedWriteGate`. While another case holds the lock, writes to the
///   shared snapshot from tasks detached from the original case scope are dropped; a case
///   without the trait that writes is reported as a failure.
///
/// The guard lives in `TestIsolationGuardTests`: a test file that touches the symbols above
/// without the trait fails.
nonisolated struct SharedProcessStateTrait: TestTrait, SuiteTrait, TestScoping {
    /// Whether the current task chain already holds the lock. Nested scopes inherit this
    /// value so a single case never acquires the lock twice and deadlocks.
    @TaskLocal static var isHeld = false

    var isRecursive: Bool { true }

    func scopeProvider(for test: Testing.Test, testCase: Testing.Test.Case?) -> SharedProcessStateTrait? {
        // The suite level takes no lock; only concrete cases do
        testCase == nil ? nil : self
    }

    // The project enables Approachable Concurrency (nonisolated(nonsending) by default), while
    // the Testing protocol requires a concurrently executing async function, so @concurrent
    // is needed to match the signature
    @concurrent
    func provideScope(
        for test: Testing.Test,
        testCase: Testing.Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        if Self.isHeld {
            try await function()
            return
        }
        await SharedProcessStateLock.shared.acquire(holder: String(describing: test.id))
        do {
            try await Self.$isHeld.withValue(true) {
                try await function()
            }
        } catch {
            // release() drains the MetadataClient background bootstrap before unlocking
            await SharedProcessStateLock.shared.release()
            throw error
        }
        await SharedProcessStateLock.shared.release()
    }

    /// Drains the background `MetadataClient.initialize()` bootstrap triggered by the case
    /// before the lock is released; returns false on timeout (the caller still releases the
    /// lock rather than hanging). The release path passes `recordsIssue: false`: an in-flight
    /// bootstrap that times out was not necessarily started by the current lock holder, so
    /// recording an Issue would blame an innocent case; its later writes are still dropped by
    /// the write gate.
    @concurrent
    static func drainMetadataBackgroundWork(
        timeout: Duration = .seconds(10),
        recordsIssue: Bool = true
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
                await MetadataClient.shared.drainBackgroundWorkForTesting()
                timer.cancel()
                finish(true)
            }
        }
        if !finished {
            if recordsIssue {
                Issue.record("Draining the MetadataClient background bootstrap before unlock exceeded \(timeout); releasing the lock anyway")
            } else {
                print("[MC-DRAIN-TIMEOUT] drain before unlock exceeded \(timeout); releasing the lock anyway; later writes are decided by the write gate")
            }
        }
        return finished
    }
}

nonisolated extension Trait where Self == SharedProcessStateTrait {
    /// This case reads or writes process-wide shared state and runs mutually exclusively across suites.
    static var sharedProcessState: Self { Self() }
}

/// The write gate's verdict on one write to shared state.
nonisolated enum SharedStateWriteDecision: Equatable {
    case allow
    /// The writing case lacks `.sharedProcessState`: record an Issue, then allow
    case allowRecordingMissingTrait
    /// The writer is not the current lock holder (a task detached from its scope): drop
    case drop
}

/// Mutex for process-wide shared state: first come, first served (FIFO continuation queue);
/// on release, ownership is handed straight to the head waiter. It also records the holder so
/// the `MetadataClient` write gate can tell whether a writer is the current lock-holding case.
actor SharedProcessStateLock {
    static let shared = SharedProcessStateLock()

    /// Current holder: the `Test.ID` description for a Swift Testing case, `"xctest:<name>"`
    /// for XCTest; nil when idle. The write gate reads it synchronously inside MetadataClient,
    /// so it lives in a lock outside the actor.
    nonisolated static let holderState = OSAllocatedUnfairLock<String?>(initialState: nil)
    nonisolated static var currentHolder: String? { holderState.withLock { $0 } }

    private var isLocked = false
    private var waiters: [(continuation: CheckedContinuation<Void, Never>, holder: String)] = []
    private var gateInstalled = false

    func acquire(holder: String) async {
        installWriteGateIfNeeded()
        if !isLocked {
            isLocked = true
            Self.holderState.withLock { $0 = holder }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((continuation, holder))
        }
    }

    /// Release: first drain the MetadataClient background bootstrap triggered by the holder,
    /// then reset the metadata singleton, and finally unlock (shared by Swift Testing and XCTest).
    ///
    /// Exit reset: cases that write `MetadataClient.shared` need not each clean up on exit, and
    /// read-only cases (such as `RelayRuntimeRoutingTests` reading `syncRelayRuntimeConfig`)
    /// never see leftovers from the previous case. The reset happens before unlocking, still as
    /// the holder (`isHeld = true`), so the write gate treats it as the case's own write.
    func release() async {
        _ = await SharedProcessStateTrait.drainMetadataBackgroundWork(recordsIssue: false)
        await SharedProcessStateTrait.$isHeld.withValue(true) {
            await MetadataClient.shared.resetForTesting()
        }
        if waiters.isEmpty {
            isLocked = false
            Self.holderState.withLock { $0 = nil }
        } else {
            // Keep isLocked set: ownership passes unchanged to the head waiter
            let next = waiters.removeFirst()
            Self.holderState.withLock { $0 = next.holder }
            next.continuation.resume()
        }
    }

    /// Pure decision: origin is the writing case (nil = not inside a Swift Testing case, e.g.
    /// XCTest / detached), holder is the current lock holder, isHeld says whether the writer's
    /// task chain carries the trait.
    nonisolated static func writeDecision(origin: String?, holder: String?, isHeld: Bool) -> SharedStateWriteDecision {
        guard let origin else { return .allow }
        guard isHeld else { return .allowRecordingMissingTrait }
        return origin == holder ? .allow : .drop
    }

    private func installWriteGateIfNeeded() {
        guard !gateInstalled else { return }
        gateInstalled = true
        MetadataClient.debugSharedWriteGate = { entry in
            let origin = Test.current.map { String(describing: $0.id) }
            let holder = SharedProcessStateLock.currentHolder
            switch SharedProcessStateLock.writeDecision(
                origin: origin, holder: holder, isHeld: SharedProcessStateTrait.isHeld
            ) {
            case .allow:
                return true
            case .allowRecordingMissingTrait:
                Issue.record("A case that writes process-wide shared state must carry .sharedProcessState (entry \(entry))")
                return true
            case .drop:
                print("[MC-FENCE] dropped \(entry) from \(origin ?? "nil") while held by \(holder ?? "nil")")
                return false
            }
        }
    }
}
