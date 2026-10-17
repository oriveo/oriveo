import Foundation

/// Output rules shared by structured formats (attachment extraction spec section 3.1 normalization, section 3.3 tables).
nonisolated enum StructuredTextFormat {
    static let maxTableColumns = 50

    // MARK: - Section 3.1 normalization

    /// Normalize line breaks to `\n` -> U+00A0 becomes a space -> strip trailing spaces and `\t` on each line -> compress 3 or more `\n` to 2 -> trim leading/trailing whitespace of the whole text.
    static func normalize(_ text: String) -> String {
        let unified = PlainTextExtractor.normalizeNewlines(text)
        var lines: [Substring] = []
        for rawLine in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine.replacingOccurrences(of: "\u{00A0}", with: " "))
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            lines.append(line)
        }
        var result = ""
        var blankRun = 0
        for (index, line) in lines.enumerated() {
            if index > 0 {
                if line.isEmpty {
                    blankRun += 1
                    if blankRun >= 2 { continue }
                } else {
                    blankRun = 0
                }
                result += "\n"
            }
            result += line
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Section 3.3 tables

    enum TableBlock: Equatable {
        /// Pipe table; when `omittedColumns > 0`, a `(N more columns not shown)` paragraph follows the table directly.
        case table(String, omittedColumns: Int)
        /// 1 row x 1 column: the cell text is output as a paragraph.
        case paragraph(String)
    }

    /// Multiple paragraphs in a cell are each trimmed, empty ones dropped, and joined with `<br>`; leftover line breaks -> `<br>`, `\t` -> space, `|` -> `\|`, then trim.
    static func cellText(paragraphs: [String]) -> String {
        let joined = paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "<br>")
        let escaped = joined
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
        return escaped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cells already processed by `cellText` -> table block; returns nil if all cells are empty (the whole block is discarded).
    static func table(_ rows: [[String]]) -> TableBlock? {
        guard rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return nil }
        let columnCount = rows.map(\.count).max() ?? 0
        if rows.count == 1, columnCount == 1 {
            return .paragraph(rows[0][0].replacingOccurrences(of: "<br>", with: "\n"))
        }
        let kept = min(columnCount, maxTableColumns)
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            var cells = Array(row.prefix(kept))
            cells += Array(repeating: "", count: kept - cells.count)
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if index == 0 {
                lines.append("| " + Array(repeating: "---", count: kept).joined(separator: " | ") + " |")
            }
        }
        return .table(lines.joined(separator: "\n"), omittedColumns: columnCount - kept)
    }

    static func omittedColumnsNote(_ count: Int) -> String {
        "(\(count) more columns not shown)"
    }
}
