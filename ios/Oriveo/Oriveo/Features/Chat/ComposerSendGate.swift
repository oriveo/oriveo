import Foundation

/// In-flight gate for composer sends: when hardware Return and the send button each fire once in the same frame, the later one is blocked here.
/// A new conversation (no conversation id yet) uses the same criterion as an existing one: while a send from this composer has not returned, no second send goes out.
@MainActor
final class ComposerSendGate {
    private(set) var isInFlight = false

    /// The flag is set before the first suspension, so a second Task queued in the same frame always sees it.
    func send(_ operation: () async -> ChatSendOutcome) async -> ChatSendOutcome {
        guard !isInFlight else { return .blockedWhileSending }
        isInFlight = true
        defer { isInFlight = false }
        return await operation()
    }
}
