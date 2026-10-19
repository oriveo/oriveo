import Foundation

/// How one request attempt was started.
nonisolated enum ChatAttemptKind: String, Sendable, Equatable {
    case send
    case edit
    /// Retry on a failed message.
    case retry
    /// Regenerate a completed answer.
    case regenerate
    /// Continue a cut-off answer.
    case continueResponse = "continue"
    /// Automatic recovery of an interrupted stream.
    case recovery
}
