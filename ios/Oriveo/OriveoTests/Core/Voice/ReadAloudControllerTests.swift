import AVFoundation
import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Drives ReadAloudController with a fake engine: start/stop, switching, finishing, failures and the automatic stops.
@Suite("Read aloud controller", .serialized)
@MainActor
struct ReadAloudControllerTests {

    private let engine = FakeSpeechEngine()
    private let platform = FakeReadAloudPlatform()
    private let idleTimer = FakeIdleTimer()
    private let screenAwake: ScreenAwakeHolds
    private let center = NotificationCenter()
    private let messageA = UUID()
    private let messageB = UUID()
    private let conversation = UUID()
    private static let threeSentences = "First sentence. Second sentence. Third sentence."

    init() {
        screenAwake = ScreenAwakeHolds(timer: idleTimer)
    }

    private func makeController() -> ReadAloudController {
        ReadAloudController(
            engine: engine, platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { _ in "en" }
        )
    }

    private func makeController(engines: ReadAloudEngineSource) -> ReadAloudController {
        ReadAloudController(
            engines: engines, platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { _ in "en" }
        )
    }

    /// Production resolution source for a user whose settings still hold the system engine (nothing stored).
    private func systemSource() -> ReadAloudEngineSource {
        .resolving(settings: Self.freshSettings(), catalog: { nil }, providers: { [] }, system: engine)
    }

    private static let cloudModel = "gpt-4o-mini-tts"

    private static let ttsEntry = VoiceTTSEntry(
        model: cloudModel, transport: .openAISpeech, path: "/v1/audio/speech", outputFormat: "mp3",
        maxChars: 4_000,
        voices: [VoiceCatalogVoice(id: "alloy", isDefault: true), VoiceCatalogVoice(id: "nova", isDefault: false)],
        speedRange: VoiceSpeedRange(min: 0.25, max: 4), isDefault: true
    )

    private static let catalog = VoiceCatalog(
        schemaVersion: 2, revision: "r1", providers: [.relay: VoiceProviderEntries(stt: [], tts: [ttsEntry])]
    )

    private static func relayProvider() -> Provider {
        TestFactories.makeProvider(kind: .relay, apiKey: "sk-voice", baseURLText: "https://relay.example.com/gateway/v1")
    }

    private static func freshSettings() -> VoiceEngineSettings {
        VoiceEngineSettings(defaults: UserDefaults(suiteName: "ReadAloudControllerTests-\(UUID().uuidString)")!)
    }

    /// Writes a cloud read-aloud selection and, by default, the provider disclosure consent too
    /// (a selection made through the engine sheet always has the consent recorded).
    private static func selectCloud(_ settings: VoiceEngineSettings, connectionID: String, accepted: Bool = true) {
        settings.setSelection(.cloud(VoiceCloudEngine(
            providerKind: .relay, connectionID: connectionID, model: cloudModel, voice: "nova"
        )), for: .tts)
        if accepted { settings.disclosures.markAccepted(.relay, direction: .tts) }
    }

    // MARK: Start and stop

    @Test("Toggle starts reading: state, audio session and idle timer")
    func toggleStarts() {
        idleTimer.isIdleTimerDisabled = false
        let controller = makeController(engines: systemSource())
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(engine.spoken.last?.map(\.text) == ["First sentence.", "Second sentence.", "Third sentence."])
        #expect(engine.spoken.last?.allSatisfy { $0.language == "en" } == true)
        #expect(platform.activations == 1)
        #expect(idleTimer.isIdleTimerDisabled)
    }

    @Test("Tapping the same reply again stops: back to idle, idle timer restored, session released")
    func toggleSameStops() {
        idleTimer.isIdleTimerDisabled = false
        let controller = makeController(engines: systemSource())
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .idle)
        #expect(engine.stopCount == 1)
        #expect(platform.deactivations == 1)
        #expect(!idleTimer.isIdleTimerDisabled)
        #expect(engine.spoken.count == 1)
    }

    @Test("Tapping another reply stops the current one, then starts the new one")
    func toggleOtherSwitches() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.toggle(messageID: messageB, text: "Only one.")

        #expect(controller.state == .speaking(messageID: messageB, index: 0, total: 1))
        #expect(engine.stopCount == 1)
        #expect(platform.deactivations == 1)
        #expect(engine.spoken.count == 2)
    }

    @Test("Advances segment by segment and returns to idle when finished")
    func finishesAfterAllSegments() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        engine.delegate?.speechEngineDidStartSegment(at: 1)
        #expect(controller.state == .speaking(messageID: messageA, index: 1, total: 3))
        engine.delegate?.speechEngineDidStartSegment(at: 2)
        engine.delegate?.speechEngineDidFinishAll()

        #expect(controller.state == .idle)
        #expect(platform.toasts.isEmpty)
        #expect(platform.deactivations == 1)
    }

    @Test("Engine failure marks the reply failed and shows a toast")
    func failureMarksFailed() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        engine.delegate?.speechEngineDidStartSegment(at: 1)
        engine.delegate?.speechEngineDidFail()

        #expect(controller.state == .failed(messageID: messageA))
        #expect(platform.toasts == [.couldNotRead])
        #expect(platform.deactivations == 1)
    }

    @Test("After a failure the button looks idle (speaker) and tapping it starts again")
    func failedButtonLooksIdleAndRestarts() throws {
        let controller = makeController()
        let readAloud = ReadAloudButton(controller: controller)
        readAloud.configure(messageID: messageA, text: Self.threeSentences, isEligible: true)
        let button = try #require(readAloud.subviews.compactMap { $0 as? UIButton }.first)
        #expect(!readAloud.isHidden)

        button.sendActions(for: .touchUpInside)
        #expect(button.accessibilityLabel == L10n.tr("Stop Reading", table: .voice))
        engine.delegate?.speechEngineDidFail()
        #expect(controller.state == .failed(messageID: messageA))
        #expect(button.accessibilityLabel == L10n.tr("Read Aloud", table: .voice))
        #expect(button.accessibilityValue == nil)
        #expect(button.configuration?.baseForegroundColor != .clear)

        button.sendActions(for: .touchUpInside)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(engine.spoken.count == 2)
    }

    @Test("Empty text, whitespace and separators only, and ineligible messages show no read-aloud button")
    func buttonHiddenWithoutSpeakableContent() {
        let readAloud = ReadAloudButton(controller: makeController())
        readAloud.configure(messageID: messageA, text: "", isEligible: true)
        #expect(readAloud.isHidden)
        readAloud.configure(messageID: messageA, text: "  \n\n---\n\n**  **\n", isEligible: true)
        #expect(readAloud.isHidden)
        readAloud.configure(messageID: messageA, text: Self.threeSentences, isEligible: false)
        #expect(readAloud.isHidden)
        readAloud.configure(messageID: messageA, text: Self.threeSentences, isEligible: true)
        #expect(!readAloud.isHidden)
    }

    @Test("No system voice on the device shows a toast and does not start")
    func noVoiceShowsToast() {
        engine.hasAnyVoice = false
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .failed(messageID: messageA))
        #expect(platform.toasts == [.noVoice])
        #expect(engine.spoken.isEmpty)
        #expect(platform.activations == 0)
    }

    @Test("Nothing speakable does nothing")
    func emptySpeakableTextIsIgnored() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: "```\ncode only\n```")
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 1))
        controller.stop(.userStopped)
        controller.toggle(messageID: messageB, text: "🎉 👍")
        #expect(controller.state == .idle)
        #expect(engine.spoken.count == 1)
    }

    @Test("Measurement: language detection plus engine selection when starting a 20,000-character reply (printed, not asserted)")
    func measureStartLanguageDetectionCost() {
        let paragraph = String(
            repeating: "\u{8FD9}\u{662F}\u{4E00}\u{6BB5}\u{7528}\u{4E8E}\u{6D4B}\u{91CF}\u{6717}\u{8BFB}\u{5F00}\u{59CB}\u{8017}\u{65F6}\u{7684}\u{4E2D}\u{6587}\u{53E5}\u{5B50}\u{FF0C}\u{5305}\u{542B}\u{4E00}\u{4E9B} English words \u{6DF7}\u{6392}\u{3002}",
            count: 8
        )
        var text = ""
        while text.count < 20_000 { text += paragraph + "\n\n" }
        let joined = SpeakableText.segments(text: text, final: true).compactMap { segment -> String? in
            if case .sentence(let sentence) = segment { return sentence }
            return nil
        }.joined(separator: " ")
        let clock = ContinuousClock()
        let detect = clock.measure { _ = ReadAloudController.dominantLanguage(joined) }
        let controller = ReadAloudController(
            engines: systemSource(), platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: ReadAloudController.dominantLanguage
        )
        let start = clock.measure { controller.toggle(messageID: messageA, text: text) }
        print("READ_ALOUD_START_COST chars=\(text.count) detectLanguage=\(detect) toggleStart=\(start)")
        #expect(controller.state != .idle)
    }

    @Test("Placeholder sentences come from the Voice table in the placeholder locale")
    func placeholderUsesLocalizedSentence() {
        platform.uiLanguage = "ja"
        let controller = ReadAloudController(
            engine: engine, platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { _ in "fi" }
        )
        controller.toggle(messageID: messageA, text: "Before.\n\n| a |\n\nAfter.")

        let utterances = engine.spoken.last ?? []
        #expect(utterances.count == 3)
        #expect(utterances[1] == SpeechUtterance(text: "ja:Here's a table.", language: "ja"))
        #expect(utterances[0].language == "fi")
    }

    @Test("Language detection input is the first 2000 code points (same as Android), not graphemes")
    func language_detection_prefix_counts_code_points() {
        var detected: [String] = []
        let controller = ReadAloudController(
            engine: engine, platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { detected.append($0); return "en" }
        )
        // Each grapheme is 2 code points (e + combining acute), 3000 code points in total.
        controller.toggle(messageID: messageA, text: String(repeating: "e\u{301}", count: 1_500) + ".")

        let input = detected.first ?? ""
        #expect(input.unicodeScalars.count == ReadAloudController.languageDetectionLimit)
        // Cutting by grapheme would take twice as many code points; the grapheme count is necessarily below the limit.
        #expect(input.count < ReadAloudController.languageDetectionLimit)
    }

    // MARK: Engine selection from settings

    @Test("System selected: the system engine is used and no cloud engine is built")
    func systemSelectionUsesSystemEngine() {
        var cloudBuilt = 0
        let controller = makeController(engines: .resolving(
            settings: Self.freshSettings(),
            catalog: { .available(Self.catalog) },
            providers: { [Self.relayProvider()] },
            system: engine,
            makeCloud: { _, _, _ in cloudBuilt += 1; return FakeSpeechEngine() }
        ))
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts.isEmpty)
    }

    @Test("Cloud selected and available: the cloud engine gets the entry, voice, effective speed and reading language")
    func cloudSelectionUsesCloudEngine() throws {
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, connectionID: provider.id.uuidString)
        settings.speechRate = 1.237
        let cloud = FakeSpeechEngine()
        var setups: [CloudSpeechSetup] = []
        var fallbacks: [SpeechEngine] = []
        let fallbackEngine = FakeSpeechEngine()
        let controller = makeController(engines: .resolving(
            settings: settings,
            catalog: { .available(Self.catalog) },
            providers: { [provider] },
            system: engine,
            makeFallback: { fallbackEngine },
            makeCloud: { setup, fallback, _ in
                setups.append(setup)
                fallbacks.append(fallback)
                return cloud
            }
        ))
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        let baseURL = try #require(DictationEngineSource.requestBaseURL(provider))
        #expect(setups == [CloudSpeechSetup(
            entry: Self.ttsEntry, providerKind: .relay, baseURL: baseURL, apiKey: "sk-voice",
            voice: "nova", speed: 1.24, language: "en"
        )])
        #expect(fallbacks.count == 1)
        #expect(fallbacks.first === fallbackEngine)
        #expect(cloud.spoken.last?.map(\.text) == ["First sentence.", "Second sentence.", "Third sentence."])
        #expect(engine.spoken.isEmpty)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(platform.toasts.isEmpty)
        #expect(settings.selection(for: .tts) != .system)

        cloud.delegate?.speechEngineDidFinishAll()
        #expect(controller.state == .idle)
    }

    @Test("A cloud selection without a recorded disclosure (restored backup or old data) uses the system engine this time, without rewriting settings or showing a notice")
    func cloudSelectionWithoutConsentUsesSystemOnce() {
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, connectionID: provider.id.uuidString, accepted: false)
        let selected = settings.selection(for: .tts)
        var cloudBuilt = 0
        let controller = makeController(engines: .resolving(
            settings: settings,
            catalog: { .available(Self.catalog) },
            providers: { [provider] },
            system: engine,
            makeCloud: { _, _, _ in cloudBuilt += 1; return FakeSpeechEngine() }
        ))
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts.isEmpty)
        #expect(settings.selection(for: .tts) == selected)
        #expect(settings.takePendingNotice(site: .settings, direction: .tts) == nil)
    }

    @Test("Cloud falls back midway: one notice (provider name, not the connection's custom name), reading continues, settings untouched")
    func cloudMidwayFallbackToastsOnce() {
        let settings = Self.freshSettings()
        var provider = Self.relayProvider()
        provider.customName = "My Team Gateway"
        Self.selectCloud(settings, connectionID: provider.id.uuidString)
        let selected = settings.selection(for: .tts)
        let cloud = FakeSpeechEngine()
        var triggers: [() -> Void] = []
        let controller = makeController(engines: .resolving(
            settings: settings,
            catalog: { .available(Self.catalog) },
            providers: { [provider] },
            system: engine,
            makeFallback: { FakeSpeechEngine() },
            makeCloud: { _, _, onFallback in
                triggers.append(onFallback)
                return cloud
            }
        ))
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        cloud.delegate?.speechEngineDidStartSegment(at: 1)
        triggers.first?()
        triggers.first?()

        #expect(platform.toasts == [.cloudFallback(providerName: ProviderKind.relay.displayName)])
        #expect(provider.displayName == "My Team Gateway")
        #expect(!platform.toasts.contains(.cloudFallback(providerName: provider.displayName)))
        #expect(ReadAloudToast.cloudFallback(providerName: "Relay").localizationKey
                == "%@ is unavailable right now. Switched to the system voice.")
        #expect(controller.state == .speaking(messageID: messageA, index: 1, total: 3))
        cloud.delegate?.speechEngineDidStartSegment(at: 2)
        #expect(controller.state == .speaking(messageID: messageA, index: 2, total: 3))
        #expect(settings.selection(for: .tts) == selected)

        cloud.delegate?.speechEngineDidFinishAll()
        #expect(controller.state == .idle)

        // A callback that arrives after reading finished shows nothing; the next reading may show one notice again.
        triggers.first?()
        #expect(platform.toasts.count == 1)
        controller.toggle(messageID: messageB, text: "Only one.")
        #expect(triggers.count == 2)
        triggers.last?()
        #expect(platform.toasts.count == 2)
    }

    @Test("The selected connection is gone: system engine, a \"selected engine is unavailable\" notice, and settings are rewritten to system")
    func missingConnectionFallsBackAndRewrites() {
        let settings = Self.freshSettings()
        Self.selectCloud(settings, connectionID: UUID().uuidString)
        var cloudBuilt = 0
        let controller = makeController(engines: .resolving(
            settings: settings,
            catalog: { .available(Self.catalog) },
            providers: { [Self.relayProvider()] },
            system: engine,
            makeCloud: { _, _, _ in cloudBuilt += 1; return FakeSpeechEngine() }
        ))
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts == [.engineUnavailable])
        #expect(ReadAloudToast.engineUnavailable.localizationKey
                == "The selected read-aloud engine is unavailable. Using the system voice.")
        #expect(settings.selection(for: .tts) == .system)
    }

    @Test("The settings page found the fallback first and rewrote it: the next reading shows the \"engine unavailable\" notice once, the one after shows none")
    func settingsSiteFallbackNotifiesNextReadOnce() {
        let settings = Self.freshSettings()
        Self.selectCloud(settings, connectionID: UUID().uuidString)
        // When the settings page resolved, the selected connection was already gone: storage goes back to system
        // and one pending notice is left for the place of use.
        settings.resolve(
            direction: .tts, catalog: Self.catalog,
            connections: [Self.relayProvider()].map(VoiceConnection.init(provider:)), site: .settings
        )
        #expect(settings.selection(for: .tts) == .system)
        var cloudBuilt = 0
        let controller = makeController(engines: .resolving(
            settings: settings,
            catalog: { .available(Self.catalog) },
            providers: { [Self.relayProvider()] },
            system: engine,
            makeCloud: { _, _, _ in cloudBuilt += 1; return FakeSpeechEngine() }
        ))

        controller.toggle(messageID: messageA, text: Self.threeSentences)
        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts == [.engineUnavailable])
        controller.stop(.userStopped)

        controller.toggle(messageID: messageB, text: "Only one.")
        #expect(engine.spoken.count == 2)
        #expect(platform.toasts == [.engineUnavailable])
        #expect(settings.takePendingNotice(site: .settings, direction: .tts) == nil)
        controller.stop(.userStopped)
    }

    @Test("No cached catalog, load failure or an unavailable (404) catalog: system engine, settings untouched, no notice")
    func catalogWithoutConclusionKeepsSelection() {
        let states: [VoiceCatalogState?] = [nil, .loadFailed, .unavailable]
        for state in states {
            let settings = Self.freshSettings()
            let provider = Self.relayProvider()
            Self.selectCloud(settings, connectionID: provider.id.uuidString)
            let system = FakeSpeechEngine()
            var cloudBuilt = 0
            let controller = makeController(engines: .resolving(
                settings: settings,
                catalog: { state },
                providers: { [provider] },
                system: system,
                makeCloud: { _, _, _ in cloudBuilt += 1; return FakeSpeechEngine() }
            ))
            controller.toggle(messageID: messageA, text: Self.threeSentences)

            #expect(system.spoken.count == 1, "\(String(describing: state))")
            #expect(cloudBuilt == 0)
            #expect(platform.toasts.isEmpty)
            #expect(settings.selection(for: .tts) == .cloud(VoiceCloudEngine(
                providerKind: .relay, connectionID: provider.id.uuidString, model: Self.cloudModel, voice: "nova"
            )))
            controller.stop(.userStopped)
        }
    }

    // MARK: Catalog snapshot

    private static let snapshotBaseURL = "https://read-aloud-catalog.test"

    /// A voice-view envelope with one read-aloud entry per model under relay (voices alloy / nova).
    private static func catalogEnvelope(models: [String]) throws -> Data {
        let tts: [[String: Any]] = models.map { model in
            [
                "model": model, "transport": "openai_speech", "path": "/v1/audio/speech", "outputFormat": "mp3",
                "maxChars": 4_000,
                "voices": [["id": "alloy", "isDefault": true], ["id": "nova", "isDefault": false]],
                "speedRange": ["min": 0.25, "max": 4], "isDefault": model == models.first,
            ]
        }
        let data: [String: Any] = [
            "view": "voice", "schemaVersion": 2, "revision": "rev-\(models.joined(separator: "+"))",
            "providers": [ProviderKind.relay.rawValue: ["tts": tts]],
        ]
        return try JSONSerialization.data(withJSONObject: ["code": 0, "data": data, "message": "ok"])
    }

    private static func catalogResponse(_ status: Int, etag: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "\(snapshotBaseURL)/api/metadata?view=voice")!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: etag.map { ["Etag": $0] } ?? [:]
        )!
    }

    private static func makeCatalogClient(directory: URL) -> VoiceCatalogClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadAloudCatalogURLProtocol.self]
        return VoiceCatalogClient(
            session: URLSession(configuration: configuration), cacheDirectory: directory, baseURL: { snapshotBaseURL }
        )
    }

    private static func makeCatalogDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadAloudCatalogSnapshot-\(UUID().uuidString)", isDirectory: true)
    }

    private static func ttsModels(_ state: VoiceCatalogState?) -> [String]? {
        state?.catalog?.ttsEntries(.relay).map(\.model)
    }

    @Test("Snapshot holds catalog A, the client refreshes to B with the selected entry, reading goes through the cloud engine, settings untouched, no notice")
    func snapshotFollowsClientRefresh() async throws {
        let directory = Self.makeCatalogDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogA = try Self.catalogEnvelope(models: ["tts-legacy"])
        ReadAloudCatalogURLProtocol.reset { _ in (Self.catalogResponse(200, etag: "\"a\""), catalogA) }
        let client = Self.makeCatalogClient(directory: directory)
        await client.refresh()
        let snapshot = ReadAloudCatalogSnapshot(client: client)
        await snapshot.settle()
        #expect(Self.ttsModels(snapshot.state) == ["tts-legacy"])

        // The settings page refreshes to a new catalog B (containing cloudModel) and the user selects it there.
        let catalogB = try Self.catalogEnvelope(models: ["tts-legacy", Self.cloudModel])
        ReadAloudCatalogURLProtocol.reset { _ in (Self.catalogResponse(200, etag: "\"b\""), catalogB) }
        await client.refresh()
        #expect(Self.ttsModels(snapshot.state) == ["tts-legacy", Self.cloudModel])
        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, connectionID: provider.id.uuidString)
        let selected = settings.selection(for: .tts)

        ReadAloudCatalogURLProtocol.reset(nil)
        let cloud = FakeSpeechEngine()
        var setups: [CloudSpeechSetup] = []
        let controller = makeController(engines: .resolving(
            settings: settings,
            catalog: { snapshot.current() },
            providers: { [provider] },
            system: engine,
            makeCloud: { setup, _, _ in setups.append(setup); return cloud }
        ))
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(setups.map(\.entry.model) == [Self.cloudModel])
        #expect(setups.first?.voice == "nova")
        #expect(cloud.spoken.count == 1)
        #expect(engine.spoken.isEmpty)
        #expect(platform.toasts.isEmpty)
        #expect(settings.selection(for: .tts) == selected)
        // A push arrived less than 10 minutes ago: reading the snapshot sends no request.
        await snapshot.settle()
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.isEmpty)
        controller.stop(.userStopped)
    }

    @Test("An empty snapshot triggers one refresh when reading starts; this reading uses the system engine without rewriting or notice; after 10 minutes it refreshes again with the ETag")
    func emptySnapshotTriggersRefresh() async throws {
        let directory = Self.makeCatalogDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogB = try Self.catalogEnvelope(models: [Self.cloudModel])
        ReadAloudCatalogURLProtocol.reset { request in
            if request.value(forHTTPHeaderField: "If-None-Match") != nil {
                return (Self.catalogResponse(304), Data())
            }
            return (Self.catalogResponse(200, etag: "\"b\""), catalogB)
        }
        let clock = SnapshotClock()
        let snapshot = ReadAloudCatalogSnapshot(client: Self.makeCatalogClient(directory: directory), now: { clock.now })
        await snapshot.settle()
        #expect(snapshot.state == nil)
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.isEmpty)

        let settings = Self.freshSettings()
        let provider = Self.relayProvider()
        Self.selectCloud(settings, connectionID: provider.id.uuidString)
        let selected = settings.selection(for: .tts)
        var cloudBuilt = 0
        let controller = makeController(engines: .resolving(
            settings: settings,
            catalog: { snapshot.current() },
            providers: { [provider] },
            system: engine,
            makeCloud: { _, _, _ in cloudBuilt += 1; return FakeSpeechEngine() }
        ))
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts.isEmpty)
        #expect(settings.selection(for: .tts) == selected)
        await snapshot.settle()
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.count == 1)
        #expect(Self.ttsModels(snapshot.state) == [Self.cloudModel])
        controller.stop(.userStopped)

        // The next reading uses the refreshed catalog and sends no request.
        controller.toggle(messageID: messageB, text: "Only one.")
        #expect(cloudBuilt == 1)
        controller.stop(.userStopped)
        await snapshot.settle()
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.count == 1)

        // After 10 minutes, reading again triggers a refresh that carries the ETag.
        clock.now = clock.now.addingTimeInterval(ReadAloudCatalogSnapshot.refreshInterval)
        _ = snapshot.current()
        await snapshot.settle()
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.count == 2)
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"b\"")
        #expect(Self.ttsModels(snapshot.state) == [Self.cloudModel])
    }

    // MARK: Preview

    /// A controller for previews: records the setup of every cloud engine built and returns a fake engine.
    private func makePreviewController(
        previews: FakeSpeechEngine, setups: @escaping (CloudSpeechSetup) -> Void
    ) -> ReadAloudController {
        ReadAloudController(
            engines: systemSource(), platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { _ in "en" },
            makePreview: { setup in setups(setup); return previews }
        )
    }

    @Test("Preview stops any reading first, builds the cloud engine from the given entry, connection, voice and effective speed, and speaks the sample in the UI language")
    func previewStopsReadingAndSpeaksSample() throws {
        platform.uiLanguage = "ja"
        let provider = Self.relayProvider()
        let previews = FakeSpeechEngine()
        var setups: [CloudSpeechSetup] = []
        let controller = makePreviewController(previews: previews) { setups.append($0) }
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        controller.preview(entry: Self.ttsEntry, provider: provider, voice: "nova", speed: 1.5)

        #expect(controller.state == .idle)
        #expect(engine.stopCount == 1)
        let baseURL = try #require(DictationEngineSource.requestBaseURL(provider))
        #expect(setups == [CloudSpeechSetup(
            entry: Self.ttsEntry, providerKind: .relay, baseURL: baseURL, apiKey: "sk-voice",
            voice: "nova", speed: 1.5, language: "ja"
        )])
        #expect(previews.spoken == [[SpeechUtterance(
            text: "ja:Hi, this is how I'll sound when I read your replies.", language: "ja"
        )]])
        #expect(controller.previewingVoice == "nova")
        #expect(platform.activations == 2)
        #expect(engine.spoken.count == 1)

        previews.delegate?.speechEngineDidFinishAll()
        #expect(controller.previewingVoice == nil)
        #expect(platform.deactivations == 2)
        #expect(platform.toasts.isEmpty)
    }

    @Test("A failed preview shows a \"couldn't play the preview\" notice and does not fall back to the system engine")
    func previewFailureToastsWithoutFallback() {
        let previews = FakeSpeechEngine()
        let controller = makePreviewController(previews: previews) { _ in }
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)
        previews.delegate?.speechEngineDidFail()

        #expect(platform.toasts == [.couldNotPreview])
        #expect(ReadAloudToast.couldNotPreview.localizationKey == "Couldn't play the preview")
        #expect(engine.spoken.isEmpty)
        #expect(controller.previewingVoice == nil)
        #expect(controller.state == .idle)
        #expect(platform.deactivations == 1)

        // The production preview engine: the cloud engine gets the same setup; the fallback engine only reports
        // failure and never speaks with a system voice.
        let setup = CloudSpeechSetup(
            entry: Self.ttsEntry, providerKind: .relay, baseURL: URL(string: "https://relay.example.com")!,
            apiKey: "sk-voice", voice: "alloy", speed: 1, language: "en"
        )
        let cloud = ReadAloudController.makePreviewEngine(setup) as? CloudSpeechEngine
        #expect(cloud?.voice == "alloy")
        #expect(cloud?.language == "en")
        let fallback = PreviewFallbackEngine()
        let spy = FailureSpy()
        fallback.delegate = spy
        fallback.speak([SpeechUtterance(text: "Hi.", language: "en")])
        #expect(spy.failures == 1)
    }

    @Test("Tapping preview again or leaving the settings page stops the preview, restores the audio session, and a late callback shows nothing")
    func previewTapAgainOrLeaveStops() {
        let previews = FakeSpeechEngine()
        var built = 0
        let controller = makePreviewController(previews: previews) { _ in built += 1 }
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)
        let firstDelegate = previews.delegate
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)

        #expect(built == 1)
        #expect(previews.stopCount == 1)
        #expect(controller.previewingVoice == nil)
        #expect(platform.deactivations == 1)
        firstDelegate?.speechEngineDidFail()
        #expect(platform.toasts.isEmpty)

        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "nova", speed: 1)
        #expect(built == 2)
        #expect(controller.previewingVoice == "nova")
        controller.stopPreview()
        #expect(previews.stopCount == 2)
        #expect(controller.previewingVoice == nil)
        #expect(platform.deactivations == 2)
        controller.stopPreview()
        #expect(platform.deactivations == 2)
    }

    @Test("Tapping another voice during a preview stops the current one and previews the new voice; a late callback from the old engine shows nothing")
    func previewOtherVoiceSwitches() {
        let previews = FakeSpeechEngine()
        var voices: [String] = []
        let controller = makePreviewController(previews: previews) { voices.append($0.voice) }
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)
        let firstDelegate = previews.delegate
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "nova", speed: 1)

        #expect(voices == ["alloy", "nova"])
        #expect(previews.stopCount == 1)
        #expect(previews.spoken.count == 2)
        #expect(controller.previewingVoice == "nova")
        #expect(platform.activations == 2)
        #expect(platform.deactivations == 1)
        firstDelegate?.speechEngineDidFail()
        #expect(platform.toasts.isEmpty)
        #expect(controller.previewingVoice == "nova")

        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "nova", speed: 1)
        #expect(voices.count == 2)
        #expect(controller.previewingVoice == nil)
    }

    @Test("Going to the background, an interruption beginning or the old route disappearing stops the preview")
    func systemEventsStopPreview() {
        let previews = FakeSpeechEngine()
        let controller = makePreviewController(previews: previews) { _ in }
        let notes: [(Notification.Name, [AnyHashable: Any]?)] = [
            (UIApplication.didEnterBackgroundNotification, nil),
            (AVAudioSession.interruptionNotification,
             [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]),
            (AVAudioSession.routeChangeNotification,
             [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]),
        ]
        for (index, note) in notes.enumerated() {
            controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)
            #expect(controller.previewingVoice == "alloy")
            center.post(name: note.0, object: nil, userInfo: note.1)
            #expect(controller.previewingVoice == nil, "\(note.0.rawValue)")
            #expect(previews.stopCount == index + 1)
            #expect(platform.deactivations == index + 1)
        }
        #expect(platform.toasts.isEmpty)
    }

    // MARK: observeChat

    @Test("observeChat: a conversation change stops reading")
    func conversationChangeStops() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        #expect(controller.state != .idle)
        controller.observeChat(conversationID: UUID(), streamingMessageID: nil)

        #expect(controller.state == .idle)
        #expect(engine.stopCount == 1)
    }

    @Test("stopIfSpeaking stops only when the deleted messages include the one being read")
    func stopIfSpeakingOnlyForDeletedMessage() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.stopIfSpeaking(messageIDs: [messageB], .navigated)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))

        controller.stopIfSpeaking(messageIDs: [messageB, messageA], .navigated)
        #expect(controller.state == .idle)

        controller.toggle(messageID: messageB, text: Self.threeSentences)
        controller.stopIfSpeaking(messageIDs: [messageB], .newGeneration)
        #expect(controller.state == .idle)
        #expect(engine.stopCount == 2)
    }

    @Test("observeChat: keeps reading in the same conversation with no new generation (paged window changes do not stop it)")
    func sameConversationKeepsSpeaking() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
    }

    @Test("observeChat: streamingMessageID going from nil to non-nil stops reading")
    func newGenerationStops() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: messageB)

        #expect(controller.state == .idle)
        #expect(engine.stopCount == 1)
    }

    // MARK: System events

    @Test("Going to the background, an interruption beginning or the old route disappearing stops reading")
    func systemEventsStop() {
        let controller = makeController()

        controller.toggle(messageID: messageA, text: Self.threeSentences)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(controller.state == .idle)

        controller.toggle(messageID: messageA, text: Self.threeSentences)
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        #expect(controller.state != .idle)
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        #expect(controller.state == .idle)

        controller.toggle(messageID: messageA, text: Self.threeSentences)
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        )
        #expect(controller.state != .idle)
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        #expect(controller.state == .idle)

        #expect(engine.stopCount == 3)
        #expect(platform.deactivations == 3)
    }

    @Test("The reading audio session uses .playback with .spokenAudio")
    func readAloudUsesPlaybackCategory() {
        let config = SystemReadAloudPlatform.sessionConfiguration
        #expect(config.category == .playback)
        #expect(config.mode == .spokenAudio)
    }

    @Test("System engine speech rate: default rate times the multiplier, clamped to the system limits, keeping the accessibility speech settings")
    func systemEngineSpeechRate() {
        let item = SpeechUtterance(text: "Hello.", language: "en")
        let utterances = [0.5, 1.0, 2.0].map { SystemSpeechEngine.makeUtterance(item, voice: nil, speechRate: $0) }

        #expect(utterances.map(\.rate) == [
            AVSpeechUtteranceDefaultSpeechRate * 0.5,
            AVSpeechUtteranceDefaultSpeechRate,
            AVSpeechUtteranceMaximumSpeechRate,
        ])
        #expect(utterances.allSatisfy { $0.prefersAssistiveTechnologySettings })
        #expect(SystemSpeechEngine.utteranceRate(speechRate: 10) == AVSpeechUtteranceMaximumSpeechRate)
        #expect(SystemSpeechEngine.utteranceRate(speechRate: 0) == AVSpeechUtteranceMinimumSpeechRate)
    }
}

// MARK: - Test doubles

private final class SnapshotClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

final class ReadAloudCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        requestHandler = handler
        capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private final class FakeSpeechEngine: SpeechEngine {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice = true
    private(set) var spoken: [[SpeechUtterance]] = []
    private(set) var stopCount = 0

    func speak(_ utterances: [SpeechUtterance]) {
        spoken.append(utterances)
    }

    func stop() {
        stopCount += 1
    }
}

private final class FailureSpy: SpeechEngineDelegate {
    private(set) var failures = 0
    func speechEngineDidStartSegment(at index: Int) {}
    func speechEngineDidFinishAll() {}
    func speechEngineDidFail() { failures += 1 }
}

@MainActor
private final class FakeReadAloudPlatform: ReadAloudPlatform {
    var uiLanguage = "en"
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var toasts: [ReadAloudToast] = []

    func activateAudioSession() throws { activations += 1 }
    func deactivateAudioSession() { deactivations += 1 }
    func localizedVoiceString(_ key: String, locale: String) -> String { "\(locale):\(key)" }
    func showToast(_ toast: ReadAloudToast) { toasts.append(toast) }
}
