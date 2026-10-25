import Foundation
import Testing
@testable import Oriveo

/// The engine selection sheet and the cloud-only disclosure sheet (driven by VoiceEngineSheetModel, which only forwards intents).
@MainActor
@Suite("Voice engine sheet view")
struct VoiceEngineSheetViewTests {

    private static let catalog: VoiceCatalog = VoiceCatalogDecoder.decode([
        "providers": [
            "openAI": [
                "stt": [[
                    "model": "gpt-4o-transcribe",
                    "transport": "openai_transcriptions",
                    "path": "/v1/audio/transcriptions",
                    "maxBytes": 25_000_000,
                    "maxDurationSec": 600,
                ]],
                "tts": [[
                    "model": "gpt-4o-mini-tts",
                    "transport": "openai_speech",
                    "path": "/v1/audio/speech",
                    "outputFormat": "mp3",
                    "maxChars": 4096,
                    "voices": [["id": "alloy", "isDefault": true]],
                ]],
                "realtime": [[
                    "model": "gpt-realtime",
                    "transport": "openai_realtime",
                    "path": "/v1/realtime",
                    "contextWindow": 128_000,
                    "voices": [["id": "marin", "isDefault": true]],
                    "inputTranscriptionModel": "gpt-4o-mini-transcribe",
                ]],
            ],
        ],
    ] as [String: Any])

    private static let openAI = VoiceConnection(id: "c1", providerKind: .openAI, authMode: .apiKey, hasKey: true)

    private final class Fixture {
        let suiteName = "VoiceEngineSheetViewTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: VoiceEngineSettings
        let disclosures: VoiceDisclosureStore
        let chooser: VoiceEngineChooser

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            settings = VoiceEngineSettings(defaults: defaults)
            disclosures = VoiceDisclosureStore(defaults: defaults)
            chooser = VoiceEngineChooser(settings: settings, disclosures: disclosures)
        }

        @MainActor
        func flow(_ direction: VoiceDirection) -> VoiceEngineSheetFlow {
            VoiceEngineSheetFlow(model: VoiceEngineSheetModel(
                direction: direction,
                catalogState: { .available(VoiceEngineSheetViewTests.catalog) },
                connections: { VoiceEngineSheetConnections([VoiceEngineSheetViewTests.openAI], names: ["c1": "Work"]) },
                chooser: chooser
            ))
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func cloudRow(_ flow: VoiceEngineSheetFlow) throws -> VoiceEngineSheetRow {
        try #require(flow.model.rows.first { if case .cloud = $0.option { true } else { false } })
    }

    @Test("The sheet renders the model's rows: System first, cloud rows supplied by the model")
    func sheetIsDrivenByModel() {
        let fixture = Fixture()
        let flow = fixture.flow(.stt)
        #expect(flow.model.rows.map(\.title) == ["System", "OpenAI"])
        #expect(flow.model.rows.map(\.isSelected) == [true, false])
        #expect(flow.disclosure == nil)
    }

    @Test("Tapping System applies immediately and closes the sheet without a disclosure")
    func tapSystemAppliesAndCloses() {
        let fixture = Fixture()
        let flow = fixture.flow(.tts)
        #expect(flow.tap(flow.model.rows[0]))
        #expect(flow.disclosure == nil)
        #expect(fixture.settings.selection(for: .tts) == .system)
    }

    @Test("Tapping an unconsented cloud row presents the disclosure, leaves settings untouched and keeps the engine sheet open")
    func tapCloudWithoutConsentPresentsDisclosure() throws {
        let fixture = Fixture()
        let flow = fixture.flow(.stt)
        #expect(!flow.tap(try cloudRow(flow)))
        let request = try #require(flow.disclosure)
        #expect(request.engine == VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "gpt-4o-transcribe"))
        #expect(request.direction == .stt)
        #expect(fixture.settings.selection(for: .stt) == .system)
    }

    @Test("Disclosure title and body differ per direction, and the link comes from ProviderKind.privacyPolicyURL")
    func disclosureCopyPerDirection() throws {
        #expect(VoiceDisclosureSheet.title(provider: .openAI, direction: .stt) == "Use OpenAI for Dictation?")
        #expect(VoiceDisclosureSheet.title(provider: .openAI, direction: .tts) == "Use OpenAI for Read Aloud?")
        #expect(VoiceDisclosureSheet.message(provider: .openAI, direction: .stt)
            == "Your recordings will be sent to OpenAI to be transcribed. Oriveo doesn't keep them, and the provider's privacy policy applies.")
        #expect(VoiceDisclosureSheet.message(provider: .openAI, direction: .tts)
            == "Replies you play will be sent as text to OpenAI to generate speech. Oriveo doesn't keep them, and the provider's privacy policy applies.")
        let url = try #require(VoiceDisclosureSheet.policyURL(provider: .openAI))
        #expect(url == ProviderKind.openAI.privacyPolicyURL)
    }

    @Test("Conversation engine disclosure: title and body name the provider, link same as the other directions")
    func realtimeDisclosureCopy() {
        #expect(VoiceDisclosureSheet.title(provider: .openAI, direction: .realtime) == "Use OpenAI for Voice Conversations?")
        #expect(VoiceDisclosureSheet.message(provider: .openAI, direction: .realtime)
            == "In voice conversations, OpenAI answers instead of this chat's model. Your voice and this chat's history are sent to OpenAI, usage is billed to your connection, and OpenAI's privacy policy applies.")
    }

    @Test("Conversation engine: an unconsented cloud row shows the disclosure; Not Now writes nothing, Agree writes the selection and records realtime consent")
    func realtimeDisclosureGatesSelection() throws {
        let fixture = Fixture()
        let flow = fixture.flow(.realtime)
        let engine = VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "gpt-realtime", voice: "marin")

        #expect(!flow.tap(try cloudRow(flow)))
        #expect(flow.disclosure == VoiceDisclosureRequest(engine: engine, direction: .realtime))
        flow.answerDisclosure(accepted: false)
        #expect(!flow.disclosureDismissed())
        #expect(fixture.settings.selection(for: .realtime) == .system)
        #expect(!fixture.disclosures.hasAccepted(.openAI, direction: .realtime))

        #expect(!flow.tap(try cloudRow(flow)))
        flow.answerDisclosure(accepted: true)
        #expect(flow.disclosureDismissed())
        #expect(fixture.settings.selection(for: .realtime) == .cloud(engine))
        #expect(fixture.disclosures.hasAccepted(.openAI, direction: .realtime))
        #expect(!fixture.disclosures.hasAccepted(.openAI, direction: .stt))
    }

    @Test("Disclosure buttons are Agree and Use / Not Now, and the link is Privacy Policy")
    func disclosureButtons() throws {
        let source = try String(contentsOf: sheetSourceURL, encoding: .utf8)
        let disclosure = try source.requiredSlice(from: "struct VoiceDisclosureSheet", to: ".presentationDetents")
        #expect(disclosure.contains("L10n.tr(\"Agree and Use\", table: .voice)"))
        #expect(disclosure.contains("L10n.tr(\"Not Now\", table: .voice)"))
        #expect(disclosure.contains("L10n.tr(\"Privacy Policy\", table: .voice)"))
        #expect(!disclosure.contains("interactiveDismissDisabled"))
    }

    // Previously the body and buttons shared one content-height VStack capped at 640pt with only a .height detent;
    // with large type or long copy beyond 640pt the buttons were pushed out of view and unreachable.
    @Test("The disclosure body scrolls inside a ScrollView, buttons are pinned outside it, and detents include .large as a fallback")
    func disclosure_body_scrolls_and_buttons_stay_outside_scroll() throws {
        let source = try String(contentsOf: sheetSourceURL, encoding: .utf8)
        let disclosure = try source.requiredSlice(from: "struct VoiceDisclosureSheet", to: "private var fittedHeight")
        let scrolled = try disclosure.requiredSlice(from: "ScrollView {", to: ".scrollBounceBehavior")
        #expect(scrolled.contains("Self.title(provider: provider, direction: direction)"))
        #expect(scrolled.contains("Self.message(provider: provider, direction: direction)"))
        #expect(scrolled.contains("L10n.tr(\"Privacy Policy\", table: .voice)"))
        #expect(!scrolled.contains("L10n.tr(\"Agree and Use\", table: .voice)"))
        #expect(!scrolled.contains("L10n.tr(\"Not Now\", table: .voice)"))
        let pinned = try disclosure.requiredSlice(from: ".scrollBounceBehavior", to: ".presentationDetents")
        #expect(pinned.contains("L10n.tr(\"Agree and Use\", table: .voice)"))
        #expect(pinned.contains("L10n.tr(\"Not Now\", table: .voice)"))
        let detents = try disclosure.requiredSlice(from: ".presentationDetents(", to: "\n")
        #expect(detents.contains(".large"))
    }

    @Test("Agree and Use records consent, writes the setting, and closes the engine sheet along with the disclosure")
    func agreeAppliesAndClosesEngineSheet() throws {
        let fixture = Fixture()
        let flow = fixture.flow(.tts)
        _ = flow.tap(try cloudRow(flow))
        let engine = try #require(flow.disclosure?.engine)
        flow.answerDisclosure(accepted: true)
        #expect(flow.disclosureDismissed())
        #expect(flow.disclosure == nil)
        #expect(fixture.settings.selection(for: .tts) == .cloud(engine))
        #expect(fixture.disclosures.hasAccepted(.openAI, direction: .tts))
        #expect(flow.model.rows.map(\.isSelected) == [false, true])
    }

    @Test("Not Now writes no setting and keeps the engine sheet open")
    func notNowKeepsSelection() throws {
        let fixture = Fixture()
        let flow = fixture.flow(.stt)
        _ = flow.tap(try cloudRow(flow))
        flow.answerDisclosure(accepted: false)
        #expect(!flow.disclosureDismissed())
        #expect(fixture.settings.selection(for: .stt) == .system)
        #expect(!fixture.disclosures.hasAccepted(.openAI, direction: .stt))
    }

    @Test("Swipe-dismissing without an answer counts as a decline")
    func swipeDismissCountsAsDecline() throws {
        let fixture = Fixture()
        let flow = fixture.flow(.stt)
        _ = flow.tap(try cloudRow(flow))
        #expect(!flow.disclosureDismissed())
        #expect(flow.disclosure == nil)
        #expect(fixture.settings.selection(for: .stt) == .system)
        #expect(!fixture.disclosures.hasAccepted(.openAI, direction: .stt))
        // Tapping again still requires the disclosure
        #expect(!flow.tap(try cloudRow(flow)))
        #expect(flow.disclosure != nil)
    }

    @Test("A cloud engine that was already consented applies directly")
    func consentedCloudAppliesDirectly() throws {
        let fixture = Fixture()
        fixture.disclosures.markAccepted(.openAI, direction: .stt)
        let flow = fixture.flow(.stt)
        #expect(flow.tap(try cloudRow(flow)))
        #expect(flow.disclosure == nil)
    }

    @Test("Add Connection dismisses the sheet first, then calls openProviderSetup(from: .providers)")
    func addConnectionDismissesThenOpensSetup() {
        var calls: [String] = []
        VoiceEngineSheetFlow.addConnection(
            dismiss: { calls.append("dismiss") },
            openProviderSetup: { calls.append("open:\($0.rawValue)") }
        )
        #expect(calls == ["dismiss", "open:providers"])
    }

    @Test("Add Connection is the last row of the white card and the footer sits below the card")
    func addConnectionIsLastRowOfCard() throws {
        let source = try String(contentsOf: sheetSourceURL, encoding: .utf8)
        let section = try source.requiredSlice(from: "Section {", to: ".listStyle(.insetGrouped)")
        let rows = try #require(section.range(of: "ForEach(model.rows)"))
        let add = try #require(section.range(of: "addConnectionRow"))
        let footer = try #require(section.range(of: "} footer: {"))
        #expect(rows.lowerBound < add.lowerBound)
        #expect(add.lowerBound < footer.lowerBound)
        #expect(section.contains("model.footer"))
    }

    private var sheetSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo project root
            .appendingPathComponent("Oriveo/Features/Settings/VoiceEngineSheet.swift")
    }
}

private enum VoiceEngineSheetSliceError: Error {
    case missingBoundary
}

private extension String {
    func requiredSlice(from start: String, to end: String) throws -> String {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
            throw VoiceEngineSheetSliceError.missingBoundary
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
