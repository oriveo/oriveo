import Foundation
import Testing
@testable import Oriveo

/// What the reasoning card says beyond the list of levels.
///
/// The defect: a model reported as automatically available with an empty set of available levels
/// (real examples exist - some models accept only "high", others only "medium", and the catalog
/// deliberately publishes no ladder for them) rendered as an "available" card that listed no levels
/// at all, with a footnote about higher levels being slower and more expensive underneath. With no
/// ladder there is no higher level. The user saw the worst kind of dead end: an entry point that is
/// present, does nothing, explains nothing and offers no action.
///
/// Empty states come first here: the "no ladder" and "not configurable" cases are pinned, and the
/// cases that do have a ladder act as a control group so the predicate cannot be hard-coded true.
@Suite("Model Controls Reasoning Notes Tests")
struct ModelControlsReasoningNotesTests {
    @Test("Empty Intents Explains Fixed Tier")
    func emptyIntentsExplainsFixedTier() {
        let notes = ModelControlReasoningNotes.all(isConfigurable: true, intents: [])
        #expect(notes.map(\.kind) == [.fixedTier])
        #expect(notes[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(!notes.map(\.kind).contains(.higherLevelsCost))
    }

    @Test("Unavailable Says Nothing Here")
    func unavailableSaysNothingHere() {
        #expect(ModelControlReasoningNotes.all(isConfigurable: false, intents: []).isEmpty)
        #expect(ModelControlReasoningNotes.all(isConfigurable: false, intents: ["low"]).isEmpty)
    }

    @Test("Tiered Without Off Keeps Both Notes")
    func tieredWithoutOffKeepsBothNotes() {
        let notes = ModelControlReasoningNotes.all(
            isConfigurable: true, intents: ["low", "balanced", "deep", "max"]
        )
        #expect(notes.map(\.kind) == [.cannotTurnOff, .higherLevelsCost])
    }

    @Test("Tiered With Off Drops The Cannot Turn Off Note")
    func tieredWithOffDropsTheCannotTurnOffNote() {
        let notes = ModelControlReasoningNotes.all(isConfigurable: true, intents: ["off", "balanced"])
        #expect(notes.map(\.kind) == [.higherLevelsCost])
    }

    /// The tests above cover the function; this one pins the rendering side to the same function.
    ///
    /// The consumer moved from the panel to `ModelControlReasoningLayout`: the reasoning card no
    /// longer has a deep-thinking switch, and the "this cannot be turned off" sentence became a
    /// footnote below the single-selection list, produced by the layout function. The panel must not
    /// inline a single word of it, or there would be a second source of truth.
    @Test("Reasoning Copy Has A Single Source")
    func reasoningCopyHasASingleSource() throws {
        let layout = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlCapabilityLayout.swift",
        ])
        #expect(layout.contains("ModelControlReasoningNotes.all("), "the footnote does not consume the shared explanation copy")

        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsSheet.swift",
        ])
        for copy in [
            "This model cannot turn thinking off.",
            "Higher levels are usually slower",
            "This model runs at a fixed thinking level",
        ] {
            #expect(!sheet.contains(copy), "the panel still inlines reasoning copy: \(copy)")
            #expect(!layout.contains(copy), "the layout function keeps a second copy of the reasoning text: \(copy)")
        }
    }

    @Test("Tier Captions Ship In Every Locale")
    func tierCaptionsShipInEveryLocale() throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.findFile([
            "ios", "Oriveo", "Oriveo", "Chat.xcstrings",
        ]))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        for key in [
            "Answer right away, no thinking time.",
            "The model decides on its own.",
            "Simple questions, fast answers.",
            "A balance of speed and depth.",
            "Hard questions, take more time.",
            "The hardest problems, whatever time it takes.",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "Chat.xcstrings has no such key: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in Self.translatedLanguages {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(
                    (unit?["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                    "\(language) is missing the translation for the level annotation: \(key)"
                )
            }
        }
    }

    private static let translatedLanguages = [
        "ar", "de", "es", "fr", "hi", "id", "ja", "ko",
        "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    private static func source(_ components: [String]) throws -> String {
        try String(contentsOf: findFile(components), encoding: .utf8)
    }

    @Test("Fixed Tier Copy Ships In Every Locale")
    func fixedTierCopyShipsInEveryLocale() throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.findFile([
            "ios", "Oriveo", "Oriveo", "Chat.xcstrings",
        ]))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let key = "This model runs at a fixed thinking level and can’t be adjusted."
        let entry = try #require(strings[key] as? [String: Any], "Chat.xcstrings has no such key")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for language in Self.translatedLanguages {
            let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String
            #expect(
                value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "\(language) is missing the translation for the fixed-level explanation"
            )
        }
    }

    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("fixture not found: \(components.joined(separator: "/"))")
    }
}
