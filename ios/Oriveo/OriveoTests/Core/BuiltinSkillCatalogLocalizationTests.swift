import Foundation
import Testing

/// Builtin skills (`skill.<key>.name / description / starter_N`, `skill.category.<id>`) and folder colors
/// (`color_<name>`) use identifier-style keys that `Skill.localizedName`, `SkillCategory.localizedName` and
/// `FolderColor` build at runtime.
///
/// hi / id / ru / th / tr / vi once had translations of the key itself rather than of the English text, so the UI
/// showed "कौशल.श्रेणी.सीखना", "keterampilan.brainstorm.nama", "цвет_синий" or "ทักษะการระดมสมองคำอธิบาย". Skill names,
/// category names and color names were rewritten for their meaning and match Android; the descriptions and starter
/// messages in those six languages were removed and fall back to the text the catalog ships
/// (`Skill.localizedDescription` uses `description` when there is no translation).
/// This locks two things: no translation in any language keeps identifier fragments, and in those six languages the
/// skill and category names match Android entry by entry. Folder color names only exist on iOS, so the fragment check
/// alone covers them.
@Suite("Builtin skill and folder color catalog")
struct BuiltinSkillCatalogLocalizationTests {
    private static let identifierKey = "^(skill\\.[a-z_]+\\.(name|description|starter_[0-9])|skill\\.category\\.[a-z_]+|color_[a-z]+)$"
    private static let sharedNameKey = "^(skill\\.[a-z_]+\\.name|skill\\.category\\.[a-z_]+)$"
    private static let repairedLocales: [String: String] = [
        "hi": "values-hi", "id": "values-in", "ru": "values-ru", "th": "values-th", "tr": "values-tr", "vi": "values-vi",
    ]

    @Test("Translations of identifier-style keys keep no key fragments (underscores, dots followed by letters)")
    func noIdentifierFragments() throws {
        var problems: [String] = []
        for (key, localizations) in try identifierEntries() {
            for (locale, text) in localizations where locale != "en" {
                let withoutEllipsis = text.replacingOccurrences(of: "...", with: "…")
                if withoutEllipsis.contains("_") || withoutEllipsis.range(of: "\\.\\p{L}", options: .regularExpression) != nil {
                    problems.append("\(key) [\(locale)]: \(text)")
                }
            }
        }
        #expect(problems.isEmpty, "translations keep identifier fragments:\n\(problems.joined(separator: "\n"))")
    }

    @Test("In the six languages that once translated the identifiers, skill and category names match Android")
    func repairedLocalesMatchAndroid() throws {
        let entries = try identifierEntries().filter { $0.key.range(of: Self.sharedNameKey, options: .regularExpression) != nil }
        #expect(entries.count >= 30, "too few name keys: \(entries.count)")
        var problems: [String] = []
        for (locale, directory) in Self.repairedLocales {
            let android = try androidStrings(directory)
            for (key, localizations) in entries {
                let expected = android[androidName(for: key)]
                if localizations[locale] != expected {
                    problems.append("\(key) [\(locale)]: iOS=\(localizations[locale] ?? "<nil>") Android=\(expected ?? "<nil>")")
                }
            }
        }
        #expect(problems.isEmpty, "differs from Android:\n\(problems.prefix(40).joined(separator: "\n"))")
    }

    // MARK: - Helpers

    private func identifierEntries() throws -> [String: [String: String]] {
        let url = catalogsRoot.appendingPathComponent("Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        var out: [String: [String: String]] = [:]
        for (key, raw) in strings where key.range(of: Self.identifierKey, options: .regularExpression) != nil {
            let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            out[key] = localizations.compactMapValues {
                (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
        }
        return out
    }

    /// `skill.math_tutor.name` → `skill_math_tutor_name`; `skill.category.coding` → `skill_category_coding`
    private func androidName(for key: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        if parts[1] == "category" { return "skill_category_\(parts[2])" }
        let field = parts[2] == "description" ? "desc" : parts[2]
        return "skill_\(parts[1])_\(field)"
    }

    private func androidStrings(_ directory: String) throws -> [String: String] {
        let url = repositoryRoot.appendingPathComponent("android/app/src/main/res/\(directory)/strings.xml")
        #expect(FileManager.default.fileExists(atPath: url.path), "Android \(directory)/strings.xml not found")
        let collector = AndroidStringsCollector()
        let parser = try #require(XMLParser(contentsOf: url))
        parser.delegate = collector
        #expect(parser.parse(), "failed to parse \(url.path)")
        return collector.strings
    }

    private var catalogsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
    }

    /// Two levels above the iOS project
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// Collects only the text of `<string name="…">` and undoes aapt's `\'` / `\"` escapes
private final class AndroidStringsCollector: NSObject, XMLParserDelegate {
    private(set) var strings: [String: String] = [:]
    private var currentName: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "string" else { return }
        currentName = attributeDict["name"]
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentName != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "string", let name = currentName else { return }
        strings[name] = buffer.replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\"", with: "\"")
        currentName = nil
    }
}
