import Foundation

/// The "database opens, but writes fail" case.
///
/// ## Why it is not the blocking page
///
/// Failing to open is a hard stop: nothing done inside the app would mean anything. Failing to
/// write is softer: history is there, it still reads, messages still reach the model — only
/// **whatever is new may not be kept**. Blocking the whole app is an overreaction; saying nothing
/// is worse. Messages come from a GRDB `ValueObservation`, not an in-memory array, so on a write
/// failure what the user sees is the model's reply vanishing, with no explanation anywhere.
///
/// ## Why a persistent banner and not a toast
///
/// "Not being kept" is an ongoing condition, not an event that happened. A toast that disappears
/// after three seconds states it as a one-off notice: miss it and the rest of the conversation is
/// silently lost.
@MainActor
@Observable
final class StorageWriteHealth {
    static let shared = StorageWriteHealth()

    /// Local writes are currently degraded: the last one failed on device storage and none has
    /// succeeded since.
    private(set) var isDegraded = false

    init() {}

    func markDegraded() {
        isDegraded = true
    }

    func markRecovered() {
        isDegraded = false
    }
}

/// The signal entry point on the persistence queue (nonisolated).
///
/// Only the "device is out of space" case counts: failing with space to spare is a local fault,
/// and a banner about storage would neither be true nor give the user anything to do.
enum StorageWriteHealthSignal {
    /// A local mirror, so a successful write does not dispatch onto the main actor every time.
    /// The write is already doing SQLite IO, so one lock is free by comparison.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var degraded = false

    /// - Parameter availableBytes: evaluated lazily. The capacity query can be slow, and a failure
    ///   outside the storage family should never trigger it.
    static func recordFailure(
        _ error: Error,
        availableBytes: @autoclosure () -> Int64? = availableStorageBytesForAppContainer()
    ) {
        guard let verdict = triageStorageFailure(error, availableBytes: availableBytes()),
              case .deviceStorageFull = verdict else { return }
        lock.lock()
        let alreadyDegraded = degraded
        degraded = true
        lock.unlock()
        guard !alreadyDegraded else { return }
        Task { @MainActor in StorageWriteHealth.shared.markDegraded() }
    }

    /// One successful write means the path recovered. Only dispatches while degraded.
    static func recordSuccess() {
        lock.lock()
        let wasDegraded = degraded
        degraded = false
        lock.unlock()
        guard wasDegraded else { return }
        Task { @MainActor in StorageWriteHealth.shared.markRecovered() }
    }

    /// Tests only: clear the process-wide mirror so cases do not bleed into each other.
    static func resetForTesting() {
        lock.lock()
        degraded = false
        lock.unlock()
    }
}
