import AVFoundation
import Combine
import Foundation
import Observation
import Speech
import UIKit

// MARK: - State and output

/// Where the user wants the recording to go once done: "transcribe" inserts into the input field, "up arrow" sends directly.
nonisolated enum DictationIntent: Sendable, Hashable {
    case insert
    case send
}

/// What to offer the user when stopped; the recording is always still in its slot.
nonisolated enum DictationFailureKind: Sendable, Hashable {
    case retry
    case checkConnection
    /// The precheck found voice but recognition returned empty text: the recording is kept and can be retried.
    case noTranscript
    /// System engine recognition failed (subdivided by DictationRules.systemFailure): the recording is kept.
    case system(SystemFailureKind)
}

/// Which permission was denied.
nonisolated enum DictationDeniedPermission: Sendable, Hashable {
    case microphone
    /// Speech recognition authorization needed by the system engine on iOS 18-25.
    case speechRecognition
}

nonisolated enum DictationState: Sendable, Equatable {
    case idle
    /// Authorization denied: the system prompt is not shown again; the UI guides the user to Settings.
    case denied(DictationDeniedPermission)
    /// When the mic is tapped the slot still holds a recording waiting for transcription: ask the user to "transcribe first" or "discard and re-record".
    case slotOccupied
    case recording(startedAt: Date)
    case transcribing(DictationIntent)
    /// The recording was interrupted / sent to background / discard undone: the file is closed and in the slot, waiting for the user to transcribe or discard.
    case interrupted
    case failed(DictationFailureKind)
}

/// A one-shot result the controller hands to the UI.
nonisolated enum DictationEvent: Sendable, Equatable {
    case insert(String)
    case send(String)
    /// The precheck failed (too short / no voice): the recording is deleted and the engine is not called.
    case noSpeechHeard
    /// The stored cloud engine is no longer valid; this time the system engine is used and the setting has been reset to system; the UI shows a notice once.
    case engineFallback(VoiceFallbackReason)
    /// The live text of this segment is discarded (failure / nothing recognized / X discard / interruption): the host withdraws the live text on screen.
    case liveDiscarded
}

// MARK: - Live recognition

/// Engine that can recognize while recording (the system engine); cloud engines do not conform and only recognize the recording file.
nonisolated protocol LiveSTTEngine: STTEngine {
    func startLive(language: String?) -> SystemSTTSession
}

extension SystemSTTEngine: LiveSTTEngine {}

/// Live text during recording (value = DictationRules.livePartial): published separately so refreshes do not trigger DictationController's objectWillChange.
/// Set to nil when this segment ends (finalized / failed / discarded / interrupted).
@MainActor
final class DictationLiveText: ObservableObject {
    @Published private(set) var value: LiveDictationText?

    /// Each new session / clear starts a new generation: late snapshots from the old generation are dropped.
    private(set) var generation = 0

    /// Starts a new generation and returns its id.
    func begin() -> Int {
        generation += 1
        if value != nil { value = nil }
        return generation
    }

    func publish(_ snapshot: SystemSTTLiveSnapshot, generation: Int) {
        guard generation == self.generation else { return }
        let next = DictationRules.livePartial(finals: snapshot.finals, partial: snapshot.partial)
        if next != value { value = next }
    }

    func reset() {
        generation += 1
        if value != nil { value = nil }
    }
}

// MARK: - Engine selection

/// Public identity of a cloud engine: the connection name shown on the card and the connection id. The system engine has none.
nonisolated struct DictationEngineInfo: Sendable, Equatable {
    let displayName: String
    let providerID: UUID
}

/// Result of one engine selection.
struct DictationEngineChoice {
    let engine: any STTEngine
    /// Before recording, the system engine needs speech recognition authorization / on-device model preparation.
    let isSystem: Bool
    /// Non-nil means fell back from cloud to the system engine (only this time needs a notice).
    let fallback: VoiceFallbackReason?
    /// Engine identifier written into the slot sidecar: systemEngineID for the system engine, cloudEngineID(kind:model:) for cloud.
    let engineID: String?
    /// Display name and id of the connection used by the cloud engine; nil for the system engine.
    let displayName: String?
    let providerID: UUID?

    init(engine: any STTEngine, isSystem: Bool, fallback: VoiceFallbackReason?, engineID: String? = nil,
         displayName: String? = nil, providerID: UUID? = nil) {
        self.engine = engine
        self.isSystem = isSystem
        self.fallback = fallback
        self.engineID = engineID ?? (isSystem ? Self.systemEngineID : nil)
        self.displayName = isSystem ? nil : displayName
        self.providerID = isSystem ? nil : providerID
    }

    /// Exposed only when both are present.
    var info: DictationEngineInfo? {
        guard let displayName, let providerID else { return nil }
        return DictationEngineInfo(displayName: displayName, providerID: providerID)
    }

    static let systemEngineID = "system"

    static func cloudEngineID(kind: ProviderKind, model: String) -> String {
        "\(kind.rawValue)/\(model)"
    }
}

/// Chooses the dictation engine before recording (or on retry when none was chosen yet): settings + catalog + connections.
struct DictationEngineSource {
    let select: () async -> DictationEngineChoice

    /// Fixes one engine without reading settings.
    static func fixed(_ engine: any STTEngine, isSystem: Bool = false, engineID: String? = nil,
                      displayName: String? = nil, providerID: UUID? = nil) -> DictationEngineSource {
        DictationEngineSource {
            DictationEngineChoice(engine: engine, isSystem: isSystem, fallback: nil, engineID: engineID,
                                  displayName: displayName, providerID: providerID)
        }
    }

    /// Resolves from the stored dictation engine selection; on fallback the setting is reset to system (persisted by VoiceEngineSettings.resolve).
    /// When the catalog has no usable result (no cache and loading failed / unavailable) this time uses the system engine, leaves settings unchanged and shows no notice.
    /// If the catalog fetch (a network refresh on cold start) does not return within catalogLimit it counts as a load failure; a late result is dropped.
    static func resolving(
        settings: VoiceEngineSettings = VoiceEngineSettings(),
        catalog: @escaping @MainActor @Sendable () async -> VoiceCatalogState? = DictationEngineSource.sharedCatalog,
        catalogLimit: Duration = DictationEngineSource.catalogLimit,
        providers: @escaping () -> [Provider],
        makeSystem: @escaping () -> any STTEngine,
        makeCloud: @escaping (_ baseURL: URL, _ apiKey: String, _ entry: VoiceSTTEntry) -> any STTEngine = {
            CloudSTTEngine(baseURL: $0, apiKey: $1, entry: $2)
        }
    ) -> DictationEngineSource {
        DictationEngineSource {
            func system(_ fallback: VoiceFallbackReason?) -> DictationEngineChoice {
                DictationEngineChoice(engine: makeSystem(), isSystem: true, fallback: fallback,
                                      displayName: nil, providerID: nil)
            }
            // When the settings page already noticed a fallback and reset to system, it left a pending notice here: take it and clear it, shown once for this recording.
            let pending = settings.takePendingNotice(site: .use, direction: .stt)
            guard case .cloud(let stored) = settings.selection(for: .stt) else { return system(pending) }
            // A cloud selection without accepted disclosure (restored backup / leftover data) sends nothing out: use the system engine this time, without rewriting settings or showing a notice.
            guard settings.disclosures.hasAccepted(stored.providerKind, direction: .stt) else { return system(nil) }
            guard let catalog = await VoiceDeadline.value(within: catalogLimit, { await catalog() })??.catalog
            else { return system(nil) }
            let providers = providers()
            let resolution = settings.resolve(
                direction: .stt,
                catalog: catalog,
                connections: providers.map(VoiceConnection.init(provider:)),
                site: .use
            )
            switch resolution {
            case .system(let fallback):
                return system(fallback)
            case .cloud(let selected):
                guard let provider = providers.first(where: { $0.id.uuidString == selected.connectionID }),
                      let entry = catalog.sttEntries(selected.providerKind).first(where: { $0.model == selected.model })
                else { return system(nil) }
                let apiKey = ProviderCredentialResolver.apiKey(provider: provider, modelID: nil)
                let engineID = DictationEngineChoice.cloudEngineID(kind: selected.providerKind, model: selected.model)
                guard let baseURL = requestBaseURL(provider) else {
                    // The connection address cannot be built: a connection configuration problem, so transcription stops at "check connection" and the recording is kept.
                    return DictationEngineChoice(engine: MisconfiguredSTTEngine(), isSystem: false, fallback: nil,
                                                 engineID: engineID, displayName: provider.displayName,
                                                 providerID: provider.id)
                }
                return DictationEngineChoice(engine: makeCloud(baseURL, apiKey, entry), isSystem: false, fallback: nil,
                                             engineID: engineID, displayName: provider.displayName,
                                             providerID: provider.id)
            }
        }
    }

    /// Production catalog: use the result this process already has, and refresh once when there is no usable catalog.
    /// Default limit for the catalog fetch before recording.
    static let catalogLimit: Duration = .seconds(10)

    static let sharedCatalog: @MainActor @Sendable () async -> VoiceCatalogState? = {
        let client = VoiceCatalogClient.shared
        if let state = await client.state, state.catalog != nil { return state }
        return await client.refresh()
    }

    /// Connection address (no scheme is treated as https); the request URL takes its origin from it and appends the catalog path via DictationRules.requestURL.
    static func requestBaseURL(_ provider: Provider) -> URL? {
        guard let raw = provider.requestBaseURLText()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let text = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://\(raw)"
        return URL(string: text)
    }
}

/// Placeholder engine for an invalid connection address: always stops at "check connection".
nonisolated struct MisconfiguredSTTEngine: STTEngine {
    func transcribe(_ recording: RecordingResult, language: String?) async throws -> String {
        throw STTError(action: .checkConnection, failure: nil)
    }
}

/// One-time prompt shown when the on-device language pack for the recognition language is missing; download runs in the background and recording does not wait for it.
nonisolated struct DictationLanguagePackPrompt: Sendable, Equatable {
    /// Language of the language pack (BCP 47).
    let localeID: String
    /// Language name shown in the current UI language.
    let displayName: String
    /// true = download tapped, installing in the background.
    var downloading: Bool
}

/// Preparation before the system engine records: on iOS 18–25 speech recognition authorization is requested after the microphone; on iOS 26+ no authorization is needed, and a missing on-device model only prompts a download without blocking recording.
struct DictationSystemPreparation {
    /// Languages already prompted (BCP 47 array); recorded both on download and on "don't remind", so each language prompts only once.
    static let promptedDefaultsKey = "voice.speech_assets.prompted"

    /// true = iOS 26+ (SpeechAnalyzer available).
    let analyzerAvailable: Bool
    let authorizer: any SpeechAuthorizing
    let assets: SpeechAssetManager?
    /// Recognition language (nil = automatic) -> the language whose model to check; nil means no check.
    let assetLocale: @Sendable (String?) async -> Locale?
    /// Limit for assetLocale; when the system query hangs it times out as nil (no model check) and the start-recording flow finishes as usual.
    var assetLocaleLimit: Duration = VoiceDeadline.systemQuery
    /// Storage recording the languages already prompted.
    var promptDefaults: UserDefaults = .standard

    /// No preparation at all (used with a fixed engine).
    static let skipped = DictationSystemPreparation(
        analyzerAvailable: true, authorizer: SystemSpeechAuthorizer(), assets: nil, assetLocale: { _ in nil }
    )

    static func makeDefault(assets: SpeechAssetManager) -> DictationSystemPreparation {
        if #available(iOS 26, *) {
            return DictationSystemPreparation(
                analyzerAvailable: true,
                authorizer: SystemSpeechAuthorizer(),
                assets: assets,
                assetLocale: { language in
                    let locale: Locale
                    if let language, !language.isEmpty {
                        locale = Locale(identifier: language)
                    } else {
                        locale = await SystemSTTEngine.appLocale()
                    }
                    guard SpeechTranscriber.isAvailable else { return nil }
                    return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
                }
            )
        }
        return DictationSystemPreparation(
            analyzerAvailable: false, authorizer: SystemSpeechAuthorizer(), assets: nil, assetLocale: { _ in nil }
        )
    }
}

// MARK: - Microphone permission

nonisolated enum MicrophonePermissionStatus: Sendable, Equatable {
    case undetermined
    case denied
    case granted
}

protocol MicrophonePermission: AnyObject {
    var status: MicrophonePermissionStatus { get }
    /// Called only when undetermined; returns whether the user agreed.
    func request() async -> Bool
}

final class SystemMicrophonePermission: MicrophonePermission {
    var status: MicrophonePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// Holds NotificationCenter observer tokens: released together with the owning controller, removing each one on release.
private nonisolated final class NotificationTokenBag: @unchecked Sendable {
    private let center: NotificationCenter
    var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}

/// Hands capture and the handler to a background thread to open capture; the start-recording flow does not touch this capture while the main thread awaits (detach before the writer is attached does not stop it).
private nonisolated struct CaptureStartRequest: @unchecked Sendable {
    let capture: AudioCapture
    let handlers: [AudioBufferHandler]
}

/// Tap format returned by the background capture open.
private nonisolated struct CaptureStartResult: @unchecked Sendable {
    let format: AVAudioFormat
}

private extension DictationState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

// MARK: - Controller

/// Main dictation flow: slot check -> microphone permission -> engine selection (the system engine then does authorization / model preparation) -> record -> precheck -> transcribe -> result.
/// From the moment recording starts the audio lives in a RecordingStore slot and is deleted only after a successful transcription or a user discard (also when the precheck fails: there is no voice in it).
/// The slot key is given by bind(slotKey:); until bound, no operation takes effect.
@MainActor
final class DictationController: ObservableObject {

    /// Undo window for a discard; only discards of recordings longer than DictationRules.discardUndoAboveSec open one.
    static let discardUndoWindow: Duration = .seconds(4)

    @Published private(set) var state: DictationState = .idle {
        didSet {
            if state == .idle { engineInfo = nil }
            syncRecordingSideEffects(from: oldValue)
            refreshPendingDuration()
        }
    }

    /// Live input level while recording (for the waveform); published separately so refreshes do not trigger this controller's objectWillChange. Cleared on leaving recording.
    let levelMeter = DictationLevelMeter()

    /// Live partial text while recording with the system engine; published on its own.
    let liveText = DictationLiveText()

    /// Connection name and id of the cloud engine used for this recording (for the card): set when the engine is chosen, cleared on returning to idle; nil for the system engine.
    @Published private(set) var engineInfo: DictationEngineInfo?

    /// Duration of the recording waiting in the slot (read from the same slot's sidecar): only provided in interrupted / slotOccupied / failed.
    /// On entering those states the sidecar is read on the store queue and published back on the main thread; in other states it is nil immediately. Views read only this published value and never touch the disk.
    @Published private(set) var pendingDurationSec: Double?

    /// Language-pack prompt for the recognition language when its on-device pack is missing; nil = no prompt.
    @Published private(set) var languagePackPrompt: DictationLanguagePackPrompt?

    /// In-flight background download of the language pack; the prompt is cleared when it finishes (success or failure).
    private(set) var languagePackDownload: Task<Void, Never>?

    /// The in-flight sidecar duration read; cancelled when the state changes again so the old result is not published.
    private(set) var pendingDurationLoad: Task<Void, Never>?

    /// The in-flight bound-slot query (which also starts the sweep before the first binding); cancelled on rebinding so the old result no longer lands on the state.
    private(set) var bindLoad: Task<Void, Never>?

    /// Insert / send / no sound heard, picked up by the input field.
    var onEvent: ((DictationEvent) -> Void)?

    /// The currently bound slot (conversation UUID or home draft).
    private(set) var slotKey: String?

    /// The engine used for this recording; chosen before recording and reused on retry. When none was chosen yet, it is chosen before transcribing.
    private(set) var engine: (any STTEngine)?

    /// Timer of the in-flight undo window; automatically commitDiscard when due. Undo / early commit / a new discard cancels it.
    var undoWindowTask: Task<Void, Never>? { pendingDiscard?.task }

    private let engines: DictationEngineSource
    private let system: DictationSystemPreparation
    private let capture: AudioCapture
    /// Audio session ownership shared with voice conversation; waits for the conversation lease to be released before capture starts.
    private let audioSession: VoiceAudioSessionOwner
    private let store: RecordingStore
    private let permission: MicrophonePermission
    private let readAloud: ReadAloudController
    /// Holder that keeps the screen awake while recording (held only in the recording state); shares one hold count with read-aloud.
    private let screenAwake: ScreenAwakeHolds
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Recognition language (nil = automatic); read at each recording start / transcription.
    let language: () -> String?

    /// App UI language; read each time a name is fetched (injected by tests).
    private let uiLocale: () -> Locale
    /// Recognition language at the moment of entering the failed state (automatic = the full BCP-47 tag of the UI language then); the failure card shows it, and later language changes do not affect it.
    private var failedRecognitionLanguage: String?

    /// Name of the recognition language in the App UI language, used by the failure card text. In the failed state it reads the language recorded when the failure happened, otherwise the current recognition language.
    var recognitionLanguageName: String {
        let uiLocale = uiLocale()
        let id: String
        if case .failed = state, let failedRecognitionLanguage {
            id = failedRecognitionLanguage
        } else {
            id = Self.recognitionLanguageID(language(), uiLocale: uiLocale)
        }
        return uiLocale.localizedString(forIdentifier: id) ?? id
    }

    /// Recognition language identifier; when automatic, takes the full BCP-47 tag of the UI language (zh-Hans is not reduced to zh).
    nonisolated static func recognitionLanguageID(_ language: String?, uiLocale: Locale) -> String {
        if let language, !language.isEmpty { return language }
        return uiLocale.identifier(.bcp47)
    }
    private var engineID: String?
    /// Whether the chosen engine is the system engine; set and cleared together with engine.
    private var engineIsSystem = false
    /// Public identifier of the chosen engine; engineInfo is cleared after returning to idle, and transcribing with the same engine gives it out again from here.
    private var chosenInfo: DictationEngineInfo?
    private var writer: LockedRecordingWriter?
    private var transcription: Task<String, Error>?
    /// In-flight live recognition (opened while the system engine records); cleared when a result comes out or it is discarded.
    private var live: LiveRun?
    /// System notification observers; removed from the center when the controller is released.
    private let notificationTokens: NotificationTokenBag
    /// Token of the in-flight start-recording flow (authorization / engine selection / model preparation); discard, a slot switch or a new round replaces it, and an old flow that wakes up no longer starts recording.
    private var startToken: UUID?
    /// The start-recording flow has begun opening capture and has not handed it over yet (writer attached, or stopped by itself): no second flow starts meanwhile.
    /// When a superseded flow is cleaned up it only stops the capture it opened itself, never a newer flow's.
    private var captureOpening = false
    /// The discard inside the undo window: owning slot key + token + timer task.
    private var pendingDiscard: (slotKey: String, token: UUID, task: Task<Void, Never>)?

    /// permission / readAloud / screenAwake use the production implementations when nil (resolved inside the init body to avoid main-actor isolation warnings on default arguments).
    init(
        engines: DictationEngineSource,
        system: DictationSystemPreparation,
        capture: AudioCapture,
        store: RecordingStore,
        audioSession: VoiceAudioSessionOwner = .shared,
        permission: MicrophonePermission? = nil,
        readAloud: ReadAloudController? = nil,
        screenAwake: ScreenAwakeHolds? = nil,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        language: @escaping () -> String? = { nil },
        uiLocale: @escaping () -> Locale = { AppLocalization.currentLanguage.locale }
    ) {
        self.engines = engines
        self.system = system
        self.capture = capture
        self.audioSession = audioSession
        self.store = store
        self.permission = permission ?? SystemMicrophonePermission()
        self.readAloud = readAloud ?? .shared
        self.screenAwake = screenAwake ?? .shared
        self.now = now
        self.sleep = sleep
        self.language = language
        self.uiLocale = uiLocale
        notificationTokens = NotificationTokenBag(center: notificationCenter)
        observeSystemNotifications(notificationCenter)
    }

    // MARK: Store IO

    /// File operations of the slot store (sidecar reads, slot queries, discard / commit discard) all run on this serial queue, off the main thread;
    /// serial order keeps them consistent with the order submitted from the main thread (a query after a discard sees the slot after the discard).
    private nonisolated static let storeQueue = DispatchQueue(label: "com.oriveo.dictation.recording-store")

    /// RecordingStore has no shared mutable state (only lets and file operations), and the file operations are serialized through storeQueue, so passing it across threads is safe.
    private nonisolated struct StoreRef: @unchecked Sendable {
        let store: RecordingStore
    }

    private nonisolated static func onStoreQueue<T>(
        _ store: RecordingStore, _ work: @escaping @Sendable (RecordingStore) -> T
    ) async -> T {
        let ref = StoreRef(store: store)
        let box: UncheckedResult<T> = await withCheckedContinuation { continuation in
            storeQueue.async { continuation.resume(returning: UncheckedResult(value: work(ref.store))) }
        }
        return box.value
    }

    private nonisolated struct UncheckedResult<T>: @unchecked Sendable {
        let value: T
    }

    /// Waits until all operations previously enqueued on the store queue are done (posts an empty block and awaits it): used by tests / probes before inspecting the store, changes no state.
    func storeDrained() async {
        await Self.onStoreQueue(store) { _ in }
    }

    /// A store write that does not wait for the result: enqueued synchronously, ahead of any store operation submitted afterwards.
    private nonisolated static func enqueueOnStoreQueue(
        _ store: RecordingStore, _ work: @escaping @Sendable (RecordingStore) -> Void
    ) {
        let ref = StoreRef(store: store)
        storeQueue.async { work(ref.store) }
    }

    /// Refreshes pendingDurationSec when the state changes: entering interrupted / slotOccupied / failed reads the sidecar in the background and then publishes; otherwise cleared.
    private func refreshPendingDuration() {
        pendingDurationLoad?.cancel()
        pendingDurationLoad = nil
        switch state {
        case .interrupted, .slotOccupied, .failed:
            guard let slotKey else {
                pendingDurationSec = nil
                return
            }
            let store = self.store
            pendingDurationLoad = Task { [weak self] in
                let duration = await Self.onStoreQueue(store) { (try? $0.slot(for: slotKey))?.durationSec }
                guard !Task.isCancelled, let self, self.slotKey == slotKey else { return }
                self.pendingDurationSec = duration
            }
        default:
            pendingDurationSec = nil
        }
    }

    // MARK: Slots

    /// Binds (or switches to) a slot: while recording, first wrap up the old slot as interrupted, then switch;
    /// the new slot shows idle first, and once the store queue finds a recording (cold start, switching back to a conversation) it turns interrupted;
    /// the query is ordered after earlier discards and sees the slot as it is after they take effect. If it is rebound or the state changed while waiting, the result is not applied.
    func bind(slotKey newKey: String) {
        guard newKey != slotKey else { return }
        let sweep = claimLaunchSweep()
        leaveCurrentSlot()
        slotKey = newKey
        forgetEngine()
        state = .idle
        bindLoad?.cancel()
        let store = self.store
        bindLoad = Task { [weak self] in
            let occupied = await Self.onStoreQueue(store) { store -> Bool in
                if sweep { _ = try? store.sweepOnLaunch() }
                return (try? store.slot(for: newKey)) != nil
            }
            guard !Task.isCancelled, let self, self.slotKey == newKey, self.state == .idle, occupied else { return }
            self.state = .interrupted
        }
    }

    /// Slot store directories already swept in this process: one directory is swept only before its first binding (a recording sidecar left by a crash becomes interrupted).
    private static var sweptRoots: Set<String> = []

    /// Whether this directory should be swept now (true for the first binding in each process); the sweep itself runs on the store queue along with the binding query.
    private func claimLaunchSweep() -> Bool {
        let key = store.root.standardizedFileURL.path
        guard !Self.sweptRoots.contains(key) else { return false }
        Self.sweptRoots.insert(key)
        return true
    }

    /// Leaves the current slot: a recording is wrapped up as interrupted; transcription is cancelled and the recording stays in the old slot marked interrupted; an in-flight start-recording flow is invalidated.
    private func leaveCurrentSlot() {
        startToken = nil
        discardLive()
        switch state {
        case .recording:
            // The wrap-up of the user's stop is still on the store queue (the writer is already detached): mark the sidecar interrupted after it.
            if !closeRecording(interrupted: true), let slotKey { markSlotInterrupted(slotKey) }
        case .transcribing:
            transcription?.cancel()
            transcription = nil
            if let slotKey { markSlotInterrupted(slotKey) }
        default:
            break
        }
    }

    #if DEBUG
    // MARK: Screenshot display state

    /// For the screenshot landing page: only sets up a display state (state + engine row), without starting capture or writing to RecordingStore.
    /// In the recording state, levels (0...1) are fed into a static waveform through the level meter's own tap; there are no further pushes afterwards, so the waveform does not move.
    func showStateForShots(_ newState: DictationState, engineInfo info: DictationEngineInfo?, levels: [Float]) {
        startToken = nil
        state = newState
        engineInfo = newState == .idle ? nil : info
        guard newState.isRecording, !levels.isEmpty else { return }
        let sampleRate = 16_000.0
        // Each chunk fills the level meter's throttle window (1 / maxUpdatesPerSecond seconds) so that one chunk yields one level.
        let frames = AVAudioFrameCount((sampleRate / DictationLevelMeter.maxUpdatesPerSecond).rounded(.up)) + 1
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let tap = levelMeter.makeTap()
        let time = AVAudioTime(sampleTime: 0, atRate: sampleRate)
        for level in levels {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let samples = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = frames
            // Inverse of level(rms:): 0 -> -60 dBFS, 1 -> 0 dBFS; the RMS of a constant signal is its amplitude.
            let clamped = min(1, max(0, level))
            let amplitude = Float(pow(10, Double(-60 + 60 * clamped) / 20))
            for index in 0..<Int(frames) { samples[index] = amplitude }
            tap(buffer, time)
        }
    }
    #endif

    // MARK: Recording

    /// Mic tapped: stop read-aloud first; if the slot is occupied, ask the user first, otherwise run the start-recording flow.
    func micTapped() async {
        readAloud.stop(.userStopped)
        guard let slotKey, startToken == nil else { return }
        switch state {
        case .recording, .transcribing, .slotOccupied: return
        case .idle, .denied, .interrupted, .failed: break
        }
        // The occupancy query runs on the store queue; if it was discarded / the slot switched / tapped again while waiting, do not proceed on this result.
        let token = UUID()
        startToken = token
        let before = state
        let occupied = await Self.onStoreQueue(store) { (try? $0.slot(for: slotKey)) != nil }
        guard startToken == token else { return }
        startToken = nil
        guard self.slotKey == slotKey, state == before else { return }
        if occupied {
            state = .slotOccupied
            return
        }
        await beginRecording(slotKey: slotKey)
    }

    /// When the slot is occupied and the user picks "transcribe first": transcribe the old recording in the slot and insert the result into the input field.
    func transcribeOccupied() async {
        guard state == .slotOccupied else { return }
        await finish(.insert)
    }

    /// When the slot is occupied and the user picks "discard and re-record": delete the old recording directly (not into the undo area), then run the start-recording flow.
    func discardAndRerecord() async {
        guard let slotKey, state == .slotOccupied else { return }
        await Self.onStoreQueue(store) { try? $0.complete(slotKey: slotKey) }
        guard self.slotKey == slotKey, state == .slotOccupied else { return }
        forgetEngine()
        state = .idle
        await beginRecording(slotKey: slotKey)
    }

    private func beginRecording(slotKey: String) async {
        // A previous start is still opening capture (session activation not yet returned) or the slot: do not open a second one concurrently; this tap is void.
        guard !captureOpening else { return }
        let token = UUID()
        startToken = token
        defer { if startToken == token { startToken = nil } }

        guard await grantMicrophone(), startToken == token else {
            if startToken == token { state = .denied(.microphone) }
            return
        }
        let choice = await engines.select()
        guard startToken == token else { return }
        adopt(choice)
        if let reason = choice.fallback { onEvent?(.engineFallback(reason)) }
        if choice.isSystem {
            guard await prepareSystemEngine(token: token) else { return }
        }
        await startRecording(slotKey: slotKey, token: token)
    }

    /// Before entering a live voice session: only the microphone authorization is needed (no engine selection, no speech recognition authorization, no on-device model preparation);
    /// when denied it stops on the same denied card as dictation. Returns false = do not enter (denied, flow cancelled, or dictation busy).
    func prepareConversationMicrophone() async -> Bool {
        guard startToken == nil else { return false }
        switch state {
        case .recording, .transcribing: return false
        case .idle, .denied, .slotOccupied, .interrupted, .failed: break
        }
        let token = UUID()
        startToken = token
        defer { if startToken == token { startToken = nil } }

        guard await grantMicrophone(), startToken == token else {
            if startToken == token { state = .denied(.microphone) }
            return false
        }
        if case .denied = state { state = .idle }
        return true
    }

    /// Before entering a live voice session: the same path as starting to record - microphone authorization -> engine selection -> the system engine's recognition authorization / on-device model preparation; no language-pack prompt is published (prompts appear only in dictation);
    /// when denied it stops on the same denied card as dictation. Does not record, does not occupy the slot, and does not change the engine chosen by this controller.
    /// Returns the engine this session uses for "listening"; nil = do not enter the conversation (denied, flow cancelled, or dictation busy).
    func prepareConversationListening() async -> DictationEngineChoice? {
        guard startToken == nil else { return nil }
        switch state {
        case .recording, .transcribing: return nil
        case .idle, .denied, .slotOccupied, .interrupted, .failed: break
        }
        let token = UUID()
        startToken = token
        defer { if startToken == token { startToken = nil } }

        guard await grantMicrophone(), startToken == token else {
            if startToken == token { state = .denied(.microphone) }
            return nil
        }
        if case .denied = state { state = .idle }
        let choice = await engines.select()
        guard startToken == token else { return nil }
        if choice.isSystem {
            guard await prepareSystemEngine(token: token, promptsLanguagePack: false) else { return nil }
        }
        return choice
    }

    private func adopt(_ choice: DictationEngineChoice) {
        engine = choice.engine
        engineID = choice.engineID
        engineIsSystem = choice.isSystem
        chosenInfo = choice.info
        engineInfo = choice.info
    }

    private func forgetEngine() {
        engine = nil
        engineID = nil
        engineIsSystem = false
        chosenInfo = nil
        engineInfo = nil
    }

    /// Dismissed from the permission card: only valid in the denied state, returns to idle.
    func dismissDenied() {
        guard case .denied = state else { return }
        state = .idle
    }

    private func grantMicrophone() async -> Bool {
        switch permission.status {
        case .denied: return false
        case .undetermined:
            return await permission.request()
        case .granted: return true
        }
    }

    /// Tapped "download" on the language-pack prompt: records that it was prompted, switches the prompt to downloading and installs in the background; the prompt is cleared when install finishes (success or failure), and a failure does not show the failure card.
    func download() {
        guard var prompt = languagePackPrompt, !prompt.downloading, let assets = system.assets else { return }
        markLanguagePackPrompted(prompt.localeID)
        prompt.downloading = true
        languagePackPrompt = prompt
        let localeID = prompt.localeID
        languagePackDownload = Task { [weak self] in
            try? await assets.prepare(.speechTranscriber, locale: Locale(identifier: localeID))
            guard let self, self.languagePackPrompt?.localeID == localeID else { return }
            self.languagePackPrompt = nil
        }
    }

    /// Tapped "don't remind" on the language-pack prompt: records that it was prompted and clears the prompt.
    func dismissLanguagePack() {
        guard let prompt = languagePackPrompt, !prompt.downloading else { return }
        markLanguagePackPrompted(prompt.localeID)
        languagePackPrompt = nil
    }

    private func languagePackPrompted(_ localeID: String) -> Bool {
        system.promptDefaults.stringArray(forKey: DictationSystemPreparation.promptedDefaultsKey)?.contains(localeID) ?? false
    }

    private func markLanguagePackPrompted(_ localeID: String) {
        let key = DictationSystemPreparation.promptedDefaultsKey
        var prompted = system.promptDefaults.stringArray(forKey: key) ?? []
        guard !prompted.contains(localeID) else { return }
        prompted.append(localeID)
        system.promptDefaults.set(prompted, forKey: key)
    }

    /// Preparation before the system engine records; returns false when recording must not start (authorization denied or the flow was discarded).
    /// promptsLanguagePack = false (voice conversation): does not check the language pack and does not publish a prompt.
    private func prepareSystemEngine(token: UUID, promptsLanguagePack: Bool = true) async -> Bool {
        if !system.analyzerAvailable {
            if !system.authorizer.isAuthorized {
                let granted = await system.authorizer.requestAuthorization()
                guard startToken == token else { return false }
                guard granted else {
                    state = .denied(.speechRecognition)
                    return false
                }
            }
            return true
        }
        guard promptsLanguagePack else { return startToken == token }
        let requested = language()
        let assetLocale = system.assetLocale
        guard let assets = system.assets,
              let locale = await VoiceDeadline.value(within: system.assetLocaleLimit, { await assetLocale(requested) })
                ?? nil
        else {
            return startToken == token
        }
        guard startToken == token else { return false }
        // Only check, never install: if the pack is missing and this language has not been prompted yet, publish the prompt; recording starts as usual (live recognition goes online).
        let localeID = SpeechAssetManager.localeKey(locale)
        guard !languagePackPrompted(localeID), languagePackPrompt?.localeID != localeID else { return true }
        let installed = await assets.isInstalled(.speechTranscriber, locale: locale)
        guard startToken == token else { return false }
        if !installed {
            languagePackPrompt = DictationLanguagePackPrompt(
                localeID: localeID,
                displayName: AppLocalization.currentLanguage.locale.localizedString(forIdentifier: localeID) ?? localeID,
                downloading: false
            )
        }
        return true
    }

    private func startRecording(slotKey: String, token: UUID) async {
        let box = LockedRecordingWriter { [weak self] failed in
            runOnMain { [weak self] in self?.recordingWriteFailed(failed) }
        }
        // Do not start while a voice conversation is wrapping up (end chime, leave-page grace): its teardown deactivates the session, so wait for its lease to be released before starting.
        await audioSession.waitForConversationRelease()
        guard startToken == token else { return }
        // Start capture first: the writer must be built from the actual tap format after the session is activated. Buffers arriving before the writer is attached are dropped.
        var handlers: [AudioBufferHandler] = [{ buffer, _ in box.append(buffer) }, levelMeter.makeTap()]
        if let session = startLive() { handlers.append(session.bufferHandler) }
        let format: AVAudioFormat
        captureOpening = true
        defer { captureOpening = false }
        do {
            // Opening capture includes session activation (a synchronous block): run it on a GCD background thread and await it, so the main thread does not stall and the cooperative pool is not occupied.
            let request = CaptureStartRequest(capture: capture, handlers: handlers)
            format = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CaptureStartResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: CaptureStartResult(
                            format: try request.capture.start(handlers: request.handlers)))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }.format
        } catch {
            // Invalidated while waiting: state and the live session are already handled by the invalidating party; nothing changes here.
            guard startToken == token else { return }
            discardLive()
            state = .idle
            return
        }
        // Cancelled / interrupted / slot switched while waiting: only stop the capture this flow just opened; state and the live session are left alone.
        guard startToken == token else {
            capture.stop()
            return
        }
        // Opening the slot (including deleting an orphan file) runs on the store queue and is awaited, ordered after earlier store operations, off the main thread.
        do {
            box.attach(try await store.open(slotKey: slotKey, inputFormat: format, engine: engineID,
                                            on: Self.storeQueue))
        } catch RecordingStoreError.slotOccupied {
            // The slot already holds a recording waiting for transcription: do not overwrite it, ask the user to transcribe or discard first.
            capture.stop()
            discardLive()
            if startToken == token { state = .slotOccupied }
            return
        } catch {
            capture.stop()
            discardLive()
            if startToken == token { state = .idle }
            return
        }
        // The start-recording flow was invalidated while opening the slot (cancel / interruption / slot switch): as with invalidation before opening, leave no recording and remove the slot just opened.
        guard startToken == token else {
            capture.stop()
            discardLive()
            Self.enqueueOnStoreQueue(store) { store in
                _ = box.close()
                try? store.complete(slotKey: slotKey)
            }
            return
        }
        writer = box
        state = .recording(startedAt: now())
    }

    /// Writer error: wrap up as an interruption; the part already on disk stays in the slot (interrupted) and is not treated as a 0-second recording.
    private func recordingWriteFailed(_ box: LockedRecordingWriter) {
        guard writer === box else { return }
        interruptRecording()
    }

    /// Stops capture (only AVAudioEngine, no file IO, stays on the main thread) and detaches the writer; returns nil when not recording.
    /// Closing the file and writing the sidecar are handed to the store queue by the caller. With keepLive false an in-flight live session is invalidated too (finish keeps it to wrap up).
    private func detachRecording(keepLive: Bool = false) -> (box: LockedRecordingWriter, slotKey: String)? {
        guard let box = writer, let slotKey else { return nil }
        capture.stop()
        if !keepLive { discardLive() }
        writer = nil
        return (box, slotKey)
    }

    // MARK: Live recognition

    /// One live recognition run: the session, the task reading snapshots (gives the last snapshot at the end), and the wrap-up after recording stops.
    @MainActor
    private final class LiveRun {
        let session: SystemSTTSession
        /// Latest snapshot received; used when the wrap-up times out (instead of waiting for the reading task).
        var latest = SystemSTTLiveSnapshot()
        var reader: Task<SystemSTTLiveSnapshot, Never>?
        var ending: Task<LiveEnding, Never>?

        init(session: SystemSTTSession) {
            self.session = session
        }
    }

    /// Outcome of a live session's wrap-up.
    private nonisolated struct LiveEnding: Sendable {
        let ended: LiveDictationEnded
        let failure: SystemRecognizerFailure?
    }

    /// With the system engine and live recognition available, opens one session; snapshots are published separately through liveText. Otherwise nil (the cloud engine goes through the recording file).
    private func startLive() -> SystemSTTSession? {
        discardLive()
        guard engineIsSystem, let engine = engine as? any LiveSTTEngine else { return nil }
        let session = engine.startLive(language: language())
        let run = LiveRun(session: session)
        let generation = liveText.begin()
        let liveText = self.liveText
        run.reader = Task { [weak run] in
            var last = SystemSTTLiveSnapshot()
            for await snapshot in session.snapshots {
                last = snapshot
                run?.latest = snapshot
                liveText.publish(snapshot, generation: generation)
            }
            return last
        }
        live = run
        return session
    }

    /// Discards the live session (X / interruption / slot switch / failure / nothing recognized): cancels the session, clears the live text, and the host withdraws the live text on screen.
    private func discardLive() {
        guard let run = live else { return }
        live = nil
        run.session.cancel()
        run.ending?.cancel()
        liveText.reset()
        onEvent?(.liveDiscarded)
    }

    /// After stopping the recording, starts the wrap-up: input ends and waits at most liveStopTimeoutMs; on timeout the session is cancelled.
    private func beginLiveEnding(_ run: LiveRun) {
        let session = run.session
        run.ending = Task {
            do {
                _ = try await VoiceDeadline.run(within: .milliseconds(DictationRules.liveStopTimeoutMs)) {
                    try await session.finish()
                }
                return LiveEnding(ended: .ok, failure: nil)
            } catch is VoiceDeadline.TimedOut {
                session.cancel()
                return LiveEnding(ended: .timeout, failure: nil)
            } catch {
                return LiveEnding(ended: .failed, failure: SystemRecognizerFailure(error))
            }
        }
    }

    /// Waits for the live session's wrap-up and gives its end state; with no live session it is treated as a normal end with no text. Returns nil if it was discarded while waiting.
    private func awaitLiveEnd(_ run: LiveRun?, stillCurrent: () -> Bool) async -> LiveDictationEnd? {
        guard let run, let ending = run.ending else {
            return LiveDictationEnd(finals: [], hasRecording: true, ended: .ok)
        }
        let result = await ending.value
        guard stillCurrent(), live === run else { return nil }
        let snapshot: SystemSTTLiveSnapshot
        if result.ended == .timeout {
            run.reader?.cancel()
            snapshot = run.latest
        } else {
            snapshot = await run.reader?.value ?? run.latest
            guard stillCurrent(), live === run else { return nil }
        }
        let failureKind = result.failure.flatMap { DictationRules.systemFailureClass($0).failureKind }
        return LiveDictationEnd(finals: snapshot.finals, partial: snapshot.partial, hasRecording: true,
                                ended: result.ended, failureKind: failureKind)
    }

    /// On the store queue: close the file and mark the sidecar ready (interrupted when interrupted / the slot switched), and return the recording result.
    private nonisolated static func closeFile(_ box: LockedRecordingWriter, slotKey: String, interrupted: Bool,
                                              in store: RecordingStore) -> RecordingResult {
        let result = box.close()
        if interrupted {
            try? store.markInterrupted(slotKey: slotKey, result: result)
        } else {
            try? store.markReady(slotKey: slotKey, result: result)
        }
        return result
    }

    /// Stops capture, and enqueues closing the file and writing the sidecar on the store queue (without waiting), ahead of any store operation submitted afterwards. Returns false when not recording.
    @discardableResult
    private func closeRecording(interrupted: Bool = false) -> Bool {
        guard let detached = detachRecording() else { return false }
        let box = detached.box, slotKey = detached.slotKey
        Self.enqueueOnStoreQueue(store) { store in
            _ = Self.closeFile(box, slotKey: slotKey, interrupted: interrupted, in: store)
        }
        return true
    }

    // MARK: Transcription

    /// Entering / leaving recording: on entering, take the dictation screen-awake hold; on leaving, release it and clear the level.
    private func syncRecordingSideEffects(from old: DictationState) {
        guard old.isRecording != state.isRecording else { return }
        if state.isRecording {
            screenAwake.acquire(.dictation)
        } else {
            screenAwake.release(.dictation)
            levelMeter.reset()
        }
    }

    /// "Transcribe" / "up arrow" tapped while recording: close the file, precheck, transcribe. Tapping the same buttons in interrupted / failed = retry with the recording in the slot.
    func finish(_ intent: DictationIntent) async {
        guard let slotKey else { return }
        switch state {
        case .recording:
            guard let detached = detachRecording(keepLive: true) else { return }
            let liveRun = live
            // The liveStopTimeoutMs wrap-up starts from the tap, in parallel with closing the file; cancelled again if the precheck fails.
            if let liveRun { beginLiveEnding(liveRun) }
            let box = detached.box
            let result = await Self.onStoreQueue(store) {
                Self.closeFile(box, slotKey: slotKey, interrupted: false, in: $0)
            }
            // Interrupted / discarded / slot switched while closing the file: the recording already landed in the slot according to that handling, so no precheck or transcription.
            guard self.slotKey == slotKey, state.isRecording, writer == nil else { return }
            guard DictationRules.precheck(durationSec: result.durationSec, envelope: result.envelope) == .ok else {
                discardLive()
                Self.enqueueOnStoreQueue(store) { try? $0.complete(slotKey: slotKey) }
                state = .idle
                onEvent?(.noSpeechHeard)
                return
            }
            await transcribe(result, slotKey: slotKey, intent: intent, live: live === liveRun ? liveRun : nil)
        case .interrupted, .failed, .slotOccupied:
            // The slot query runs on the store queue; if it was discarded / the slot switched / transcription already started while waiting, do not proceed on this result.
            let before = state
            let slot = await Self.onStoreQueue(store) { try? $0.slot(for: slotKey) }
            guard self.slotKey == slotKey, state == before else { return }
            guard let slot else {
                state = .idle
                return
            }
            let result = RecordingResult(url: store.audioURL(for: slotKey),
                                         durationSec: slot.durationSec, envelope: slot.envelope)
            await transcribe(result, slotKey: slotKey, intent: intent)
        default:
            return
        }
    }

    /// live: the live session opened while recording (wrap-up already started); the system engine finalizes by dictationOutcome, the cloud engine only recognizes the recording file.
    private func transcribe(_ result: RecordingResult, slotKey: String, intent: DictationIntent,
                            live liveRun: LiveRun? = nil) async {
        state = .transcribing(intent)
        /// Discarded or slot switched during transcription: the state was changed, so the result no longer lands here.
        func stillCurrent() -> Bool { state == .transcribing(intent) && self.slotKey == slotKey }
        let engine: any STTEngine
        if let chosen = self.engine {
            engine = chosen
            engineInfo = chosenInfo
        } else {
            let choice = await engines.select()
            guard stillCurrent() else { return }
            adopt(choice)
            if let reason = choice.fallback { onEvent?(.engineFallback(reason)) }
            engine = choice.engine
        }
        let language = self.language()
        if engineIsSystem {
            await transcribeSystem(result, engine: engine, language: language, slotKey: slotKey, intent: intent,
                                   live: liveRun, stillCurrent: stillCurrent)
            return
        }
        let task = Task<String, Error> { try await engine.transcribe(result, language: language) }
        transcription = task
        let outcome: Result<String, Error>
        do {
            outcome = .success(try await task.value)
        } catch {
            outcome = .failure(error)
        }
        if transcription == task { transcription = nil }
        guard stillCurrent() else { return }
        switch outcome {
        case .success(let text):
            let trimmed = DictationRules.trim(text)
            guard !trimmed.isEmpty else {
                fail(.noTranscript, slotKey: slotKey)
                return
            }
            deliver(trimmed, result: result, slotKey: slotKey, intent: intent)
        case .failure(let error as STTError):
            let kind: DictationFailureKind = error.action == .checkConnection ? .checkConnection : .retry
            fail(kind, slotKey: slotKey)
        case .failure:
            fail(.retry, slotKey: slotKey)
        }
    }

    /// Recognized text: hand it to the host and delete the slot. With no receiver it is equivalent to an interruption: the recording stays in the slot and is not deleted.
    private func deliver(_ text: String, result: RecordingResult, slotKey: String, intent: DictationIntent) {
        guard let onEvent else {
            Self.enqueueOnStoreQueue(store) { try? $0.markInterrupted(slotKey: slotKey, result: result) }
            state = .interrupted
            return
        }
        Self.enqueueOnStoreQueue(store) { try? $0.complete(slotKey: slotKey) }
        state = .idle
        onEvent(intent == .insert ? .insert(text) : .send(text))
    }

    /// System engine: wait for the live session to wrap up (<= liveStopTimeoutMs); when the recording file must be recognized, recognize it under a time limit (a timeout counts as the timeout condition);
    /// busy retries automatically per systemFailure; finally finalize per dictationOutcome or fail.
    private func transcribeSystem(_ result: RecordingResult, engine: any STTEngine, language: String?, slotKey: String,
                                  intent: DictationIntent, live liveRun: LiveRun?,
                                  stillCurrent: () -> Bool) async {
        guard let liveEnd = await awaitLiveEnd(liveRun, stillCurrent: stillCurrent) else { return }
        var file: DictationFileResult?
        /// Disposition of the last failed file recognition (after automatic retries).
        var fileDecision: SystemFailureDecision?
        var attempt = 1
        if DictationRules.needsFileRecognition(liveEnd) {
            let seconds = result.durationSec * DictationRules.fileTimeoutFactor + DictationRules.fileTimeoutBaseSec
            let limit = Duration.milliseconds(Int64((seconds * 1000).rounded(.up)))
            attempts: while true {
                let task = Task<String, Error> {
                    try await VoiceDeadline.run(within: limit) { try await engine.transcribe(result, language: language) }
                }
                transcription = task
                let outcome: Result<String, Error>
                do {
                    outcome = .success(try await task.value)
                } catch {
                    outcome = .failure(error)
                }
                if transcription == task { transcription = nil }
                guard stillCurrent() else { return }
                switch outcome {
                case .success(let text):
                    file = .text(text)
                case .failure(let error as STTError) where error.audioUnreadable:
                    file = .failed(.other)
                case .failure(let error):
                    let failure: SystemRecognizerFailure = error is VoiceDeadline.TimedOut
                        ? .condition(.timeout) : SystemRecognizerFailure(error)
                    let decision = DictationRules.systemFailure(failure, attempt: attempt)
                    if decision.autoRetry {
                        attempt += 1
                        continue attempts
                    }
                    file = decision.kind == .noTranscript ? .text("") : .failed(decision.kind.failureKind ?? .other)
                    fileDecision = decision
                }
                break attempts
            }
        }
        let shown = live != nil
        live = nil
        liveText.reset()
        let announceDiscard = { [weak self] in if shown { self?.onEvent?(.liveDiscarded) } }
        switch DictationRules.dictationOutcome(live: liveEnd, file: file) {
        case .text(let text, _):
            deliver(DictationRules.trim(text), result: result, slotKey: slotKey, intent: intent)
        case .noTranscript:
            announceDiscard()
            fail(.noTranscript, slotKey: slotKey)
        case .failed(let kind):
            announceDiscard()
            switch fileDecision?.kind {
            case .permission?:
                // Speech recognition authorization was revoked: keep the recording and stay on the existing permission card.
                Self.enqueueOnStoreQueue(store) { try? $0.markFailed(slotKey: slotKey) }
                state = .denied(.speechRecognition)
            case .cancelled?:
                // The system cancelled recognition: not a failure and not reported; the recording is kept as interrupted.
                Self.enqueueOnStoreQueue(store) { try? $0.markInterrupted(slotKey: slotKey, result: result) }
                state = .interrupted
            default:
                fail(.system(kind), slotKey: slotKey)
            }
        }
    }

    /// A recording already in the slot (interrupted during transcription) is marked interrupted with the duration and envelope from its sidecar.
    /// Done on the store queue (enqueued synchronously, ahead of later binding queries).
    private func markSlotInterrupted(_ slotKey: String) {
        Self.enqueueOnStoreQueue(store) { store in
            guard let slot = try? store.slot(for: slotKey) else { return }
            let result = RecordingResult(url: store.audioURL(for: slotKey),
                                         durationSec: slot.durationSec, envelope: slot.envelope)
            try? store.markInterrupted(slotKey: slotKey, result: result)
        }
    }

    private func fail(_ kind: DictationFailureKind, slotKey: String) {
        Self.enqueueOnStoreQueue(store) { try? $0.markFailed(slotKey: slotKey) }
        failedRecognitionLanguage = Self.recognitionLanguageID(language(), uiLocale: uiLocale())
        state = .failed(kind)
    }

    // MARK: Discard

    /// X button: a recording that is in progress, interrupted, failed or being transcribed can all be discarded. One longer than discardUndoAboveSec returns undoable and opens the undo window:
    /// discardUndoWindow auto commitDiscard when due, and undoDiscard within the window restores it. Returns nil when there is no recording to discard.
    /// The state goes back to idle synchronously first; reading the sidecar and moving / deleting files run on the store queue, and the result is returned when done.
    @discardableResult
    func discard() async -> RecordingDiscardOutcome? {
        guard let slotKey else { return nil }
        discardLive()
        switch state {
        case .recording:
            _ = closeRecording()
        case .transcribing:
            transcription?.cancel()
            transcription = nil
        case .interrupted, .failed, .slotOccupied:
            break
        case .idle, .denied:
            return nil
        }
        state = .idle
        // Only one undo window at a time: a new discard first makes the previous one take effect (with the same key store.discard replaces the old file in the undo area).
        // Committing the previous one and discarding this one form a single store-queue block: no other query (such as the occupancy query when tapping the mic) can slip in between and see a recording pending deletion;
        // when the mic is tapped while a discard is in flight, the query is ordered after this block and starts recording after the discard completes, according to the state at that time.
        let previous = pendingDiscard
        previous?.task.cancel()
        pendingDiscard = nil
        let outcome = await Self.onStoreQueue(store) { store -> RecordingDiscardOutcome? in
            if let previousKey = previous?.slotKey { try? store.commitDiscard(slotKey: previousKey) }
            return try? store.discard(slotKey: slotKey)
        }
        guard let outcome else { return nil }
        if outcome == .undoable { openUndoWindow(slotKey: slotKey) }
        return outcome
    }

    /// Undo a discard (only valid within the undo window and while still on the same slot): the recording returns to the slot as it was, waiting for the user to transcribe or discard again.
    /// The undo window is closed first on the main thread (the timer no longer commits when due), and moving files runs on the store queue; if it cannot be moved back (the slot already has a new recording) the discard takes effect immediately.
    /// If the slot switched or the state changed while waiting, the recording still returns to the original slot and the state is untouched (bind finds it when switching back).
    func undoDiscard() async {
        guard let pending = pendingDiscard, pending.slotKey == slotKey else { return }
        pending.task.cancel()
        pendingDiscard = nil
        let restored = await Self.onStoreQueue(store) { (try? $0.undoDiscard(slotKey: pending.slotKey)) != nil }
        guard restored else {
            await Self.onStoreQueue(store) { try? $0.commitDiscard(slotKey: pending.slotKey) }
            return
        }
        guard self.slotKey == pending.slotKey, state == .idle else { return }
        state = .interrupted
    }

    /// Ends the undo window early (for example when the notice is dismissed): the discard takes effect immediately. The undo window is closed synchronously, and file deletion runs on the store queue.
    func commitDiscard() async {
        guard let pending = pendingDiscard else { return }
        pending.task.cancel()
        pendingDiscard = nil
        await Self.onStoreQueue(store) { try? $0.commitDiscard(slotKey: pending.slotKey) }
    }

    /// When the timer fires, commit by the slot key from when the window opened, unaffected by later slot switches.
    private func openUndoWindow(slotKey: String) {
        let sleep = self.sleep
        let store = self.store
        let token = UUID()
        let task = Task { [weak self] in
            do { try await sleep(Self.discardUndoWindow) } catch { return }
            guard !Task.isCancelled else { return }
            // First close the window on the main thread (later undos no longer take effect), then delete the files on the store queue.
            if self?.pendingDiscard?.token == token { self?.pendingDiscard = nil }
            await Self.onStoreQueue(store) { try? $0.commitDiscard(slotKey: slotKey) }
        }
        pendingDiscard = (slotKey, token, task)
    }

    // MARK: System events

    /// Host leaving: while recording, wrap up as an interruption; while transcribing, cancel the transcription and leave the recording in the slot marked interrupted;
    /// an in-flight start-recording flow (authorization / language-pack check) is invalidated and does not start recording even if it completes later. Other states are untouched.
    func interrupt() {
        switch state {
        case .recording:
            interruptRecording()
        case .transcribing:
            leaveCurrentSlot()
            state = .interrupted
        default:
            startToken = nil
        }
    }

    /// Interruption began / went to background: stop capture synchronously and enter interrupted; closing the file and marking the sidecar interrupted run on the store queue.
    /// holdBackgroundTask: the background path wraps this in a background task and ends it after the wrap-up on the store queue is done.
    private func interruptRecording(holdBackgroundTask: Bool = false) {
        guard case .recording = state else { return }
        let holder: BackgroundTaskHolder? = holdBackgroundTask ? BackgroundTaskHolder() : nil
        if let holder {
            holder.id = UIApplication.shared.beginBackgroundTask(withName: "oriveo.dictationClose") {
                holder.endOnMain()
            }
        }
        // The wrap-up of the user's stop is still on the store queue (the writer is already detached): mark the sidecar interrupted after it; finish sees the state changed and no longer transcribes.
        discardLive()
        if !closeRecording(interrupted: true), let slotKey { markSlotInterrupted(slotKey) }
        if let holder { Self.enqueueOnStoreQueue(store) { _ in holder.endOnMain() } }
        state = .interrupted
    }

    private func observeSystemNotifications(_ center: NotificationCenter) {
        notificationTokens.tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            runOnMain { [weak self] in self?.interruptRecording() }
        })
        notificationTokens.tokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            runOnMain { [weak self] in self?.interruptRecording(holdBackgroundTask: true) }
        })
        // Media services reset: the audio engine is no longer valid, wrap up as an interruption.
        notificationTokens.tokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            runOnMain { [weak self] in self?.interruptRecording() }
        })
    }
}

// MARK: - Locked writer

/// The tap callback appends on the audio thread and the main thread closes: serialized with a lock. Appends before attach and after close are dropped.
/// On an append error the first error is recorded, nothing more is written, and onError is notified once (outside the lock).
nonisolated final class LockedRecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: RecordingWriter?
    private var url: URL?
    private var closed = false
    private(set) var firstError: Error?
    private let onError: @Sendable (LockedRecordingWriter) -> Void

    init(onError: @escaping @Sendable (LockedRecordingWriter) -> Void) {
        self.onError = onError
    }

    /// Attaches the writer; if already closed, closes it right away.
    func attach(_ writer: RecordingWriter) {
        let accepted = lock.withLock { () -> Bool in
            guard !closed else { return false }
            self.writer = writer
            self.url = writer.url
            return true
        }
        if !accepted { _ = try? writer.close() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let failed = lock.withLock { () -> Bool in
            guard firstError == nil, let writer else { return false }
            do {
                try writer.append(buffer)
                return false
            } catch {
                firstError = error
                return true
            }
        }
        if failed { onError(self) }
    }

    /// Closes the file; if closing fails, reads the duration and envelope back from the frames already on disk so the recording is not lost.
    func close() -> RecordingResult {
        lock.withLock {
            defer {
                writer = nil
                closed = true
            }
            if let result = try? writer?.close() { return result }
            // The writer was never attached (the controller holds it only after attach, so this normally cannot happen): there is no recording file to read back.
            guard let url else {
                return RecordingResult(url: URL(fileURLWithPath: "/dev/null"), durationSec: 0, envelope: [])
            }
            let recovered = RecordingStore.readBack(url)
            return RecordingResult(url: url, durationSec: recovered.durationSec, envelope: recovered.envelope)
        }
    }
}
