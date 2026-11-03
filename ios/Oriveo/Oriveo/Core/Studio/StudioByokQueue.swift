import Foundation

/// BYOK image round queue: at most `StudioByokTasks.maxConcurrentRounds` rounds run per
/// device, the rest wait FIFO. State changes only through `StudioByokTasks.QueueState.reduce`;
/// this class only turns its effects into run tasks and update events.
@MainActor
final class StudioByokQueue<R> {
    enum Event {
        case queued
        case started
        case result(R)
        case cancelled(mayBeBilled: Bool)
    }

    private struct InFlight {
        var id: String
        var task: Task<Void, Never>
    }

    private let run: (String) async -> R
    private let onUpdate: (String, Event) -> Void
    private var state = StudioByokTasks.QueueState()
    /// Every launched run that has not returned yet, cancelled ones included, by token.
    private var inFlight: [Int: InFlight] = [:]
    /// Token of the live (not cancelled) run of each running round.
    private var liveToken: [String: Int] = [:]
    private var nextToken = 0

    init(run: @escaping (String) async -> R, onUpdate: @escaping (String, Event) -> Void) {
        self.run = run
        self.onUpdate = onUpdate
    }

    /// Queues a round; starts it right away when a slot is free. Duplicate ids are ignored.
    func submit(_ id: String) {
        let known = state.running.contains(id) || state.queued.contains(id)
        let effects = state.reduce(.submit(id))
        if !known, state.queued.contains(id) { onUpdate(id, .queued) }
        apply(effects)
    }

    /// Cancels a queued or running round; a running round frees its slot immediately.
    func cancel(_ id: String) {
        apply(state.reduce(.cancel(id)))
    }

    func snapshot() -> (running: [String], queued: [String]) {
        (state.running, state.queued)
    }

    /// Waits until every run launched for `id` has returned, cancelled ones included.
    /// Returns only once those runs return, so callers must let them finish.
    func waitForRuns(of id: String) async {
        while let entry = inFlight.values.first(where: { $0.id == id }) {
            await entry.task.value
        }
    }

    private func apply(_ effects: [StudioByokTasks.QueueEffect]) {
        for effect in effects {
            switch effect {
            case .start(let id):
                start(id)
            case .cancelled(let id, let mayBeBilled):
                if let token = liveToken.removeValue(forKey: id) {
                    inFlight[token]?.task.cancel()
                }
                onUpdate(id, .cancelled(mayBeBilled: mayBeBilled))
            case .accept, .drop:
                // Only produced by `.response`, handled in `receive`.
                break
            }
        }
    }

    private func start(_ id: String) {
        nextToken += 1
        let token = nextToken
        liveToken[id] = token
        onUpdate(id, .started)
        let run = self.run
        let task = Task { [weak self] in
            let value = await run(id)
            self?.receive(id, token: token, value: value)
        }
        inFlight[token] = InFlight(id: id, task: task)
    }

    private func receive(_ id: String, token: Int, value: R) {
        inFlight[token] = nil
        // A cancelled run of a round that was resubmitted and is running again must not
        // be taken for the new run's response.
        if liveToken[id] != token, state.running.contains(id) { return }
        for effect in state.reduce(.response(id)) {
            switch effect {
            case .accept(let id):
                liveToken[id] = nil
                onUpdate(id, .result(value))
                apply(state.reduce(.finish(id)))
            case .drop:
                break
            case .start, .cancelled:
                apply([effect])
            }
        }
    }
}

extension StudioByokQueue.Event: Equatable where R: Equatable {}
