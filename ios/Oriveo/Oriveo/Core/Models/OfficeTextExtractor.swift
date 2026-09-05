import Foundation
import ZIPFoundation

nonisolated enum OfficeTextExtractor {

    static let supportedExtensions: Set<String> = ["docx", "xlsx", "pptx"]

    static func isOfficeFile(extension ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    static func extractText(
        from data: Data,
        fileExtension ext: String,
        budget: ArchiveExtractionBudget = .attachment(maxOutputBytes: FileExtractionLimits.maxBytes)
    ) throws -> String? {
        let normalized = ext.lowercased()
        guard supportedExtensions.contains(normalized) else { return nil }
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var reader = BoundedArchiveReader(budget: budget)
        switch normalized {
        case "docx": return try extractDocxText(archive, reader: &reader)
        case "xlsx": return try extractXlsxText(archive, reader: &reader)
        case "pptx": return try extractPptxText(archive, reader: &reader)
        default:     return nil
        }
    }

    // MARK: - DOCX

    private static func extractDocxText(_ archive: Archive, reader: inout BoundedArchiveReader) throws -> String {
        guard let xml = try readEntry(archive, path: "word/document.xml", reader: &reader) else { return "" }
        let withBreaks = xml.replacingOccurrences(of: "</w:p>", with: "\n</w:p>")
        return parseXMLText(withBreaks).collapseNewlines()
    }

    // MARK: - PPTX

    private static func extractPptxText(_ archive: Archive, reader: inout BoundedArchiveReader) throws -> String {
        let slideEntries = archive.sorted { $0.path < $1.path }
            .filter { $0.path.hasPrefix("ppt/slides/slide") && $0.path.hasSuffix(".xml") }
        var parts: [String] = []
        for entry in slideEntries {
            let xml = try reader.string(from: archive, entry: entry)
            let withBreaks = xml.replacingOccurrences(of: "</a:p>", with: "\n</a:p>")
            let text = parseXMLText(withBreaks).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - XLSX

    private static func extractXlsxText(_ archive: Archive, reader: inout BoundedArchiveReader) throws -> String {
        let sharedStrings: [String]
        if let ssXML = try readEntry(archive, path: "xl/sharedStrings.xml", reader: &reader) {
            sharedStrings = parseSharedStrings(ssXML)
        } else {
            sharedStrings = []
        }

        let sheetEntries = archive.sorted { $0.path < $1.path }
            .filter { $0.path.hasPrefix("xl/worksheets/sheet") && $0.path.hasSuffix(".xml") }
        var parts: [String] = []
        for entry in sheetEntries {
            let xml = try reader.string(from: archive, entry: entry)
            let sheetText = parseSheetXML(xml, sharedStrings: sharedStrings)
            if !sheetText.isEmpty { parts.append(sheetText) }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func parseSharedStrings(_ xml: String) -> [String] {
        let handler = SharedStringsHandler()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = handler
        parser.parse()
        return handler.strings
    }

    private static func parseSheetXML(_ xml: String, sharedStrings: [String]) -> String {
        let handler = SheetHandler(sharedStrings: sharedStrings)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = handler
        parser.parse()
        return handler.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }


    private static func readEntry(
        _ archive: Archive,
        path: String,
        reader: inout BoundedArchiveReader
    ) throws -> String? {
        guard let entry = archive[path] else { return nil }
        return try reader.string(from: archive, entry: entry)
    }


    private static func parseXMLText(_ xml: String) -> String {
        let handler = TextCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = handler
        parser.parse()
        return handler.text
    }
}

// MARK: - XMLParser Delegates

nonisolated private final class TextCollector: NSObject, XMLParserDelegate {
    var text = ""
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }
}

nonisolated private final class SharedStringsHandler: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var currentText = ""
    private var inSI = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { inSI = true; currentText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inSI { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == "si" { strings.append(currentText); inSI = false }
    }
}

nonisolated private final class SheetHandler: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var rows: [[String]] = []
    private var currentRow: [String] = []
    private var cellValue = ""
    private var cellType = ""
    private var inValue = false

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row": currentRow = []
        case "c":   cellType = attributes["t"] ?? ""; cellValue = ""
        case "v":   inValue = true; cellValue = ""
        default:    break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { cellValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch name {
        case "v": inValue = false
        case "c":
            if cellType == "s", let idx = Int(cellValue), idx < sharedStrings.count {
                currentRow.append(sharedStrings[idx])
            } else {
                currentRow.append(cellValue)
            }
        case "row": rows.append(currentRow)
        default: break
        }
    }
}

nonisolated private extension String {
    func collapseNewlines() -> String {
        replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
