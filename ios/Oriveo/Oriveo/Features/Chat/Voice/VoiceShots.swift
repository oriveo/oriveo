#if DEBUG
import CryptoKit
import Foundation
import Observation

/// Debug direct-open pages for the voice page family, used to capture sample shots; Release builds contain nothing from this file.
///
/// Usage: `xcrun simctl launch <udid> ai.oriveo.community -AUTO_OPEN_PAGE <page name> -SHOTS_PROBE`; page names are listed in `Shot`.
/// Launched with one of these page names, the whole process uses an in-memory `AppState` (`OriveoApp.init` goes through `seedDemoData` according to `isRequested`).
///
/// Page names and each page's state are read only from the shared manifest `shared/test-fixtures/shots/voice.v1.json`; when it cannot be read or a field is missing, opening is refused instead of falling back to hard-coded values.
/// Does not open the mic, make sound, touch the network, or write to the real library:
/// - The conversation takes the manifest `conversation`, pinned to the sample chat model `chatModelID` (added to the demo seed's Anthropic connection and set as the current model); written to in-memory state only.
/// - Speaking: shown via `ReadAloudController.showSpeakingForShots`; does not call `toggle` or go through `-AUTO_READ_ALOUD` (which would make sound).
/// - Main button / home: the draft is empty, and ≋ is decided by the production `VoiceConversationEntry.primaryAction`.
/// - Home with text: `HomeDraftInjection` prefills `homeDraftText` into the home input; ↑ is given by the same decision.
/// - Voice bar: state is set via `VoiceConversationDemo.shotsStatus`; the display state is mapped by `VoiceConversationDemo.displayState(for:)`;
///   the caption and fixed level of the caption page come from the manifest caption / level (`shotsCaption` / `shotsLevel`); the speaking page may give a level, other voice-bar pages have level 0;
///   the stage animation clock comes from the manifest stageClockMs (`shotsStageClock`, in seconds), and the ball and fog stop at that moment;
///   the recognition language of the checkLanguage page comes from the manifest recognitionLanguage, is written into the sample-shot UserDefaults suite, and the capsule name is derived by the production display function.
/// - Dictation: after the conversation is attached, wait for the input to bind the shared dictation controller to this conversation's slot, then stage the manifest state via `DictationController.showStateForShots`
///   (only sets state and engine rows; does not start capture or write RecordingStore); while recording, the level bar is the static manifest dictationLevels value,
///   and the timer is fixed to the manifest elapsedSec via `ComposerDictationBar.shotsFrozenElapsedSec`.
///   The live-segment page then sends the manifest liveFinal + liveVolatile as one system-recognition snapshot into the controller's liveText,
///   and writes it into the input through the host's production write path (`ComposerSelectionProbe.writeLive`): one finalized segment + one unfinalized segment.
/// - Settings: the catalog is decoded from the manifest `catalog` (a repo path) by the production decoder; connections come from the manifest `connections` (seed-present ones are reused,
///   missing ones become in-memory placeholder-key connections); the dictation engine comes from the manifest `dictationEngine` and is written into a separate UserDefaults
///   suite; handed to the settings page via `VoiceSettingsModel.shotsInjection`, with no network and no reading or writing of real connections or keychain.
///   After entering the engine-sheet page, open the sheet in the manifest `direction`.
/// - Engine first-time disclosure: when the engine-sheet page carries the manifest `disclosure`, `VoiceEngineSheetFlow.showDisclosureForShots` shows the production disclosure for that
///   provider (model taken from the manifest `dictationEngine`); not preselected, and no consent is written.
/// - Realtime model disclosure: when the composer page carries the manifest `disclosure`, after the conversation page is attached the request goes through `takeRealtimeDisclosure` to
///   `ChatView.presentRealtimeDisclosure`, which shows the production cloud disclosure for the isDefault realtime[] model in that provider's catalog; no consent is written.
enum VoiceShots {
    enum Shot: String, CaseIterable {
        case voiceReadAloudIdle, voiceReadAloudSpeaking
        case voiceDictationRecording, voiceDictationTranscribing, voiceDictationFailed, voiceDictationInterrupted
        case voiceDictationLivePartial
        case voiceSettings, voiceEngineSheet, voiceComposerButton, voiceHome, voiceHomeDraft
        case voiceBarListening, voiceBarUserSpeaking, voiceBarThinking, voiceBarSpeaking, voiceBarMuted, voiceBarSayAgain
        case voiceBarAwaitingApproval, voiceBarError, voiceBarCheckLanguage
        case voiceRealtimeDisclosure
    }

    /// The realtime model disclosure to show once the conversation page is attached (the conversation the sample names).
    private static var pendingRealtimeDisclosure: RealtimeModelDisclosureRequest?

    /// Called when ChatView appears: if this is the conversation the sample names, take the realtime disclosure to show (given only once).
    static func takeRealtimeDisclosure(conversationID: UUID?) -> RealtimeModelDisclosureRequest? {
        guard let pending = pendingRealtimeDisclosure, pending.conversationID == conversationID else { return nil }
        pendingRealtimeDisclosure = nil
        return pending
    }

    /// The launch arguments name a page of this family.
    static var isRequested: Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-AUTO_OPEN_PAGE"), index + 1 < arguments.count else { return false }
        return Shot(rawValue: arguments[index + 1]) != nil
    }

    // MARK: - Entry

    @MainActor
    static func open(_ shot: Shot, appState: AppState) async {
        // With a persisted store, writing a conversation would go into the real database, so better not to stage anything.
        guard !appState.prefersAuthoritativeConversationStore else {
            report("\(shot.rawValue): AppState is not in-memory, demo data was not injected")
            return
        }
        let staged: Staged
        do {
            staged = try stage(shot, manifestData: manifestData())
        } catch {
            report("\(shot.rawValue): \(error)")
            return
        }
        // The demo seed hard-codes a dark theme; sample shots follow the system, and light / dark is decided by simctl appearance
        appState.preferences.theme = .system

        switch staged.surface {
        case .settings, .engineSheet:
            await openSettings(staged, appState: appState, shot: shot)
            return
        case .home:
            HomeDraftInjection.shared.text = shot == .voiceHomeDraft ? homeDraftText : nil
            appState.selectedTab = .home
            appState.navigation.reset(to: [])
            return
        case .readAloud, .composer, .voiceBar, .dictation:
            break
        }

        VoiceConversationDemo.shotsStatus = staged.status
        VoiceConversationDemo.shotsPage = .chat
        applyBarOverrides(staged)
        let conversation: Conversation
        do {
            conversation = try install(staged, into: appState)
        } catch {
            report("\(shot.rawValue): \(error)")
            return
        }

        pendingRealtimeDisclosure = nil
        if let disclosure = staged.disclosure {
            guard let model = staged.realtimeModel,
                  let provider = appState.providers.first(where: { $0.kind == disclosure })
            else {
                report("\(shot.rawValue): the demo seed has no \(disclosure.rawValue) connection, so the realtime disclosure was not shown")
                return
            }
            pendingRealtimeDisclosure = RealtimeModelDisclosureRequest(
                selection: RealtimeModelSelection(providerID: provider.id, providerKind: disclosure, model: model),
                conversationID: conversation.id
            )
        }

        // The chat page is mounted on the home stack: switch back to home first, then open the conversation through the production entry once the home stack is attached (pushing at launch would be overwritten by the root view's first-frame stack).
        appState.selectedTab = .home
        appState.navigation.reset(to: [])
        guard await waitUntil({ appState.navigation.path.isEmpty && appState.selectedTab == .home }) else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        appState.openChat(conversationID: conversation.id)

        if staged.surface == .dictation {
            await showDictation(staged, conversation: conversation, appState: appState, shot: shot)
            return
        }
        guard staged.readAloud == .speaking else { return }
        guard let assistant = conversation.messages.last(where: { $0.role == .assistant }) else { return }
        // Wait for the read-aloud button of the latest answer to be configured (it configures last when entering the conversation), then stage the playing state.
        guard await waitUntil({ ReadAloudButton.debugLastEligible?.messageID == assistant.id }) else {
            report("\(shot.rawValue): the read-aloud button did not attach, the playing state was not staged")
            return
        }
        ReadAloudController.shared.showSpeakingForShots(messageID: assistant.id, text: assistant.text)
    }

    /// Settings › Voice: hand the injection to the settings model first, then switch to the settings tab and push the voice settings page once the stack is attached.
    @MainActor
    private static func openSettings(_ staged: Staged, appState: AppState, shot: Shot) async {
        guard let settingsStage = staged.settings else {
            report("\(shot.rawValue): the manifest has no settings state")
            return
        }
        VoiceSettingsModel.shotsInjection = settingsStage.injection(seedProviders: appState.providers)
        appState.selectedTab = .settings
        appState.navigation.reset(to: [])
        guard await waitUntil({ appState.navigation.path.isEmpty && appState.selectedTab == .settings }) else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        appState.navigation.reset(to: [.voiceSettings])
    }

    /// Waits for the chat page input to bind the shared dictation controller to this conversation's slot (binding resets the state), then stages the manifest state.
    @MainActor
    private static func showDictation(_ staged: Staged, conversation: Conversation, appState: AppState, shot: Shot) async {
        guard let controller = DictationHub.shared.controller else {
            report("\(shot.rawValue): the dictation controller could not be created, the dictation state was not staged")
            return
        }
        guard let state = staged.dictationState(now: Date()) else { return }
        let slotKey = ChatComposerBar.dictationSlotKey(conversationID: conversation.id)
        guard await waitUntil({ controller.slotKey == slotKey }) else {
            report("\(shot.rawValue): the input did not bind this conversation's slot, the dictation state was not staged")
            return
        }
        applyDictationDisplayOverrides(staged)
        controller.showStateForShots(
            state,
            engineInfo: staged.dictationEngineInfo(providers: appState.providers),
            levels: staged.dictationLevels ?? []
        )
        // Live segment: start a new generation and publish the manifest snapshot; the host subscribes and writes it into the input via ComposerSelectionProbe.writeLive.
        guard let snapshot = staged.liveSnapshot else { return }
        let generation = controller.liveText.begin()
        controller.liveText.publish(snapshot, generation: generation)
    }

    /// Subtitle / fixed level / stage clock / recognition language of the voice-bar pages: cleared on non-voice-bar pages; voice-bar pages without a level give 0.
    /// The recognition language is written into a separate suite (cleared first), without touching real preferences.
    @MainActor
    static func applyBarOverrides(_ staged: Staged) {
        let bar = staged.surface == .voiceBar
        VoiceConversationDemo.shotsCaption = staged.caption
        VoiceConversationDemo.shotsLevel = bar ? (staged.level ?? 0) : nil
        VoiceConversationDemo.shotsStageClock = bar ? staged.stageClock : nil
        guard let language = staged.recognitionLanguage else {
            VoiceConversationDemo.shotsSettings = nil
            return
        }
        guard let defaults = UserDefaults(suiteName: SettingsStage.defaultsSuite) else {
            preconditionFailure("the sample-shot preferences suite \(SettingsStage.defaultsSuite) could not be created")
        }
        defaults.removePersistentDomain(forName: SettingsStage.defaultsSuite)
        let settings = VoiceEngineSettings(defaults: defaults)
        settings.recognitionLanguage = language
        VoiceConversationDemo.shotsSettings = settings
    }

    /// The recording bar timer is pinned to the manifest elapsedSec and does not follow time; non-recording pages clear the override. Must be set before the recording bar appears.
    @MainActor
    static func applyDictationDisplayOverrides(_ staged: Staged) {
        ComposerDictationBar.shotsFrozenElapsedSec = staged.dictation == .recording ? staged.elapsedSec : nil
    }


    /// The sample chat model (same value on both platforms; Android VoiceShotsData.CHAT_MODEL_ID / CHAT_MODEL_NAME): the page header, message metadata and home model capsule all show it.
    static let chatModelID = "claude-haiku-5-5"
    static let chatModelName = "Claude Haiku 5.5"

    /// The manifest conversation is pinned to the sample chat model when written into in-memory state: the model is added to the demo seed's Anthropic connection (not duplicated if present),
    /// and set as the current model so the page header does not drift with the demo seed's default model; rejected when the model can only generate images (≋ will not appear).
    @MainActor
    static func install(_ staged: Staged, into appState: AppState) throws -> Conversation {
        guard let index = appState.providers.firstIndex(where: { $0.kind == .anthropic }) else {
            throw ManifestError.invalid("demo seed has no Anthropic connection")
        }
        var provider = appState.providers[index]
        let model = provider.models.first(where: { $0.id == chatModelID })
            ?? AIModel(
                id: chatModelID, name: chatModelName, capabilities: [.text], reasoningModeAvailable: false,
                isAvailable: true, isDefault: false, priceTier: "", summary: nil, groupKey: nil, groupName: nil
            )
        if !provider.models.contains(where: { $0.id == chatModelID }) {
            provider.models.insert(model, at: 0)
            if !provider.catalogModels.contains(where: { $0.id == chatModelID }) {
                provider.catalogModels.insert(model, at: 0)
            }
            appState.providers[index] = provider
        }
        guard VoiceConversationEntry.modelProducesText(model) else {
            throw ManifestError.invalid("sample model \(model.id) can only generate images")
        }
        appState.lastUsedModelRef = LastUsedModelRef(providerID: provider.id, modelID: model.id)
        let conversation = staged.conversation(provider: provider, model: model)
        appState.upsertConversationProjection(conversation, deletingMessageIDs: Set(conversation.messages.map(\.id)))
        return conversation
    }

    /// The draft prefilled on the home page "with text" page (the same sentence on both platforms).
    static let homeDraftText = "Plan a weekend in Kyoto"

    /// Draft injection for the home page "with text" page: HomeView observes `text` and writes it into the input when non-nil (works whether the home page is already attached or attaches later).
    @MainActor
    @Observable
    final class HomeDraftInjection {
        static let shared = HomeDraftInjection()
        var text: String?
    }

    // MARK: - Manifest → in-memory objects

    enum Surface: String {
        case readAloud, dictation, settings, engineSheet, composer, home, voiceBar
    }

    enum ReadAloud: String {
        case idle, speaking
    }

    enum Dictation: String {
        case recording, transcribing, failed, interrupted
    }

    /// Manifest direction (engine sheet pages) → production direction.
    static func sheetDirection(_ raw: String) -> VoiceDirection? {
        switch raw {
        case "dictation": .stt
        case "readAloud": .tts
        default: nil
        }
    }

    /// State of the two settings pages: catalog, connections, dictation engine and sheet direction.
    struct SettingsStage {
        let catalog: VoiceCatalog
        let connections: [ProviderKind]
        let dictationEngine: DictationEngine
        /// The direction the engine-sheet page opens its sheet with; nil for other pages.
        let sheetDirection: VoiceDirection?
        /// The provider whose disclosure the disclosure page shows (manifest disclosure); nil for other pages.
        var disclosure: ProviderKind? = nil

        /// Sample-shot settings storage: a separate suite, cleared every time an injection is built.
        static let defaultsSuite = "ai.oriveo.community.shots.voice"

        /// Manifest connections: a seed provider of the same kind is reused (the same connection as on the dictation page), and missing ones become in-memory placeholder-key connections.
        func providers(seedProviders: [Provider]) -> [Provider] {
            connections.map { kind in
                seedProviders.first { $0.kind == kind }
                    ?? SampleData.makeProvider(
                        kind: kind,
                        apiKey: "shots-placeholder-key",
                        existingID: VoiceShots.uuid("connection-\(kind.rawValue)")
                    )
            }
        }

        func injection(seedProviders: [Provider]) -> VoiceSettingsModel.ShotsInjection {
            let providers = providers(seedProviders: seedProviders)
            // Stop if the suite cannot be created: falling back to .standard would write the demo selection into real preferences.
            guard let defaults = UserDefaults(suiteName: Self.defaultsSuite) else {
                preconditionFailure("the sample-shot preferences suite \(Self.defaultsSuite) could not be created")
            }
            defaults.removePersistentDomain(forName: Self.defaultsSuite)
            let settings = VoiceEngineSettings(defaults: defaults)
            if let provider = providers.first(where: { $0.kind.rawValue == dictationEngine.provider }) {
                settings.setSelection(.cloud(VoiceCloudEngine(
                    providerKind: provider.kind,
                    connectionID: provider.id.uuidString,
                    model: dictationEngine.model,
                    voice: nil
                )), for: .stt)
            }
            return VoiceSettingsModel.ShotsInjection(
                settings: settings,
                catalogState: .available(catalog),
                providers: providers,
                openEngineSheet: sheetDirection,
                disclosure: disclosureEngine(providers: providers)
            )
        }

        /// The engine of the disclosure page: the connection of the manifest disclosure provider + the manifest dictationEngine model.
        func disclosureEngine(providers: [Provider]) -> VoiceCloudEngine? {
            guard let disclosure, let provider = providers.first(where: { $0.kind == disclosure }) else { return nil }
            return VoiceCloudEngine(providerKind: disclosure, connectionID: provider.id.uuidString, model: dictationEngine.model)
        }
    }

    enum DictationFailure: String {
        case retry, checkConnection, noTranscript

        var kind: DictationFailureKind {
            switch self {
            case .retry: .retry
            case .checkConnection: .checkConnection
            case .noTranscript: .noTranscript
            }
        }
    }

    /// Manifest dictationEngine: the raw ProviderKind value + model.
    struct DictationEngine: Decodable, Equatable {
        let provider: String
        let model: String
    }

    struct Staged {
        struct Message {
            let id: UUID
            let role: ChatRole
            let text: String
        }

        let surface: Surface
        /// The read-aloud state of read-aloud pages; nil for the other pages.
        let readAloud: ReadAloud?
        /// The status key of voice bar pages; nil for the other pages.
        let status: VoiceConversationLogic.StatusKey?
        /// Manifest conversation, oldest → newest.
        let messages: [Message]
        /// The dictation state of dictation pages; nil for the other pages.
        var dictation: Dictation? = nil
        /// The timer seconds of the recording page.
        var elapsedSec: Int? = nil
        /// The failure kind of failure pages.
        var failure: DictationFailure? = nil
        /// Manifest dictationEngine; always present on dictation pages.
        var dictationEngine: DictationEngine? = nil
        /// Manifest dictationLevels (0…1, oldest → newest); always present on the recording page, with the same values on both platforms.
        var dictationLevels: [Float]? = nil
        /// Settings state of the two settings pages; nil for other pages.
        var settings: SettingsStage? = nil
        /// Caption of the caption page (manifest caption); nil for other pages.
        var caption: String? = nil
        /// Fixed level of the caption page (required) and the speaking page (optional) (manifest level, 0…1); nil for other pages.
        var level: Double? = nil
        /// Stage animation clock of voice-bar pages (manifest stageClockMs / 1000, in seconds); nil for other pages.
        var stageClock: TimeInterval? = nil
        /// Recognition language of the checkLanguage page (manifest recognitionLanguage, BCP-47); nil for other pages.
        var recognitionLanguage: String? = nil
        /// Finalized segment of the live-segment page (manifest liveFinal); nil for other pages.
        var liveFinal: String? = nil
        /// Unfinalized segment of the live-segment page (manifest liveVolatile); nil for other pages.
        var liveVolatile: String? = nil
        /// Provider whose disclosure the realtime disclosure page shows (manifest disclosure, composer page); nil for other pages. The engine-sheet page's is in settings.disclosure.
        var disclosure: ProviderKind? = nil
        /// Model of the realtime disclosure page: the isDefault one in that provider's realtime[] in the manifest catalog; nil for other pages.
        var realtimeModel: String? = nil

        /// System-recognition snapshot the live-segment page sends to the controller: one finalized segment + one unfinalized segment; nil for other pages.
        var liveSnapshot: SystemSTTLiveSnapshot? {
            guard let liveFinal, let liveVolatile else { return nil }
            return SystemSTTLiveSnapshot(finals: [liveFinal], partial: liveVolatile)
        }

        /// The controller state of dictation pages; for recording, the start time = now − elapsedSec.
        func dictationState(now: Date) -> DictationState? {
            switch dictation {
            case .recording?:
                guard let elapsedSec else { return nil }
                return .recording(startedAt: now.addingTimeInterval(-TimeInterval(elapsedSec)))
            case .transcribing?:
                return .transcribing(.insert)
            case .failed?:
                guard let failure else { return nil }
                return .failed(failure.kind)
            case .interrupted?:
                return .interrupted
            case nil:
                return nil
            }
        }

        /// The engine row: the first connection of the manifest dictationEngine's provider; nil if there is none (same as the system engine, no connection name shown).
        func dictationEngineInfo(providers: [Provider]) -> DictationEngineInfo? {
            guard let dictationEngine,
                  let provider = providers.first(where: { $0.kind.rawValue == dictationEngine.provider })
            else { return nil }
            return DictationEngineInfo(displayName: provider.displayName, providerID: provider.id)
        }

        /// The voice bar display state: derived from the status key through the production mapping.
        var barDisplayState: VoiceConversationLogic.DisplayState? {
            VoiceConversationDemo.displayState(for: status)
        }

        func conversation(provider: Provider, model: AIModel) -> Conversation {
            let chatMessages = messages.map { message in
                ChatMessage(
                    id: message.id,
                    role: message.role,
                    text: message.text,
                    providerID: provider.id,
                    providerKind: provider.kind,
                    providerName: provider.kind.displayName,
                    modelID: message.role == .assistant ? model.id : nil,
                    modelName: model.name,
                    estimatedCost: 0,
                    state: .delivered,
                    createdAt: Date()
                )
            }
            var conversation = Conversation(
                id: uuid("conversation"),
                title: messages.first?.text ?? "",
                providerID: provider.id,
                providerKind: provider.kind,
                modelID: model.id,
                previewText: messages.last?.text ?? "",
                estimatedCost: 0,
                isDraft: false,
                messages: chatMessages,
                draftText: ""
            )
            conversation.hasCustomTitle = true
            return conversation
        }
    }

    enum ManifestError: Error, CustomStringConvertible {
        case repositoryNotFound
        case invalid(String)

        var description: String {
            switch self {
            case .repositoryNotFound: "Walking up from the source file location did not find a repository root containing the shared directory"
            case let .invalid(reason): reason
            }
        }
    }

    struct Manifest: Decodable {
        struct Message: Decodable {
            let role: String
            let text: String
        }

        struct Page: Decodable {
            let name: String
            let surface: String
            let readAloud: String?
            let status: String?
            let dictation: String?
            let elapsedSec: Int?
            let failure: String?
            let direction: String?
            let disclosure: String?
            let caption: String?
            let level: Double?
            let recognitionLanguage: String?
            let liveFinal: String?
            let liveVolatile: String?
        }

        let schema: String
        let conversation: [Message]
        let catalog: String?
        let connections: [String]?
        let dictationEngine: DictationEngine?
        let dictationLevels: [Float]?
        let stageClockMs: Double?
        let pages: [Page]

        static func load(from data: Data) throws -> Manifest {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schema == "oriveo.shots.voice/v1" else {
                throw ManifestError.invalid("schema is not oriveo.shots.voice/v1: \(manifest.schema)")
            }
            return manifest
        }
    }

    /// Reads the manifest and builds everything this page needs; any failing step throws and the caller refuses to open.
    static func stage(
        _ shot: Shot,
        manifestData data: Data,
        repositoryFile: (String) throws -> Data = { try Data(contentsOf: repositoryRoot().appendingPathComponent($0)) }
    ) throws -> Staged {
        let manifest = try Manifest.load(from: data)
        guard let page = manifest.pages.first(where: { $0.name == shot.rawValue }) else {
            throw ManifestError.invalid("the manifest has no page \(shot.rawValue)")
        }
        guard let surface = Surface(rawValue: page.surface) else {
            throw ManifestError.invalid("the surface of \(shot.rawValue) is not recognized: \(page.surface)")
        }
        var readAloud: ReadAloud?
        if surface == .readAloud {
            guard let raw = page.readAloud, let value = ReadAloud(rawValue: raw) else {
                throw ManifestError.invalid("the readAloud of \(shot.rawValue) is missing or not recognized")
            }
            readAloud = value
        }
        var status: VoiceConversationLogic.StatusKey?
        if surface == .voiceBar {
            guard let raw = page.status, let value = VoiceConversationLogic.StatusKey(rawValue: raw) else {
                throw ManifestError.invalid("the status of \(shot.rawValue) is missing or not recognized")
            }
            status = value
        }
        var caption: String?
        var level: Double?
        if status == .caption {
            guard let text = page.caption, !text.isEmpty else {
                throw ManifestError.invalid("\(shot.rawValue) caption is missing or empty")
            }
            guard let value = page.level, (0...1).contains(value) else {
                throw ManifestError.invalid("\(shot.rawValue) level is missing or outside 0…1")
            }
            caption = text
            level = value
        } else if status == .speaking, let value = page.level {
            guard (0...1).contains(value) else {
                throw ManifestError.invalid("\(shot.rawValue) level is outside 0…1")
            }
            level = value
        } else if page.caption != nil || page.level != nil {
            throw ManifestError.invalid("\(shot.rawValue) is not a caption / speaking page but has caption / level")
        }
        var stageClock: TimeInterval?
        if surface == .voiceBar {
            // Non-negative integer milliseconds; decimals and negatives are rejected.
            guard let ms = manifest.stageClockMs, ms.isFinite, ms >= 0, ms.rounded() == ms else {
                throw ManifestError.invalid("stageClockMs is missing, negative, or not an integer number of milliseconds")
            }
            stageClock = ms / 1000
        }
        var recognitionLanguage: String?
        if status == .checkLanguage {
            guard let code = page.recognitionLanguage, !code.isEmpty else {
                throw ManifestError.invalid("\(shot.rawValue) recognitionLanguage is missing or empty")
            }
            recognitionLanguage = code
        } else if page.recognitionLanguage != nil {
            throw ManifestError.invalid("\(shot.rawValue) is not a checkLanguage page but has recognitionLanguage")
        }
        var dictation: Dictation?
        var elapsedSec: Int?
        var failure: DictationFailure?
        if surface == .dictation {
            guard let raw = page.dictation, let value = Dictation(rawValue: raw) else {
                throw ManifestError.invalid("the dictation of \(shot.rawValue) is missing or not recognized")
            }
            dictation = value
            if value == .recording {
                guard let seconds = page.elapsedSec, seconds >= 0 else {
                    throw ManifestError.invalid("the elapsedSec of \(shot.rawValue) is missing or negative")
                }
                elapsedSec = seconds
                guard let levels = manifest.dictationLevels, !levels.isEmpty, levels.allSatisfy({ (0...1).contains($0) }) else {
                    throw ManifestError.invalid("manifest dictationLevels is missing or outside 0…1")
                }
            }
            if value == .failed {
                guard let raw = page.failure, let kind = DictationFailure(rawValue: raw) else {
                    throw ManifestError.invalid("the failure of \(shot.rawValue) is missing or not recognized")
                }
                failure = kind
            }
            guard manifest.dictationEngine != nil else {
                throw ManifestError.invalid("the manifest is missing dictationEngine")
            }
        }
        var liveFinal: String?
        var liveVolatile: String?
        if page.liveFinal != nil || page.liveVolatile != nil {
            guard dictation == .recording else {
                throw ManifestError.invalid("\(shot.rawValue) is not a recording page but has liveFinal / liveVolatile")
            }
            guard let final = page.liveFinal, !final.isEmpty,
                  let volatile = page.liveVolatile, !volatile.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw ManifestError.invalid("\(shot.rawValue) liveFinal / liveVolatile: one is missing or empty")
            }
            liveFinal = final
            liveVolatile = volatile
        }
        // disclosure is only allowed on the composer page (realtime disclosure) and the engine-sheet page (engine first-time disclosure).
        if page.disclosure != nil, surface != .composer, surface != .engineSheet {
            throw ManifestError.invalid("\(shot.rawValue) has disclosure but is not a composer / engine-sheet page")
        }
        var disclosure: ProviderKind?
        var realtimeModel: String?
        if surface == .composer, let raw = page.disclosure {
            guard let kind = ProviderKind(rawValue: raw), manifest.connections?.contains(raw) == true else {
                throw ManifestError.invalid("\(shot.rawValue) disclosure is unknown or not in connections: \(raw)")
            }
            let catalog = try decodeCatalog(manifest: manifest, repositoryFile: repositoryFile)
            guard let entry = catalog.realtimeEntries(kind).first(where: \.isDefault) else {
                throw ManifestError.invalid("\(shot.rawValue): \(raw) has no isDefault realtime model in the catalog")
            }
            disclosure = kind
            realtimeModel = entry.model
        }
        var settings: SettingsStage?
        if surface == .settings || surface == .engineSheet {
            settings = try settingsStage(shot: shot, page: page, surface: surface, manifest: manifest, repositoryFile: repositoryFile)
        }
        let messages = try manifest.conversation.enumerated().map { index, fixture in
            let role: ChatRole
            switch fixture.role {
            case "user": role = .user
            case "assistant": role = .assistant
            default: throw ManifestError.invalid("the role of conversation[\(index)] is not recognized: \(fixture.role)")
            }
            return Staged.Message(id: uuid("message-\(index)"), role: role, text: fixture.text)
        }
        guard messages.last?.role == .assistant else {
            throw ManifestError.invalid("the last conversation message is not an answer, so there is nowhere to attach the read-aloud button")
        }
        return Staged(
            surface: surface, readAloud: readAloud, status: status, messages: messages,
            dictation: dictation, elapsedSec: elapsedSec, failure: failure,
            dictationEngine: surface == .dictation ? manifest.dictationEngine : nil,
            dictationLevels: dictation == .recording ? manifest.dictationLevels : nil,
            settings: settings,
            caption: caption, level: level, stageClock: stageClock, recognitionLanguage: recognitionLanguage,
            liveFinal: liveFinal, liveVolatile: liveVolatile,
            disclosure: disclosure, realtimeModel: realtimeModel
        )
    }

    /// Settings pages: the catalog is decoded by the production decoder from the manifest catalog (a repository path, the data of a response envelope); any missing item throws.
    private static func settingsStage(
        shot: Shot,
        page: Manifest.Page,
        surface: Surface,
        manifest: Manifest,
        repositoryFile: (String) throws -> Data
    ) throws -> SettingsStage {
        let catalog = try decodeCatalog(manifest: manifest, repositoryFile: repositoryFile)
        guard let rawConnections = manifest.connections, !rawConnections.isEmpty else {
            throw ManifestError.invalid("the manifest is missing connections")
        }
        let connections = try rawConnections.map { raw in
            guard let kind = ProviderKind(rawValue: raw) else { throw ManifestError.invalid("connections not recognized: \(raw)") }
            return kind
        }
        guard let dictationEngine = manifest.dictationEngine else { throw ManifestError.invalid("the manifest is missing dictationEngine") }
        guard rawConnections.contains(dictationEngine.provider) else {
            throw ManifestError.invalid("engine provider \(dictationEngine.provider) is not in connections")
        }
        var sheetDirection: VoiceDirection?
        if surface == .engineSheet {
            guard let raw = page.direction, let direction = Self.sheetDirection(raw) else {
                throw ManifestError.invalid("the direction of \(shot.rawValue) is missing or not recognized")
            }
            sheetDirection = direction
        }
        var disclosure: ProviderKind?
        if let raw = page.disclosure {
            guard let kind = ProviderKind(rawValue: raw), connections.contains(kind) else {
                throw ManifestError.invalid("the disclosure of \(shot.rawValue) is not recognized or not in connections: \(raw)")
            }
            guard surface == .engineSheet else {
                throw ManifestError.invalid("\(shot.rawValue) has disclosure but is not a composer / engine-sheet page")
            }
            disclosure = kind
        }
        return SettingsStage(
            catalog: catalog,
            connections: connections,
            dictationEngine: dictationEngine,
            sheetDirection: sheetDirection,
            disclosure: disclosure
        )
    }

    /// The manifest catalog (a repo path; the data of the response envelope) is decoded by the production decoder; throws if missing or undecodable.
    private static func decodeCatalog(manifest: Manifest, repositoryFile: (String) throws -> Data) throws -> VoiceCatalog {
        guard let catalogPath = manifest.catalog else { throw ManifestError.invalid("manifest is missing catalog") }
        let envelope = try JSONSerialization.jsonObject(with: repositoryFile(catalogPath)) as? [String: Any]
        guard let data = envelope?["data"] else { throw ManifestError.invalid("\(catalogPath) is not a response envelope with data") }
        let catalog = VoiceCatalogDecoder.decode(data)
        guard catalog != .empty else { throw ManifestError.invalid("\(catalogPath) could not be decoded into a catalog") }
        return catalog
    }

    /// Manifest id → stable UUID (the same on every launch, so sample shots can be compared).
    static func uuid(_ name: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data("oriveo.shots.voice/\(name)".utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 40 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    // MARK: - Manifest location

    /// The manifest is not in the bundle: the simulator process can read host files, so walk up from this source file location to the repository root that contains `shared/`.
    static func manifestURL(sourceFile: String = #filePath) throws -> URL {
        try repositoryRoot(sourceFile: sourceFile).appendingPathComponent("shared/test-fixtures/shots/voice.v1.json")
    }

    /// Walks up from this source file location to the repository root that contains `shared/`.
    static func repositoryRoot(sourceFile: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            let shared = directory.appendingPathComponent("shared")
            if FileManager.default.fileExists(atPath: shared.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw ManifestError.repositoryNotFound
    }

    static func manifestData() throws -> Data {
        try Data(contentsOf: manifestURL())
    }

    private static func report(_ message: String) {
        print("[VoiceShots] \(message)")
        ShotsLayoutProbe.fail(message)
    }
}
#endif
