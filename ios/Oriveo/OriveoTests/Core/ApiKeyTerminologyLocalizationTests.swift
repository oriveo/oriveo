import Foundation
import Testing

/// API key terminology in th / vi (every xcstrings table).
///
/// Older translations turned the API key into something else: a door key (th กุญแจ, vi chìa khóa), a keyboard key
/// (vi phím), an English/local duplicate ("API Key คีย์", "Khóa API Key"), or dropped the key and kept only "API"
/// ("กรอก API ของคุณ" reads as "enter your API"). The terms are th "คีย์ API" and vi "khóa API".
@Suite("API key terminology in th / vi")
struct ApiKeyTerminologyLocalizationTests {
    private static let wrongSense: [String: [(pattern: String, why: String)]] = [
        "th": [
            ("กุญแจ", "กุญแจ is a door key"),
            ("API Key คีย์|คีย์ API Key|API คีย์", "duplicated or reversed term"),
        ],
        "vi": [
            ("(?i)chìa khóa", "chìa khóa is a physical key"),
            ("(?i)phím API", "phím is a keyboard key"),
            ("(?i)khóa API Key", "duplicated term"),
        ],
    ]
    /// API key in English; request header names such as x-api-key / x-goog-api-key do not count
    private static let englishApiKey = "(?i)(?<![-\\w])API[ -]?keys?\\b"
    private static let keepsKey = ["th": "(?i)คีย์|API ?Key", "vi": "(?i)khóa|API ?Key"]

    @Test("th / vi never render the key as a door key or a keyboard key, and never duplicate it")
    func noWrongSense() throws {
        var problems: [String] = []
        for (table, key, locale, value, _) in try entries() {
            for rule in Self.wrongSense[locale] ?? [] where matches(rule.pattern, value) {
                problems.append("\(table) \(key) [\(locale)]: \(value) (\(rule.why))")
            }
        }
        #expect(problems.isEmpty, "API key translated as something else:\n\(problems.joined(separator: "\n"))")
    }

    @Test("Wherever English says API key, th / vi keep more than \"API\"")
    func keepsTheWordKey() throws {
        var problems: [String] = []
        for (table, key, locale, value, english) in try entries()
        where matches(Self.englishApiKey, english) && !matches(Self.keepsKey[locale] ?? "", value) {
            problems.append("\(table) \(key) [\(locale)]: \(value)")
        }
        #expect(problems.isEmpty, "English says API key but the translation only keeps \"API\":\n\(problems.joined(separator: "\n"))")
    }

    // MARK: - Helpers

    private func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// (table, key, locale, translation, English source); without an en entry the key itself is the source
    private func entries() throws -> [(String, String, String, String, String)] {
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        #expect(catalogs.count >= 10, "too few xcstrings tables found: \(catalogs.count)")
        var out: [(String, String, String, String, String)] = []
        for url in catalogs {
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            for (key, raw) in strings {
                let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                let english = value(localizations["en"]) ?? key
                for locale in ["th", "vi"] {
                    if let text = value(localizations[locale]) {
                        out.append((url.deletingPathExtension().lastPathComponent, key, locale, text, english))
                    }
                }
            }
        }
        return out
    }

    private func value(_ localeEntry: Any?) -> String? {
        ((localeEntry as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    private var catalogsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
    }
}
