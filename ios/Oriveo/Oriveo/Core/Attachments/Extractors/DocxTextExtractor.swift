import Foundation

/// DOCX extraction (attachment extraction spec section 5): find the main document by root relationship -> find styles / numbering / footnotes / endnotes by main-document relationship ->
/// emit paragraphs, headings, list items, tables in document order -> append referenced footnotes and endnotes after the body -> section 3.1 normalization.
nonisolated enum DocxTextExtractor {
    static func extract(_ package: OfficePackage) throws -> String {
        let mainPath = try package.mainPart(fallback: "word/document.xml")
        guard let document = try package.xml(mainPath) else {
            throw ExtractionError(code: .corruptedFile, underlying: "docx main document missing")
        }
        let relationships = try package.relationships(of: mainPath)
        func partPath(_ type: String, fallback: String) -> String {
            relationships.first { $0.hasType(type) }?.target ?? fallback
        }

        let styles = try package.xml(partPath("/styles", fallback: "word/styles.xml")).map(StyleTable.init) ?? StyleTable()
        let numbering = try package.xml(partPath("/numbering", fallback: "word/numbering.xml")).map(NumberingTable.init)

        var walker = Walker(styles: styles, numbering: numbering)
        if let body = document.child("w:body") {
            walker.blocks(of: body)
        }

        if !walker.noteReferences.isEmpty {
            let footnotes = try package.xml(partPath("/footnotes", fallback: "word/footnotes.xml")).map { notes(in: $0, element: "w:footnote") } ?? [:]
            let endnotes = try package.xml(partPath("/endnotes", fallback: "word/endnotes.xml")).map { notes(in: $0, element: "w:endnote") } ?? [:]
            var first = true
            for reference in walker.noteReferences {
                let note = reference.isEndnote ? endnotes[reference.id] : footnotes[reference.id]
                guard let note else { continue }
                let label = reference.isEndnote ? "[^e\(reference.id)]" : "[^\(reference.id)]"
                walker.writer.paragraph("\(label): \(noteText(note, styles: styles))", blankBefore: first)
                first = false
            }
        }
        return walker.writer.render()
    }

    private static func notes(in root: OfficeXmlNode, element: String) -> [String: OfficeXmlNode] {
        var result: [String: OfficeXmlNode] = [:]
        for note in root.children(element) {
            let type = note.attr("w:type") ?? ""
            guard type != "separator", type != "continuationSeparator", let id = note.attr("w:id") else { continue }
            if result[id] == nil { result[id] = note }
        }
        return result
    }

    /// Note text: each paragraph is trimmed, empty paragraphs are dropped, and the rest are joined with one space. Each note has its own field stack.
    private static func noteText(_ note: OfficeXmlNode, styles: StyleTable) -> String {
        var walker = Walker(styles: styles, numbering: nil)
        var paragraphs: [String] = []
        walker.collectParagraphs(of: note, into: &paragraphs)
        return paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Styles

    struct StyleTable {
        struct Style {
            let name: String?
            let basedOn: String?
            let outlineLevel: Int?
        }

        private var styles: [String: Style] = [:]

        init() {}

        init(_ root: OfficeXmlNode) {
            for node in root.children("w:style") {
                guard let id = node.attr("w:styleId"), styles[id] == nil else { continue }
                styles[id] = Style(
                    name: node.child("w:name")?.attr("w:val")?.lowercased(),
                    basedOn: node.child("w:basedOn")?.attr("w:val"),
                    outlineLevel: node.child("w:pPr")?.child("w:outlineLvl")?.attr("w:val").flatMap { Int($0) }
                )
            }
        }

        /// Walk up `w:basedOn` from `id` at most 10 levels.
        func chain(from id: String?) -> [Style] {
            var result: [Style] = []
            var visited: Set<String> = []
            var current = id
            while let key = current, result.count <= 10, !visited.contains(key), let style = styles[key] {
                visited.insert(key)
                result.append(style)
                current = style.basedOn
            }
            return result
        }
    }

    // MARK: - Numbering

    struct NumberingTable {
        struct Level {
            let format: String?
            let start: Int
        }

        private var abstractOfNum: [String: String] = [:]
        private var levels: [String: [Int: Level]] = [:]

        init(_ root: OfficeXmlNode) {
            for abstract in root.children("w:abstractNum") {
                guard let id = abstract.attr("w:abstractNumId"), levels[id] == nil else { continue }
                var table: [Int: Level] = [:]
                for level in abstract.children("w:lvl") {
                    guard let ilvl = level.attr("w:ilvl").flatMap({ Int($0) }), table[ilvl] == nil else { continue }
                    table[ilvl] = Level(
                        format: level.child("w:numFmt")?.attr("w:val"),
                        start: level.child("w:start")?.attr("w:val").flatMap { Int($0) } ?? 1
                    )
                }
                levels[id] = table
            }
            for num in root.children("w:num") {
                guard let id = num.attr("w:numId"), abstractOfNum[id] == nil,
                      let abstract = num.child("w:abstractNumId")?.attr("w:val") else { continue }
                abstractOfNum[id] = abstract
            }
        }

        func level(numId: String, ilvl: Int) -> Level? {
            guard let abstract = abstractOfNum[numId] else { return nil }
            return levels[abstract]?[ilvl]
        }
    }

    // MARK: - Body

    struct NoteReference: Hashable {
        let id: String
        let isEndnote: Bool
    }

    private enum FieldState {
        case instruction
        case result
    }

    private struct Walker {
        let styles: StyleTable
        let numbering: NumberingTable?
        var writer = StructuredBlockWriter()
        private(set) var noteReferences: [NoteReference] = []
        private var seenReferences: Set<NoteReference> = []
        /// Field stack: shared across the whole part, kept across paragraphs and tables.
        private var fields: [FieldState] = []
        private var listCounters: [String: [Int: Int]] = [:]

        init(styles: StyleTable, numbering: NumberingTable?) {
            self.styles = styles
            self.numbering = numbering
        }

        /// Children of block containers (`w:body`, `w:sdtContent`, `w:txbxContent`) are emitted in order.
        mutating func blocks(of container: OfficeXmlNode) {
            for node in container.elements {
                switch node.name {
                case "w:p":
                    paragraphBlock(node)
                case "w:tbl":
                    writer.table(tableRows(node))
                case "w:sdt":
                    if let content = node.child("w:sdtContent") { blocks(of: content) }
                case "w:customXml", "w:sdtContent":
                    blocks(of: node)
                case "mc:AlternateContent":
                    if let choice = node.child("mc:Choice") { blocks(of: choice) }
                default:
                    continue
                }
            }
        }

        private mutating func paragraphBlock(_ paragraph: OfficeXmlNode) {
            var text = ""
            var boxes: [OfficeXmlNode] = []
            inline(paragraph, text: &text, boxes: &boxes)
            let properties = paragraph.child("w:pPr")

            if let level = headingLevel(properties) {
                writer.heading(level: level, text: text)
            } else if let list = listMarker(properties) {
                writer.listItem(depth: list.depth, marker: list.marker, text: text)
            } else {
                writer.paragraph(text)
            }
            // Paragraphs inside a text box each become their own block, placed after the enclosing paragraph.
            for box in boxes { blocks(of: box) }
        }

        // MARK: Paragraph classification

        private func headingLevel(_ properties: OfficeXmlNode?) -> Int? {
            if let own = properties?.child("w:outlineLvl")?.attr("w:val").flatMap({ Int($0) }), (0...8).contains(own) {
                return own + 1
            }
            let chain = styles.chain(from: properties?.child("w:pStyle")?.attr("w:val"))
            for style in chain {
                guard let name = style.name else { continue }
                if name == "title" { return 1 }
                if name.hasPrefix("heading "), let level = Int(name.dropFirst("heading ".count)), (1...9).contains(level),
                   name.count == "heading ".count + 1 {
                    return level
                }
            }
            for style in chain {
                if let level = style.outlineLevel, (0...8).contains(level) { return level + 1 }
            }
            return nil
        }

        private mutating func listMarker(_ properties: OfficeXmlNode?) -> (depth: Int, marker: String)? {
            guard let numPr = properties?.child("w:numPr"),
                  let numId = numPr.child("w:numId")?.attr("w:val"),
                  numId != "0", !numId.isEmpty else { return nil }
            let ilvl = max(numPr.child("w:ilvl")?.attr("w:val").flatMap { Int($0) } ?? 0, 0)
            guard let level = numbering?.level(numId: numId, ilvl: ilvl) else { return (ilvl, "- ") }
            switch level.format {
            case "bullet":
                return (ilvl, "- ")
            case "none":
                return nil
            default:
                var counters = listCounters[numId] ?? [:]
                let value = counters[ilvl].map { $0 + 1 } ?? level.start
                counters[ilvl] = value
                for deeper in counters.keys where deeper > ilvl { counters[deeper] = nil }
                listCounters[numId] = counters
                return (ilvl, "\(value). ")
            }
        }

        // MARK: Text within a paragraph

        private var inInstruction: Bool {
            fields.contains(.instruction)
        }

        private static let skipped: Set<String> = [
            "w:del", "w:moveFrom", "mc:Fallback", "w:pPr", "w:rPr", "w:delText", "w:instrText", "w:fldData",
            "w:footnoteRef", "w:endnoteRef", "w:sdtPr", "w:sdtEndPr",
        ]

        /// Output elements skipped while a field is in the "instruction" state (spec section 5).
        private static let fieldSuppressed: Set<String> = [
            "w:t", "w:tab", "w:br", "w:cr", "w:noBreakHyphen", "w:footnoteReference", "w:endnoteReference", "w:txbxContent",
        ]

        private mutating func inline(_ node: OfficeXmlNode, text: inout String, boxes: inout [OfficeXmlNode]) {
            for child in node.elements {
                if Self.skipped.contains(child.name) { continue }
                if inInstruction, Self.fieldSuppressed.contains(child.name) { continue }
                switch child.name {
                case "w:t":
                    text += child.textContent
                case "w:r":
                    if Self.isHidden(child) { continue }
                    inline(child, text: &text, boxes: &boxes)
                case "mc:AlternateContent":
                    if let choice = child.child("mc:Choice") { inline(choice, text: &text, boxes: &boxes) }
                case "w:fldChar":
                    switch child.attr("w:fldCharType") {
                    case "begin":
                        fields.append(.instruction)
                    case "separate":
                        if !fields.isEmpty { fields[fields.count - 1] = .result }
                    case "end":
                        _ = fields.popLast()
                    default:
                        break
                    }
                case "w:tab":
                    text += "\t"
                case "w:br", "w:cr":
                    text += "\n"
                case "w:noBreakHyphen":
                    text += "-"
                case "w:softHyphen", "w:sym":
                    continue
                case "w:footnoteReference", "w:endnoteReference":
                    guard let id = child.attr("w:id") else { continue }
                    let isEndnote = child.name == "w:endnoteReference"
                    text += isEndnote ? "[^e\(id)]" : "[^\(id)]"
                    let reference = NoteReference(id: id, isEndnote: isEndnote)
                    if seenReferences.insert(reference).inserted { noteReferences.append(reference) }
                case "w:txbxContent":
                    boxes.append(child)
                default:
                    inline(child, text: &text, boxes: &boxes)
                }
            }
        }

        /// A run whose `w:rPr` has `w:vanish` (with no `w:val`, or a value other than `0` / `false`) is skipped entirely.
        private static func isHidden(_ run: OfficeXmlNode) -> Bool {
            guard let vanish = run.child("w:rPr")?.child("w:vanish") else { return false }
            guard let value = vanish.attr("w:val") else { return true }
            return value != "0" && value != "false"
        }

        // MARK: Tables

        private mutating func tableRows(_ table: OfficeXmlNode) -> [[String]] {
            var rows: [[String]] = []
            for row in Self.collect(table, item: "w:tr") {
                var cells: [String] = []
                for cell in Self.collect(row, item: "w:tc") {
                    let properties = cell.child("w:tcPr")
                    var paragraphs: [String] = []
                    collectParagraphs(of: cell, into: &paragraphs)
                    if let merge = properties?.child("w:vMerge"), merge.attr("w:val") != "restart" {
                        cells.append("")
                    } else {
                        cells.append(StructuredTextFormat.cellText(paragraphs: paragraphs))
                    }
                    let span = properties?.child("w:gridSpan")?.attr("w:val").flatMap { Int($0) } ?? 1
                    if span > 1 { cells += Array(repeating: "", count: min(span - 1, 1_000)) }
                }
                rows.append(cells)
            }
            return rows
        }

        /// Rows of a table / cells of a row: direct children, or wrapped in `w:sdt` / `w:customXml`.
        private static func collect(_ node: OfficeXmlNode, item: String) -> [OfficeXmlNode] {
            var result: [OfficeXmlNode] = []
            for child in node.elements {
                switch child.name {
                case item:
                    result.append(child)
                case "w:sdt":
                    if let content = child.child("w:sdtContent") { result += collect(content, item: item) }
                case "w:customXml":
                    result += collect(child, item: item)
                default:
                    continue
                }
            }
            return result
        }

        /// Text of the paragraphs in a block container (no heading or list markers); nested tables are flattened into one paragraph: ` / ` between rows, `; ` between cells.
        mutating func collectParagraphs(of container: OfficeXmlNode, into paragraphs: inout [String]) {
            for node in container.elements {
                switch node.name {
                case "w:p":
                    var text = ""
                    var boxes: [OfficeXmlNode] = []
                    inline(node, text: &text, boxes: &boxes)
                    paragraphs.append(text)
                    for box in boxes { collectParagraphs(of: box, into: &paragraphs) }
                case "w:tbl":
                    paragraphs.append(flattenedTable(node))
                case "w:sdt":
                    if let content = node.child("w:sdtContent") { collectParagraphs(of: content, into: &paragraphs) }
                case "w:customXml", "w:sdtContent":
                    collectParagraphs(of: node, into: &paragraphs)
                case "mc:AlternateContent":
                    if let choice = node.child("mc:Choice") { collectParagraphs(of: choice, into: &paragraphs) }
                default:
                    continue
                }
            }
        }

        private mutating func flattenedTable(_ table: OfficeXmlNode) -> String {
            var rows: [String] = []
            for row in Self.collect(table, item: "w:tr") {
                var cells: [String] = []
                for cell in Self.collect(row, item: "w:tc") {
                    var paragraphs: [String] = []
                    collectParagraphs(of: cell, into: &paragraphs)
                    cells.append(
                        paragraphs
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                    )
                }
                rows.append(cells.joined(separator: "; "))
            }
            return rows.joined(separator: " / ")
        }
    }
}
