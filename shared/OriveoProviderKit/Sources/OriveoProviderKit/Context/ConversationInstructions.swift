import Foundation

/// The single normalization definition for conversation instructions; source of truth is `shared/context-contracts/conversation-instructions.v1.json`.
/// Settings, remote reads and backup imports all pass through it before writing locally; local reads are not normalized again.
public enum ConversationInstructions {
    /// The limit counts Unicode code points (the same unit as Web / Android), not graphemes or UTF-16.
    public static let maxCodePoints = 8000

    /// All White_Space -> ""; otherwise the original text is not trimmed and only the first `maxCodePoints` code points are kept.
    public static func normalize(_ text: String) -> String {
        if ContextSanitizer.trimWhiteSpace(text).isEmpty { return "" }
        let scalars = text.unicodeScalars
        guard scalars.count > maxCodePoints else { return text }
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: scalars.prefix(maxCodePoints))
        return String(cut)
    }
}
