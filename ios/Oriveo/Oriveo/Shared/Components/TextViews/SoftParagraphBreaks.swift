import Foundation
import UIKit

/// Display-only soft paragraph breaks: very long paragraphs are split into several display paragraphs
/// with U+2029 (PARAGRAPH SEPARATOR), while everything that leaves the view (bindings, drafts, sending,
/// copy, save as note, ask) always gets the source text without the U+2029 characters.
///
/// Why split at all: TextKit lays text out paragraph by paragraph and builds one CTTypesetter per
/// paragraph, so any line inside a paragraph first pays for bidi and glyph shaping of the whole
/// paragraph. A single unbroken paste makes every layout pass redo the whole thing, and Arabic is
/// especially expensive (50–80x slower than Latin text of the same length on the simulator); pasting one
/// long Arabic paragraph used to freeze the composer and the sent bubble for seconds.
/// Break points reuse `NoteSoftParagraphBreaks.breakOffsets` (sentence end > whitespace > grapheme boundary).
///
/// Why U+2029 rather than the note editor's attribute-marked "\n": the composer is editable, and undo/redo,
/// Writing Tools and inserts normalized to the typing attributes all drop attribute markers, after which a
/// soft break can no longer be told apart from a newline the user typed. U+2029 is a paragraph separator in
/// its own right, lays out exactly like "\n", survives undo, and is removed by deleting it.
/// Trade-off: a rare U+2029 in the user's own text is normalized to "\n" (both mean a paragraph break).
nonisolated enum SoftParagraphBreaks {
    static let separator: unichar = 0x2029
    static let separatorString = "\u{2029}"

    /// Maximum display paragraph length in UTF-16. On the simulator a 32K single Arabic paragraph takes
    /// 616ms per layout pass; split at 2K it takes 183ms (1K: 171ms, 4K: 231ms, 2K is the knee).
    static let maxParagraphUTF16 = 2_048

    /// Source → display string (plain text): normalize U+2029 in the source to "\n", then insert U+2029
    /// inside overlong paragraphs.
    static func display(forSource source: String, maxParagraphUTF16: Int = maxParagraphUTF16) -> String {
        let text = normalized(source) as NSString
        let offsets = NoteSoftParagraphBreaks.breakOffsets(in: text, maxParagraphUTF16: maxParagraphUTF16)
        guard !offsets.isEmpty else { return text as String }
        let result = NSMutableString(capacity: text.length + offsets.count)
        var previous = 0
        for offset in offsets {
            result.append(text.substring(with: NSRange(location: previous, length: offset - previous)))
            result.append(separatorString)
            previous = offset
        }
        result.append(text.substring(from: previous))
        return result as String
    }

    /// Display string → source.
    static func source(fromDisplay display: String) -> String {
        display.utf16.contains(separator)
            ? display.replacingOccurrences(of: separatorString, with: "")
            : display
    }

    /// Normalizes U+2029 in the source to "\n", so every U+2029 in a display string is a soft break
    /// and can safely be removed when restoring the source.
    static func normalized(_ source: String) -> String {
        source.utf16.contains(separator)
            ? source.replacingOccurrences(of: separatorString, with: "\n")
            : source
    }
}
