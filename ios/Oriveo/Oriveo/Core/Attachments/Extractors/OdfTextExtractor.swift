import Foundation

/// ODT / ODS / ODP extraction (attachment extraction spec section 9): read only `content.xml`, walk `office:body` in document order,
/// compress character data by ODF whitespace rules -> emit blocks -> append footnotes after the body -> section 3.1 normalization.
nonisolated enum OdfTextExtractor {
    static func extract(
        data: Data,
        fileExtension: String,
        budget: ArchiveExtractionBudget = .attachment(maxOutputBytes: FileExtractionLimits.maxBytes),
        deadline: ExtractionDeadline = ExtractionDeadline()
    ) throws -> String {
        let package = try OfficePackage(data: data, budget: budget, deadline: deadline)
        guard let content = try package.xml("content.xml") else {
            throw ExtractionError(code: .corruptedFile, underlying: "odf content.xml missing")
        }
        var walker = Walker(deadline: deadline)
        for child in content.child("office:body")?.elements ?? [] {
            switch child.name {
            case "office:spreadsheet":
                try walker.spreadsheet(child)
            case "office:presentation":
                try walker.presentation(child)
            default:
                try walker.blocks(of: child)
            }
        }
        walker.writeNotes()
        return walker.writer.render()
    }

    private static let skipped: Set<String> = [
        "office:annotation", "office:annotation-end", "text:tracked-changes", "text:sequence-decls",
        "text:variable-decls", "office:forms", "svg:title", "svg:desc",
    ]

    private static func isSkipped(_ node: OfficeXmlNode) -> Bool {
        skipped.contains(node.name) || node.local.hasSuffix("-source")
    }

    /// Compress `[ \t\n\r]+` in character data to one space.
    static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var inRun = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "\r":
                if !inRun { result.append(" ") }
                inRun = true
            default:
                result.unicodeScalars.append(scalar)
                inRun = false
            }
        }
        return result
    }

    private static let skippedPresentationClasses: Set<String> = ["page-number", "date-time", "footer", "header"]

    private struct Walker {
        let deadline: ExtractionDeadline
        var writer = StructuredBlockWriter()
        private var notes: [(citation: String, text: String)] = []

        init(deadline: ExtractionDeadline) {
            self.deadline = deadline
        }

        // MARK: ODT blocks

        /// `listLevel` is the nesting level of the enclosing `text:list`; `inItem` means we are inside a `text:list-item` (paragraphs are emitted as list items).
        mutating func blocks(of container: OfficeXmlNode, listLevel: Int = 0, inItem: Bool = false) throws {
            for node in container.elements {
                if OdfTextExtractor.isSkipped(node) { continue }
                switch node.name {
                case "text:h", "text:p":
                    var text = ""
                    var frames: [OfficeXmlNode] = []
                    inline(node, text: &text, frames: &frames)
                    if inItem {
                        writer.listItem(depth: listLevel - 1, marker: "- ", text: text)
                    } else if node.name == "text:h" {
                        writer.heading(level: node.attr("text:outline-level").flatMap { Int($0) } ?? 1, text: text)
                    } else {
                        writer.paragraph(text)
                    }
                    // Text box inside a paragraph: its paragraphs each become their own block, placed after the enclosing paragraph.
                    for frame in frames { try blocks(of: frame) }
                case "text:list":
                    for child in node.elements {
                        switch child.name {
                        case "text:list-item":
                            try blocks(of: child, listLevel: listLevel + 1, inItem: true)
                        case "text:list-header":
                            try blocks(of: child, listLevel: listLevel + 1, inItem: false)
                        default:
                            continue
                        }
                    }
                case "table:table":
                    try tableGrid(node, trackDeadline: false).write(into: &writer, trimToUsedRange: false)
                case "text:soft-page-break":
                    continue
                default:
                    try blocks(of: node, listLevel: listLevel, inItem: inItem)
                }
            }
        }

        // MARK: Text within a paragraph

        mutating func inline(_ node: OfficeXmlNode, text: inout String, frames: inout [OfficeXmlNode]) {
            for child in node.children {
                switch child {
                case .text(let value):
                    text += OdfTextExtractor.collapseWhitespace(value)
                case .element(let element):
                    if OdfTextExtractor.isSkipped(element) { continue }
                    switch element.name {
                    case "text:s":
                        let count = element.attr("text:c").flatMap { Int($0) } ?? 1
                        text += String(repeating: " ", count: min(max(count, 0), 10_000))
                    case "text:tab":
                        text += "\t"
                    case "text:line-break":
                        text += "\n"
                    case "text:soft-page-break":
                        continue
                    case "text:note":
                        var citation = ""
                        var ignored: [OfficeXmlNode] = []
                        if let node = element.child("text:note-citation") { inline(node, text: &citation, frames: &ignored) }
                        citation = citation.trimmingCharacters(in: .whitespacesAndNewlines)
                        text += "[^\(citation)]"
                        var paragraphs: [String] = []
                        var found = false
                        if let body = element.child("text:note-body") { collectParagraphs(of: body, into: &paragraphs, found: &found) }
                        let noteText = paragraphs
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                        notes.append((citation, noteText))
                    case "draw:frame":
                        frames.append(element)
                    default:
                        inline(element, text: &text, frames: &frames)
                    }
                }
            }
        }

        /// Text of the paragraphs (`text:p` / `text:h`) in a container; nested tables are flattened into one paragraph (` / ` between rows, `; ` between cells).
        mutating func collectParagraphs(of container: OfficeXmlNode, into paragraphs: inout [String], found: inout Bool) {
            for node in container.elements {
                if OdfTextExtractor.isSkipped(node) { continue }
                switch node.name {
                case "text:p", "text:h":
                    found = true
                    var text = ""
                    var frames: [OfficeXmlNode] = []
                    inline(node, text: &text, frames: &frames)
                    paragraphs.append(text)
                    for frame in frames { collectParagraphs(of: frame, into: &paragraphs, found: &found) }
                case "table:table":
                    found = true
                    paragraphs.append(flattenedTable(node))
                default:
                    collectParagraphs(of: node, into: &paragraphs, found: &found)
                }
            }
        }

        private mutating func flattenedTable(_ table: OfficeXmlNode) -> String {
            Self.rows(of: table).map { row in
                row.elements
                    .filter { $0.name == "table:table-cell" || $0.name == "table:covered-table-cell" }
                    .map { cell in
                        var paragraphs: [String] = []
                        var found = false
                        collectParagraphs(of: cell, into: &paragraphs, found: &found)
                        return paragraphs
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                    }
                    .joined(separator: "; ")
            }
            .joined(separator: " / ")
        }

        // MARK: Tables

        /// Rows can be at any depth: direct children, or inside `table:table-header-rows` / `table:table-rows` / `table:table-row-group`.
        private static func rows(of table: OfficeXmlNode) -> [OfficeXmlNode] {
            var result: [OfficeXmlNode] = []
            for child in table.elements {
                switch child.name {
                case "table:table-row":
                    result.append(child)
                case "table:table-header-rows", "table:table-rows", "table:table-row-group":
                    result += rows(of: child)
                default:
                    continue
                }
            }
            return result
        }

        /// Repeats of empty cells / empty rows are recorded only as pending gaps (a sparse grid just advances the position) and land only when non-empty content follows;
        /// non-empty cells repeat up to column 50, each run of empty / non-empty rows repeats at most 100 times; the width of the used range is computed from the full repeat count.
        mutating func tableGrid(_ table: OfficeXmlNode, trackDeadline: Bool) throws -> SpreadsheetGrid {
            var grid = SpreadsheetGrid()
            var rowNumber = 0
            for (index, row) in Self.rows(of: table).enumerated() {
                if trackDeadline, index % 1_000 == 0 { try deadline.check() }
                let rowRepeat = max(row.attr("table:number-rows-repeated").flatMap { Int($0) } ?? 1, 1)
                var column = 0
                var cells: [(Int, String)] = []
                var lastUsedColumn = 0
                for cell in row.elements where cell.name == "table:table-cell" || cell.name == "table:covered-table-cell" {
                    let repeatCount = max(cell.attr("table:number-columns-repeated").flatMap { Int($0) } ?? 1, 1)
                    let text = cell.name == "table:covered-table-cell" ? "" : cellText(cell)
                    if !text.isEmpty {
                        let last = column + repeatCount
                        let materializedLast = max(column + 1, min(last, StructuredTextFormat.maxTableColumns))
                        for target in (column + 1)...materializedLast { cells.append((target, text)) }
                        lastUsedColumn = last
                    }
                    column += repeatCount
                }
                if cells.isEmpty {
                    // Repeated empty rows only advance the position and land when content follows; at most 100 rows per run
                    rowNumber += min(rowRepeat, 100)
                    continue
                }
                for _ in 0..<min(rowRepeat, 100) {
                    rowNumber += 1
                    for (target, text) in cells { grid.set(row: rowNumber, column: target, text: text) }
                }
                grid.extendWidth(to: lastUsedColumn)
            }
            return grid
        }

        /// Cell value: join the `text:p` elements with `<br>`; with no `text:p`, try the value attributes in turn.
        private mutating func cellText(_ cell: OfficeXmlNode) -> String {
            var paragraphs: [String] = []
            var found = false
            collectParagraphs(of: cell, into: &paragraphs, found: &found)
            if !found {
                let attributes = ["office:string-value", "office:value", "office:date-value", "office:time-value", "office:boolean-value"]
                if let value = attributes.lazy.compactMap({ cell.attr($0) }).first { paragraphs = [value] }
            }
            return StructuredTextFormat.cellText(paragraphs: paragraphs)
        }

        // MARK: ODS

        mutating func spreadsheet(_ spreadsheet: OfficeXmlNode) throws {
            for table in spreadsheet.children("table:table") {
                try deadline.check()
                writer.section("## Sheet: \(table.attr("table:name") ?? "")")
                try tableGrid(table, trackDeadline: true).write(into: &writer)
            }
        }

        // MARK: ODP

        mutating func presentation(_ presentation: OfficeXmlNode) throws {
            for (index, page) in presentation.children("draw:page").enumerated() {
                try deadline.check()
                let title = Self.titleFrame(in: page)
                var heading = "## Slide \(index + 1)"
                if let title {
                    var paragraphs: [String] = []
                    var found = false
                    collectParagraphs(of: title, into: &paragraphs, found: &found)
                    let text = paragraphs
                        .joined(separator: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { heading += ": \(text)" }
                }
                writer.section(heading)
                try pageBody(page, title: title)

                var noteParagraphs: [String] = []
                for frame in Self.frames(in: page.child("presentation:notes")) where frame.attr("presentation:class") == "notes" {
                    var found = false
                    collectParagraphs(of: frame, into: &noteParagraphs, found: &found)
                }
                let nonEmpty = noteParagraphs.filter { !StructuredBlockWriter.trimSpacesAndTabs($0).isEmpty }
                if !nonEmpty.isEmpty {
                    writer.notesHeading()
                    for paragraph in nonEmpty { writer.paragraph(paragraph) }
                }
            }
        }

        /// `draw:frame` elements on the page (excluding notes) in document order, including those inside `draw:g` groups.
        private static func frames(in node: OfficeXmlNode?) -> [OfficeXmlNode] {
            guard let node else { return [] }
            var result: [OfficeXmlNode] = []
            for child in node.elements {
                switch child.name {
                case "draw:frame":
                    result.append(child)
                case "draw:g":
                    result += frames(in: child)
                default:
                    continue
                }
            }
            return result
        }

        private static func titleFrame(in page: OfficeXmlNode) -> OfficeXmlNode? {
            frames(in: page).first { $0.attr("presentation:class") == "title" }
        }

        private mutating func pageBody(_ page: OfficeXmlNode, title: OfficeXmlNode?) throws {
            for frame in Self.frames(in: page) {
                if let title, frame === title { continue }
                if let kind = frame.attr("presentation:class"), OdfTextExtractor.skippedPresentationClasses.contains(kind) { continue }
                for child in frame.elements {
                    switch child.name {
                    case "draw:text-box":
                        try blocks(of: child)
                    case "table:table":
                        try tableGrid(child, trackDeadline: false).write(into: &writer, trimToUsedRange: false)
                    default:
                        continue
                    }
                }
            }
        }

        // MARK: Footnotes

        mutating func writeNotes() {
            for (index, note) in notes.enumerated() {
                writer.paragraph("[^\(note.citation)]: \(note.text)", blankBefore: index == 0)
            }
        }
    }
}
