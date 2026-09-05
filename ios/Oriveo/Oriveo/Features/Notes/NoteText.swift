import Foundation

enum NoteText {
    /// Rich Markdown/TextEditor layout becomes watchdog-sensitive for multi-megabyte generated notes.
    /// Keep ordinary notes unchanged and route only very large bodies to a fixed, independently
    /// scrolling plain-text viewport whose TextKit layout is bounded to visible content.
    static let boundedLayoutUTF16Threshold = 20_000

    static func requiresBoundedLayout(_ text: String) -> Bool {
        text.utf16.count >= boundedLayoutUTF16Threshold
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
