import Foundation
import Testing
@testable import Oriveo

/// Drain steps of `TestPartitionCleanup` are time-limited and name the stuck step; live AppStates carry the creating test's label.
@MainActor
@Suite("TestPartitionCleanup drain: per-step time limit and creation labels")
struct TestPartitionCleanupDrainTests {
    /// Holds the continuation of a step that never resumes on its own, so it can be released after the assertion.
    private final class PendingStep: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        func park(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func release() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    @Test("A step that never resumes returns after the time limit and records an Issue naming the step")
    func neverResumingStepTimesOutWithNamedIssue() async {
        let pending = PendingStep()
        defer { pending.release() }
        var finished: Bool?
        await withKnownIssue("injected step never resumes") {
            finished = await TestPartitionCleanup.runStep(
                "injectedNeverResumingStep",
                owner: "uid=drain-timeout-probe",
                timeout: .milliseconds(200)
            ) {
                await withCheckedContinuation { continuation in
                    pending.park(continuation)
                }
            }
        } matching: { issue in
            let text = issue.comments.map(\.rawValue).joined(separator: " ")
            return text.hasPrefix("TestPartitionCleanup drain timeout")
                && text.contains("injectedNeverResumingStep")
                && text.contains("uid=drain-timeout-probe")
        }
        #expect(finished == false)
    }

    @Test("AppState registry carries the label of the creating test")
    func liveInstanceCarriesCreatingTestLabel() async throws {
        TestPartitionCleanup.installCreationLabelProviderIfNeeded()
        let uid = "drain-label-\(UUID().uuidString)"
        DatabaseManager.shared.close()
        let state = AppState(sessionUID: uid)
        defer {
            await TestPartitionCleanup.remove(uid)
        }
        let expected = try #require(Test.current.map { String(describing: $0.id) })
        let entries = AppState.liveInstancesForTesting(boundTo: [uid])
        let entry = try #require(entries.first { $0.state === state })
        #expect(entry.creationLabel == expected)
        #expect(entry.uid == uid)
    }
}
