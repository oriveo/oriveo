import Foundation
import Testing
@testable import Oriveo

/// Engine selection sheet presentation model: title, rows, checkmark, footer, and handing taps to the engine-choosing flow.
@MainActor
@Suite("Voice engine sheet model")
struct VoiceEngineSheetModelTests {

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
            ],
        ],
    ] as [String: Any])

    private static let openAIWork = VoiceConnection(id: "c1", providerKind: .openAI, authMode: .apiKey, hasKey: true)
    private static let openAIHome = VoiceConnection(id: "c2", providerKind: .openAI, authMode: .apiKey, hasKey: true)
    private static let anthropic = VoiceConnection(id: "c3", providerKind: .anthropic, authMode: .apiKey, hasKey: true)
    private static let deepseek = VoiceConnection(id: "c4", providerKind: .deepseek, authMode: .apiKey, hasKey: true)

    private final class Fixture {
        let suiteName = "VoiceEngineSheetModelTests-\(UUID().uuidString)"
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

        func model(
            _ direction: VoiceDirection,
            state: VoiceCatalogState = .available(VoiceEngineSheetModelTests.catalog),
            connections: [VoiceConnection] = [VoiceEngineSheetModelTests.openAIWork],
            names: [String: String] = [:]
        ) -> VoiceEngineSheetModel {
            VoiceEngineSheetModel(
                direction: direction,
                catalogState: { state },
                connections: { VoiceEngineSheetConnections(connections, names: names) },
                chooser: chooser
            )
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("Titles differ for dictation, read aloud and conversation")
    func titles() {
        let fixture = Fixture()
        #expect(fixture.model(.stt).title == "Dictation Engine")
        #expect(fixture.model(.tts).title == "Read-Aloud Engine")
        #expect(fixture.model(.realtime).title == "Conversation Engine")
        #expect(fixture.model(.stt).addConnectionTitle == "Add Connection")
    }

    @Test("Conversation engine: the first row follows the current model (subtitle dictation → current model → read aloud), cloud rows are formatted like dictation")
    func realtimeRows() {
        let fixture = Fixture()
        let catalog = VoiceCatalogDecoder.decode([
            "providers": [
                "openAI": [
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
        let model = fixture.model(.realtime, state: .available(catalog))
        #expect(model.rows.map(\.title) == ["Follow Current Model", "OpenAI"])
        #expect(model.rows.map(\.subtitle) == ["Dictation → current model → read aloud", "gpt-realtime"])
        #expect(model.rows.map(\.isSelected) == [true, false])
    }

    @Test("System row first; a cloud row is provider name + model; a single connection of one provider omits the connection name")
    func rowsSingleConnection() {
        let fixture = Fixture()
        let rows = fixture.model(.stt, names: ["c1": "Work"]).rows
        #expect(rows.count == 2)
        #expect(rows[0].option == .system)
        #expect(rows[0].title == "System")
        #expect(rows[0].subtitle == "Built into your device, free")
        #expect(rows[1].title == "OpenAI")
        #expect(rows[1].subtitle == "gpt-4o-transcribe")

        let ttsRows = fixture.model(.tts).rows
        #expect(ttsRows.map(\.subtitle) == ["Built into your device, free", "gpt-4o-mini-tts"])
    }

    @Test("With several connections of one provider the subtitle appends \" · connection name\"")
    func rowsMultipleConnectionsOfSameKind() {
        let fixture = Fixture()
        let rows = fixture.model(
            .stt,
            connections: [Self.openAIWork, Self.openAIHome, Self.anthropic],
            names: ["c1": "Work", "c2": "Home", "c3": "Claude"]
        ).rows
        #expect(rows.map(\.title) == ["System", "OpenAI", "OpenAI"])
        #expect(rows.dropFirst().map(\.subtitle) == ["gpt-4o-transcribe · Work", "gpt-4o-transcribe · Home"])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test("The current selection is checked")
    func checkmark() {
        let fixture = Fixture()
        #expect(fixture.model(.stt).rows.map(\.isSelected) == [true, false])

        fixture.settings.setSelection(
            .cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: "c2", model: "gpt-4o-transcribe")),
            for: .stt
        )
        let rows = fixture.model(.stt, connections: [Self.openAIWork, Self.openAIHome]).rows
        #expect(rows.map(\.isSelected) == [false, false, true])
        // The other direction is unaffected.
        #expect(fixture.model(.tts).rows.map(\.isSelected) == [true, false])
    }

    @Test("Catalog 404 shows no cloud voice engines; a load failure without cache shows can't-load; both leave only the System row")
    func footerForCatalogStates() {
        let fixture = Fixture()
        let unavailable = fixture.model(.stt, state: .unavailable)
        #expect(unavailable.footer == "No cloud voice engines yet")
        #expect(unavailable.rows.map(\.option) == [.system])

        let failed = fixture.model(.tts, state: .loadFailed)
        #expect(failed.footer == "Cloud engines can't be loaded right now")
        #expect(failed.rows.map(\.option) == [.system])
    }

    @Test("Connections empty and catalog undecided at open; once they arrive, the same sheet's rows and footer refresh")
    func sheetRowsRefreshWhenConnectionsArriveLate() {
        let fixture = Fixture()
        var state: VoiceCatalogState?
        var connections: [VoiceConnection] = []
        var names: [String: String] = [:]
        let model = VoiceEngineSheetModel(
            direction: .stt,
            catalogState: { state },
            connections: { VoiceEngineSheetConnections(connections, names: names) },
            chooser: fixture.chooser
        )
        #expect(model.catalogState == nil)
        #expect(model.rows.map(\.option) == [.system])
        #expect(model.footer == nil)

        state = .available(Self.catalog)
        connections = [Self.openAIWork, Self.openAIHome, Self.anthropic]
        names = ["c1": "Work", "c2": "Home"]
        #expect(model.catalogState == .available(Self.catalog))
        #expect(model.rows.map(\.title) == ["System", "OpenAI", "OpenAI"])
        #expect(model.rows.dropFirst().map(\.subtitle) == ["gpt-4o-transcribe · Work", "gpt-4o-transcribe · Home"])
        #expect(model.footer == "Voice isn't available yet for your Anthropic connections")
    }

    @Test("A non-empty pending list shows the not-yet-supported footer (provider names joined by ListFormatter); an empty list shows no footer")
    func footerForPendingProviders() {
        let fixture = Fixture()
        let model = fixture.model(.stt, connections: [Self.openAIWork, Self.anthropic, Self.deepseek])
        let pending = VoiceEngineResolver.pendingProviders(
            direction: .stt,
            catalog: Self.catalog,
            connections: [Self.openAIWork, Self.anthropic, Self.deepseek]
        )
        #expect(pending == [.anthropic, .deepseek])
        let joined = ListFormatter.localizedString(byJoining: ["Anthropic", "DeepSeek"])
        #expect(model.footer == "Voice isn't available yet for your \(joined) connections")

        #expect(fixture.model(.stt).footer == nil)
    }

    @Test("An unknown providerKind shows the raw string")
    func unknownProviderKindShowsRawString() {
        #expect(VoiceEngineSheetModel.providerTitle("anthropic") == "Anthropic")
        #expect(VoiceEngineSheetModel.providerTitle("someNewVendor") == "someNewVendor")
    }

    @Test("Choosing an unconsented cloud row requires disclosure and leaves settings untouched; after consent it is written and checked")
    func choosingUnconsentedCloudRowNeedsDisclosure() {
        let fixture = Fixture()
        let model = fixture.model(.tts)
        let cloudRow = model.rows[1]
        let outcome = model.choose(cloudRow)
        let engine = VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "gpt-4o-mini-tts", voice: "alloy")
        #expect(outcome == .needsDisclosure(engine))
        #expect(fixture.settings.selection(for: .tts) == .system)
        #expect(model.rows.map(\.isSelected) == [true, false])

        #expect(model.resolveDisclosure(engine, accepted: true))
        #expect(fixture.settings.selection(for: .tts) == .cloud(engine))
        #expect(model.rows.map(\.isSelected) == [false, true])

        #expect(model.choose(model.rows[0]) == .applied(.system))
        #expect(model.rows.map(\.isSelected) == [true, false])
    }
}
