import Foundation
import Testing
@testable import Oriveo

/// BYOK round queue: 4 rounds per device, FIFO, and cancellation / late responses
/// follow `StudioByokTasks.QueueState.reduce`.
@MainActor
@Suite("StudioByokQueueTests")
struct StudioByokQueueTests {
    /// Fake run that suspends each round until the test releases it; no timers.
    private final class FakeRunner {
        private var values: [String: String] = [:]
        private var waiters: [String: CheckedContinuation<String, Never>] = [:]
        private(set) var calls: [String] = []
        private(set) var cancelledRuns: Set<String> = []

        func run(_ id: String) async -> String {
            calls.append(id)
            let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                if let value = values.removeValue(forKey: id) {
                    continuation.resume(returning: value)
                } else {
                    waiters[id] = continuation
                }
            }
            if Task.isCancelled { cancelledRuns.insert(id) }
            return value
        }

        /// Resumes the round's run now, or as soon as it starts.
        func release(_ id: String, with value: String) {
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume(returning: value)
            } else {
                values[id] = value
            }
        }
    }

    private struct Entry: Equatable {
        var id: String
        var event: StudioByokQueue<String>.Event
    }

    private final class Recorder {
        var entries: [Entry] = []
    }

    private func makeQueue() -> (StudioByokQueue<String>, FakeRunner, Recorder) {
        let runner = FakeRunner()
        let recorder = Recorder()
        let queue = StudioByokQueue<String>(
            run: { id in await runner.run(id) },
            onUpdate: { id, event in recorder.entries.append(Entry(id: id, event: event)) }
        )
        return (queue, runner, recorder)
    }

    private let ids = ["r1", "r2", "r3", "r4", "r5"]

    @Test func fifthRoundQueues() async {
        let (queue, runner, recorder) = makeQueue()
        for id in ids { queue.submit(id) }

        #expect(recorder.entries == [
            Entry(id: "r1", event: .started),
            Entry(id: "r2", event: .started),
            Entry(id: "r3", event: .started),
            Entry(id: "r4", event: .started),
            Entry(id: "r5", event: .queued),
        ])
        var snapshot = queue.snapshot()
        #expect(snapshot.running == ["r1", "r2", "r3", "r4"])
        #expect(snapshot.queued == ["r5"])

        runner.release("r1", with: "img-1")
        await queue.waitForRuns(of: "r1")

        #expect(Array(recorder.entries.suffix(2)) == [
            Entry(id: "r1", event: .result("img-1")),
            Entry(id: "r5", event: .started),
        ])
        snapshot = queue.snapshot()
        #expect(snapshot.running == ["r2", "r3", "r4", "r5"])
        #expect(snapshot.queued.isEmpty)
    }

    @Test func cancelQueuedNotBilled() async {
        let (queue, runner, recorder) = makeQueue()
        for id in ids { queue.submit(id) }

        queue.cancel("r5")

        #expect(recorder.entries.last == Entry(id: "r5", event: .cancelled(mayBeBilled: false)))
        let snapshot = queue.snapshot()
        #expect(snapshot.running == ["r1", "r2", "r3", "r4"])
        #expect(snapshot.queued.isEmpty)

        for id in ids.prefix(4) {
            runner.release(id, with: "img-\(id)")
            await queue.waitForRuns(of: id)
        }
        #expect(runner.calls.sorted() == ["r1", "r2", "r3", "r4"])
        #expect(!recorder.entries.contains(Entry(id: "r5", event: .started)))
        #expect(queue.snapshot().running.isEmpty)
    }

    @Test func cancelRunningBilledAndFreesSlot() async {
        let (queue, runner, recorder) = makeQueue()
        for id in ids { queue.submit(id) }

        queue.cancel("r2")

        #expect(Array(recorder.entries.suffix(2)) == [
            Entry(id: "r2", event: .cancelled(mayBeBilled: true)),
            Entry(id: "r5", event: .started),
        ])
        let snapshot = queue.snapshot()
        #expect(snapshot.running == ["r1", "r3", "r4", "r5"])
        #expect(snapshot.queued.isEmpty)

        runner.release("r2", with: "late")
        await queue.waitForRuns(of: "r2")
        #expect(runner.cancelledRuns.contains("r2"))
        #expect(!recorder.entries.contains(Entry(id: "r2", event: .result("late"))))
    }

    @Test func lateResultDropped() async {
        let (queue, runner, recorder) = makeQueue()
        queue.submit("r1")
        queue.cancel("r1")

        runner.release("r1", with: "late")
        await queue.waitForRuns(of: "r1")

        #expect(runner.calls == ["r1"])
        #expect(recorder.entries == [
            Entry(id: "r1", event: .started),
            Entry(id: "r1", event: .cancelled(mayBeBilled: true)),
        ])
        let snapshot = queue.snapshot()
        #expect(snapshot.running.isEmpty)
        #expect(snapshot.queued.isEmpty)
    }
}
