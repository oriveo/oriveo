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
    /// Each test case gets its own session lease, not shared with the parallel dictation / conversation cases via .shared.
    private let owner = VoiceAudioSessionOwner()
    private let messageA = UUID()
    private let messageB = UUID()
    private let conversation = UUID()
    private static let threeSentences = "First sentence. Second sentence. Third sentence."

    init() {
        screenAwake = ScreenAwakeHolds(timer: idleTimer)
    }

    private func makeController() -> ReadAloudController {
        makeController(engines: .fixed(engine))
    }

    private func makeController(engines: ReadAloudEngineSource) -> ReadAloudController {
        ReadAloudController(
            engines: engines, platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { _ in "en" }, sessionOwner: owner
        )
    }

    /// Production resolution source when the setting is the system engine (nothing saved yet).
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

    /// Writes the cloud read-aloud choice; by default also records that provider's consent notice (always already accepted when written normally through the engine sheet).
    private static func selectCloud(_ settings: VoiceEngineSettings, connectionID: String, accepted: Bool = true) {
        settings.setSelection(.cloud(VoiceCloudEngine(
            providerKind: .relay, connectionID: connectionID, model: cloudModel, voice: "nova"
        )), for: .tts)
        if accepted { settings.disclosures.markAccepted(.relay, direction: .tts) }
    }

    /// Waits for the most recent session activation to settle (synthesis only starts after activation completes asynchronously on the coordinator queue).
    private func settle(_ controller: ReadAloudController) async {
        await controller.pendingActivation?.value
    }

    // MARK: Start and stop

    @Test("Toggle starts reading: state, audio session and idle timer")
    func toggleStarts() async {
        idleTimer.isIdleTimerDisabled = false
        let controller = makeController(engines: systemSource())
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        await settle(controller)

        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(engine.spoken.last?.map(\.text) == ["First sentence.", "Second sentence.", "Third sentence."])
        #expect(engine.spoken.last?.allSatisfy { $0.language == "en" } == true)
        #expect(platform.activations == 1)
        #expect(idleTimer.isIdleTimerDisabled)
    }

    func toggleSameStops() async {
        idleTimer.isIdleTimerDisabled = false
        let controller = makeController(engines: systemSource())
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        await settle(controller)
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .idle)
        #expect(engine.stopCount == 1)
        #expect(platform.deactivations == 1)
        #expect(!idleTimer.isIdleTimerDisabled)
    }

    @Test("Another reply: stop the current one first, then start")
    func toggleOtherSwitches() async {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        await settle(controller)
        controller.toggle(messageID: messageB, text: "Only one.")
        await settle(controller)

        #expect(controller.state == .speaking(messageID: messageB, index: 0, total: 1))
        #expect(engine.spoken.count == 2)
    }

    func finishesAfterAllSegments() async {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        await settle(controller)
        engine.delegate?.speechEngineDidStartSegment(at: 1)
        #expect(controller.state == .speaking(messageID: messageA, index: 1, total: 3))
        engine.delegate?.speechEngineDidStartSegment(at: 2)
        engine.delegate?.speechEngineDidFinishAll()

        #expect(controller.state == .idle)
        #expect(platform.deactivations == 1)
    }

    func failureMarksFailed() async {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        await settle(controller)
        engine.delegate?.speechEngineDidStartSegment(at: 1)
        engine.delegate?.speechEngineDidFail()

        #expect(controller.state == .failed(messageID: messageA))
        #expect(platform.toasts == [.couldNotRead])
    }

    @Test("After failure, the button looks like idle (speaker icon); tapping again restarts normally")
    func failedButtonLooksIdleAndRestarts() async throws {
        let controller = makeController()
        let readAloud = ReadAloudButton(controller: controller)
        readAloud.configure(messageID: messageA, text: Self.threeSentences, isEligible: true)
        let button = try #require(readAloud.subviews.compactMap { $0 as? UIButton }.first)
        #expect(!readAloud.isHidden)

        button.sendActions(for: .touchUpInside)
        #expect(button.accessibilityLabel == L10n.tr("Stop Reading", table: .voice))
        await settle(controller)
        engine.delegate?.speechEngineDidFail()
        #expect(controller.state == .failed(messageID: messageA))
        #expect(button.accessibilityLabel == L10n.tr("Read Aloud", table: .voice))
        #expect(button.accessibilityValue == nil)
        #expect(button.configuration?.baseForegroundColor != .clear)

        button.sendActions(for: .touchUpInside)
        await settle(controller)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(engine.spoken.count == 2)
    }

    @Test("Empty text, whitespace and divider-only text, and unreadable messages do not show the read-aloud button")
    func buttonHiddenWithoutSpeakableContent() {
        let readAloud = ReadAloudButton(controller: makeController())
        // Text comes from the shared fixtures empty_reply / whitespace_and_markup_only_reply.
        readAloud.configure(messageID: messageA, text: "", isEligible: true)
        #expect(readAloud.isHidden)
        readAloud.configure(messageID: messageA, text: "  \n\n---\n\n**  **\n", isEligible: true)
        #expect(readAloud.isHidden)
        readAloud.configure(messageID: messageA, text: Self.threeSentences, isEligible: false)
        #expect(readAloud.isHidden)
        readAloud.configure(messageID: messageA, text: Self.threeSentences, isEligible: true)
        #expect(!readAloud.isHidden)
    }

    @Test("Device has no system voice → toast, does not start")
    func noVoiceShowsToast() {
        engine.hasAnyVoice = false
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)

        #expect(controller.state == .failed(messageID: messageA))
        #expect(platform.toasts == [.noVoice])
        #expect(engine.spoken.isEmpty)
    }

    @Test("Nothing readable → do nothing")
    func emptySpeakableTextIsIgnored() async {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: "```\ncode only\n```")
        await settle(controller)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 1))
        controller.stop(.userStopped)
        controller.toggle(messageID: messageB, text: "🎉 👍")
        #expect(controller.state == .idle)
        #expect(engine.spoken.count == 1)
    }

    @Test("Measure: start-time language detection and engine selection cost for a 20k-character reply (print only, no lock)")
    func measureStartLanguageDetectionCost() {
        let paragraph = String(repeating: "This sentence is used to measure read-aloud start latency, mixed with some English words.", count: 8)
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

    @Test("Placeholder sentence takes its text from the Voice table by placeholderLocale")
    func placeholderUsesLocalizedSentence() async {
        platform.uiLanguage = "ja"
        let controller = ReadAloudController(
            engine: engine, platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { _ in "fi" }
        )
        controller.toggle(messageID: messageA, text: "Before.\n\n| a |\n\nAfter.")
        await settle(controller)

        let utterances = engine.spoken.last ?? []
        #expect(utterances.count == 3)
        #expect(utterances[1] == SpeechUtterance(text: "ja:Here's a table.", language: "ja"))
        #expect(utterances[0].language == "fi")
    }

    @Test("Language detection input is truncated to the first 2000 code points (same as Android), not graphemes")
    func language_detection_prefix_counts_code_points() {
        var detected: [String] = []
        let controller = ReadAloudController(
            engine: engine, platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { detected.append($0); return "en" }
        )
        // Each grapheme = 2 code points (e + combining accent), 3000 code points in total.
        controller.toggle(messageID: messageA, text: String(repeating: "e\u{301}", count: 1_500) + ".")

        let input = detected.first ?? ""
        #expect(input.unicodeScalars.count == ReadAloudController.languageDetectionLimit)
        // Truncating by grapheme would take up to twice as many code points; here the grapheme count is necessarily below the limit.
        #expect(input.count < ReadAloudController.languageDetectionLimit)
    }

    // MARK: Engine selection by settings

    @Test("Settings choose the system engine → system engine, no cloud engine built")
    func systemSelectionUsesSystemEngine() async {
        var cloudBuilt = 0
        let controller = makeController(engines: .resolving(
            settings: Self.freshSettings(),
            catalog: { .available(Self.catalog) },
            providers: { [Self.relayProvider()] },
            system: engine,
            makeCloud: { _, _, _ in cloudBuilt += 1; return FakeSpeechEngine() }
        ))
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        await settle(controller)

        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts.isEmpty)
    }

    @Test("Settings choose cloud and it is available → cloud engine receives entry / voice / effective rate / reading language")
    func cloudSelectionUsesCloudEngine() async throws {
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
            await settle(controller)

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

    @Test("Cloud selection without recorded consent (restored backup / old data) → system engine this time, no cloud build, no settings rewrite, no prompt")
    func cloudSelectionWithoutConsentUsesSystemOnce() async {
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
        await settle(controller)

        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts.isEmpty)
        #expect(settings.selection(for: .tts) == selected)
        #expect(settings.takePendingNotice(site: .settings, direction: .tts) == nil)
    }

    @Test("Mid-way cloud fallback → prompts once (with provider name, not the connection custom name), still reading, settings not rewritten")
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

        // A late callback after reading finishes does not prompt; the next read-aloud allows prompting once again.
        triggers.first?()
        #expect(platform.toasts.count == 1)
        controller.toggle(messageID: messageB, text: "Only one.")
        #expect(triggers.count == 2)
        triggers.last?()
        #expect(platform.toasts.count == 2)
    }

    @Test("Selected connection gone → system engine + prompt \"selected read-aloud engine is no longer available\" + settings rewritten to system")
    func missingConnectionFallsBackAndRewrites() async {
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
        await settle(controller)

        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts == [.engineUnavailable])
        #expect(ReadAloudToast.engineUnavailable.localizationKey
                == "The selected read-aloud engine is unavailable. Using the system voice.")
        #expect(settings.selection(for: .tts) == .system)
    }

    @Test("Settings page discovers the fallback first and rewrites → next read-aloud prompts \"selected read-aloud engine is no longer available\" once, not again after that")
    func settingsSiteFallbackNotifiesNextReadOnce() async {
        let settings = Self.freshSettings()
        Self.selectCloud(settings, connectionID: UUID().uuidString)
        // The connection chosen at settings-page resolution is gone: storage reverts to system, and one pending prompt is left for the point of use.
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
        await settle(controller)
        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts == [.engineUnavailable])
        controller.stop(.userStopped)

        controller.toggle(messageID: messageB, text: "Only one.")
        await settle(controller)
        #expect(engine.spoken.count == 2)
        #expect(platform.toasts == [.engineUnavailable])
        #expect(settings.takePendingNotice(site: .settings, direction: .tts) == nil)
        controller.stop(.userStopped)
    }

    @Test("No cached catalog / load failure / 404 unavailable → system engine, settings not rewritten, no prompt")
    func catalogWithoutConclusionKeepsSelection() async {
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
            await settle(controller)

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

    /// Voice-view envelope for one read-aloud entry per relay (voices alloy / nova).
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

    @Test("Snapshot is catalog A → client refreshes to get B containing the selected entry → read-aloud goes to cloud, settings not rewritten, no prompt")
    func snapshotFollowsClientRefresh() async throws {
        let directory = Self.makeCatalogDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogA = try Self.catalogEnvelope(models: ["tts-legacy"])
        ReadAloudCatalogURLProtocol.reset { _ in (Self.catalogResponse(200, etag: "\"a\""), catalogA) }
        let client = Self.makeCatalogClient(directory: directory)
        await client.refresh()
        let snapshot = ReadAloudCatalogSnapshot(client: client)
        #expect(Self.ttsModels(snapshot.state) == ["tts-legacy"])

        // The settings page refreshes to a new catalog B (containing cloudModel), and the user selects it there.
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
        await settle(controller)

        #expect(setups.map(\.entry.model) == [Self.cloudModel])
        #expect(setups.first?.voice == "nova")
        #expect(cloud.spoken.count == 1)
        #expect(engine.spoken.isEmpty)
        #expect(platform.toasts.isEmpty)
        #expect(settings.selection(for: .tts) == selected)
        // Received a push less than 10 minutes ago: reading the snapshot does not send a request.
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.isEmpty)
        controller.stop(.userStopped)
    }

    @Test("Building the snapshot on the main thread does not read the catalog cache file; after the background read the snapshot has a value; disk reads are off the main thread")
    func snapshotDoesNotReadCacheOnMainThread() async throws {
        let directory = Self.makeCatalogDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogA = try Self.catalogEnvelope(models: ["tts-legacy"])
        ReadAloudCatalogURLProtocol.reset { _ in (Self.catalogResponse(200, etag: "\"a\""), catalogA) }
        // First, one client refreshes and writes to disk as the cache for the next cold start.
        await Self.makeCatalogClient(directory: directory).refresh()
        ReadAloudCatalogURLProtocol.reset { _ in (Self.catalogResponse(500), Data()) }

        let reads = CacheReadRecorder()
        let baseURL = Self.snapshotBaseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadAloudCatalogURLProtocol.self]
        let client = VoiceCatalogClient(
            session: URLSession(configuration: configuration), cacheDirectory: directory, baseURL: { baseURL },
            readCacheFile: { url in
                reads.record(onMainThread: Thread.isMainThread)
                return try? Data(contentsOf: url)
            }
        )
        #expect(Thread.isMainThread)
        let snapshot = ReadAloudCatalogSnapshot(client: client)
        #expect(reads.mainThreadReads == 0)
        #expect(reads.total == 0)
        #expect(snapshot.state == nil)

        #expect(Self.ttsModels(snapshot.state) == ["tts-legacy"])
        #expect(reads.total == 1)
        #expect(reads.mainThreadReads == 0)
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.isEmpty)
    }

    @Test("Empty snapshot: read-aloud triggers one refresh, uses system this time, no rewrite or prompt; after 10 minutes refreshes again with ETag")
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
        await settle(controller)

        #expect(engine.spoken.count == 1)
        #expect(cloudBuilt == 0)
        #expect(platform.toasts.isEmpty)
        #expect(settings.selection(for: .tts) == selected)
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.count == 1)
        #expect(Self.ttsModels(snapshot.state) == [Self.cloudModel])
        controller.stop(.userStopped)

        // The next read-aloud uses the catalog refreshed earlier and sends no request.
        controller.toggle(messageID: messageB, text: "Only one.")
        #expect(cloudBuilt == 1)
        controller.stop(.userStopped)
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.count == 1)

        // After 10 minutes: the next read triggers an ETag-carrying refresh.
        clock.now = clock.now.addingTimeInterval(ReadAloudCatalogSnapshot.refreshInterval)
        _ = snapshot.current()
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.count == 2)
        #expect(ReadAloudCatalogURLProtocol.capturedRequests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"b\"")
        #expect(Self.ttsModels(snapshot.state) == [Self.cloudModel])
    }

    // MARK: Preview

    /// Controller for previews: records the parameters of each cloud engine construction and returns a fake engine.
    private func makePreviewController(
        previews: FakeSpeechEngine, setups: @escaping (CloudSpeechSetup) -> Void
    ) -> ReadAloudController {
        ReadAloudController(
            engines: systemSource(), platform: platform, screenAwake: screenAwake, notificationCenter: center,
            detectLanguage: { _ in "en" },
            makePreview: { setup in setups(setup); return previews },
            sessionOwner: owner
        )
    }

    @Test("Preview: stop current reading first (user_stopped), build the cloud engine with the given entry / connection / voice / effective rate, read the sample in the interface language")
    func previewStopsReadingAndSpeaksSample() async throws {
            platform.uiLanguage = "ja"
            let provider = Self.relayProvider()
            let previews = FakeSpeechEngine()
            var setups: [CloudSpeechSetup] = []
            let controller = makePreviewController(previews: previews) { setups.append($0) }
            controller.toggle(messageID: messageA, text: Self.threeSentences)
            await settle(controller)

            controller.preview(entry: Self.ttsEntry, provider: provider, voice: "nova", speed: 1.5)
            await settle(controller)

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

    @Test("Preview failure → toast \"unable to preview\", does not fall back to the system engine")
    func previewFailureToastsWithoutFallback() async {
        let previews = FakeSpeechEngine()
        let controller = makePreviewController(previews: previews) { _ in }
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)
        await settle(controller)
        previews.delegate?.speechEngineDidFail()

        #expect(platform.toasts == [.couldNotPreview])
        #expect(ReadAloudToast.couldNotPreview.localizationKey == "Couldn't play the preview")
        #expect(engine.spoken.isEmpty)
        #expect(controller.previewingVoice == nil)
        #expect(controller.state == .idle)
        #expect(platform.deactivations == 1)

        // Production preview engine: the cloud engine receives the same parameters; the fallback engine only reports failure and does not read the system voice.
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

    @Test("Tap preview again / leave the settings page → stop preview, restore audio session, late callbacks do not prompt")
    func previewTapAgainOrLeaveStops() async {
        let previews = FakeSpeechEngine()
        var built = 0
        let controller = makePreviewController(previews: previews) { _ in built += 1 }
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)
        await settle(controller)
        let firstDelegate = previews.delegate
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)

        #expect(built == 1)
        #expect(previews.stopCount == 1)
        #expect(controller.previewingVoice == nil)
        #expect(platform.deactivations == 1)
        firstDelegate?.speechEngineDidFail()
        #expect(platform.toasts.isEmpty)

        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "nova", speed: 1)
        await settle(controller)
        #expect(built == 2)
        #expect(controller.previewingVoice == "nova")
        controller.stopPreview()
        #expect(previews.stopCount == 2)
        #expect(controller.previewingVoice == nil)
        #expect(platform.deactivations == 2)
        controller.stopPreview()
        #expect(platform.deactivations == 2)
    }

    @Test("Tap another voice during preview → stop current and read with the new voice; late callbacks from the old engine do not prompt")
    func previewOtherVoiceSwitches() async {
        let previews = FakeSpeechEngine()
        var voices: [String] = []
        let controller = makePreviewController(previews: previews) { voices.append($0.voice) }
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)
        await settle(controller)
        let firstDelegate = previews.delegate
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "nova", speed: 1)
        await settle(controller)

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

    @Test("Enter background / interruption begins / old device unplugged → stop preview")
    func systemEventsStopPreview() async {
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
            await settle(controller)
            #expect(controller.previewingVoice == "alloy")
            center.post(name: note.0, object: nil, userInfo: note.1)
            #expect(controller.previewingVoice == nil, "\(note.0.rawValue)")
            #expect(previews.stopCount == index + 1)
            #expect(platform.deactivations == index + 1)
        }
        #expect(platform.toasts.isEmpty)
    }

    // MARK: observeChat

    @Test("observeChat: session changed → navigated")
    func conversationChangeStops() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        #expect(controller.state != .idle)
        controller.observeChat(conversationID: UUID(), streamingMessageID: nil)

        #expect(controller.state == .idle)
    }

    @Test("stopIfSpeaking: deleted messages include the one being read → stop; reason passed through")
    func stopIfSpeakingOnlyForDeletedMessage() {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.stopIfSpeaking(messageIDs: [messageB], .navigated)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))

        controller.stopIfSpeaking(messageIDs: [messageB, messageA], .navigated)
        #expect(controller.state == .idle)

        controller.toggle(messageID: messageB, text: Self.threeSentences)
        controller.stopIfSpeaking(messageIDs: [messageB], .newGeneration)
    }

    @Test("observeChat: same conversation with no new generation → keeps reading (paged window changes do not stop it by mistake)")
    func sameConversationKeepsSpeaking() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
    }

    @Test("observeChat: streamingMessageID changes from nil to non-nil → new_generation")
    func newGenerationStops() {
        let controller = makeController()
        controller.observeChat(conversationID: conversation, streamingMessageID: nil)
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        controller.observeChat(conversationID: conversation, streamingMessageID: messageB)

        #expect(controller.state == .idle)
    }

    // MARK: System events

    @Test("Enter background → backgrounded; interruption begins / old device unplugged → interrupted")
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

    }

    @Test("Read-aloud session: production setCategory uses .playback + .spokenAudio")
    func readAloudUsesPlaybackCategory() {
        let config = SystemReadAloudPlatform.sessionConfiguration
        #expect(config.category == .playback)
        #expect(config.mode == .spokenAudio)
    }

    @Test("Read-aloud session: activation / deactivation go through the coordinator serial queue, not changing the session on the main thread")
    func systemPlatformGoesThroughCoordinator() async throws {
        let recorder = SessionOpRecorder()
        let coordinator = AudioSessionCoordinator(apply: recorder.apply)
        let platform = SystemReadAloudPlatform(coordinator: coordinator)
        let config = SystemReadAloudPlatform.sessionConfiguration

        #expect(Thread.isMainThread)
        try await platform.activateAudioSession()
        #expect(recorder.operations == [
            .configure(.init(category: config.category, mode: config.mode)), .activate,
        ])
        #expect(recorder.anyOnMain == false)

        platform.deactivateAudioSession()
        try await coordinator.perform([])
        #expect(recorder.operations.last == .deactivate(notifyOthers: true))
        #expect(recorder.anyOnMain == false)
    }

    @Test("Stop during pending activation → no sound; after activation settles, deactivate only once")
    func stopWhileActivatingStaysSilent() async throws {
            let recorder = SessionOpRecorder()
            let queue = DispatchQueue(label: "ReadAloudControllerTests.session")
            let coordinator = AudioSessionCoordinator(queue: queue, apply: recorder.apply)
            let controller = ReadAloudController(
                engines: .fixed(engine), platform: SystemReadAloudPlatform(coordinator: coordinator),
                screenAwake: screenAwake, notificationCenter: center, detectLanguage: { _ in "en" },
                sessionOwner: owner
            )
            queue.suspend()
            controller.toggle(messageID: messageA, text: Self.threeSentences)
            #expect(controller.state == .speaking(messageID: messageA, index: 0, total: 3))
            controller.toggle(messageID: messageA, text: Self.threeSentences)
            #expect(controller.state == .idle)
            queue.resume()
            await settle(controller)
            try await coordinator.perform([])

            #expect(engine.spoken.isEmpty)
            #expect(recorder.operations.filter { $0 == .deactivate(notifyOthers: true) }.count == 1)
            #expect(recorder.operations.last == .deactivate(notifyOthers: true))
            #expect(!idleTimer.isIdleTimerDisabled)
    }

    @Test("Stop during pending activation while dictation claimed the session lease in between → after activation settles no deactivation, dictation is not stopped")
    func lapseYieldsToSessionLeaseHolder() async throws {
            let recorder = SessionOpRecorder()
            let queue = DispatchQueue(label: "ReadAloudControllerTests.session.leased")
            let coordinator = AudioSessionCoordinator(queue: queue, apply: recorder.apply)
            let owner = VoiceAudioSessionOwner()
            let controller = ReadAloudController(
                engines: .fixed(engine), platform: SystemReadAloudPlatform(coordinator: coordinator),
                screenAwake: screenAwake, notificationCenter: center, detectLanguage: { _ in "en" },
                sessionOwner: owner
            )
            queue.suspend()
            controller.toggle(messageID: messageA, text: Self.threeSentences)
            controller.toggle(messageID: messageA, text: Self.threeSentences)
            #expect(controller.state == .idle)
            #expect(owner.current?.client == .readAloud)
            let dictation = owner.claim(.dictation)
            queue.resume()
            await settle(controller)
            try await coordinator.perform([])

            #expect(engine.spoken.isEmpty)
            #expect(recorder.operations.contains(.activate))
            #expect(!recorder.operations.contains(.deactivate(notifyOthers: true)))
            // The read-aloud lease was taken over, so release returns false; the dictation lease is still in place
            #expect(owner.current == dictation)
    }

    @Test("Stop during pending activation with no session lease claimant → after activation settles, deactivate once more")
    func lapseDeactivatesWhenNoLeaseHolder() async throws {
            let recorder = SessionOpRecorder()
            let queue = DispatchQueue(label: "ReadAloudControllerTests.session.unleased")
            let coordinator = AudioSessionCoordinator(queue: queue, apply: recorder.apply)
            let owner = VoiceAudioSessionOwner()
            let controller = ReadAloudController(
                engines: .fixed(engine), platform: SystemReadAloudPlatform(coordinator: coordinator),
                screenAwake: screenAwake, notificationCenter: center, detectLanguage: { _ in "en" },
                sessionOwner: owner
            )
            queue.suspend()
            controller.toggle(messageID: messageA, text: Self.threeSentences)
            controller.toggle(messageID: messageA, text: Self.threeSentences)
            #expect(controller.state == .idle)
            // Stopped before activation settled: the read-aloud lease is left for the activation task to return when it resumes
            #expect(owner.current?.client == .readAloud)
            queue.resume()
            await settle(controller)
            try await coordinator.perform([])

            #expect(engine.spoken.isEmpty)
            // Read-aloud lease already returned
            #expect(owner.current == nil)
            #expect(recorder.operations.filter { $0 == .deactivate(notifyOthers: true) }.count == 1)
            #expect(recorder.operations.last == .deactivate(notifyOthers: true))
    }

    @Test("Claim the .readAloud lease before read-aloud activation; if not taken over, return the lease and deactivate once when it ends")
    func readAloudClaimsLeaseAndReleasesOnFinish() async {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        let lease = owner.current
        #expect(lease?.client == .readAloud)
        await settle(controller)
        #expect(platform.activations == 1)
        #expect(owner.current == lease)

        controller.toggle(messageID: messageA, text: Self.threeSentences)
        #expect(controller.state == .idle)
        #expect(owner.current == nil)
        #expect(platform.deactivations == 1)
    }

    @Test("Dictation claim takes over during read-aloud → no deactivation when read-aloud ends, dictation lease still in place")
    func readAloudTakenOverByDictationKeepsSession() async {
        let controller = makeController()
        controller.toggle(messageID: messageA, text: Self.threeSentences)
        await settle(controller)
        let dictation = owner.claim(.dictation)

        controller.toggle(messageID: messageA, text: Self.threeSentences)
        #expect(controller.state == .idle)
        #expect(platform.deactivations == 0)
        #expect(owner.current == dictation)
    }

    @Test("Preview also claims .readAloud: deactivate once if not taken over; no deactivation if taken over by conversation")
    func previewSharesReadAloudLease() async {
        let previews = FakeSpeechEngine()
        let controller = makePreviewController(previews: previews) { _ in }
        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "alloy", speed: 1)
        #expect(owner.current?.client == .readAloud)
        await settle(controller)
        controller.stopPreview()
        #expect(owner.current == nil)
        #expect(platform.deactivations == 1)

        controller.preview(entry: Self.ttsEntry, provider: Self.relayProvider(), voice: "nova", speed: 1)
        await settle(controller)
        let conversation = owner.claim(.conversation)
        controller.stopPreview()
        #expect(platform.deactivations == 1)
        #expect(owner.current == conversation)
    }

    @Test("System engine speech rate: default rate × multiplier, clamped to the system max, preserves accessibility read-aloud settings")
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
    private var clock = Date(timeIntervalSince1970: 1_000)

    func activateAudioSession() async throws { activations += 1 }
    func deactivateAudioSession() { deactivations += 1 }
    func localizedVoiceString(_ key: String, locale: String) -> String { "\(locale):\(key)" }
    func showToast(_ toast: ReadAloudToast) { toasts.append(toast) }

    /// Advances time by 1 second on each read: exactly 1000 ms between start and end.
    func now() -> Date {
        defer { clock = clock.addingTimeInterval(1) }
        return clock
    }
}

/// Records the number of catalog cache file reads and how many of them happened on the main thread.
private final class CacheReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (total: 0, main: 0)

    var total: Int { lock.withLock { counts.total } }
    var mainThreadReads: Int { lock.withLock { counts.main } }

    func record(onMainThread: Bool) {
        lock.withLock {
            counts.total += 1
            if onMainThread { counts.main += 1 }
        }
    }
}
