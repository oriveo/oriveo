import Foundation
import Testing

/// When the app speaks to the user, hi uses the आप register. Older translations left तुम-register -ओ imperatives
/// ("सबको अचयनित करो", "शुरू हो जाओ", "सब कुछ दिखाओ") that read as ordering the user around. Quick prompts the user
/// sends to the assistant ("यह कोड समझाओ") are in the user's own voice and are not in this word list.
@Suite("hi register")
struct HindiRegisterLocalizationTests {
    private static let tumImperatives = ["करो", "जाओ", "हटाओ", "हटो", "छुपाओ", "छिपाओ", "दिखाओ", "देखो", "चुनो", "रखो", "बदलो", "भेजो"]

    @Test("hi does not address the user with तुम-register imperatives")
    func noTumImperatives() throws {
        let pattern = "(?<![\\u0900-\\u097F])(\(Self.tumImperatives.joined(separator: "|")))(?![\\u0900-\\u097F])"
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        #expect(catalogs.count >= 10, "too few xcstrings tables found: \(catalogs.count)")

        var problems: [String] = []
        for url in catalogs {
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            for (key, raw) in strings {
                let hi = (((raw as? [String: Any])?["localizations"] as? [String: Any])?["hi"] as? [String: Any])?["stringUnit"]
                guard let value = (hi as? [String: Any])?["value"] as? String,
                      value.range(of: pattern, options: .regularExpression) != nil else { continue }
                problems.append("\(url.deletingPathExtension().lastPathComponent) \(key): \(value)")
            }
        }
        #expect(problems.isEmpty, "hi still has तुम-register imperatives; use the आप register (-एँ / -ें):\n\(problems.joined(separator: "\n"))")
    }

    private var catalogsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
    }
}
