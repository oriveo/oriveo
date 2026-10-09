import Foundation

/// Which editor one body editing session uses. The two editors are different controls, and swapping
/// controls mid-edit loses the first responder, the caret and any input method composition, so the
/// choice cannot be re-evaluated by length on every change: it is made once when editing starts.
/// While editing, the only allowed move is up from `TextEditor` to the bounded view (pasting a
/// large block into a short note is more than `TextEditor` can carry), and once there it does not
/// switch back even if the text is deleted below the threshold. The session is discarded when
/// editing ends and decided again next time.
struct NoteBodyEditorSession: Equatable {
    enum Editor: Equatable {
        case plain
        case bounded
    }

    /// When the session moves up to the bounded view mid-edit, the new control has to take back
    /// first responder and restore the caret. `sourceLocation` is a UTF-16 offset into the stored
    /// text; nil means it could not be derived and the caret goes to the end.
    struct FocusTakeover: Equatable {
        let sourceLocation: Int?
    }

    private(set) var editor: Editor
    private(set) var focusTakeover: FocusTakeover?

    init(body: String) {
        editor = NoteText.requiresBoundedLayout(body) ? .bounded : .plain
    }

    mutating func bodyDidChange(from old: String, to new: String) {
        guard editor == .plain, NoteText.requiresBoundedLayout(new) else { return }
        editor = .bounded
        focusTakeover = FocusTakeover(sourceLocation: NoteText.caretLocationAfterEdit(from: old, to: new))
    }
}

enum NoteText {
    /// Rich Markdown/TextEditor layout becomes watchdog-sensitive for multi-megabyte generated notes.
    /// Keep ordinary notes unchanged and route only very large bodies to a fixed, independently
    /// scrolling plain-text viewport whose TextKit layout is bounded to visible content.
    ///
    /// The threshold is 10,000. Measured on the iOS 18.0 simulator, a single paragraph without line
    /// breaks in `TextEditor` stalls for 116 ms on first mount and takes 60-78 ms per keystroke at
    /// 20,000 characters, and 89 ms / 28 ms at 10,000; the bounded view mounts in 8-13 ms and types
    /// in 1-3 ms at either size. Unbroken paragraphs of 10,000 to 20,000 characters are the only
    /// range where `TextEditor` starts to struggle (samples with line breaks all stay within
    /// 26 ms), so the threshold sits at 10,000 and goes no lower.
    /// See `NoteBodyEditorSession` for how the threshold is used while editing.
    static let boundedLayoutUTF16Threshold = 10_000

    static func requiresBoundedLayout(_ text: String) -> Bool {
        text.utf16.count >= boundedLayoutUTF16Threshold
    }

    /// `TextEditor` does not expose its selection, so the caret has to be derived from the text
    /// before and after one edit: whatever lies after the shared prefix and before the shared suffix
    /// is what the edit wrote, and the caret is at its end. Returns nil when the text did not change.
    static func caretLocationAfterEdit(from old: String, to new: String) -> Int? {
        let before = Array(old.utf16)
        let after = Array(new.utf16)
        guard before != after else { return nil }
        let shared = min(before.count, after.count)
        var prefix = 0
        while prefix < shared, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shared - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let location = after.count - suffix
        // The shared suffix is compared by UTF-16 code unit and can cut into a surrogate pair or a
        // combining sequence; move the caret past that character.
        let text = new as NSString
        guard location < text.length else { return location }
        let character = text.rangeOfComposedCharacterSequence(at: location)
        return character.location == location ? location : NSMaxRange(character)
    }

    static func displayTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.tr("Untitled note", table: .notes) : trimmed
    }

    static func preview(from body: String, userNote: String? = nil, limit: Int = 280) -> String {
        var text = stripBlocks(previewSource(body, userNote, limit: limit))
        text = text.replacingOccurrences(of: "[*_`~]", with: " ", options: .regularExpression)
        text = collapse(text)
        return String(text.prefix(limit))
    }

    static func previewAttributed(from body: String, userNote: String? = nil, limit: Int = 280) -> AttributedString {
        let clipped = String(collapseKeepingNewlines(stripBlocks(previewSource(body, userNote, limit: limit))).prefix(limit))
        guard !clipped.isEmpty else { return AttributedString("") }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attr = try? AttributedString(markdown: clipped, options: options) {
            return attr
        }
        return AttributedString(clipped)
    }

    static func readingMarkdown(_ text: String) -> String {
        let kept = text.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3, let first = t.first else { return true }
            return !(t.allSatisfy { $0 == first } && (first == "-" || first == "*" || first == "_"))
        }
        let joined = kept.joined(separator: "\n")
        let collapsed = excessBlankLinesRegex.stringByReplacingMatches(
            in: joined,
            range: NSRange(joined.startIndex..., in: joined),
            withTemplate: "\n\n"
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mediumDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted)
            .locale(AppLocalization.currentLocale))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(AppLocalization.currentLocale))
    }


    private static let excessBlankLinesRegex = try! NSRegularExpression(pattern: "\n{3,}")

    private static func previewWindow(_ limit: Int) -> Int { max(limit * 32, 2_048) }

    private static func previewSource(_ body: String, _ userNote: String?, limit: Int) -> String {
        let bounded = String(rawSource(body, userNote).prefix(NoteSummary.bodyProjectionCharacters))
        return String(displayBody(bounded).prefix(previewWindow(limit)))
    }

    private static func rawSource(_ body: String, _ userNote: String?) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (userNote ?? "") : body
    }

    static func displayBody(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## Cross-check") }) else {
            return body
        }
        let display = lines.dropFirst(index + 1).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? body : display
    }

    private static func stripBlocks(_ source: String) -> String {
        var text = source
        text = text.replacingOccurrences(of: "```[a-zA-Z0-9]*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "~~~", with: "")
        text = text.replacingOccurrences(of: #"\$\$([\s\S]+?)\$\$"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\$)\$([^\$\n]+?)\$(?!\$)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^>\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^[-*+]\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\d+\\.\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "|", with: " ")
        return text
    }

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseKeepingNewlines(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^[ \\t]+|[ \\t]+$", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
