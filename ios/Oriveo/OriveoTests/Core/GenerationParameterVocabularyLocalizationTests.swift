import Foundation
import Testing
@testable import Oriveo

/// Names and translations of generation parameters.
///
/// - `min_keep` is the minimum number of candidate tokens a sampler keeps (llama.cpp server). It is unrelated to
///   the repeat penalty and must not share the `repeat_last_n` name.
/// - "token" must not be translated as an everyday word: in ru, tr and vi the dictionary words mean a game chip
///   or a notification code, not an LLM token.
@Suite("generation parameter vocabulary")
struct GenerationParameterVocabularyLocalizationTests {
    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    @Test("min_keep no longer shows as the repeat penalty window")
    func minKeepHasItsOwnName() {
        let minKeep = GenerationParameterVocabulary.title("min_keep")
        #expect(minKeep != GenerationParameterVocabulary.title("repeat_last_n"))
        #expect(minKeep == L10n.tr("Minimum tokens to keep", table: .chat))
    }

    @Test("every parameter name in the vocabulary is translated in 16 languages, without mistranslating token")
    func everyTitleIsTranslated() throws {
        let source = try String(contentsOf: repoFile([
            "Oriveo", "Core", "Providers", "GenerationParameterSupportPresentation.swift",
        ]), encoding: .utf8)
        // Read the keys from title(_:) itself: the production vocabulary is the only source of truth.
        let titleBody = try #require(source.components(separatedBy: "static func title(").dropFirst().first?
            .components(separatedBy: "static func source(").first)
        let pattern = try NSRegularExpression(pattern: #"L10n\.tr\("([^"]+)", table: \.chat\)"#)
        let range = NSRange(titleBody.startIndex..., in: titleBody)
        let keys = Set(pattern.matches(in: titleBody, range: range).compactMap { match in
            Range(match.range(at: 1), in: titleBody).map { String(titleBody[$0]) }
        })
        #expect(keys.contains("Minimum tokens to keep"), "min_keep has no key of its own")

        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: repoFile([
            "Oriveo", "Chat.xcstrings",
        ]))) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])

        // In these languages the listed words read as something other than an LLM token. The Chinese entries
        // (escaped) are the words for an access token and for a linguistic lexeme.
        let forbidden: [String: [String]] = [
            "ru": ["жетон"],
            "tr": ["jeton", "belirteç"],
            "vi": ["mã thông báo"],
            "fr": ["jeton"],
            "zh-Hans": ["\u{4EE4}\u{724C}", "\u{8BCD}\u{5143}"],
            "zh-Hant": ["\u{6B0A}\u{6756}", "\u{8A5E}\u{5143}"],
        ]

        var problems: [String] = []
        for key in keys.sorted() {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for locale in Self.locales {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    problems.append("\(key) [\(locale)] missing translation")
                    continue
                }
                for word in forbidden[locale] ?? [] where value.lowercased().contains(word) {
                    problems.append("\(key) [\(locale)] contains \"\(word)\": \(value)")
                }
            }
        }
        #expect(problems.isEmpty, "\n\(problems.joined(separator: "\n"))")
    }

    private func repoFile(_ components: [String]) -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }
}
