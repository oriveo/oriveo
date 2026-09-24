import Foundation
import Testing

/// The brand name Oriveo stays in Latin in every language. Older hi strings transliterated it as "ओरिवियो". Other
/// languages may drop the subject, so only hi is required to keep Oriveo wherever the English names it.
@Suite("brand name in hi")
struct HindiBrandNameLocalizationTests {
    @Test("hi keeps the brand name Oriveo as is and never transliterates it")
    func brandStaysLatin() throws {
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        #expect(catalogs.count >= 10, "too few xcstrings tables found: \(catalogs.count)")

        var problems: [String] = []
        for url in catalogs {
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            for (key, raw) in strings {
                let localizations = (raw as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                guard let hindi = value(localizations["hi"]) else { continue }
                let english = value(localizations["en"]) ?? key
                let transliterated = hindi.range(of: "ओर[िी]व", options: .regularExpression) != nil
                if transliterated || (english.contains("Oriveo") && !hindi.contains("Oriveo")) {
                    problems.append("\(url.deletingPathExtension().lastPathComponent) \(key): \(hindi)")
                }
            }
        }
        #expect(problems.isEmpty, "hi transliterates or drops the brand name; keep Oriveo as is:\n\(problems.joined(separator: "\n"))")
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
