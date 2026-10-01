import Foundation
import Testing

/// Full-width punctuation belongs to Chinese and Japanese only. A translation copied clause by clause from a
/// Chinese draft leaks full-width brackets, commas and full stops into other languages, for example a parameter
/// name rendered as "Top P" followed by a full-width bracketed note. Outside zh-Hans / zh-Hant / ja no value may
/// contain any of the characters listed in `fullwidth`.
@Suite("fullwidth punctuation outside CJK")
struct FullwidthPunctuationLocalizationTests {
    private static let cjkLocales: Set<String> = ["zh-Hans", "zh-Hant", "ja"]
    private static let fullwidth: Set<Character> = ["（", "）", "。", "，", "：", "；", "！", "？", "「", "」", "、"]

    @Test("languages other than Chinese and Japanese contain no full-width punctuation")
    func noFullwidthPunctuationOutsideCJK() throws {
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        // Finding almost no catalogs means the path is wrong; without this check the test would silently pass.
        #expect(catalogs.count >= 10, "too few xcstrings catalogs found: \(catalogs.count)")

        var problems: [String] = []
        for url in catalogs {
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            let table = url.deletingPathExtension().lastPathComponent
            for (key, raw) in strings {
                let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                for (locale, entry) in localizations where !Self.cjkLocales.contains(locale) {
                    for value in values(entry) where value.contains(where: Self.fullwidth.contains) {
                        problems.append("\(table) [\(locale)] \(key): \(value)")
                    }
                }
            }
        }
        #expect(problems.isEmpty, "full-width punctuation outside Chinese and Japanese:\n\(problems.sorted().joined(separator: "\n"))")
    }

    /// Checks the plain stringUnit and every branch of plural / device variations.
    private func values(_ entry: Any?) -> [String] {
        guard let entry = entry as? [String: Any] else { return [] }
        var result: [String] = []
        if let value = (entry["stringUnit"] as? [String: Any])?["value"] as? String {
            result.append(value)
        }
        for axis in (entry["variations"] as? [String: Any] ?? [:]).values {
            for variant in (axis as? [String: Any] ?? [:]).values {
                if let value = ((variant as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String {
                    result.append(value)
                }
            }
        }
        return result
    }

    private var catalogsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
    }
}
