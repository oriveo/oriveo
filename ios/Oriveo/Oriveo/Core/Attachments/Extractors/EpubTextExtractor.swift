import Foundation
import ZIPFoundation

/// EPUB extraction (attachment extraction spec section 10): DRM check -> OPF path from container.xml -> manifest / spine ->
/// decode each chapter per spec section 8, rewrite self-closing tags, parse and emit -> blank line between chapters -> section 3.1 normalization.
nonisolated enum EpubTextExtractor {
    /// Font obfuscation algorithms: not counted as DRM.
    static let fontObfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]
    static let drmMarkerEntries = ["META-INF/rights.xml", "META-INF/license.lcpl", "META-INF/sinf.xml"]
    static let chapterMediaTypes: Set<String> = ["application/xhtml+xml", "text/html"]

    static func extract(
        data: Data,
        uiLanguage: ExtractionUILanguage = .en,
        budget: ArchiveExtractionBudget = .attachment(maxOutputBytes: FileExtractionLimits.maxBytes),
        deadline: ExtractionDeadline = ExtractionDeadline()
    ) throws -> String {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw ExtractionError(code: .corruptedFile)
        }
        var reader = BoundedArchiveReader(budget: budget)
        let index = EntryIndex(archive)

        // 1. DRM
        if drmMarkerEntries.contains(where: { index.entry($0) != nil }) {
            throw ExtractionError(code: .unsupportedFormat, underlying: "epub_drm")
        }
        if let encryption = index.entry("META-INF/encryption.xml") {
            let algorithms = XmlScan.attributes(in: try reader.data(from: archive, entry: encryption), element: "EncryptionMethod", attribute: "Algorithm")
            try deadline.check()
            if algorithms.contains(where: { !fontObfuscationAlgorithms.contains($0) }) {
                throw ExtractionError(code: .unsupportedFormat, underlying: "epub_drm")
            }
        }

        // 2. OPF path: the first rootfile@full-path in container.xml
        guard let container = index.entry("META-INF/container.xml"),
              let opfPath = XmlScan.attributes(in: try reader.xmlData(from: archive, entry: container), element: "rootfile", attribute: "full-path").first,
              let opfEntry = index.entry(opfPath) else {
            throw ExtractionError(code: .corruptedFile, underlying: "epub missing OPF")
        }
        try deadline.check()

        // 3. manifest / spine
        let package = OpfPackage(data: try reader.xmlData(from: archive, entry: opfEntry))
        try deadline.check()
        let opfDirectory = opfPath.split(separator: "/", omittingEmptySubsequences: false).dropLast().map(String.init)

        // 4-5. Per chapter
        var chapters: [String] = []
        for idref in package.spine {
            try deadline.check()
            guard let item = package.manifest[idref],
                  chapterMediaTypes.contains(item.mediaType),
                  let path = resolve(href: item.href, against: opfDirectory),
                  let entry = index.entry(path) else { continue }
            let html = try HtmlTextExtractor.decode([UInt8](try reader.data(from: archive, entry: entry)), uiLanguage: uiLanguage)
            let text = try HtmlTextExtractor.extract(html: HtmlTextExtractor.expandSelfClosingTags(html), deadline: deadline)
            if !text.isEmpty { chapters.append(text) }
        }
        // 6. Blank line between chapters
        return StructuredTextFormat.normalize(chapters.joined(separator: "\n\n"))
    }

    /// Resolve manifest `href` against the OPF directory by URL rules: strip after `#`, handle `.` / `..`, percent-decode.
    /// Return nil (discard) if it starts with `/` or `..` escapes the package root.
    static func resolve(href: String, against baseDirectory: [String]) -> String? {
        let withoutFragment = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !withoutFragment.isEmpty, !withoutFragment.hasPrefix("/") else { return nil }
        var segments = baseDirectory
        for segment in withoutFragment.split(separator: "/", omittingEmptySubsequences: false) {
            switch segment {
            case ".":
                continue
            case "..":
                guard !segments.isEmpty else { return nil }
                segments.removeLast()
            default:
                segments.append(String(segment).removingPercentEncoding ?? String(segment))
            }
        }
        let path = segments.joined(separator: "/")
        return path.isEmpty ? nil : path
    }

    // MARK: - Zip entry lookup

    /// Exact match first, then case-insensitive match.
    private struct EntryIndex {
        private let exact: [String: Entry]
        private let caseInsensitive: [String: Entry]

        init(_ archive: Archive) {
            var exact: [String: Entry] = [:]
            var folded: [String: Entry] = [:]
            for entry in archive where entry.type == .file {
                if exact[entry.path] == nil { exact[entry.path] = entry }
                let key = entry.path.lowercased()
                if folded[key] == nil { folded[key] = entry }
            }
            self.exact = exact
            self.caseInsensitive = folded
        }

        func entry(_ path: String) -> Entry? {
            exact[path] ?? caseInsensitive[path.lowercased()]
        }
    }

    // MARK: - OPF

    private struct ManifestItem {
        let href: String
        let mediaType: String
    }

    private final class OpfPackage: NSObject, XMLParserDelegate {
        private(set) var manifest: [String: ManifestItem] = [:]
        private(set) var spine: [String] = []

        init(data: Data) {
            super.init()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            parser.parse()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch XmlScan.localName(name) {
            case "item":
                if let id = attributes["id"], let href = attributes["href"], manifest[id] == nil {
                    let mediaType = (attributes["media-type"] ?? "")
                        .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    manifest[id] = ManifestItem(href: href, mediaType: mediaType)
                }
            case "itemref":
                if let idref = attributes["idref"] { spine.append(idref) }
            default:
                break
            }
        }
    }

    // MARK: - Small XML scanner

    private final class XmlScan: NSObject, XMLParserDelegate {
        private let element: String
        private let attribute: String
        private var values: [String] = []

        private init(element: String, attribute: String) {
            self.element = element
            self.attribute = attribute
        }

        /// Collect the value of `attribute` on every element whose local name is `element` (namespace prefix ignored).
        static func attributes(in data: Data, element: String, attribute: String) -> [String] {
            let scan = XmlScan(element: element, attribute: attribute)
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = scan
            parser.parse()
            return scan.values
        }

        static func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard Self.localName(name) == element else { return }
            if let value = attributes[attribute] { values.append(value.trimmingCharacters(in: .whitespaces)) }
        }
    }
}
