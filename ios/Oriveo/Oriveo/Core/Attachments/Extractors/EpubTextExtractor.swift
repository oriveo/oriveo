import Foundation
import ZIPFoundation

enum EpubTextExtractor {
    static func extract(
        data: Data,
        budget: ArchiveExtractionBudget = .attachment(maxOutputBytes: FileExtractionLimits.maxBytes)
    ) throws -> String {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw ExtractionError(code: .corruptedFile)
        }
        var reader = BoundedArchiveReader(budget: budget)

        guard let containerXml = try readString(archive, path: "META-INF/container.xml", reader: &reader) else {
            throw ExtractionError(code: .corruptedFile)
        }
        guard let opfPath = parseOpfPath(containerXml) else {
            throw ExtractionError(code: .corruptedFile)
        }

        guard let opfXml = try readString(archive, path: opfPath, reader: &reader) else {
            throw ExtractionError(code: .corruptedFile)
        }
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let opfHandler = OpfHandler(opfDir: opfDir)
        let parser = XMLParser(data: Data(opfXml.utf8))
        parser.delegate = opfHandler
        parser.parse()

        var parts: [String] = []
        for href in opfHandler.spineHrefs {
            if let xhtml = try readString(archive, path: href, reader: &reader),
               let text = try? HtmlTextExtractor.extract(data: Data(xhtml.utf8)) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { parts.append(t) }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func readString(
        _ archive: Archive,
        path: String,
        reader: inout BoundedArchiveReader
    ) throws -> String? {
        guard let entry = archive[path] else { return nil }
        return try reader.string(from: archive, entry: entry)
    }

    private static func parseOpfPath(_ containerXml: String) -> String? {
        let pattern = #"full-path="([^"]+)""#
        guard let range = containerXml.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(containerXml[range])
        return match.replacingOccurrences(of: "full-path=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
    }

    private final class OpfHandler: NSObject, XMLParserDelegate {
        let opfDir: String
        var manifest: [String: String] = [:]    // id -> href
        var spineRefs: [String] = []
        var spineHrefs: [String] { spineRefs.compactMap { manifest[$0] }.map { resolve($0) } }

        init(opfDir: String) {
            self.opfDir = opfDir
        }

        private func resolve(_ href: String) -> String {
            opfDir.isEmpty ? href : "\(opfDir)/\(href)"
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "item":
                if let id = attributes["id"], let href = attributes["href"] {
                    manifest[id] = href
                }
            case "itemref":
                if let idref = attributes["idref"] {
                    spineRefs.append(idref)
                }
            default: break
            }
        }
    }
}
