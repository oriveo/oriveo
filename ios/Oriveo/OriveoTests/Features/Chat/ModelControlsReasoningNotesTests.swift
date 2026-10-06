import Foundation
import Testing
@testable import Oriveo

/// **What the thinking row says** besides the levels.
///
/// The defect: a model reported as automatically available with an empty set of available levels
/// (real examples exist - some models accept only "high", others only "medium", and the catalog
/// deliberately publishes no ladder for them) rendered as an "available" card that listed no levels
/// at all, with a footnote about higher levels being slower and more expensive underneath. With no
/// ladder there is no higher level. The user saw the worst kind of dead end: an entry point that is
/// present, does nothing, explains nothing and offers no action.
///
/// These sentences come from `ModelOptionCapabilityShape.resolve` together with the shape. The empty state comes first: "no levels" is pinned,
/// and the cases with levels serve as a control group so the criterion cannot be hard-wired to always true.
@Suite("Model Controls Reasoning Notes Tests")
struct ModelControlsReasoningNotesTests {
    private static func shape(_ intents: [String], selected: String? = nil) -> ModelOptionCapabilityShape {
        ModelOptionCapabilityShape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: intents, selectedIntent: selected
        ))
    }

    private static let higherLevelsCost = "Higher levels take longer and may cost more."

    @Test("Empty Intents Explains Fixed Tier")
    func emptyIntentsExplainsFixedTier() {
        guard case let .notice(notice) = Self.shape([]) else {
            Issue.record("without levels this should be a note, got \(Self.shape([]))")
            return
        }
        #expect(notice.body == L10n.tr(
            "This model runs at a fixed thinking level and can’t be adjusted.", table: .chat
        ))
        // Something that cannot be adjusted gets no link that leads nowhere; with no levels there is no talk of "higher levels" either.
        #expect(notice.link == nil)
        #expect(!notice.body.contains(L10n.tr(Self.higherLevelsCost, table: .chat)))
    }

    @Test("levels that cannot be turned off: the top right says it always thinks first, below it says higher levels are slower and cost more, and there is no Off segment")
    func tieredWithoutOffSaysSoWithoutADeadSegment() {
        guard case let .tiers(tiers) = Self.shape(["low", "balanced", "deep", "max"], selected: "low") else {
            Issue.record("with levels this should be segments")
            return
        }
        #expect(!tiers.includesOff)
        #expect(!tiers.options.map(\.id).contains("off"))
        #expect(tiers.headerNote == L10n.tr("Always thinks before answering", table: .chat))
        #expect(tiers.footnotes.contains(L10n.tr(Self.higherLevelsCost, table: .chat)))
    }

    @Test("levels including off: no always-thinks note and no fixed-level explanation")
    func tieredWithOffDropsTheAlwaysThinksNote() {
        guard case let .tiers(tiers) = Self.shape(["off", "low", "deep"], selected: "low") else {
            Issue.record("with levels this should be segments")
            return
        }
        #expect(tiers.includesOff)
        #expect(tiers.headerNote != L10n.tr("Always thinks before answering", table: .chat))
    }

    /// Neither the panel nor the components may inline a single word of thinking copy; that would be a second source of truth.
    /// There is no "this model cannot turn thinking off" footnote: the segments carry no Off, and one note at the top right is enough.
    @Test("thinking copy has the shape function as its single source, the panel inlines none, and the retired footnote stays gone")
    func reasoningCopyHasASingleSource() throws {
        let directory = ["ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls"]
        for name in ["ModelControlsSheet.swift", "ModelControlsComponents.swift", "ModelControlCapabilityLayout.swift"] {
            let source = try Self.source(directory + [name])
            for copy in [
                "Higher levels take longer",
                "This model runs at a fixed thinking level",
                "Always thinks before answering",
            ] {
                #expect(!source.contains(copy), "\(name) inlines thinking copy: \(copy)")
            }
        }
        let shape = try Self.source(directory + ["ModelOptionCapabilityShape.swift"])
        for retired in ["This model cannot turn thinking off.", "Higher levels are usually slower"] {
            #expect(!shape.contains(retired), "the retired footnote is back: \(retired)")
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
