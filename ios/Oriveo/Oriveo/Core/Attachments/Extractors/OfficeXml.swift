import Foundation
import ZIPFoundation

// Shared infrastructure for OOXML / ODF extraction (attachment extraction spec section 3.2 blocks and separators, 4A common OOXML, 14 deadline, 15 XML safety):
// small XML tree, zip package access (entry lookup, relationship resolution, DOCTYPE check), block joining, spreadsheet grid rendering.

// MARK: - XML tree

/// A parsed XML element. `name` is the normalized qualified name: known namespaces are replaced by fixed prefixes (`w:` `a:` `p:` `r:` `mc:` `x:` `office:` `text:` ...),
/// so the prefix actually used in the document does not affect matching; unknown namespaces keep their original prefix. `local` is the local name without the prefix.
nonisolated final class OfficeXmlNode {
    enum Child {
        case element(OfficeXmlNode)
        case text(String)
    }

    let name: String
    let local: String
    let attributes: [String: String]
    fileprivate(set) var children: [Child] = []

    init(name: String, local: String, attributes: [String: String]) {
        self.name = name
        self.local = local
        self.attributes = attributes
    }

    var elements: [OfficeXmlNode] {
        children.compactMap { child in
            if case .element(let node) = child { return node }
            return nil
        }
    }

    func attr(_ name: String) -> String? {
        attributes[name]
    }

    func child(_ name: String) -> OfficeXmlNode? {
        for case .element(let node) in children where node.name == name { return node }
        return nil
    }

    func children(_ name: String) -> [OfficeXmlNode] {
        elements.filter { $0.name == name }
    }

    func childByLocal(_ local: String) -> OfficeXmlNode? {
        for case .element(let node) in children where node.local == local { return node }
        return nil
    }

    /// Find the first descendant named `name` in document order (excluding self).
    func firstDescendant(_ name: String) -> OfficeXmlNode? {
        for case .element(let node) in children {
            if node.name == name { return node }
            if let found = node.firstDescendant(name) { return found }
        }
        return nil
    }

    /// Concatenate the character data of all descendants in order.
    var textContent: String {
        var result = ""
        appendText(into: &result)
        return result
    }

    private func appendText(into result: inout String) {
        for child in children {
            switch child {
            case .text(let text): result += text
            case .element(let node): node.appendText(into: &result)
            }
        }
    }
}

nonisolated enum OfficeXmlTree {
    /// Namespace URI -> fixed prefix. The Transitional and Strict URI sets map to the same prefix.
    static let knownNamespaces: [String: String] = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main": "w",
        "http://purl.oclc.org/ooxml/wordprocessingml/main": "w",
        "http://schemas.openxmlformats.org/drawingml/2006/main": "a",
        "http://purl.oclc.org/ooxml/drawingml/main": "a",
        "http://schemas.openxmlformats.org/presentationml/2006/main": "p",
        "http://purl.oclc.org/ooxml/presentationml/main": "p",
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main": "x",
        "http://purl.oclc.org/ooxml/spreadsheetml/main": "x",
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships": "r",
        "http://purl.oclc.org/ooxml/officeDocument/relationships": "r",
        "http://schemas.openxmlformats.org/markup-compatibility/2006": "mc",
        "http://schemas.openxmlformats.org/package/2006/relationships": "pr",
        "urn:oasis:names:tc:opendocument:xmlns:office:1.0": "office",
        "urn:oasis:names:tc:opendocument:xmlns:text:1.0": "text",
        "urn:oasis:names:tc:opendocument:xmlns:table:1.0": "table",
        "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0": "draw",
        "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0": "presentation",
        "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0": "svg",
    ]

    /// Parse one XML part (external entities are not resolved; DOCTYPE was already blocked when reading the entry). If the root element does not close completely -> `corrupted_file`.
    static func parse(_ data: Data) throws -> OfficeXmlNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = builder
        let succeeded = parser.parse()
        // Namespace warnings such as undeclared prefixes are not fatal: parsing counts as successful as long as the root element closes completely.
        guard let root = builder.root, succeeded || builder.rootClosed else {
            throw ExtractionError(code: .corruptedFile, underlying: "xml parse failed: \(String(describing: parser.parserError))")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: OfficeXmlNode?
        var rootClosed = false
        private var stack: [OfficeXmlNode] = []
        private var scopes: [[String: String]] = [[:]]
        private var pendingText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            flushText()
            var scope = scopes.last ?? [:]
            var plain: [(String, String)] = []
            for (key, value) in attributeDict {
                if key == "xmlns" {
                    scope[""] = value
                } else if key.hasPrefix("xmlns:") {
                    scope[String(key.dropFirst(6))] = value
                } else {
                    plain.append((key, value))
                }
            }
            scopes.append(scope)
            let (name, local) = Self.canonical(elementName, scope: scope, isAttribute: false)
            var attributes: [String: String] = [:]
            for (key, value) in plain {
                attributes[Self.canonical(key, scope: scope, isAttribute: true).name] = value
            }
            let node = OfficeXmlNode(name: name, local: local, attributes: attributes)
            if let parent = stack.last {
                parent.children.append(.element(node))
            } else if root == nil {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            pendingText += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            pendingText += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            flushText()
            if let node = stack.popLast(), node === root { rootClosed = true }
            if scopes.count > 1 { scopes.removeLast() }
        }

        private func flushText() {
            guard !pendingText.isEmpty else { return }
            stack.last?.children.append(.text(pendingText))
            pendingText = ""
        }

        static func canonical(_ qualified: String, scope: [String: String], isAttribute: Bool) -> (name: String, local: String) {
            guard let colon = qualified.firstIndex(of: ":") else {
                // Unprefixed attributes belong to no namespace; unprefixed elements belong to the default namespace.
                if !isAttribute, let uri = scope[""], let known = knownNamespaces[uri] {
                    return ("\(known):\(qualified)", qualified)
                }
                return (qualified, qualified)
            }
            let prefix = String(qualified[..<colon])
            let local = String(qualified[qualified.index(after: colon)...])
            if let uri = scope[prefix], let known = knownNamespaces[uri] {
                return ("\(known):\(local)", local)
            }
            return (qualified, local)
        }
    }
}

// MARK: - Zip package

nonisolated struct OfficeRelationship {
    let id: String
    let type: String
    /// Already resolved to a package path per spec section 4A.
    let target: String

    func hasType(_ suffix: String) -> Bool {
        type.hasSuffix(suffix)
    }
}

/// OOXML / ODF zip package: entries are looked up exactly first, then case-insensitively; the deadline is checked before reading each XML part (spec section 14, zip entries), and the DOCTYPE check (section 15) runs after reading.
nonisolated final class OfficePackage {
    let deadline: ExtractionDeadline
    private let archive: Archive
    private var reader: BoundedArchiveReader
    private let exact: [String: Entry]
    private let folded: [String: Entry]
    let paths: [String]

    init(data: Data, budget: ArchiveExtractionBudget, deadline: ExtractionDeadline) throws {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw ExtractionError(code: .corruptedFile, underlying: "not a zip archive")
        }
        self.archive = archive
        self.reader = BoundedArchiveReader(budget: budget)
        self.deadline = deadline
        var exact: [String: Entry] = [:]
        var folded: [String: Entry] = [:]
        var paths: [String] = []
        for entry in archive where entry.type == .file {
            if exact[entry.path] == nil { exact[entry.path] = entry }
            let key = entry.path.lowercased()
            if folded[key] == nil { folded[key] = entry }
            paths.append(entry.path)
        }
        self.exact = exact
        self.folded = folded
        self.paths = paths
    }

    func hasEntry(_ path: String) -> Bool {
        entry(path) != nil
    }

    private func entry(_ path: String) -> Entry? {
        exact[path] ?? folded[path.lowercased()]
    }

    /// Read the bytes of an XML part; returns nil if the entry does not exist.
    func xmlData(_ path: String) throws -> Data? {
        try deadline.check()
        guard let entry = entry(path) else { return nil }
        do {
            return try reader.xmlData(from: archive, entry: entry)
        } catch let error as BoundedArchiveError {
            throw error
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError(code: .corruptedFile, underlying: "zip entry \(path): \(error)")
        }
    }

    /// Read and parse an XML part; returns nil if the entry does not exist. The deadline is checked once more after parsing (parsing a single part is uninterruptible).
    func xml(_ path: String) throws -> OfficeXmlNode? {
        guard let data = try xmlData(path) else { return nil }
        let node = try OfficeXmlTree.parse(data)
        try deadline.check()
        return node
    }

    /// The relationships file of part `a/b/c.xml` is `a/b/_rels/c.xml.rels`; for the package root (`""`) it is `_rels/.rels`.
    static func relationshipsPath(for part: String) -> String {
        guard let slash = part.lastIndex(of: "/") else { return "_rels/\(part).rels" }
        let directory = part[..<slash]
        let file = part[part.index(after: slash)...]
        return "\(directory)/_rels/\(file).rels"
    }

    /// A relationship Target resolves against the source part's directory, handling `.` and `..`; one starting with `/` is an absolute path from the package root.
    static func resolve(target: String, from part: String) -> String {
        var segments: [String]
        var remainder = Substring(target)
        if remainder.hasPrefix("/") {
            segments = []
            while remainder.hasPrefix("/") { remainder = remainder.dropFirst() }
        } else {
            segments = part.split(separator: "/", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
        for segment in remainder.split(separator: "/", omittingEmptySubsequences: false) {
            switch segment {
            case ".", "":
                continue
            case "..":
                if !segments.isEmpty { segments.removeLast() }
            default:
                segments.append(String(segment))
            }
        }
        return segments.joined(separator: "/")
    }

    /// Relationship table of `part` (ignoring `TargetMode="External"`); returns empty if the relationships file does not exist.
    func relationships(of part: String) throws -> [OfficeRelationship] {
        guard let root = try xml(Self.relationshipsPath(for: part)) else { return [] }
        return root.elements.compactMap { node in
            guard node.local == "Relationship",
                  let target = node.attr("Target"),
                  node.attr("TargetMode")?.caseInsensitiveCompare("External") != .orderedSame else { return nil }
            return OfficeRelationship(
                id: node.attr("Id") ?? "",
                type: node.attr("Type") ?? "",
                target: Self.resolve(target: target, from: part)
            )
        }
    }

    /// The relationship in the package-root `_rels/.rels` whose Type ends with `/officeDocument`; use `fallback` if none is found.
    func mainPart(fallback: String) throws -> String {
        try relationships(of: "").first { $0.hasType("/officeDocument") }?.target ?? fallback
    }
}

// MARK: - Block joining (spec section 3.2)

/// Block sequence of structured output. Adjacent blocks get a blank line between them if either is a heading, table, section heading or notes heading, otherwise just a line break; finally normalized per spec section 3.1.
nonisolated struct StructuredBlockWriter {
    private var output = ""
    private var previousSpaced = false
    private var isEmpty = true

    private mutating func append(_ text: String, spaced: Bool, blankBefore: Bool = false) {
        if !isEmpty {
            output += (spaced || previousSpaced || blankBefore) ? "\n\n" : "\n"
        }
        output += text
        previousSpaced = spaced
        isEmpty = false
    }

    /// Paragraph: trim leading/trailing spaces and `\t`, drop if empty; inner `\n` is kept. `blankBefore` is used for the first entry of the footnote area.
    mutating func paragraph(_ text: String, blankBefore: Bool = false) {
        let trimmed = Self.trimSpacesAndTabs(text)
        guard !trimmed.isEmpty else { return }
        append(trimmed, spaced: false, blankBefore: blankBefore)
    }

    /// Heading: `#` x min(level, 6) + space + text; `\n` `\t` in the text become spaces, then trim; drop if empty.
    mutating func heading(level: Int, text: String) {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        append(String(repeating: "#", count: min(max(level, 1), 6)) + " " + cleaned, spaced: true)
    }

    /// List item: two spaces x depth + marker + text (`\n` becomes a space); drop if the text is empty.
    mutating func listItem(depth: Int, marker: String, text: String) {
        let cleaned = Self.trimSpacesAndTabs(text.replacingOccurrences(of: "\n", with: " "))
        guard !cleaned.isEmpty else { return }
        append(String(repeating: "  ", count: max(depth, 0)) + marker + cleaned, spaced: false)
    }

    /// Table: the cells of `rows` were already processed by `StructuredTextFormat.cellText`. `extraOmittedColumns` is the number of columns the caller already cut.
    mutating func table(_ rows: [[String]], extraOmittedColumns: Int = 0) {
        guard let block = StructuredTextFormat.table(rows) else { return }
        switch block {
        case .paragraph(let text):
            paragraph(text)
        case .table(let text, let omitted):
            append(text, spaced: true)
            let total = omitted + extraOmittedColumns
            if total > 0 { paragraph(StructuredTextFormat.omittedColumnsNote(total)) }
        }
    }

    /// Section heading (`## Sheet: ...` / `## Slide ...`).
    mutating func section(_ title: String) {
        append(title, spaced: true)
    }

    /// Notes heading `### Notes`.
    mutating func notesHeading() {
        append("### Notes", spaced: true)
    }

    func render() -> String {
        StructuredTextFormat.normalize(output)
    }

    static func trimSpacesAndTabs(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first == " " || first == "\t" { slice.removeFirst() }
        while let last = slice.last, last == " " || last == "\t" { slice.removeLast() }
        return String(slice)
    }
}

// MARK: - Spreadsheet grid (spec section 6 range and empty rows, 9 ODS)

/// Sparse cells (row and column numbers both start at 1) -> table. Only the minimal to maximal row and minimal to maximal column of non-empty cells are output;
/// consecutive empty rows in the range collapse into one empty table row (output row by row when `trimToUsedRange` is false); beyond 50 columns only the first 50 are kept, and `fullWidth` gives the full width used to compute the omitted column count.
nonisolated struct SpreadsheetGrid {
    private(set) var rows: [Int: [Int: String]] = [:]
    private(set) var maxColumn = 0

    var isEmpty: Bool { rows.isEmpty }

    mutating func set(row: Int, column: Int, text: String) {
        guard !text.isEmpty else { return }
        rows[row, default: [:]][column] = text
        maxColumn = max(maxColumn, column)
    }

    /// Only record the width (the part of repeated cells beyond column 50 does not land, but counts toward the used range).
    mutating func extendWidth(to column: Int) {
        maxColumn = max(maxColumn, column)
    }

    /// When `trimToUsedRange` is false, counting starts at row 1 column 1 (ODT / ODP tables).
    func write(into writer: inout StructuredBlockWriter, trimToUsedRange: Bool = true) {
        guard !rows.isEmpty else { return }
        let rowNumbers = rows.keys.sorted()
        let minColumn = trimToUsedRange ? (rows.values.flatMap(\.keys).min() ?? 1) : 1
        let firstRow = trimToUsedRange ? rowNumbers[0] : 1
        let width = maxColumn - minColumn + 1
        let kept = min(width, StructuredTextFormat.maxTableColumns)

        var table: [[String]] = []
        var previous = firstRow - 1
        for number in rowNumbers {
            if number > previous + 1 {
                // ODS merges into one empty table row; empty rows in the middle of ODT / ODP tables are not merged and are output row by row
                let gap = trimToUsedRange ? 1 : number - previous - 1
                table.append(contentsOf: Array(repeating: Array(repeating: "", count: kept), count: gap))
            }
            let cells = rows[number] ?? [:]
            table.append((0..<kept).map { cells[minColumn + $0] ?? "" })
            previous = number
        }
        writer.table(table, extraOmittedColumns: width - kept)
    }
}
