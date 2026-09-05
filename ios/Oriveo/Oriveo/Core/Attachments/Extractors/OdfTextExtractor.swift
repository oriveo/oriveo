import Foundation
import ZIPFoundation

enum OdfTextExtractor {
    static func extract(
        data: Data,
        fileExtension: String,
        budget: ArchiveExtractionBudget = .attachment(maxOutputBytes: FileExtractionLimits.maxBytes)
    ) throws -> String {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw ExtractionError(code: .corruptedFile)
        }
        guard let entry = archive["content.xml"] else {
            throw ExtractionError(code: .corruptedFile)
        }
        var reader = BoundedArchiveReader(budget: budget)
        let xml = try reader.string(from: archive, entry: entry)
        let withBreaks = xml.replacingOccurrences(of: "</text:p>", with: "\n</text:p>")
        let handler = TextCollector()
        let parser = XMLParser(data: Data(withBreaks.utf8))
        parser.delegate = handler
        guard parser.parse() else {
            throw ExtractionError(code: .corruptedFile)
        }
        return handler.text
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class TextCollector: NSObject, XMLParserDelegate {
        var text = ""
        func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    }
}
