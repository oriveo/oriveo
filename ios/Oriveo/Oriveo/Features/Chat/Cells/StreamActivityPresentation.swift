import Foundation

/// The label shown while waiting: the neutral "Generating", or the label of an observed activity.
nonisolated enum StreamActivityCaption: Equatable, Sendable {
    case neutral
    case activity(StreamActivity)
}

@MainActor
extension StreamActivityCaption {
    /// The neutral label reuses the existing `Generating` key, the same one the typing indicator
    /// shows, with no trailing ellipsis.
    var localizedText: String {
        switch self {
        case .neutral:
            return L10n.tr("Generating")
        case .activity(.webSearch):
            return L10n.tr("Searching the web", table: .chat)
        }
    }
}

/// Decides how waiting feedback is presented while a reply streams. It is a pure function and the
/// cell only consumes the result, so at most one waiting label is on screen at any moment.
nonisolated enum StreamActivityPresentation: Equatable, Sendable {
    /// No status line. The typing indicator, if visible, keeps its default label.
    case hidden
    /// The typing indicator is visible and carries the activity label; no status line on top.
    case typingCaption(StreamActivity)
    /// The status line below the body text.
    case statusLine(StreamActivityCaption)

    /// - Parameters:
    ///   - isGenerating: The message is still generating and the cell holds a streaming subscription.
    ///   - hasBodyText: Body text is already on screen.
    ///   - typingIndicatorVisible: The typing indicator is currently visible.
    ///   - activity: The observed activity. Observation only, never intent.
    ///   - quiet: Nothing visible has changed for 1500 ms.
    static func resolve(
        isGenerating: Bool,
        hasBodyText: Bool,
        typingIndicatorVisible: Bool,
        activity: StreamActivity?,
        quiet: Bool
    ) -> StreamActivityPresentation {
        guard isGenerating else { return .hidden }
        if let activity {
            return typingIndicatorVisible ? .typingCaption(activity) : .statusLine(.activity(activity))
        }
        // A pause with an empty body gets no status line: the typing indicator or the reasoning
        // block is already moving.
        if quiet, hasBodyText { return .statusLine(.neutral) }
        return .hidden
    }
}
