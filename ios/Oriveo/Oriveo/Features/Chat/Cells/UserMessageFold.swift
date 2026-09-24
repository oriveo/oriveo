import CoreGraphics

/// Folding of very long user messages: the bubble lays out only a prefix and the full text opens in
/// `UserMessageFullTextSheet`.
///
/// Why it has to fold: TextKit shaping costs time linear in the number of characters, about 470ms for one pass
/// over 200,000 characters of Arabic, and a new cell needs at least one pass to measure and one to display. Soft
/// paragraph breaks and leaving the constraint engine only lower the constant; the only way to make one bubble's
/// main-thread cost independent of message length is to not lay out the whole text.
///
/// The rule and its parameters are shared with Android (`UserMessageFold.kt`) and the web
/// (`user-message-fold.ts`); change all three together.
nonisolated enum UserMessageFold {
    /// Messages longer than this fold. 6,000 characters is already 4 to 10 screens on a phone; one pass over that much
    /// Arabic takes about 14ms, so the worst unfolded cost stays around a frame.
    static let thresholdUTF16 = 6_000
    /// Prefix length cap: enough to fill the folded viewport (about 80 Latin letters x 14 lines in the widest web
    /// bubble) with room to spare.
    static let previewUTF16 = 2_000
    /// Most line breaks the prefix may carry: a message of short lines (logs, lists) need not lay out thousands of
    /// them to fill the viewport.
    static let previewLineCap = 60
    /// Visible height of the folded body (about 14 lines); the rest is clipped.
    static let collapsedTextHeight: CGFloat = 320
    /// Height of the bottom fade, matching the code card's mask.
    static let fadeHeight: CGFloat = 44

    static func shouldFold(_ text: String) -> Bool {
        text.utf16.count > thresholdUTF16
    }

    /// Cuts the prefix on a grapheme boundary, never splitting surrogate pairs, combining marks or emoji sequences.
    /// Only the prefix itself is walked, so the cost does not depend on the full length.
    static func preview(of text: String) -> String {
        var utf16 = 0
        var newlines = 0
        var end = text.startIndex
        while end < text.endIndex {
            let character = text[end]
            let units = character.utf16.count
            if utf16 + units > previewUTF16 { break }
            if character.isNewline {
                newlines += 1
                if newlines > previewLineCap { break }
            }
            utf16 += units
            end = text.index(after: end)
        }
        return String(text[..<end])
    }
}
