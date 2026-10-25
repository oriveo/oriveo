import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import UIKit

// MARK: - State and end reasons

enum ReadAloudState: Equatable {
    case idle
    /// index is the segment being spoken (zero-based); total is the number of segments.
    case speaking(messageID: UUID, index: Int, total: Int)
    case failed(messageID: UUID)
}

/// Why a read-aloud session ended.
nonisolated enum ReadAloudEndReason: String, Sendable {
    case finished
    case userStopped = "user_stopped"
    case navigated
    case newGeneration = "new_generation"
    case backgrounded
    case interrupted
    case failed
}

enum ReadAloudToast: Equatable {
    case couldNotRead
    case noVoice
    /// The stored cloud read-aloud engine is no longer usable (connection / key / entry); this reading uses the system engine and the setting has been reset to system.
    case engineUnavailable
    /// A cloud chunk failed and reading continues from that chunk with the system engine (the setting is left alone); providerName is the provider's name (providerKind.displayName), not the connection's custom name.
    case cloudFallback(providerName: String)
    /// The voice preview in settings failed (no fallback to the system engine).
    case couldNotPreview

    var localizationKey: String {
        switch self {
        case .couldNotRead: return "Couldn't read this reply aloud"
        case .noVoice: return "No system voice is available on this device"
        case .engineUnavailable: return "The selected read-aloud engine is unavailable. Using the system voice."
        case .cloudFallback: return "%@ is unavailable right now. Switched to the system voice."
        case .couldNotPreview: return "Couldn't play the preview"
        }
    }

    /// Looks up the Voice-table string for the UI language and substitutes arguments.
    var localizedText: String {
        let template = L10n.tr(localizationKey, table: .voice)
        if case .cloudFallback(let providerName) = self { return L10n.format(template, providerName) }
        return template
    }
}

// MARK: - Engine and platform abstractions

/// One segment to speak; language is BCP-47, nil means the system default voice.
struct SpeechUtterance: Equatable {
    let text: String
    let language: String?
}

protocol SpeechEngineDelegate: AnyObject {
    func speechEngineDidStartSegment(at index: Int)
    func speechEngineDidFinishAll()
    func speechEngineDidFail()
}

/// Speech engine: speaks segments in order and reports segment i started / all finished / failed. No callbacks after stop().
protocol SpeechEngine: AnyObject {
    var delegate: SpeechEngineDelegate? { get set }
    var hasAnyVoice: Bool { get }
    func speak(_ utterances: [SpeechUtterance])
    func stop()
}

/// Audio session, strings, toasts and clock (the screen stays awake through ScreenAwakeHolds): the system in production, fakes in tests.
protocol ReadAloudPlatform: AnyObject {
    func activateAudioSession() throws
    func deactivateAudioSession()
    var uiLanguage: String { get }
    func localizedVoiceString(_ key: String, locale: String) -> String
    func showToast(_ toast: ReadAloudToast)
}

// MARK: - Engine selection

/// The engine chosen for one reading.
struct ReadAloudEngineChoice {
    let engine: SpeechEngine
    /// Non-nil means the stored cloud choice is no longer valid and this reading fell back to the system engine (only this one needs a notice).
    let fallback: VoiceFallbackReason?

    static func system(_ engine: SpeechEngine, fallback: VoiceFallbackReason? = nil) -> ReadAloudEngineChoice {
        ReadAloudEngineChoice(engine: engine, fallback: fallback)
    }
}

/// Everything needed to build a cloud read-aloud engine (entry, connection, voice, effective speed, reading language).
struct CloudSpeechSetup: Equatable {
    let entry: VoiceTTSEntry
    let providerKind: ProviderKind
    let baseURL: URL
    let apiKey: String
    let voice: String
    let speed: Double
    let language: String
}

/// Picks the engine each time a reading starts: settings + catalog + connections. Inputs are this reply's
/// reading language and the callback for a cloud engine falling back to the system mid-reading
/// (carries the provider name; may be called several times, the controller de-duplicates).
struct ReadAloudEngineSource {
    let select: (_ language: String, _ onFallback: @escaping (_ providerName: String) -> Void) -> ReadAloudEngineChoice

    /// Pins one engine and ignores settings.
    static func fixed(_ engine: SpeechEngine) -> ReadAloudEngineSource {
        ReadAloudEngineSource { _, _ in .system(engine) }
    }

    /// Resolves the stored read-aloud engine choice; on fallback the setting is reset to system (persisted by VoiceEngineSettings.resolve).
    /// When the catalog has no usable verdict (no cache / load failed / unavailable) this reading uses the system engine without touching settings or showing a notice.
    /// The cloud engine's fallback engine is built separately by makeFallback: sharing the system engine would overwrite its delegate.
    static func resolving(
        settings: VoiceEngineSettings = VoiceEngineSettings(),
        catalog: @escaping () -> VoiceCatalogState?,
        providers: @escaping () -> [Provider],
        system: SpeechEngine,
        makeFallback: @escaping () -> SpeechEngine = { SystemSpeechEngine() },
        makeCloud: @escaping (
            _ setup: CloudSpeechSetup, _ fallback: SpeechEngine, _ onFallback: @escaping () -> Void
        ) -> SpeechEngine = {
            ReadAloudEngineSource.makeCloudEngine($0, fallback: $1, onFallback: $2)
        }
    ) -> ReadAloudEngineSource {
        ReadAloudEngineSource { language, onFallback in
            // When settings already noticed the fallback and reset to system, it left one pending notice here: take it once and show it for this reading.
            let pending = settings.takePendingNotice(site: .use, direction: .tts)
            guard case .cloud(let stored) = settings.selection(for: .tts) else { return .system(system, fallback: pending) }
            // A cloud choice whose disclosure was never accepted (restored backup / leftover data) sends nothing: use the system engine this time, no setting change, no notice.
            guard settings.disclosures.hasAccepted(stored.providerKind, direction: .tts) else { return .system(system) }
            guard let catalog = catalog()?.catalog else { return .system(system) }
            let providers = providers()
            let resolution = settings.resolve(
                direction: .tts,
                catalog: catalog,
                connections: providers.map(VoiceConnection.init(provider:)),
                site: .use
            )
            switch resolution {
            case .system(let fallback):
                return .system(system, fallback: fallback)
            case .cloud(let selected):
                guard let provider = providers.first(where: { $0.id.uuidString == selected.connectionID }),
                      let entry = catalog.ttsEntries(selected.providerKind).first(where: { $0.model == selected.model }),
                      let voice = selected.voice,
                      let baseURL = DictationEngineSource.requestBaseURL(provider)
                else { return .system(system) }
                let setup = CloudSpeechSetup(
                    entry: entry,
                    providerKind: provider.kind,
                    baseURL: baseURL,
                    apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: nil),
                    voice: voice,
                    speed: CloudReadAloudRules.effectiveSpeed(slider: settings.speechRate, entry: entry),
                    language: language
                )
                let providerName = provider.kind.displayName
                return ReadAloudEngineChoice(
                    engine: makeCloud(setup, makeFallback(), { onFallback(providerName) }),
                    fallback: nil
                )
            }
        }
    }

    /// The production cloud engine; calls onFallback when it falls back mid-reading, and the controller shows the notice.
    static func makeCloudEngine(
        _ setup: CloudSpeechSetup, fallback: SpeechEngine, onFallback: @escaping () -> Void
    ) -> SpeechEngine {
        CloudSpeechEngine(
            entry: setup.entry,
            providerKind: setup.providerKind,
            baseURL: setup.baseURL,
            apiKey: setup.apiKey,
            voice: setup.voice,
            speed: setup.speed,
            language: setup.language,
            fallback: fallback,
            onFallback: onFallback,
            cache: SpeechAudioCache.shared
        )
    }
}

/// Reading starts synchronously but VoiceCatalogClient is an actor: this snapshot subscribes to the client's state pushes
/// (written on the main thread), so a catalog refreshed from settings applies to reading immediately. A read that finds
/// no verdict yet, or the last refresh at least 10 minutes old, also kicks off an ETag refresh for next time.
final class ReadAloudCatalogSnapshot {
    static let shared = ReadAloudCatalogSnapshot()
    static let refreshInterval: TimeInterval = 10 * 60

    private(set) var state: VoiceCatalogState?
    private let client: VoiceCatalogClient
    private let now: () -> Date
    /// When the last refresh happened (triggered by this snapshot or received as a push); nil means this process has not refreshed yet.
    private var lastRefreshAt: Date?
    private var subscription: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?

    init(client: VoiceCatalogClient = .shared, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
        subscription = Task { [weak self] in
            let initial = await client.subscribe { [weak self] latest in
                await self?.apply(latest)
            }
            // A push may land before this point and already hold newer state; don't overwrite it with the stale value from subscribing.
            if let self, self.state == nil {
                self.state = initial
            }
        }
    }

    func current() -> VoiceCatalogState? {
        refreshIfStale()
        return state
    }

    /// Waits for the subscription to be set up and for any in-flight refresh (and its push) to be handled.
    func settle() async {
        await subscription?.value
        await refreshing?.value
    }

    private func apply(_ latest: VoiceCatalogState) {
        state = latest
        lastRefreshAt = now()
    }

    private func refreshIfStale() {
        guard refreshing == nil else { return }
        let time = now()
        if state != nil, let last = lastRefreshAt, time.timeIntervalSince(last) < Self.refreshInterval { return }
        lastRefreshAt = time
        let client = client
        refreshing = Task { [weak self] in
            await client.refresh()
            self?.refreshing = nil
        }
    }
}

// MARK: - Controller

/// Reads assistant replies aloud (system TTS or a cloud engine). Only one reply plays at a time: tapping the same
/// reply again stops it; tapping another reply stops the current one and starts the new one.
final class ReadAloudController: ObservableObject {
    /// Connection list read when resolving a cloud read-aloud connection; injected by the app root view, empty until then.
    static var providers: () -> [Provider] = { [] }

    static let shared = ReadAloudController(
        engines: .resolving(
            catalog: { ReadAloudCatalogSnapshot.shared.current() },
            providers: { ReadAloudController.providers() },
            system: SystemSpeechEngine()
        ),
        platform: SystemReadAloudPlatform()
    )

    @Published private(set) var state: ReadAloudState = .idle
    /// The voice being previewed; nil when no preview is playing.
    @Published private(set) var previewingVoice: String?

    private struct Session {
        /// Tells readings apart: a late fallback callback from the previous reading's cloud engine must not count toward this one.
        let token: UUID
        let messageID: UUID
        let total: Int
        var index: Int
        /// The mid-reading fallback notice has already been shown for this reading.
        var fallbackNotified = false
    }

    private let engines: ReadAloudEngineSource
    /// The engine used for the current reading; supplied by engines each time a reading starts.
    private var engine: SpeechEngine?
    private let platform: ReadAloudPlatform
    /// Holder that keeps the screen awake while reading; shares one hold count with dictation.
    private let screenAwake: ScreenAwakeHolds
    private let detectLanguage: (String) -> String?
    private var session: Session?
    private var hasObservedChat = false
    private var observedConversationID: UUID?
    private var observedStreamingMessageID: UUID?
    private var notificationTokens: [NSObjectProtocol] = []
    /// Builds the cloud engine used for previews (separate from reading).
    private let makePreview: (CloudSpeechSetup) -> SpeechEngine
    private var previewEngine: SpeechEngine?
    private var previewRelay: PreviewRelay?

    init(
        engines: ReadAloudEngineSource,
        platform: ReadAloudPlatform,
        screenAwake: ScreenAwakeHolds? = nil,
        notificationCenter: NotificationCenter = .default,
        detectLanguage: @escaping (String) -> String? = ReadAloudController.dominantLanguage,
        makePreview: @escaping (CloudSpeechSetup) -> SpeechEngine = ReadAloudController.makePreviewEngine
    ) {
        self.engines = engines
        self.platform = platform
        self.screenAwake = screenAwake ?? .shared
        self.detectLanguage = detectLanguage
        self.makePreview = makePreview
        observeSystemNotifications(notificationCenter)
    }

    /// Pins one engine (settings are ignored).
    convenience init(
        engine: SpeechEngine,
        platform: ReadAloudPlatform,
        screenAwake: ScreenAwakeHolds? = nil,
        notificationCenter: NotificationCenter = .default,
        detectLanguage: @escaping (String) -> String? = ReadAloudController.dominantLanguage
    ) {
        self.init(engines: .fixed(engine), platform: platform, screenAwake: screenAwake,
                  notificationCenter: notificationCenter, detectLanguage: detectLanguage)
    }

    #if DEBUG
    /// Screenshots only: stages the playing state directly without creating a session, starting synthesis
    /// or touching the audio session, so nothing is played.
    func showSpeakingForShots(messageID: UUID, text: String) {
        let total = SpeakableText.segments(text: text, final: true).count
        state = .speaking(messageID: messageID, index: 0, total: max(total, 1))
    }
    #endif

    var speakingMessageID: UUID? {
        if case .speaking(let messageID, _, _) = state { return messageID }
        return nil
    }

    func toggle(messageID: UUID, text: String) {
        if let current = speakingMessageID {
            stop(.userStopped)
            if current == messageID { return }
        }
        start(messageID: messageID, text: text)
    }

    /// Stops the current reading; does nothing when idle.
    func stop(_ reason: ReadAloudEndReason) {
        guard session != nil else { return }
        engine?.stop()
        finish(reason)
    }

    /// Called on every chat list update (every frame while streaming): compares two ids only, free when idle.
    /// Conversation changed → navigated; a new generation started → newGeneration.
    /// It does not stop when the message is missing from the list: the list is a paged window, and expanding
    /// or jumping can leave a message that still exists temporarily outside the rows.
    func observeChat(conversationID: UUID?, streamingMessageID: UUID?) {
        let wasObserved = hasObservedChat
        let previousConversationID = observedConversationID
        let previousStreamingMessageID = observedStreamingMessageID
        hasObservedChat = true
        observedConversationID = conversationID
        observedStreamingMessageID = streamingMessageID

        guard wasObserved, session != nil else { return }
        if previousConversationID != conversationID {
            stop(.navigated)
        } else if previousStreamingMessageID == nil && streamingMessageID != nil {
            stop(.newGeneration)
        }
    }

    /// Called by the paths that really delete messages (edit truncation, regeneration replacement): stops if
    /// the message being read is among them.
    func stopIfSpeaking(messageIDs: some Sequence<UUID>, _ reason: ReadAloudEndReason) {
        guard let current = speakingMessageID, messageIDs.contains(current) else { return }
        stop(reason)
    }

    // MARK: Preview

    /// Voice preview from settings: stops any reading in progress, builds a cloud engine from the given entry / connection / voice /
    /// effective speed, and speaks one sample sentence in the UI language. Tapping the same voice while previewing stops it;
    /// tapping another voice stops the current one and plays the new voice.
    /// A failure only shows a notice and does not fall back to the system engine.
    func preview(entry: VoiceTTSEntry, provider: Provider, voice: String, speed: Double) {
        if previewEngine != nil {
            let sameVoice = previewingVoice == voice
            stopPreview()
            if sameVoice { return }
        }
        stop(.userStopped)
        let language = platform.uiLanguage
        guard let baseURL = DictationEngineSource.requestBaseURL(provider) else {
            platform.showToast(.couldNotPreview)
            return
        }
        do {
            try platform.activateAudioSession()
        } catch {
            platform.showToast(.couldNotPreview)
            return
        }
        let setup = CloudSpeechSetup(
            entry: entry,
            providerKind: provider.kind,
            baseURL: baseURL,
            apiKey: ProviderCredentialResolver.apiKey(provider: provider, modelID: nil),
            voice: voice,
            speed: speed,
            language: language
        )
        let engine = makePreview(setup)
        let relay = PreviewRelay(owner: self)
        previewEngine = engine
        previewRelay = relay
        previewingVoice = voice
        engine.delegate = relay
        let sample = platform.localizedVoiceString(Self.previewSampleKey, locale: language)
        engine.speak([SpeechUtterance(text: sample, language: language)])
    }

    /// Stops the preview (tapping preview again, leaving settings); does nothing when no preview is playing.
    func stopPreview() {
        guard let engine = previewEngine else { return }
        engine.stop()
        endPreview(failed: false)
    }

    fileprivate func previewDidEnd(_ relay: PreviewRelay, failed: Bool) {
        guard previewRelay === relay, let engine = previewEngine else { return }
        if failed { engine.stop() }
        endPreview(failed: failed)
    }

    private func endPreview(failed: Bool) {
        previewEngine = nil
        previewRelay = nil
        previewingVoice = nil
        platform.deactivateAudioSession()
        if failed { platform.showToast(.couldNotPreview) }
    }

    static let previewSampleKey = "Hi, this is how I'll sound when I read your replies."

    /// The production preview engine: a cloud engine plus a fallback engine that only fails (a preview never falls back to the system voice); shares the audio cache with reading.
    static func makePreviewEngine(_ setup: CloudSpeechSetup) -> SpeechEngine {
        ReadAloudEngineSource.makeCloudEngine(setup, fallback: PreviewFallbackEngine(), onFallback: {})
    }

    // MARK: Start / finish

    private func start(messageID: UUID, text: String) {
        stopPreview()
        let segments = SpeakableText.segments(text: text, final: true)
        guard !segments.isEmpty else { return }
        let (utterances, language) = makeUtterances(segments)
        let token = UUID()
        let choice = engines.select(language) { [weak self] providerName in
            self?.cloudDidFallBack(token: token, providerName: providerName)
        }
        let engine = choice.engine
        self.engine = engine
        engine.delegate = self
        if choice.fallback != nil { platform.showToast(.engineUnavailable) }
        guard engine.hasAnyVoice else {
            state = .failed(messageID: messageID)
            platform.showToast(.noVoice)
            return
        }
        do {
            try platform.activateAudioSession()
        } catch {
            state = .failed(messageID: messageID)
            platform.showToast(.couldNotRead)
            return
        }

        screenAwake.acquire(.readAloud)
        session = Session(
            token: token,
            messageID: messageID,
            total: utterances.count,
            index: 0
        )
        state = .speaking(messageID: messageID, index: 0, total: utterances.count)
        engine.speak(utterances)
    }

    /// The cloud engine switched to the system engine mid-reading: the notice is shown at most once per reading; state and settings are unchanged.
    private func cloudDidFallBack(token: UUID, providerName: String) {
        guard var current = session, current.token == token, !current.fallbackNotified else { return }
        current.fallbackNotified = true
        session = current
        platform.showToast(.cloudFallback(providerName: providerName))
    }

    private func finish(_ reason: ReadAloudEndReason) {
        guard let current = session else { return }
        session = nil
        platform.deactivateAudioSession()
        screenAwake.release(.readAloud)
        state = reason == .failed ? .failed(messageID: current.messageID) : .idle
        if reason == .failed { platform.showToast(.couldNotRead) }
    }

    /// Language detection only looks at this many leading characters of the reply: detecting a 20,000-character reply in full takes > 8 ms on the simulator, on the main-thread start path.
    static let languageDetectionLimit = 2_000

    /// Input for language detection: the first languageDetectionLimit code points (unicodeScalars), the same rule as Android.
    static func languageDetectionPrefix(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(languageDetectionLimit)))
    }

    /// The segments plus this reading's language (the placeholder sentence's language when there are no sentences).
    private func makeUtterances(_ segments: [SpeakableSegment]) -> ([SpeechUtterance], String) {
        let sentences = segments.compactMap { segment -> String? in
            if case .sentence(let text) = segment { return text }
            return nil
        }
        let readingLanguage = sentences.isEmpty ? nil : CloudReadAloudRules.readingLanguage(
            detected: detectLanguage(Self.languageDetectionPrefix(sentences.joined(separator: " "))),
            uiLocale: platform.uiLanguage
        )
        let placeholderLocale = SpeakableText.placeholderLocale(reading: readingLanguage, ui: platform.uiLanguage)
        let utterances = segments.map { segment -> SpeechUtterance in
            switch segment {
            case .sentence(let text):
                return SpeechUtterance(text: text, language: readingLanguage)
            case .placeholder(let kind):
                let text = platform.localizedVoiceString(Self.placeholderKey(kind), locale: placeholderLocale)
                return SpeechUtterance(text: text, language: placeholderLocale)
            }
        }
        return (utterances, readingLanguage ?? placeholderLocale)
    }

    // MARK: System events

    private func observeSystemNotifications(_ center: NotificationCenter) {
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            runOnMain { [weak self] in self?.stopAll(.interrupted) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            runOnMain { [weak self] in self?.stopAll(.interrupted) }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            runOnMain { [weak self] in self?.stopAll(.backgrounded) }
        })
    }

    /// System events stop both reading and preview.
    private func stopAll(_ reason: ReadAloudEndReason) {
        stop(reason)
        stopPreview()
    }

    // MARK: Pure functions

    static func placeholderKey(_ kind: SpeakablePlaceholder) -> String {
        switch kind {
        case .code: return "Here's a code block."
        case .table: return "Here's a table."
        case .math: return "Here's a formula."
        }
    }

    /// Detects the language: the highest hypothesis with enough confidence, see CloudReadAloudRules.confidentLanguage.
    nonisolated static func dominantLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: languageHypothesisCount)
        return CloudReadAloudRules.confidentLanguage(
            Dictionary(uniqueKeysWithValues: hypotheses.map { ($0.key.rawValue, $0.value) })
        )
    }

    nonisolated static let languageHypothesisCount = 5
}

extension ReadAloudController: SpeechEngineDelegate {
    func speechEngineDidStartSegment(at index: Int) {
        guard var current = session, index >= 0, index < current.total else { return }
        current.index = index
        session = current
        state = .speaking(messageID: current.messageID, index: index, total: current.total)
    }

    func speechEngineDidFinishAll() {
        finish(.finished)
    }

    func speechEngineDidFail() {
        guard session != nil else { return }
        engine?.stop()
        finish(.failed)
    }
}

/// Engine callbacks for one preview; the controller only honors the current one.
private final class PreviewRelay: SpeechEngineDelegate {
    weak var owner: ReadAloudController?

    init(owner: ReadAloudController) {
        self.owner = owner
    }

    func speechEngineDidStartSegment(at index: Int) {}

    func speechEngineDidFinishAll() {
        owner?.previewDidEnd(self, failed: false)
    }

    func speechEngineDidFail() {
        owner?.previewDidEnd(self, failed: true)
    }
}

/// The preview's fallback engine: when the cloud fails it reports failure directly instead of switching to a system voice.
final class PreviewFallbackEngine: SpeechEngine {
    weak var delegate: SpeechEngineDelegate?
    var hasAnyVoice: Bool { true }

    func speak(_ utterances: [SpeechUtterance]) {
        delegate?.speechEngineDidFail()
    }

    func stop() {}
}

// MARK: - Production implementations

/// AVSpeechSynthesizer: queues one utterance per segment, picks the highest-quality system voice for each segment's language, and speaks at the configured speed.
final class SystemSpeechEngine: NSObject, SpeechEngine {
    weak var delegate: SpeechEngineDelegate?

    private let synthesizer = AVSpeechSynthesizer()
    private var queued: [AVSpeechUtterance] = []
    /// Speed multiplier, read once per speak.
    private let speechRate: () -> Double

    override convenience init() {
        self.init(speechRate: { VoiceEngineSettings().speechRate })
    }

    init(speechRate: @escaping () -> Double) {
        self.speechRate = speechRate
        super.init()
        synthesizer.delegate = self
    }

    var hasAnyVoice: Bool {
        !Self.usableVoices().isEmpty
    }

    func speak(_ utterances: [SpeechUtterance]) {
        guard !utterances.isEmpty else {
            delegate?.speechEngineDidFail()
            return
        }
        let voices = Self.usableVoices()
        let rate = speechRate()
        var voiceByLanguage: [String: AVSpeechSynthesisVoice?] = [:]
        queued = utterances.map { item in
            var voice: AVSpeechSynthesisVoice?
            if let language = item.language {
                if voiceByLanguage[language] == nil {
                    voiceByLanguage[language] = Self.bestVoice(for: language, among: voices)
                }
                voice = voiceByLanguage[language] ?? nil
            }
            return Self.makeUtterance(item, voice: voice, speechRate: rate)
        }
        for utterance in queued { synthesizer.speak(utterance) }
    }

    func stop() {
        queued = []
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func handleStart(_ utterance: AVSpeechUtterance) {
        guard let index = queued.firstIndex(where: { $0 === utterance }) else { return }
        delegate?.speechEngineDidStartSegment(at: index)
    }

    private func handleFinish(_ utterance: AVSpeechUtterance) {
        guard let last = queued.last, last === utterance else { return }
        queued = []
        delegate?.speechEngineDidFinishAll()
    }

    /// One segment's utterance: a nil voice uses the system default; the accessibility speech settings still take priority.
    static func makeUtterance(
        _ item: SpeechUtterance, voice: AVSpeechSynthesisVoice?, speechRate: Double
    ) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: item.text)
        if let voice { utterance.voice = voice }
        utterance.rate = utteranceRate(speechRate: speechRate)
        utterance.prefersAssistiveTechnologySettings = true
        return utterance
    }

    /// The system default rate times the multiplier, clamped to the range the system allows.
    nonisolated static func utteranceRate(speechRate: Double) -> Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(speechRate)
        return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// Usable system voices (novelty and personal voices removed): cached once and shared by reading and conversation; invalidated when the system voices change.
    static func usableVoices() -> [AVSpeechSynthesisVoice] {
        if let cachedVoices { return cachedVoices }
        if voicesObserver == nil {
            voicesObserver = NotificationCenter.default.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { SystemSpeechEngine.cachedVoices = nil }
            }
        }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        cachedVoices = voices
        return voices
    }

    private static var cachedVoices: [AVSpeechSynthesisVoice]?
    private static var voicesObserver: NSObjectProtocol?

    /// The highest-quality voice for the language (premium > enhanced > default); on a tie, an exact language tag wins.
    static func bestVoice(for language: String, among voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let tag = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = tag.split(separator: "-").map(String.init)
        guard let base = parts.first else { return nil }
        let candidates = voices.filter { voice in
            let voiceParts = voice.language.lowercased().split(separator: "-").map(String.init)
            guard voiceParts.first == base else { return false }
            guard base == "zh" else { return true }
            let voiceRegion = voiceParts.dropFirst().last ?? ""
            let traditional = parts.contains("hant") || parts.contains { ["tw", "hk", "mo"].contains($0) }
            return traditional ? ["tw", "hk", "mo"].contains(voiceRegion) : !["tw", "hk", "mo"].contains(voiceRegion)
        }
        return candidates.max { lhs, rhs in
            let lhsScore = lhs.quality.rawValue * 10 + (lhs.language.lowercased() == tag ? 1 : 0)
            let rhsScore = rhs.quality.rawValue * 10 + (rhs.language.lowercased() == tag ? 1 : 0)
            return lhsScore < rhsScore
        } ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension SystemSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let box = UtteranceBox(utterance)
        Self.deliver { [weak self] in self?.handleStart(box.utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let box = UtteranceBox(utterance)
        Self.deliver { [weak self] in self?.handleFinish(box.utterance) }
    }

    private nonisolated static func deliver(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
}

/// AVSpeechUtterance is not Sendable; this box is only used to compare identity across callbacks.
private nonisolated final class UtteranceBox: @unchecked Sendable {
    let utterance: AVSpeechUtterance
    init(_ utterance: AVSpeechUtterance) { self.utterance = utterance }
}

final class SystemReadAloudPlatform: ReadAloudPlatform {
    /// Session configuration passed to setCategory while reading; unit tests read the same value.
    static let sessionConfiguration: (category: AVAudioSession.Category, mode: AVAudioSession.Mode) =
        (.playback, .spokenAudio)

    func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let config = Self.sessionConfiguration
        try session.setCategory(config.category, mode: config.mode)
        try session.setActive(true)
    }

    func deactivateAudioSession() {
        // Failure only means other audio still holds the session; reading has already stopped, so no toast
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var uiLanguage: String {
        AppLocalization.currentLanguage.rawValue
    }

    /// Placeholder sentences come from the Voice table of the placeholderLocale's .lproj, not the UI language.
    func localizedVoiceString(_ key: String, locale: String) -> String {
        for candidate in [locale, "en"] {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle.localizedString(forKey: key, value: key, table: L10n.Table.voice.rawValue)
            }
        }
        return key
    }

    func showToast(_ toast: ReadAloudToast) {
        ToastManager.shared.show(toast.localizedText, style: .error)
    }
}
