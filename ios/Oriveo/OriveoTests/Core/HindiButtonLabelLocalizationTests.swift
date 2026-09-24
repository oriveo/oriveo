import Foundation
import Testing

/// Older translations turned hi buttons and short labels into bare infinitives (-ना), which read like dictionary
/// entries rather than buttons: Default as गलती करना ("to make a mistake"), Crop as काटना, Stop as रुकना. Buttons use
/// the आप-register imperative (-एँ / -ें) and labels use nouns.
@Suite("hi short labels")
struct HindiButtonLabelLocalizationTests {
    /// Words that end in -ना but are nouns or adjectives, not infinitives
    private static let nounsEndingInNa: [String: String] = [
        "महीना": "month (noun)",
        "योजना": "plan (noun)",
        "सालाना": "yearly (adjective)",
        "नमूना": "sample (noun)",
        "संरचना": "composition (noun)",
    ]

    @Test("hi short labels are not bare infinitives")
    func noBareInfinitives() throws {
        let catalogs = try FileManager.default.contentsOfDirectory(at: catalogsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        #expect(catalogs.count >= 10, "too few xcstrings tables found: \(catalogs.count)")

        var problems: [String] = []
        for url in catalogs {
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            for (key, raw) in strings {
                let hi = (((raw as? [String: Any])?["localizations"] as? [String: Any])?["hi"] as? [String: Any])?["stringUnit"]
                guard let value = (hi as? [String: Any])?["value"] as? String, looksLikeInfinitiveLabel(value) else { continue }
                problems.append("\(url.deletingPathExtension().lastPathComponent) \(key): \(value)")
            }
        }
        #expect(problems.isEmpty, "hi short labels read as infinitives (-ना); use an आप-register imperative or a noun:\n\(problems.joined(separator: "\n"))")
    }

    private func looksLikeInfinitiveLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(whereSeparator: \.isWhitespace).count <= 3 else { return false }
        let devanagari = CharacterSet(charactersIn: Unicode.Scalar(0x0900)!...Unicode.Scalar(0x097F)!)
        let words = trimmed.components(separatedBy: devanagari.inverted)
            .filter { !$0.isEmpty }
        guard let last = words.last else { return false }
        return last.hasSuffix("ना") && Self.nounsEndingInNa[last] == nil
    }

    private var catalogsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
    }
}
