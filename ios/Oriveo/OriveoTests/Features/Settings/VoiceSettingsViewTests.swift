import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// The voice settings page view (driven by VoiceSettingsModel, which only forwards intents).
@MainActor
@Suite("Voice settings view")
struct VoiceSettingsViewTests {

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
                "tts": [
                    [
                        "model": "gpt-4o-mini-tts",
                        "transport": "openai_speech",
                        "path": "/v1/audio/speech",
                        "outputFormat": "mp3",
                        "maxChars": 4096,
                        "speedRange": ["min": 0.25, "max": 4.0],
                        "voices": [["id": "alloy", "isDefault": true], ["id": "echo"]],
                    ],
                    [
                        "model": "tts-1",
                        "transport": "openai_speech",
                        "path": "/v1/audio/speech",
                        "outputFormat": "mp3",
                        "maxChars": 4096,
                        "voices": [["id": "nova", "isDefault": true]],
                    ],
                ],
            ],
        ],
    ] as [String: Any])

    private static let providerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private static let provider = TestFactories.makeProvider(id: providerID, kind: .openAI)

    private final class Fixture {
        let suiteName = "VoiceSettingsViewTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: VoiceEngineSettings
        var refreshCount = 0
        var previews: [VoicePreviewRequest] = []
        var stopCount = 0

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            settings = VoiceEngineSettings(defaults: defaults)
        }

        @MainActor
        func flow() -> VoiceSettingsFlow {
            let model = VoiceSettingsModel(
                settings: settings,
                refreshCatalog: { [unowned self] in
                    self.refreshCount += 1
                    return .available(VoiceSettingsViewTests.catalog)
                },
                providers: { [VoiceSettingsViewTests.provider] },
                interfaceLanguage: { "en" },
                systemVoiceQuality: { _ in .enhanced }
            )
            return VoiceSettingsFlow(
                model: model,
                preview: { [unowned self] in self.previews.append($0) },
                stopPreview: { [unowned self] in self.stopCount += 1 }
            )
        }

        func selectCloudTTS(model: String, voice: String) {
            settings.setSelection(.cloud(VoiceCloudEngine(
                providerKind: .openAI,
                connectionID: VoiceSettingsViewTests.providerID.uuidString,
                model: model,
                voice: voice
            )), for: .tts)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("The view reads only the model: it never queries the catalog or touches connections")
    func pageIsDrivenByModel() throws {
        let view = try viewSource()
        #expect(view.contains("VoiceSettingsModel"))
        #expect(!view.contains("VoiceCatalog"))
        #expect(!view.contains("catalog"))
        #expect(!view.contains("VoiceConnection"))
        #expect(!view.contains("ttsEntries"))
        #expect(!view.contains("connectionID"))
    }

    @Test("Dictation group: engine row and recognition language row; read-aloud group: engine row, voice rows and speed")
    func groupsRenderModelRows() async throws {
        let fixture = Fixture()
        fixture.selectCloudTTS(model: "gpt-4o-mini-tts", voice: "echo")
        let flow = fixture.flow()
        await flow.appear()
        #expect(flow.model.dictationEngine.title == "System")
        #expect(flow.model.dictationEngine.providerKind == nil)
        #expect(flow.model.recognitionLanguageTitle == "Automatic")
        #expect(flow.model.readAloudEngine.providerKind == .openAI)
        #expect(flow.model.voiceRows.map(\.id) == ["alloy", "echo"])
        #expect(flow.model.voiceRows.map(\.isSelected) == [false, true])

        let view = try viewSource()
        let dictation = try view.requiredSlice(from: "private var dictationGroup", to: "private var readAloudGroup")
        #expect(dictation.contains("model.dictationEngine"))
        #expect(dictation.contains("recognitionLanguageRow"))
        #expect(dictation.contains("model.dictationFooter"))
        let readAloud = try view.requiredSlice(from: "private var readAloudGroup", to: "// MARK: Rows")
        #expect(readAloud.contains("model.readAloudEngine"))
        #expect(readAloud.contains("model.voiceRows"))
        #expect(readAloud.contains("speedRow"))
        #expect(readAloud.contains("model.readAloudFooter"))
        // Voice conversation group: after the read-aloud group, just one conversation engine row + fallback notice + group footer
        let body = try view.requiredSlice(from: "var body: some View", to: "// MARK: Groups")
        let readAloudAt = try #require(body.range(of: "readAloudGroup"))
        let realtimeAt = try #require(body.range(of: "realtimeGroup"))
        #expect(readAloudAt.upperBound <= realtimeAt.lowerBound)
        let realtime = try view.requiredSlice(from: "private var realtimeGroup", to: "// MARK: Rows")
        #expect(realtime.contains("VoiceSettingsModel.realtimeGroupTitle"))
        #expect(realtime.contains("flow.openEngineSheet(.realtime)"))
        #expect(realtime.contains("engineRowLabel(model.realtimeEngine)"))
        #expect(realtime.contains("model.realtimeNotice"))
        #expect(realtime.contains("model.realtimeFooter"))
        // Engine row: logo on the left (the system engine uses the iphone symbol), chevron on the right
        let row = try view.requiredSlice(from: "private func engineRowLabel", to: "private var recognitionLanguageRow")
        #expect(row.contains("ProviderBadgeIcon(kind: providerKind"))
        #expect(row.contains("\"iphone\""))
        #expect(row.contains("chevron"))
    }

    @Test("Selecting a recognition language or voice writes back to settings")
    func selectingWritesThroughModel() async {
        let fixture = Fixture()
        fixture.selectCloudTTS(model: "gpt-4o-mini-tts", voice: "alloy")
        let flow = fixture.flow()
        await flow.appear()
        flow.model.setRecognitionLanguage("ja")
        #expect(fixture.settings.recognitionLanguage == "ja")
        flow.selectVoice("echo")
        #expect(flow.model.voiceRows.map(\.isSelected) == [false, true])
    }

    @Test("The engine row opens the engine sheet, and closing it re-reads the local settings")
    func engineRowOpensSheet() async throws {
        let fixture = Fixture()
        let flow = fixture.flow()
        await flow.appear()
        flow.openEngineSheet(.tts)
        let presentation = try #require(flow.engineSheet)
        #expect(presentation.direction == .tts)
        #expect(presentation.model.direction == .tts)
        #expect(presentation.model.rows.map(\.title) == ["System", "OpenAI", "OpenAI"])

        fixture.selectCloudTTS(model: "gpt-4o-mini-tts", voice: "alloy")
        flow.engineSheetDismissed()
        #expect(flow.engineSheet == nil)
        #expect(flow.model.readAloudEngine.providerKind == .openAI)
        #expect(fixture.refreshCount == 1)

        let view = try viewSource()
        #expect(view.contains("VoiceEngineSheet(model: presentation.model)"))
        #expect(view.contains("onDismiss: { flow.engineSheetDismissed() }"))
        #expect(view.contains("flow.openEngineSheet(.stt)"))
        #expect(view.contains("flow.openEngineSheet(.tts)"))

        flow.openEngineSheet(.realtime)
        let realtime = try #require(flow.engineSheet)
        #expect(realtime.model.direction == .realtime)
        #expect(realtime.model.title == "Conversation Engine")
        #expect(realtime.model.rows.first?.title == "Follow Current Model")
    }

    @Test("The speed slider spans 0.5…2 in 0.1 steps and is disabled when unavailable")
    func speedSlider() async throws {
        let fixture = Fixture()
        fixture.selectCloudTTS(model: "tts-1", voice: "nova")
        let flow = fixture.flow()
        await flow.appear()
        #expect(flow.model.speedRange == 0.5...2.0)
        #expect(flow.model.speedStep == 0.1)
        #expect(!flow.model.speedEnabled)

        let view = try viewSource()
        let slider = try view.requiredSlice(from: "private var speedRow", to: "private var chevron")
        #expect(slider.contains("Slider("))
        #expect(slider.contains("in: model.speedRange"))
        #expect(slider.contains("step: model.speedStep"))
        #expect(slider.contains(".disabled(!model.speedEnabled)"))
        #expect(slider.contains("model.setSpeechRate"))
    }

    @Test("Inline voice preview is forwarded to the read-aloud controller, and leaving the page calls stopPreview")
    func inlinePreviewAndStopOnLeave() async throws {
        let fixture = Fixture()
        fixture.selectCloudTTS(model: "gpt-4o-mini-tts", voice: "alloy")
        let flow = fixture.flow()
        await flow.appear()
        flow.tapPreview("echo")
        let request = try #require(fixture.previews.first)
        #expect(request.voice == "echo")
        #expect(request.provider.id == Self.providerID)
        #expect(request.entry.model == "gpt-4o-mini-tts")
        flow.disappear()
        #expect(fixture.stopCount == 1)

        let view = try viewSource()
        let row = try view.requiredSlice(from: "private func voiceRow", to: "private var speedRow")
        #expect(row.contains("flow.tapPreview(row.id)"))
        #expect(view.contains(".onDisappear { flow.disappear() }"))
    }

    @Test("While previewing, this row's button shows the stop state and the other rows show the preview state")
    func previewButtonShowsStopWhilePreviewing() throws {
        let playing = VoiceSettingsView.previewButtonAppearance(voice: "echo", previewingVoice: "echo")
        #expect(playing.systemImage == "stop.fill")
        #expect(playing.label == "Stop Reading")
        let other = VoiceSettingsView.previewButtonAppearance(voice: "alloy", previewingVoice: "echo")
        #expect(other.systemImage == "play.circle")
        #expect(other.label == "Preview")
        let idle = VoiceSettingsView.previewButtonAppearance(voice: "alloy", previewingVoice: nil)
        #expect(idle.systemImage == "play.circle")

        let view = try viewSource()
        #expect(view.contains("@ObservedObject private var readAloud = ReadAloudController.shared"))
        let row = try view.requiredSlice(from: "private func voiceRow", to: "private var speedRow")
        #expect(row.contains("previewingVoice: readAloud.previewingVoice"))
        #expect(row.contains("Image(systemName: previewButton.systemImage)"))
        #expect(row.contains(".accessibilityLabel(Text(previewButton.label))"))
    }

    @Test("System read-aloud has no voice rows, and preview is not forwarded")
    func systemReadAloudHasNoPreview() async {
        let fixture = Fixture()
        let flow = fixture.flow()
        await flow.appear()
        #expect(flow.model.voiceRows.isEmpty)
        flow.tapPreview("alloy")
        #expect(fixture.previews.isEmpty)
    }

    @Test("Appearing refreshes the catalog")
    func appearRefreshesCatalog() async throws {
        let fixture = Fixture()
        let flow = fixture.flow()
        #expect(fixture.refreshCount == 0)
        await flow.appear()
        #expect(fixture.refreshCount == 1)
        #expect(flow.model.catalogState != nil)
        // Screenshot injection appends scrolling to the same .task in DEBUG builds, so only pin that the first statement of the page's .task is appear.
        #expect(try viewSource().contains(#/\.task \{\s*await flow\.appear\(\)/#))
    }

    private func viewSource() throws -> String {
        let source = try String(contentsOf: viewSourceURL, encoding: .utf8)
        return try source.requiredSlice(from: "struct VoiceSettingsView: View", to: "\u{0}", allowEnd: true)
    }

    private var viewSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo project root
            .appendingPathComponent("Oriveo/Features/Settings/VoiceSettingsView.swift")
    }
}

private enum VoiceSettingsViewSliceError: Error {
    case missingBoundary
}

private extension String {
    func requiredSlice(from start: String, to end: String, allowEnd: Bool = false) throws -> String {
        guard let startRange = range(of: start) else { throw VoiceSettingsViewSliceError.missingBoundary }
        if let endRange = range(of: end, range: startRange.upperBound..<endIndex) {
            return String(self[startRange.lowerBound..<endRange.lowerBound])
        }
        guard allowEnd else { throw VoiceSettingsViewSliceError.missingBoundary }
        return String(self[startRange.lowerBound...])
    }
}
