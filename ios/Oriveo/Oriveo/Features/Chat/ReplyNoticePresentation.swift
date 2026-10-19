import Foundation
import OriveoProviderKit

/// Notice line for an incomplete or filtered reply (stop-reason.v1 ui).
/// Shown only on non-streaming assistant messages without a recovery card; [Continue generating] is offered only on the last assistant message.
nonisolated struct ReplyNoticePresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case warning
        case secondary
    }

    /// The key in Chat.xcstrings.
    let titleKey: String
    let tone: Tone
    let systemImage: String
    let showsContinue: Bool

    static func make(
        stopReason: StopReason?,
        isLastAssistant: Bool,
        isStreaming: Bool,
        hasRecoveryCard: Bool
    ) -> ReplyNoticePresentation? {
        guard let stopReason, !isStreaming, !hasRecoveryCard else { return nil }
        let titleKey: String
        let tone: Tone
        let offersContinue: Bool
        switch stopReason {
        case .length:
            titleKey = "reply_incomplete_output_limit"
            tone = .warning
            offersContinue = true
        case .incomplete:
            titleKey = "reply_incomplete_connection"
            tone = .warning
            offersContinue = true
        case .contentFilter:
            titleKey = "reply_filtered"
            tone = .secondary
            offersContinue = false
        case .contextWindowExceeded:
            titleKey = "reply_context_overflow"
            tone = .warning
            offersContinue = false
        case .stop, .tool, .interrupted, .error, .unknown:
            return nil
        }
        return ReplyNoticePresentation(
            titleKey: titleKey,
            tone: tone,
            systemImage: tone == .secondary ? "info.circle" : "exclamationmark.circle",
            showsContinue: offersContinue && isLastAssistant
        )
    }
}
