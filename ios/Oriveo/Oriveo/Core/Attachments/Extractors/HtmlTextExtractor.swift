import Foundation
import SwiftSoup

/// HTML extraction (attachment extraction spec section 8): turn bytes into a string per spec section 8 "Decoding", hand it to SwiftSoup (HTML5 tree construction),
/// walk from `<body>` with the simplified innerText algorithm, then apply section 3.1 normalization. Never triggers WebKit.
nonisolated enum HtmlTextExtractor {
    static let metaSniffLimit = 1_024

    static func extract(
        data: Data,
        uiLanguage: ExtractionUILanguage = .en,
        deadline: ExtractionDeadline = ExtractionDeadline()
    ) throws -> String {
        let html = try decode([UInt8](data), uiLanguage: uiLanguage)
        return try extract(html: html, deadline: deadline)
    }

    /// Decoded HTML string -> normalized output (each EPUB chapter also goes through here).
    static func extract(html: String, deadline: ExtractionDeadline = ExtractionDeadline()) throws -> String {
        let document: Document
        do {
            document = try SwiftSoup.parse(terminateLegacyEntities(html))
        } catch {
            throw ExtractionError(code: .corruptedFile, underlying: "html parse failed: \(error)")
        }
        // Parsing is one uninterruptible call; check the deadline after it returns (spec section 14).
        try deadline.check()
        let root: Element = document.body() ?? document
        var sink = Sink(maxNewlines: 2)
        for child in root.getChildNodes() {
            render(child, context: Context(), into: &sink)
        }
        return StructuredTextFormat.normalize(sink.out)
    }

    // MARK: - Legacy entities without a semicolon (spec section 8 "Entities")

    /// The 106 legacy named entities HTML5 allows without a semicolon.
    private static let legacyEntityNames: [[UInt8]] = """
        AElig AMP Aacute Acirc Agrave Aring Atilde Auml COPY Ccedil ETH Eacute Ecirc Egrave Euml GT Iacute Icirc \
        Igrave Iuml LT Ntilde Oacute Ocirc Ograve Oslash Otilde Ouml QUOT REG THORN Uacute Ucirc Ugrave Uuml Yacute \
        aacute acirc acute aelig agrave amp aring atilde auml brvbar ccedil cedil cent copy curren deg divide eacute \
        ecirc egrave eth euml frac12 frac14 frac34 gt iacute icirc iexcl igrave iquest iuml laquo lt macr micro \
        middot nbsp not ntilde oacute ocirc ograve ordf ordm oslash otilde ouml para plusmn pound quot raquo reg \
        sect shy sup1 sup2 sup3 szlig thorn times uacute ucirc ugrave uml uuml yacute yen yuml
        """.split(separator: " ").map { Array($0.utf8) }.sorted { $0.count > $1.count }

    /// SwiftSoup 2.13.9 does not recognize legacy entities without a semicolon in text (such as `&copy` in `&copy&hellip;`), while HTML5 tree construction
    /// decodes by the longest legacy entity-name prefix. Before parsing, add the semicolon to such references so the parser decodes with the full HTML5 entity table;
    /// attributes and scripts get them too, but that content is not output.
    static func terminateLegacyEntities(_ html: String) -> String {
        let bytes = Array(html.utf8)
        guard bytes.contains(UInt8(ascii: "&")) else { return html }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count + 16)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            result.append(byte)
            index += 1
            guard byte == UInt8(ascii: "&"), index < bytes.count, isASCIILetter(bytes[index]) else { continue }
            var end = index
            while end < bytes.count, isASCIILetter(bytes[end]) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end]) {
                end += 1
            }
            let name = bytes[index..<end]
            if end < bytes.count, bytes[end] == UInt8(ascii: ";"), Entities.isNamedEntity(name) { continue }
            guard let legacy = legacyEntityNames.first(where: { name.starts(with: $0) }) else { continue }
            result += legacy
            result.append(UInt8(ascii: ";"))
            index += legacy.count
            if index < bytes.count, bytes[index] == UInt8(ascii: ";") { index += 1 }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    // MARK: - Decoding (spec section 8)

    private enum DeclaredCharset {
        case utf8
        case candidate(TextCharsetCandidate)
    }

    /// BOM -> the first `<meta ... charset=...>` declaration in the first 1024 bytes (strict decode) -> spec section 4 algorithm.
    static func decode(_ bytes: [UInt8], uiLanguage: ExtractionUILanguage) throws -> String {
        let hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF]) || bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF])
        if !hasBOM, let label = metaCharsetLabel(bytes.prefix(metaSniffLimit)), let declared = declaredCharset(label) {
            switch declared {
            case .utf8:
                if let text = String(validating: bytes, as: UTF8.self) { return text }
            case .candidate(let candidate):
                if let text = PlainTextExtractor.decode(bytes[...], as: candidate) { return text }
            }
        }
        return try PlainTextExtractor.decode(bytes, uiLanguage: uiLanguage)
    }

    private static let metaCharsetPattern = try! NSRegularExpression(
        pattern: #"<meta\b[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9._:\-]+)"#,
        options: [.caseInsensitive]
    )

    private static func metaCharsetLabel(_ prefix: ArraySlice<UInt8>) -> String? {
        // Map byte by byte to Latin-1 code points, used only to find the ASCII declaration.
        let head = String(String.UnicodeScalarView(prefix.map { Unicode.Scalar($0) }))
        let range = NSRange(head.startIndex..., in: head)
        guard let match = metaCharsetPattern.firstMatch(in: head, range: range),
              let labelRange = Range(match.range(at: 1), in: head) else { return nil }
        return String(head[labelRange])
    }

    private static func declaredCharset(_ label: String) -> DeclaredCharset? {
        switch label.lowercased() {
        case "gbk", "gb2312", "x-gbk", "gb18030": return .candidate(.gb18030)
        case "shift_jis", "sjis", "ms932": return .candidate(.shiftJIS)
        case "big5": return .candidate(.big5)
        case "euc-kr", "ks_c_5601-1987": return .candidate(.eucKR)
        case "iso-8859-1", "latin1", "ascii", "us-ascii", "windows-1252": return .candidate(.windows1252)
        case "windows-1251": return .candidate(.windows1251)
        case "utf-8", "utf8": return .utf8
        default: return nil
        }
    }

    // MARK: - EPUB preprocessing (spec section 10, step 5)

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]

    private static let selfClosingPattern = try! NSRegularExpression(
        pattern: #"<([A-Za-z][A-Za-z0-9:_.\-]*)((?:\s[^<>]*?)?)\s*/>"#
    )

    /// Rewrite the self-closing form `<tag .../>` of non-void elements to `<tag ...></tag>` so `<title/>` and `<script/>` do not swallow the text after them.
    static func expandSelfClosingTags(_ html: String) -> String {
        let source = html as NSString
        var result = ""
        var cursor = 0
        for match in selfClosingPattern.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1))
            guard !voidElements.contains(name.lowercased()) else { continue }
            let attributes = match.range(at: 2).location == NSNotFound ? "" : source.substring(with: match.range(at: 2))
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "<\(name)\(attributes)></\(name)>"
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    // MARK: - Traversal (spec section 8)

    private static let discardedElements: Set<String> = [
        "script", "style", "noscript", "template", "head", "title", "svg", "math", "iframe", "object", "embed",
        "canvas", "audio", "video", "select", "rp",
    ]

    private static let doubleBreakElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table", "hr", "dl", "figure", "address",
    ]

    private static let singleBreakElements: Set<String> = [
        "div", "li", "dt", "dd", "section", "article", "header", "footer", "nav", "aside", "main", "figcaption",
        "caption", "tr", "form", "fieldset", "legend", "details", "summary", "center",
    ]

    private struct Context {
        var inPre = false
        /// Number of enclosing `li` elements (list item indent depth).
        var listDepth = 0
        var inTableCell = false
        /// Inside list item text: `br` emits a space (spec section 8 details).
        var inListItem = false
    }

    /// Output buffer: newline requests merge by maximum, requests at the start and end of the whole text are dropped, and spaces produced by compression next to a request are removed.
    private struct Sink {
        let maxNewlines: Int
        var out = ""
        /// Newline request not yet landed (a request at the end of the text is not output; list items use it to pass the request to the outer level).
        private(set) var pending = 0
        /// Largest request received before the first output (a request at the start of the text is not output; list items use it to pass the request to the outer level).
        private(set) var leading = 0
        private var started = false
        private var trailingCollapsedSpace = false

        init(maxNewlines: Int) {
            self.maxNewlines = maxNewlines
        }

        mutating func request(_ count: Int) {
            if trailingCollapsedSpace {
                out.removeLast()
                trailingCollapsedSpace = false
            }
            pending = max(pending, min(count, maxNewlines))
            if !started { leading = pending }
        }

        mutating func collapsed(_ text: String) {
            append(HtmlTextExtractor.collapseWhitespace(text), collapsible: true)
        }

        mutating func raw(_ text: String) {
            append(text, collapsible: false)
        }

        private mutating func append(_ text: String, collapsible: Bool) {
            var piece = Substring(text)
            if collapsible, piece.first == " ", pending > 0 || !started || trailingCollapsedSpace {
                piece.removeFirst()
            }
            guard !piece.isEmpty else { return }
            if pending > 0 {
                if started { out += String(repeating: "\n", count: pending) }
                pending = 0
            }
            out += piece
            started = true
            trailingCollapsedSpace = collapsible && piece.last == " "
        }
    }

    /// Compress `[ \t\n\r\f]+` in a text node to one space.
    fileprivate static func collapseWhitespace(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "\r", "\u{0C}":
                if !inRun { scalars.append(" ") }
                inRun = true
            default:
                scalars.append(scalar)
                inRun = false
            }
        }
        return String(scalars)
    }

    private static func render(_ node: Node, context: Context, into sink: inout Sink) {
        if let text = node as? TextNode {
            if context.inPre { sink.raw(text.getWholeText()) } else { sink.collapsed(text.getWholeText()) }
            return
        }
        guard let element = node as? Element else { return }
        let tag = element.tagName().lowercased()
        if discardedElements.contains(tag) || element.hasAttr("hidden") { return }
        if let epubType = try? element.attr("epub:type"), epubType.contains("pagebreak") { return }

        switch tag {
        case "br":
            if context.inListItem { sink.collapsed(" ") } else { sink.raw("\n") }
        case "hr":
            sink.request(2)
            sink.raw("---")
            sink.request(2)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            let text = inlineText(of: element.getChildNodes(), context: context)
            sink.request(2)
            // A heading inside a cell is output as ordinary text (spec section 8 details).
            if !text.isEmpty { sink.raw(context.inTableCell ? text : String(repeating: "#", count: min(level, 6)) + " " + text) }
            sink.request(2)
        case "li":
            renderListItem(element, context: context, into: &sink)
        case "ul", "ol":
            let breaks = context.listDepth > 0 ? 1 : 2
            sink.request(breaks)
            renderChildren(of: element, context: context, into: &sink)
            sink.request(breaks)
        case "table":
            renderTable(element, context: context, into: &sink)
        case "pre":
            var inner = context
            inner.inPre = true
            sink.request(2)
            renderChildren(of: element, context: inner, into: &sink)
            sink.request(2)
        default:
            let breaks = doubleBreakElements.contains(tag) ? 2 : (singleBreakElements.contains(tag) ? 1 : 0)
            if breaks > 0 { sink.request(breaks) }
            renderChildren(of: element, context: context, into: &sink)
            if breaks > 0 { sink.request(breaks) }
        }
    }

    private static func renderChildren(of element: Element, context: Context, into sink: inout Sink) {
        for child in element.getChildNodes() {
            render(child, context: context, into: &sink)
        }
    }

    private static func subRender(_ nodes: [Node], context: Context, maxNewlines: Int = 2) -> String {
        var sink = Sink(maxNewlines: maxNewlines)
        for node in nodes {
            render(node, context: context, into: &sink)
        }
        return sink.out
    }

    /// Heading and list item text: replace `\n` and `\t` with spaces, then trim.
    private static func inlineText(of nodes: [Node], context: Context) -> String {
        subRender(nodes, context: context)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    // MARK: List items

    private static func renderListItem(_ item: Element, context: Context, into sink: inout Sink) {
        let indent = String(repeating: "  ", count: context.listDepth)
        let marker = listMarker(for: item)
        var nested = context
        nested.listDepth += 1
        var itemContext = context
        itemContext.inListItem = true
        var pendingNodes: [Node] = []
        var markerUsed = false

        // Newline requests from block elements inside the item still merge by maximum as usual (passed to the outer level); the marker is written before the first text, and later lines are indented to align.
        func flushText(into sink: inout Sink) {
            defer { pendingNodes.removeAll() }
            var inner = Sink(maxNewlines: 2)
            for node in pendingNodes { render(node, context: itemContext, into: &inner) }
            let text = inner.out
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " "))
            guard !text.isEmpty else { return }
            var lines: [String] = []
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " "))
                guard !trimmed.isEmpty else {
                    lines.append("")
                    continue
                }
                lines.append(indent + (markerUsed ? "  " : marker) + trimmed)
                markerUsed = true
            }
            if inner.leading > 0 { sink.request(inner.leading) }
            sink.raw(lines.joined(separator: "\n"))
            sink.request(max(inner.pending, 1))
        }

        sink.request(1)
        for child in item.getChildNodes() {
            if let list = child as? Element, ["ul", "ol"].contains(list.tagName().lowercased()) {
                flushText(into: &sink)
                render(list, context: nested, into: &sink)
            } else {
                pendingNodes.append(child)
            }
        }
        flushText(into: &sink)
        sink.request(1)
    }

    private static func listMarker(for item: Element) -> String {
        guard let parent = item.parent(), parent.tagName().lowercased() == "ol" else { return "- " }
        let start = (try? parent.attr("start")).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
        let siblings = parent.children().array().filter { $0.tagName().lowercased() == "li" }
        let index = siblings.firstIndex { $0 === item } ?? 0
        return "\(start + index). "
    }

    // MARK: Tables

    private static func tableRows(of table: Element) -> [[Element]] {
        var rows: [Element] = []
        for child in table.children().array() {
            switch child.tagName().lowercased() {
            case "tr": rows.append(child)
            case "thead", "tbody", "tfoot":
                rows += child.children().array().filter { $0.tagName().lowercased() == "tr" }
            default: break
            }
        }
        return rows.map { row in
            row.children().array().filter { ["td", "th"].contains($0.tagName().lowercased()) }
        }
    }

    private static func span(_ cell: Element, _ name: String) -> Int {
        (try? cell.attr(name)).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
    }

    private static func flattenedCellText(_ cell: Element, context: Context) -> String {
        subRender(cell.getChildNodes(), context: context)
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func renderTable(_ table: Element, context: Context, into sink: inout Sink) {
        var cellContext = context
        cellContext.inTableCell = true
        cellContext.inListItem = false
        let rows = tableRows(of: table)
        // A table caption is output as an ordinary block before the table.
        for caption in table.children().array() where caption.tagName().lowercased() == "caption" {
            render(caption, context: context, into: &sink)
        }

        if context.inTableCell {
            // A table nested in a cell is flattened into one paragraph (spec section 3.3): ` / ` between rows, `; ` between cells, and multiple paragraphs in an inner cell are joined with one space.
            let flattened = rows
                .map { row in row.map { flattenedCellText($0, context: cellContext) }.joined(separator: "; ") }
                .joined(separator: " / ")
            sink.request(2)
            if !flattened.isEmpty { sink.raw(flattened) }
            sink.request(2)
            return
        }

        let spanned = rows.joined().contains { span($0, "colspan") > 1 || span($0, "rowspan") > 1 }
        if spanned {
            // With merged cells: no pipe table; one line per row, `\t` between cells.
            let lines = rows
                .map { row in row.map { inlineText(of: $0.getChildNodes(), context: cellContext) } }
                .filter { $0.contains { !$0.isEmpty } }
                .map { $0.joined(separator: "\t") }
            sink.request(2)
            if !lines.isEmpty { sink.raw(lines.joined(separator: "\n")) }
            sink.request(2)
            return
        }

        let cells = rows.map { row in
            row.map { cell in
                let text = subRender(cell.getChildNodes(), context: cellContext, maxNewlines: 1)
                return StructuredTextFormat.cellText(paragraphs: text.components(separatedBy: "\n"))
            }
        }
        sink.request(2)
        switch StructuredTextFormat.table(cells) {
        case .table(let text, let omitted):
            sink.raw(text)
            if omitted > 0 {
                sink.request(2)
                sink.raw(StructuredTextFormat.omittedColumnsNote(omitted))
            }
        case .paragraph(let text):
            sink.raw(text)
        case nil:
            break
        }
        sink.request(2)
    }
}
