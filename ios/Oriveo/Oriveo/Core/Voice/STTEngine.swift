import Foundation

/// Dictation failure: the primary action offered when it stops, and the failure of the last request
/// (nil when there was no request, e.g. a local export failure).
/// The recording stays in its slot; the controller decides whether to retry or discard it.
nonisolated struct STTError: Error, Sendable, Hashable {
    let action: DictationPrimaryAction
    let failure: DictationFailure?
    /// Whether an automatic retry already happened before this failure.
    var autoRetried: Bool = false
    /// The slot recording itself could not be read (file cannot be opened / read error), as opposed to a recognizer error.
    var audioUnreadable: Bool = false
}

/// Dictation engine shared by system and cloud recognition. The recording is the closed `.aac` in the slot
/// (with duration and envelope); the engine never deletes it.
/// On success returns the joined, trimmed transcript; on failure throws STTError; throws CancellationError when the task is cancelled.
nonisolated protocol STTEngine: Sendable {
    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String
}
