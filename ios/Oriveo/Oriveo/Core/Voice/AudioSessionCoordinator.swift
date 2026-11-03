import AVFoundation
import Foundation

/// The only entry point for every call that changes AVAudioSession state.
/// setCategory / setActive are synchronous blocking calls (SDK header: "a synchronous (blocking) operation"),
/// which would stall the UI on the main thread. Async activate / deactivate need iOS 27 and the project minimum is 18,
/// so everything goes through one dedicated serial queue. Serial order keeps "activate -> start engine",
/// "stop engine -> deactivate" and interruption recovery from interleaving.
/// Outside this file and the Core/Debug probe, the main target must not call these APIs directly (scripts/ios-audio-session-guard.mjs).
nonisolated final class AudioSessionCoordinator: @unchecked Sendable {

    /// One session configuration; a nil field means leave it unchanged.
    struct Configuration: Equatable, Sendable {
        var category: AVAudioSession.Category
        var mode: AVAudioSession.Mode = .default
        var options: AVAudioSession.CategoryOptions = []
        var allowHapticsDuringRecording: Bool? = nil
    }

    enum Operation: Equatable, Sendable {
        case configure(Configuration)
        case activate
        /// Preference value; can be set before or after activation. Callers keep their original ordering.
        case preferIOBufferDuration(TimeInterval)
        case deactivate(notifyOthers: Bool)
    }

    static let shared = AudioSessionCoordinator()

    private let queue: DispatchQueue
    private let apply: @Sendable (Operation) throws -> Void

    /// Tests inject apply to record calls and their threads; production uses AVAudioSession.sharedInstance().
    init(
        queue: DispatchQueue = DispatchQueue(label: "com.oriveo.audio-session", qos: .userInitiated),
        apply: @escaping @Sendable (Operation) throws -> Void = AudioSessionCoordinator.applyToSharedSession
    ) {
        self.queue = queue
        self.apply = apply
    }

    /// Runs the operations in order on the session queue; returns once all complete (or the first throws). Callers start the engine after awaiting.
    func perform(_ operations: [Operation]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [apply] in
                continuation.resume(with: Result { try operations.forEach(apply) })
            }
        }
    }

    /// Configure and activate.
    func activate(_ configuration: Configuration?) async throws {
        try await perform((configuration.map { [.configure($0)] } ?? []) + [.activate])
    }

    /// Deactivation does not need to be awaited: it is queued on the same queue, so any later activation runs after it. Failures are only logged (same as the previous try?).
    func deactivate(notifyOthers: Bool = false) {
        queue.async { [apply] in
            do { try apply(.deactivate(notifyOthers: notifyOthers)) } catch {
                #if DEBUG
                print("[AudioSessionCoordinator] deactivate failed: \(error)")
                #endif
            }
        }
    }

    /// For callers already on a background thread whose next steps depend synchronously on the activation result; calling from the main thread is a programming error.
    func performBlocking(_ operations: [Operation]) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try queue.sync { [apply] in try operations.forEach(apply) }
    }

    static let applyToSharedSession: @Sendable (Operation) throws -> Void = { operation in
        let session = AVAudioSession.sharedInstance()
        switch operation {
        case .configure(let c):
            try session.setCategory(c.category, mode: c.mode, options: c.options)
            // Same as before the migration: failing to set haptics / system sound preferences must not affect recording.
            if let allow = c.allowHapticsDuringRecording {
                try? session.setAllowHapticsAndSystemSoundsDuringRecording(allow)
            }
        case .activate:
            try session.setActive(true)
        case .preferIOBufferDuration(let duration):
            try session.setPreferredIOBufferDuration(duration)
        case .deactivate(let notifyOthers):
            try session.setActive(false, options: notifyOthers ? .notifyOthersOnDeactivation : [])
        }
    }
}
