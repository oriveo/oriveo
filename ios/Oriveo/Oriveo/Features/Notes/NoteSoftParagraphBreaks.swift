import Foundation
import UIKit

/// Display-only soft paragraph breaks for the bounded note viewport. Very long paragraphs are split
/// into several display paragraphs; the stored note text never changes.
///
/// Why: TextKit 1 lays text out paragraph by paragraph. `NSATSTypesetter` builds one
/// `CTTypesetter` for the whole paragraph, so before any line of it can be laid out the glyphs of
/// the entire paragraph have to be positioned (GPOS kerning and so on). Non-contiguous layout can
/// skip other paragraphs, never the rest of the current one. A long paragraph without a single
/// newline (a JSON blob, a long code line, a log dump, unbroken CJK prose) therefore makes every
/// resize, width change and keystroke re-lay out the whole paragraph, and the cost grows faster
/// than linearly: on a simulator, 30k UTF-16 units in one paragraph take about 130 ms per pass and
/// 120k take about 1.7 s, which turns into multi-second hangs on device. TextKit 2 also lays out
/// whole paragraphs and measured slower (3.4 s for the same 120k), so it is not an alternative.
///
/// Split into display paragraphs of at most `maxParagraphUTF16`, the same 120k text opens in about
/// 28 ms, re-lays out on a width change in about 5 ms and edits without a measurable pause. The cost
/// is an early line break roughly every 4k units inside such a paragraph; break points prefer
/// sentence ends, so the result reads like paragraphing.
///
/// Each inserted `\n` carries `markerKey`; `strip` removes them again when writing back or copying.
/// The marker value is the serial number of the break, so a newline the user types right after a
/// soft break, even if it inherited the same marker, is kept: only the first newline per serial
/// is removed.
nonisolated enum NoteSoftParagraphBreaks {

    /// Display paragraph limit in UTF-16 units. At 4k a paragraph lays out in about 3 ms on a
    /// simulator, so per-keystroke relayout is imperceptible; a larger limit means fewer early line
    /// breaks but a more expensive paragraph to re-lay out on every keystroke.
    static let maxParagraphUTF16 = 4_096

    /// Break points are only searched in this span before the limit; if nothing natural is found
    /// the paragraph is cut at the limit.
    static let searchWindowUTF16 = 1_024

    static let markerKey = NSAttributedString.Key("OriveoNoteSoftParagraphBreak")

    /// Inserts soft breaks into a string whose paragraph directions are already resolved. Must run
    /// after `ParagraphWritingDirection`, so every block keeps the direction of its original
    /// paragraph instead of re-resolving it from the start of the block.
    /// Returns the same object when no paragraph exceeds the limit.
    static func insertingBreaks(
        into string: NSAttributedString,
        maxParagraphUTF16: Int = maxParagraphUTF16
    ) -> NSAttributedString {
        let text = string.string as NSString
        let offsets = breakOffsets(in: text, maxParagraphUTF16: maxParagraphUTF16)
        guard !offsets.isEmpty else { return string }

        // Appending substrings keeps this O(n); inserting one break at a time would move the tail
        // of a multi-megabyte string for every break.
        let result = NSMutableAttributedString()
        result.beginEditing()
        var previous = 0
        for (serial, offset) in offsets.enumerated() {
            result.append(string.attributedSubstring(from: NSRange(location: previous, length: offset - previous)))
            // The soft break terminates the previous block, so it copies the attributes of the
            // character before it (font, color and the paragraph style with its resolved direction).
            var attributes = string.attributes(at: offset - 1, effectiveRange: nil)
            attributes[markerKey] = serial
            result.append(NSAttributedString(string: "\n", attributes: attributes))
            previous = offset
        }
        result.append(string.attributedSubstring(from: NSRange(location: previous, length: text.length - previous)))
        result.endEditing()
        return result
    }

    /// Removes soft breaks and returns the stored source text. Only marked newlines are removed,
    /// and only the first one per break serial; any other character that happens to carry the
    /// marker is kept. An extra newline is recoverable, a lost character is not.
    static func strip(_ string: NSAttributedString) -> String {
        let text = string.string as NSString
        var removals: [Int] = []
        var removedSerials = Set<Int>()
        string.enumerateAttribute(markerKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let serial = value as? Int, !removedSerials.contains(serial) else { return }
            for index in range.location..<NSMaxRange(range) where text.character(at: index) == newline {
                removals.append(index)
                removedSerials.insert(serial)
                break
            }
        }
        guard !removals.isEmpty else { return string.string }

        let restored = NSMutableString(capacity: text.length - removals.count)
        var previous = 0
        for index in removals {
            restored.append(text.substring(with: NSRange(location: previous, length: index - previous)))
            previous = index + 1
        }
        restored.append(text.substring(from: previous))
        return restored as String
    }

    /// UTF-16 offsets to insert a soft break **before**, ascending. Only paragraphs longer than the
    /// limit are split, and breaks only land inside the paragraph content (never in its
    /// terminator), so a CRLF pair is never separated.
    static func breakOffsets(in text: NSString, maxParagraphUTF16: Int = maxParagraphUTF16) -> [Int] {
        guard maxParagraphUTF16 > 0, text.length > maxParagraphUTF16 else { return [] }
        var offsets: [Int] = []
        var location = 0
        while location < text.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            text.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            var cursor = start
            while contentsEnd - cursor > maxParagraphUTF16 {
                guard let offset = breakOffset(in: text, from: cursor, limit: cursor + maxParagraphUTF16) else { break }
                offsets.append(offset)
                cursor = offset
            }
            location = max(end, location + 1)
        }
        return offsets
    }

    // MARK: - Break point selection

    private static let newline: unichar = 0x0A

    /// Full-width sentence terminators (ideographic full stop, full-width exclamation, question
    /// and semicolon, horizontal ellipsis). They end a sentence on their own, no space follows.
    private static let wideTerminators: Set<unichar> = [0x3002, 0xFF01, 0xFF1F, 0xFF1B, 0x2026]
    /// ASCII terminators only count when followed by whitespace, so the dot in 3.14, a domain name
    /// or a JSON value is never taken for a full stop.
    private static let asciiTerminators: Set<unichar> = [0x2E, 0x21, 0x3F, 0x3B] // . ! ? ;
    /// Closing brackets and quotes right after a terminator stay with the previous block, so the
    /// next line never starts with one (corner brackets, full-width parenthesis, lenticular and
    /// angle brackets, curly quotes, ASCII closers).
    private static let closers: Set<unichar> = [
        0x300D, 0x300F, 0xFF09, 0x3011, 0x300B, 0x3009, 0x201D, 0x2019, 0x29, 0x5D, 0x22, 0x27,
    ]

    private static func isBlank(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x3000
    }

    /// Picks a break in (cursor, limit]: sentence end, then whitespace, then a grapheme boundary at
    /// the limit.
    private static func breakOffset(in text: NSString, from cursor: Int, limit: Int) -> Int? {
        let windowStart = max(cursor + 1, limit - searchWindowUTF16)

        var afterBlank: Int?
        var index = limit - 1
        while index >= windowStart - 1 {
            let unit = text.character(at: index)
            if wideTerminators.contains(unit),
               let offset = absorbing(closersAndBlanks: true, in: text, from: index + 1, limit: limit) {
                return offset
            }
            if asciiTerminators.contains(unit), index + 1 < limit, isBlank(text.character(at: index + 1)),
               let offset = absorbing(closersAndBlanks: false, in: text, from: index + 1, limit: limit) {
                return offset
            }
            if afterBlank == nil, isBlank(unit),
               let offset = absorbing(closersAndBlanks: false, in: text, from: index + 1, limit: limit) {
                afterBlank = offset
            }
            index -= 1
        }
        if let afterBlank { return afterBlank }

        // No natural break: fall back to the grapheme boundary at the limit, never splitting a
        // surrogate pair, a combining sequence or a ZWJ sequence.
        let cluster = text.rangeOfComposedCharacterSequence(at: limit)
        if cluster.location > cursor { return cluster.location }
        return NSMaxRange(cluster) < text.length ? NSMaxRange(cluster) : nil
    }

    /// Skips the whitespace that follows `offset` (after a sentence end also closers and repeated
    /// terminators) and returns a break on a grapheme boundary no later than `limit`. If the run is
    /// still going at `limit`, the candidate is rejected so the next line does not start with
    /// whitespace or a closer.
    private static func absorbing(closersAndBlanks: Bool, in text: NSString, from offset: Int, limit: Int) -> Int? {
        func absorbable(_ unit: unichar) -> Bool {
            isBlank(unit) || (closersAndBlanks && (closers.contains(unit) || wideTerminators.contains(unit)))
        }
        var end = offset
        while end < limit, absorbable(text.character(at: end)) {
            end += 1
        }
        guard end < text.length, !absorbable(text.character(at: end)) else { return nil }
        return text.rangeOfComposedCharacterSequence(at: end).location == end ? end : nil
    }
}

/// UITextView for the bounded viewport: copy and cut must hand out the stored text, not the
/// display-only soft breaks.
final class BoundedNoteUITextView: UITextView {
    /// Injectable for tests; always the general pasteboard in the app.
    var sourcePasteboard: UIPasteboard = .general

    override func copy(_ sender: Any?) {
        let source = selectedSourceTextIfSoftBroken()
        super.copy(sender)
        if let source { sourcePasteboard.string = source }
    }

    override func cut(_ sender: Any?) {
        // Cutting deletes the selection, so the source text has to be read before super.
        let source = selectedSourceTextIfSoftBroken()
        super.cut(sender)
        if let source { sourcePasteboard.string = source }
    }

    /// The selected source text when the selection contains a soft break; nil otherwise, which keeps
    /// the richer pasteboard content UIKit wrote.
    func selectedSourceTextIfSoftBroken() -> String? {
        let range = selectedRange
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return nil }
        let selected = textStorage.attributedSubstring(from: range)
        var containsSoftBreak = false
        selected.enumerateAttribute(
            NoteSoftParagraphBreaks.markerKey,
            in: NSRange(location: 0, length: selected.length)
        ) { value, _, stop in
            if value != nil {
                containsSoftBreak = true
                stop.pointee = true
            }
        }
        return containsSoftBreak ? NoteSoftParagraphBreaks.strip(selected) : nil
    }
}
