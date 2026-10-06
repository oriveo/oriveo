import Foundation
import Testing
@testable import Oriveo

/// Freezes the user-facing vocabulary for reasoning levels and web-search timing.
///
/// Before this was frozen, the reasoning levels had three competing sets of names and each client
/// used its own, so no two places agreed. One value must now have exactly one name everywhere it
/// appears: the picker, the read-only status row, the VoiceOver summary and every explanatory
/// sentence. The raw enum values (`off`, `low`, `balanced`, `deep`, `max`) are unchanged; only the
/// presentation is frozen.
///
/// The assertion chain is intent -> the key the production function returns -> the localized value
/// stored under that key, so replacing any link (the key, the translation, or the mapping) turns
/// this red.
@Suite("Model control intent vocabulary")
struct ModelControlIntentVocabularyTests {
    /// The frozen mapping from intent to its expected localized name. This table is the freeze
    /// itself; changing it changes the product decision.
    private static let reasoningVocabulary: [(intent: String, english: String)] = [
        (ModelOptionCapabilityShape.automaticIntent, "Automatic"),
        ("off", "Off"),
        ("low", "Fast"),
        ("balanced", "Balanced"),
        ("deep", "Deep"),
        ("max", "Max"),
    ]

    /// Web search has a single vocabulary: the timing row in the panel, the read-only status row and
    /// the VoiceOver summary all use the same words. They always appear under the "Web search" title
    /// and need no subject of their own, hence "When needed" and "Every message".
    private static let webVocabulary: [(preference: CapabilityWebPreference, english: String)] = [
        (.off, "Off"),
        (.automatic, "When needed"),
        (.force, "Every message"),
    ]

    @Test("Reasoning Vocabulary Is Frozen")
    func reasoningVocabularyIsFrozen() throws {
        for entry in Self.reasoningVocabulary {
            let mapping = try #require(
                ModelControlIntentLabel.key(entry.intent),
                "\(entry.intent) does not go through the vocabulary table and would print the raw intent to the user"
            )
            let value = try #require(
                Self.english(for: mapping.key, table: mapping.table),
                "\(mapping.table.rawValue).xcstrings has no key \"\(mapping.key)\""
            )
            #expect(value == entry.english, "\(entry.intent) reads \"\(value)\" but the vocabulary is frozen to \"\(entry.english)\"")
        }
    }

    /// This level is called "automatic", not "provider default". The reverse assertion matters just
    /// as much: the old key must be gone from the whole repository. An unused key left in the
    /// catalog is harmless; code still referencing a key that is no longer in the catalog is not,
    /// because the user then sees the raw English.
    @Test("Automatic Replaces Provider Default")
    func automaticReplacesProviderDefault() throws {
        let value = try #require(Self.english(for: "Automatic", table: .localizable))
        #expect(value == "Automatic")

        for components in [
            ["ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
             "ModelControlsComponents.swift"],
            ["ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift"],
        ] {
            let source = try Self.source(components)
            #expect(
                !source.contains("Provider Default"),
                "\(components.last!) still references the removed provider-default key"
            )
        }
        let composer = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
        ])
        #expect(composer.contains("?? L10n.tr(\"Automatic\")"))
    }

    @Test("Web Vocabulary Is Frozen")
    func webVocabularyIsFrozen() throws {
        for entry in Self.webVocabulary {
            let mapping = ModelControlIntentLabel.webKey(entry.preference)
            let value = try #require(
                Self.english(for: mapping.key, table: mapping.table),
                "\(mapping.table.rawValue).xcstrings has no key \"\(mapping.key)\""
            )
            #expect(
                value == entry.english,
                "\(entry.preference.rawValue) reads \"\(value)\" but the vocabulary is frozen to \"\(entry.english)\""
            )
        }
    }

    @Test("Tier Order Is Frozen")
    func tierOrderIsFrozen() {
        #expect(ModelOptionCapabilityShape.tierOrder == ["off", "low", "balanced", "deep", "max"])
        #expect(ModelOptionCapabilityShape.automaticIntent == "automatic")
    }

    @Test("Web Timing Vocabulary Is Frozen")
    func webTimingVocabularyIsFrozen() throws {
        #expect(try #require(Self.english(for: "When needed", table: .chat)) == "When needed")
        #expect(try #require(Self.english(for: "Every message", table: .chat)) == "Every message")

        // The two segments of the timing row are really rendered from the vocabulary keys, not from a second copy.
        let shape = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelOptionCapabilityShape.swift",
        ])
        #expect(shape.contains("ModelControlIntentLabel.webText(.automatic)"))
        #expect(shape.contains("ModelControlIntentLabel.webText(.force)"))
        // The two replaced keys must have no reference left: they are no longer in the catalog, and a leftover would show a raw key to users.
        for name in ["ModelOptionCapabilityShape.swift", "ModelControlsComponents.swift", "ModelControlsSheet.swift"] {
            let source = try Self.source([
                "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls", name,
            ])
            #expect(!source.contains("\"Search when needed\""), "\(name) still references a removed key")
            #expect(!source.contains("\"Search every message\""), "\(name) still references a removed key")
        }

        for components in [
            ["ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
             "ModelControlsComponents.swift"],
            ["ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift"],
        ] {
            #expect(!(try Self.source(components)).contains("\"Every time\""))
        }
    }

    @Test("Reasoning Captions Are Distinct")
    func reasoningCaptionsAreDistinct() {
        var captions: [String] = []
        for intent in ["off", ModelOptionCapabilityShape.automaticIntent, "low", "balanced", "deep", "max"] {
            let caption = ModelOptionCapabilityShape.caption(for: intent)
            #expect(!caption.isEmpty, "\(intent) has no caption")
            captions.append(caption)
        }
        #expect(Set(captions).count == captions.count, "two levels share the same caption, which is the same as having none")
    }

    /// A retired term must not survive inside other sentences.
    /// The two destructive-confirmation sentences differ only in scope, and the English versions
    /// share one sentence pattern. The Chinese versions used different verbs, punctuation and
    /// endings, which made the two entry points read like two different severities of action.
    /// The assertions above freeze which word is used today; they say nothing about the word that
    /// was replaced still sitting in another sentence. After the third web-search level was renamed,
    /// the sentence explaining the forced mode still used the old name, so the same value had one
    /// name in the picker and another in its explanation. Those sentences are often in rarely
    /// reached branches, so the only reliable check is scanning every value in the table rather than
    /// listing the keys someone happens to remember.
    @Test("Retired Web Intent Word Is Gone From English Values")
    func retiredWebIntentWordIsGoneFromEnglishValues() {
        for table in [L10n.Table.chat, .localizable] {
            for (key, value) in Self.allValues(table: table, locale: "en") {
                #expect(
                    !value.localizedCaseInsensitiveContains("every time"),
                    "\(table.rawValue).xcstrings / en: \"\(key)\" still uses the retired term: \(value)"
                )
            }
        }
    }

    @Test("Delete Confirmation Sentences Share One English Form")
    func deleteConfirmationSentencesShareOneEnglishForm() throws {
        let keys = [
            "This removes the custom fields for %@ on this conversation, connection, model and transport. This cannot be undone.",
            "This removes the custom fields for %@ on this connection, model and transport. This cannot be undone.",
        ]
        for key in keys {
            let value = try #require(
                Self.value(for: key, table: .chat, locale: "en"),
                "Chat.xcstrings / en has no \"\(key)\""
            )
            #expect(value.contains("This removes"), "en uses a different verb: \(value)")
            #expect(value.contains("cannot be undone"), "en uses a different ending: \(value)")
        }
    }

    // MARK: - helpers

    private static func english(for key: String, table: L10n.Table) -> String? {
        value(for: key, table: table, locale: "en") ?? key
    }

    private static func value(for key: String, table: L10n.Table, locale: String) -> String? {
        guard let strings = stringsTable(table),
              let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any],
              let value = unit["value"] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func allValues(table: L10n.Table, locale: String) -> [(String, String)] {
        guard let strings = stringsTable(table) else { return [] }
        return strings.compactMap { key, entry in
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String,
                  !value.isEmpty
            else { return nil }
            return (key, value)
        }
    }

    private static func stringsTable(_ table: L10n.Table) -> [String: Any]? {
        let url = findFile([
            "ios", "Oriveo", "Oriveo", "\(table.rawValue).xcstrings",
        ])
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = object["strings"] as? [String: Any]
        else { return nil }
        return strings
    }

    private static func source(_ components: [String]) throws -> String {
        try String(contentsOf: findFile(components), encoding: .utf8)
    }

    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("directory not found: \(components.joined(separator: "/"))")
    }
}
