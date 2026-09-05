import Foundation
import Testing
@testable import Oriveo

/// The composer chip and the actual outbound gate must be driven by the same value.
///
/// The failure this pins down: on a connection without web capability (DeepSeek, MiniMax, Groq),
/// opening any persisted older conversation made `restoreCapabilityPreferences` migrate the old
/// boolean switch into `web = .automatic` and write it back to the store. The chip read the raw
/// `webEnabled` flag, so the globe lit up and stayed lit, while the send path kept `webAllowed`
/// false and never attached a web tool. The globe was permanently on and web search never ran.
///
/// Thinking has the same shape: when the send path cannot use it the value falls back to
/// `.automatic`, but the composer's private intent state is not written back and the brain icon
/// stays lit.
@Suite("Composer capability chip convergence")
struct ComposerCapabilityChipConvergenceTests {
    @Test("Web Requested But Unavailable Lights Nothing")
    func webRequestedButUnavailableLightsNothing() {
        let decision = ChatCapabilityOutboundDecision.resolve(
            webRequested: true,
            webPermitted: false,
            reasoningModeRequested: .automatic,
            reasoningModePermitted: true,
            reasoningIntentRequested: nil,
            reasoningIntentPermitted: false
        )
        #expect(!decision.webSearchEnabled)
        #expect(decision.activeCapabilityGlyphs.isEmpty)
        #expect(!decision.hasActiveCapabilitySelection)
    }

    @Test("Web Requested And Available Lights Globe")
    func webRequestedAndAvailableLightsGlobe() {
        let decision = ChatCapabilityOutboundDecision.resolve(
            webRequested: true,
            webPermitted: true,
            reasoningModeRequested: .automatic,
            reasoningModePermitted: true,
            reasoningIntentRequested: nil,
            reasoningIntentPermitted: false
        )
        #expect(decision.webSearchEnabled)
        #expect(decision.activeCapabilityGlyphs == ["globe"])
        #expect(decision.hasActiveCapabilitySelection)
    }

    @Test("Web Available But Not Requested Stays Dark")
    func webAvailableButNotRequestedStaysDark() {
        let decision = ChatCapabilityOutboundDecision.resolve(
            webRequested: false,
            webPermitted: true,
            reasoningModeRequested: .automatic,
            reasoningModePermitted: true,
            reasoningIntentRequested: nil,
            reasoningIntentPermitted: false
        )
        #expect(!decision.webSearchEnabled)
        #expect(decision.activeCapabilityGlyphs.isEmpty)
    }

    @Test("Reasoning Fallback To Automatic Clears Brain Glyph")
    func reasoningFallbackToAutomaticClearsBrainGlyph() {
        let decision = ChatCapabilityOutboundDecision.resolve(
            webRequested: false,
            webPermitted: false,
            reasoningModeRequested: .deep,
            reasoningModePermitted: false,
            reasoningIntentRequested: "deep",
            reasoningIntentPermitted: false
        )
        #expect(decision.reasoningMode == .automatic)
        #expect(decision.reasoningIntent == nil)
        #expect(decision.activeCapabilityGlyphs.isEmpty)
    }

    @Test("Permitted Reasoning Keeps Its Tier")
    func permittedReasoningKeepsItsTier() {
        let decision = ChatCapabilityOutboundDecision.resolve(
            webRequested: false,
            webPermitted: false,
            reasoningModeRequested: .deep,
            reasoningModePermitted: true,
            reasoningIntentRequested: "deep",
            reasoningIntentPermitted: true
        )
        #expect(decision.reasoningMode == .deep)
        #expect(decision.reasoningIntent == "deep")
        #expect(decision.activeCapabilityGlyphs == ["brain"])
    }

    @Test("Intents Outside Reasoning Mode Vocabulary Still Light Brain")
    func intentsOutsideReasoningModeVocabularyStillLightBrain() {
        for intent in ["off", "low"] {
            #expect(ReasoningMode(rawValue: intent) == nil)
            let decision = ChatCapabilityOutboundDecision.resolve(
                webRequested: false,
                webPermitted: false,
                reasoningModeRequested: .automatic,
                reasoningModePermitted: true,
                reasoningIntentRequested: intent,
                reasoningIntentPermitted: true
            )
            #expect(decision.reasoningIntent == intent, "\(intent)")
            #expect(decision.activeCapabilityGlyphs == ["brain"], "\(intent)")
        }
    }

    @Test("Both Capabilities Render In Stable Order")
    func bothCapabilitiesRenderInStableOrder() {
        let decision = ChatCapabilityOutboundDecision.resolve(
            webRequested: true,
            webPermitted: true,
            reasoningModeRequested: .balanced,
            reasoningModePermitted: true,
            reasoningIntentRequested: "balanced",
            reasoningIntentPermitted: true
        )
        #expect(decision.activeCapabilityGlyphs == ["globe", "brain"])
    }

    @Test("Composer Chip Derives Only From Shared Decision")
    func composerChipDerivesOnlyFromSharedDecision() throws {
        let source = try String(
            contentsOf: Self.findFile([
                "ios", "Oriveo", "Oriveo", "Features", "Chat", "ChatComposerBar.swift",
            ]),
            encoding: .utf8
        )
        let glyphs = try #require(Self.bodyOfComputedProperty(named: "activeCapabilityGlyphs", in: source))
        #expect(glyphs.contains("capabilityDecision.activeCapabilityGlyphs"))
        #expect(!glyphs.contains("webEnabled"))
        #expect(!glyphs.contains("reasoningIntentSelection"))

        let emphasis = try #require(Self.bodyOfComputedProperty(named: "hasModelControlSelection", in: source))
        #expect(emphasis.contains("capabilityDecision.hasActiveCapabilitySelection"))
        #expect(!emphasis.contains("webEnabled"))
        #expect(!emphasis.contains("reasoningIntentSelection"))

        let summary = try #require(Self.bodyOfComputedProperty(named: "modelControlSummary", in: source))
        #expect(summary.contains("capabilityDecision.webSearchEnabled"))
        #expect(summary.contains("capabilityDecision.reasoningIntent"))
    }

    private static func bodyOfComputedProperty(named name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "var \(name): ") else { return nil }
        guard let open = source.range(of: "{", range: declaration.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("ChatComposerBar.swift not found")
    }
}
