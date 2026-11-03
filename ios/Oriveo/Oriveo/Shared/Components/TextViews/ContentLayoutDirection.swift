import SwiftUI

/// Layout direction for user content (bubbles, assistant text, input fields), decided by the
/// first strong directional character of the content itself rather than the interface language.
/// App prompts keep the interface direction; only user content goes through here.
nonisolated enum ContentLayoutDirection {

    /// Direction of the first strong character in `text`; `fallback` when there is none
    /// (empty, digits or punctuation only).
    static func layoutDirection(for text: some StringProtocol, fallback: LayoutDirection) -> LayoutDirection {
        switch ParagraphWritingDirection.firstStrongDirection(in: text) {
        case .rightToLeft:
            return .rightToLeft
        case .leftToRight:
            return .leftToRight
        default:
            return fallback
        }
    }
}
