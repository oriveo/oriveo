import Foundation

/// Dictation and voice conversation share one AVAudioSession: whoever claims last owns it, with a generation counter.
/// Only the current lease's release returns true, and the holder deactivates the session only then; releasing a stale lease
/// that was displaced by a later claim is a no-op, so a late dictation stop cannot cut the mic of a conversation that just started.
/// Dictation waits for the conversation lease to be released before starting capture, so the conversation's teardown deactivation cannot stop dictation.
nonisolated final class VoiceAudioSessionOwner: @unchecked Sendable {
    static let shared = VoiceAudioSessionOwner()

    enum Client: Sendable, Equatable {
        case dictation
        case conversation
    }

    struct Lease: Sendable, Equatable {
        let client: Client
        let generation: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var holder: Lease?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var onWaiterQueued: (@Sendable () -> Void)?

    /// onWaiterQueued: called when someone starts waiting for the conversation lease to be released (lets tests know the wait is suspended without sleeping).
    init(onWaiterQueued: (@Sendable () -> Void)? = nil) {
        self.onWaiterQueued = onWaiterQueued
    }

    /// The current lease; nil means nobody holds it.
    var current: Lease? { lock.withLock { holder } }

    /// Number of callers waiting for the conversation lease to be released.
    var waitingCount: Int { lock.withLock { waiters.count } }

    /// Claims a new lease (generation + 1), displacing the previous holder.
    func claim(_ client: Client) -> Lease {
        let (lease, woken) = lock.withLock { () -> (Lease, [CheckedContinuation<Void, Never>]) in
            generation += 1
            let lease = Lease(client: client, generation: generation)
            holder = lease
            return (lease, client == .conversation ? [] : takeWaiters())
        }
        for waiter in woken { waiter.resume() }
        return lease
    }

    /// Releases and returns true only if the lease is still current; a stale lease returns false and the caller must not deactivate the session.
    @discardableResult
    func release(_ lease: Lease) -> Bool {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>]? in
            guard holder == lease else { return nil }
            holder = nil
            return takeWaiters()
        }
        guard let woken else { return false }
        for waiter in woken { waiter.resume() }
        return true
    }

    /// Suspends while the current holder is a conversation, until its lease is released (or displaced by another client); returns immediately when the task is cancelled.
    func waitForConversationRelease() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let queued = lock.withLock { () -> (@Sendable () -> Void)?? in
                    guard holder?.client == .conversation, !Task.isCancelled else { return nil }
                    waiters[id] = continuation
                    return .some(onWaiterQueued)
                }
                guard let queued else {
                    continuation.resume()
                    return
                }
                queued?()
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    /// The caller must hold the lock.
    private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
        let taken = Array(waiters.values)
        waiters.removeAll()
        return taken
    }
}
