import Foundation
import Testing

/// Format-specifier parity across every `.xcstrings` catalog.
///
/// `String(format:)` pulls one variadic argument per specifier. A translation that carries an
/// extra `%d` or `%@` reads past the arguments at runtime and shows a random number, garbage, or
/// crashes outright, and it does so in exactly one language, so the English build never notices.
/// Two backup strings once shipped that way in six locales: the app name and the words "API keys"
/// had been replaced by a specifier.
///
/// This suite is the guard: for every catalog, key and locale it compares the multiset of
/// specifiers against the English baseline. Length modifiers and conversion characters are kept,
/// positional indexes such as `%1$` are ignored because a translation may legitimately reorder
/// its arguments, and `%%` is a literal percent sign that consumes nothing.
@Suite("Localized Format Specifiers")
struct LocalizedFormatSpecifierTests {

    @Test("every locale of every catalog keeps the English specifiers")
    func everyLocaleKeepsTheEnglishSpecifiers() throws {
        let catalogs = try catalogURLs()
        // Finding no catalogs at all means the path derivation broke; without this check the
        // test would silently pass forever.
        #expect(catalogs.count >= 10, "Only \(catalogs.count) .xcstrings catalogs found; the path derivation may be stale")

        for catalog in catalogs {
            let data = try Data(contentsOf: catalog)
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            let table = catalog.deletingPathExtension().lastPathComponent

            for (key, rawEntry) in strings {
                guard let entry = rawEntry as? [String: Any] else { continue }
                let localizations = (entry["localizations"] as? [String: Any]) ?? [:]

                // The baseline is the English text. Symbolic keys such as
                // `file_extraction_error_generic` keep their English under `en`; only catalogs
                // whose keys are the English text itself fall back to the key.
                let englishBaseline = localizedValues(in: localizations["en"]).first ?? key
                let expected = normalizedSpecifiers(in: englishBaseline)

                for (locale, rawLocalization) in localizations where locale != "en" {
                    for value in localizedValues(in: rawLocalization) {
                        #expect(
                            normalizedSpecifiers(in: value) == expected,
                            """
                            \(table).xcstrings: the \(locale) translation does not match the English specifiers (String(format:) would read past its arguments):
                            key      = \(key)
                            english  = \(englishBaseline) → \(expected)
                            \(locale) = \(value) → \(normalizedSpecifiers(in: value))
                            """
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Every translated value under one locale: the plain `stringUnit` plus each branch of a
    /// plural or device `variations` block, because each branch is formatted on its own.
    private func localizedValues(in rawLocalization: Any?) -> [String] {
        guard let localization = rawLocalization as? [String: Any] else { return [] }
        var values: [String] = []
        if let unit = localization["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            values.append(value)
        }
        if let variations = localization["variations"] as? [String: Any] {
            for (_, rawAxis) in variations {
                guard let axis = rawAxis as? [String: Any] else { continue }
                for (_, rawCase) in axis {
                    guard let variantCase = rawCase as? [String: Any],
                          let unit = variantCase["stringUnit"] as? [String: Any],
                          let value = unit["value"] as? String else { continue }
                    values.append(value)
                }
            }
        }
        return values
    }

    private static let specifierPattern = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ #0]*[\d*]*(?:\.\d+)?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#
    )

    /// The sorted multiset of "length modifier + conversion" tokens in a string.
    private func normalizedSpecifiers(in text: String) -> [String] {
        let ns = text as NSString
        var tokens: [String] = []
        Self.specifierPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let conversionRange = match.range(at: 2)
            guard conversionRange.location != NSNotFound else { return }
            let conversion = ns.substring(with: conversionRange)
            guard conversion != "%" else { return }
            let lengthRange = match.range(at: 1)
            let length = lengthRange.location == NSNotFound ? "" : ns.substring(with: lengthRange)
            tokens.append(length + conversion)
        }
        return tokens.sorted()
    }

    private func catalogURLs() throws -> [URL] {
        // OriveoTests/Core/<file>.swift → the directory that holds both Oriveo/ and OriveoTests/
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo")
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == "xcstrings" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
