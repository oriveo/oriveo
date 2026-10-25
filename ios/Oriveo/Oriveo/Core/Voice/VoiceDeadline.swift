import Foundation

/// System speech calls made before recording starts (resource queries, reservations) may never return.
/// This races the call against a timer: whichever finishes first wins and the other is cancelled.
/// It does not use a task group: a group would wait for a system call that ignores cancellation; here the hanging call is simply abandoned and its late result dropped.
/// When the outer task is cancelled it returns immediately (value yields nil, run throws CancellationError) and cancels both inner tasks.
nonisolated enum VoiceDeadline {

    /// Default limit for system speech queries before recording starts.
    static let systemQuery: Duration = .seconds(2)

    struct TimedOut: Error, Sendable, Hashable {}

    /// The operation's result; nil if it did not return within `limit`.
    static func value<T: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        switch await race(within: limit, operation) {
        case .success(let value)?: return value
        case .failure, nil: return nil
        }
    }

    /// The operation's result; an error it throws is rethrown as is, `TimedOut` is thrown if it did not return within `limit`, and `CancellationError` if the outer task is cancelled.
    static func run<T: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        switch await race(within: limit, operation) {
        case .success(let value)?: return value
        case .failure(let error)?: throw error
        case nil:
            if Task.isCancelled { throw CancellationError() }
            throw TimedOut()
        }
    }

    private static func race<T: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error>? {
        let gate = RaceGate<Result<T, Error>?>()
        // If cancellation arrives before start, RaceGate stashes nil; start then resumes immediately and cancels both tasks.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.start(
                    continuation,
                    work: Task {
                        let result: Result<T, Error>
                        do { result = .success(try await operation()) } catch { result = .failure(error) }
                        gate.finish(result)
                    },
                    timer: Task {
                        try? await Task.sleep(for: limit)
                        gate.finish(nil)
                    }
                )
            }
        } onCancel: {
            gate.finish(nil)
        }
    }
}

/// The continuation resumes only once; the losing task is cancelled and any later finish from it is ignored.
private nonisolated final class RaceGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var tasks: [Task<Void, Never>] = []
    /// Holds the winning value when a task completes before start() registers the continuation.
    private var early: [Value] = []
    private var finished = false

    func start(_ continuation: CheckedContinuation<Value, Never>, work: Task<Void, Never>, timer: Task<Void, Never>) {
        // An array rather than Value?: when Value is itself optional, a single optional would be conflated with "not finished yet".
        let winners: [Value] = lock.withLock {
            guard finished else {
                self.continuation = continuation
                tasks = [work, timer]
                return []
            }
            return early
        }
        if winners.isEmpty { return }
        work.cancel()
        timer.cancel()
        continuation.resume(returning: winners[0])
    }

    func finish(_ value: Value) {
        let (resume, losers): (CheckedContinuation<Value, Never>?, [Task<Void, Never>]) = lock.withLock {
            guard !finished else { return (nil, []) }
            finished = true
            guard let resume = continuation else {
                early = [value]
                return (nil, [])
            }
            continuation = nil
            let losers = tasks
            tasks = []
            return (resume, losers)
        }
        losers.forEach { $0.cancel() }
        resume?.resume(returning: value)
    }
}
