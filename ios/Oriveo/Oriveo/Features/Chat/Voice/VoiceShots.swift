#if DEBUG
import CryptoKit
import Foundation
import Observation

/// Debug direct-open pages for the voice page family, used to capture sample shots; Release builds contain nothing from this file.
///
/// Usage: `xcrun simctl launch <udid> ai.oriveo.community -AUTO_OPEN_PAGE <page name> -SHOTS_PROBE`; page names are listed in `Shot`.
/// Launched with one of these page names, the whole process uses an in-memory `AppState` (`OriveoApp.init` goes through `seedDemoData` according to `isRequested`).
///
/// Page names and per-page states are read only from the shared manifest `shared/test-fixtures/shots/voice.v1.json`; when it cannot be read or a field is missing, opening is refused and no hard-coded values are used as a fallback.
/// No microphone, no sound, no network, no real store writes:
/// - The conversation comes from the manifest `conversation`, hangs on the demo seed's current model (`activeModel`), and is written to in-memory state only.
/// - Read aloud playing: the playing state is staged through `ReadAloudController.showSpeakingForShots`, without calling `toggle` and without `-AUTO_READ_ALOUD` (which would make sound).
/// - Primary button / home page: the draft is empty, and ≋ is decided by the production `VoiceConversationEntry.primaryAction`.
/// - Home page with text: `homeDraftText` is prefilled into the home input through `HomeDraftInjection`, and ↑ comes from the same decision.
/// - Voice bar: the state is set through `VoiceConversationDemo.shotsStatus`, and the display state is mapped by `VoiceConversationDemo.displayState(for:)`.
/// - Dictation: once the conversation is attached, wait for the input to bind this conversation's slot, then stage the manifest state through `DictationController.showStateForShots`
///   (only the state and engine row are set; capture is not started and nothing is written to RecordingStore); the recording level bars are the static manifest dictationLevels,
///   and the timer is pinned to the manifest elapsedSec through `ComposerDictationBar.shotsFrozenElapsedSec`.
/// - Settings: the catalog is decoded by the production decoder from the manifest `catalog` (a repository path), connections come from the manifest `connections` (those already in the demo seed are reused,
///   the rest become in-memory placeholder-key connections), the dictation engine comes from the manifest `dictationEngine`, and the conversation engine is taken from `realtime` only on realtimeNotice=acknowledged pages, written to a separate UserDefaults
///   suite; it is handed to the settings page through `VoiceSettingsModel.shotsInjection`, with no network and no reads or writes of real connections or the keychain.
///   Engine sheet pages open the sheet for the manifest `direction` after the page appears; the conversation engine row page scrolls to the "Voice conversation" group.
/// - Conversation engine first-use notice: opens the conversation engine direction sheet, then raises the production notice for the manifest
///   `disclosure` provider (using the manifest `realtime` model) through `VoiceEngineSheetFlow.showDisclosureForShots`; the conversation engine is not preselected and no consent is recorded.
enum VoiceShots {
    enum Shot: String, CaseIterable {
        case voiceReadAloudIdle, voiceReadAloudSpeaking
        case voiceDictationRecording, voiceDictationTranscribing, voiceDictationFailed, voiceDictationInterrupted
        case voiceSettings, voiceEngineSheet, voiceComposerButton, voiceHome, voiceHomeDraft
        case voiceBarListening, voiceBarThinking, voiceBarSpeaking, voiceBarMuted, voiceBarAwaitingApproval, voiceBarError
        case voiceRealtimeRow, voiceRealtimeNotice
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
        let conversation: Conversation
        do {
            conversation = try install(staged, into: appState)
        } catch {
            report("\(shot.rawValue): \(error)")
            return
        }

        // The chat page sits on the home stack: switch back to home first, wait for the home stack to attach, then open the conversation through the production entry (a push at launch would be overwritten by the root view's first-frame stack).
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
    }

    /// The recording bar timer is pinned to the manifest elapsedSec and does not follow time; non-recording pages clear the override. Must be set before the recording bar appears.
    @MainActor
    static func applyDictationDisplayOverrides(_ staged: Staged) {
        ComposerDictationBar.shotsFrozenElapsedSec = staged.dictation == .recording ? staged.elapsedSec : nil
    }


    /// Attaches the manifest conversation to the demo seed's current model and writes it to in-memory state; refuses when the current model can only generate images (≋ would not appear).
    @MainActor
    static func install(_ staged: Staged, into appState: AppState) throws -> Conversation {
        guard let active = appState.activeModel else { throw ManifestError.invalid("the demo seed has no current model") }
        guard VoiceConversationEntry.modelProducesText(active.model) else {
            throw ManifestError.invalid("demo model \(active.model.id) can only generate images")
        }
        let conversation = staged.conversation(provider: active.provider, model: active.model)
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

    /// Manifest realtimeNotice: shown = the one-time notice after selecting a realtime model is visible; acknowledged = the row shows the selected model, no notice.
    enum RealtimeNotice: String {
        case acknowledged, shown
    }

    /// Manifest scrollTo.
    enum ScrollTarget: String {
        case realtimeEngine
    }

    /// Manifest direction (engine sheet pages) → production direction.
    static func sheetDirection(_ raw: String) -> VoiceDirection? {
        switch raw {
        case "dictation": .stt
        case "readAloud": .tts
        case "realtime": .realtime
        default: nil
        }
    }

    /// State of the four settings pages: catalog, connections, the engines of both directions and the in-page landing point.
    struct SettingsStage {
        let catalog: VoiceCatalog
        let connections: [ProviderKind]
        let dictationEngine: DictationEngine
        let realtime: DictationEngine
        /// The direction an engine sheet page opens; nil for the other pages.
        let sheetDirection: VoiceDirection?
        let scrollTo: ScrollTarget?
        let realtimeNotice: RealtimeNotice?
        /// The provider whose notice the disclosure page raises (manifest disclosure); nil for the other pages.
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
            // Only realtimeNotice == acknowledged pages write the conversation engine selection; the other pages keep the default (follow the current model).
            let selected: [(VoiceDirection, DictationEngine)] = realtimeNotice == .acknowledged
                ? [(.stt, dictationEngine), (.realtime, realtime)]
                : [(.stt, dictationEngine)]
            for (direction, engine) in selected {
                guard let provider = providers.first(where: { $0.kind.rawValue == engine.provider }) else { continue }
                settings.setSelection(.cloud(VoiceCloudEngine(
                    providerKind: provider.kind,
                    connectionID: provider.id.uuidString,
                    model: engine.model,
                    voice: nil
                )), for: direction)
            }
            return VoiceSettingsModel.ShotsInjection(
                settings: settings,
                catalogState: .available(catalog),
                providers: providers,
                openEngineSheet: sheetDirection,
                scrollToRealtimeEngine: scrollTo == .realtimeEngine,
                disclosure: disclosureEngine(providers: providers)
            )
        }

        /// The engine of the disclosure page: the connection of the manifest disclosure provider + the manifest realtime model (same provider) or the dictationEngine model.
        func disclosureEngine(providers: [Provider]) -> VoiceCloudEngine? {
            guard let disclosure, let provider = providers.first(where: { $0.kind == disclosure }) else { return nil }
            let engine = sheetDirection == .realtime ? realtime : dictationEngine
            return VoiceCloudEngine(providerKind: disclosure, connectionID: provider.id.uuidString, model: engine.model)
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
        /// The state of the four settings pages; nil for the other pages.
        var settings: SettingsStage? = nil

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
            let scrollTo: String?
            let realtimeNotice: String?
            let disclosure: String?
        }

        let schema: String
        let conversation: [Message]
        let catalog: String?
        let connections: [String]?
        let dictationEngine: DictationEngine?
        let realtime: DictationEngine?
        let dictationLevels: [Float]?
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
            settings: settings
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
        guard let catalogPath = manifest.catalog else { throw ManifestError.invalid("the manifest is missing catalog") }
        let envelope = try JSONSerialization.jsonObject(with: repositoryFile(catalogPath)) as? [String: Any]
        guard let data = envelope?["data"] else { throw ManifestError.invalid("\(catalogPath) is not a response envelope with data") }
        let catalog = VoiceCatalogDecoder.decode(data)
        guard catalog != .empty else { throw ManifestError.invalid("\(catalogPath) cannot be decoded into a catalog") }
        guard let rawConnections = manifest.connections, !rawConnections.isEmpty else {
            throw ManifestError.invalid("the manifest is missing connections")
        }
        let connections = try rawConnections.map { raw in
            guard let kind = ProviderKind(rawValue: raw) else { throw ManifestError.invalid("connections not recognized: \(raw)") }
            return kind
        }
        guard let dictationEngine = manifest.dictationEngine else { throw ManifestError.invalid("the manifest is missing dictationEngine") }
        guard let realtime = manifest.realtime else { throw ManifestError.invalid("the manifest is missing realtime") }
        for engine in [dictationEngine, realtime] where !rawConnections.contains(engine.provider) {
            throw ManifestError.invalid("engine provider \(engine.provider) is not in connections")
        }
        var sheetDirection: VoiceDirection?
        if surface == .engineSheet {
            guard let raw = page.direction, let direction = Self.sheetDirection(raw) else {
                throw ManifestError.invalid("the direction of \(shot.rawValue) is missing or not recognized")
            }
            sheetDirection = direction
        }
        var scrollTo: ScrollTarget?
        if let raw = page.scrollTo {
            guard let target = ScrollTarget(rawValue: raw) else { throw ManifestError.invalid("the scrollTo of \(shot.rawValue) is not recognized: \(raw)") }
            scrollTo = target
        }
        var realtimeNotice: RealtimeNotice?
        if let raw = page.realtimeNotice {
            guard let value = RealtimeNotice(rawValue: raw) else {
                throw ManifestError.invalid("the realtimeNotice of \(shot.rawValue) is not recognized: \(raw)")
            }
            realtimeNotice = value
        }
        var disclosure: ProviderKind?
        if let raw = page.disclosure {
            guard let kind = ProviderKind(rawValue: raw), connections.contains(kind) else {
                throw ManifestError.invalid("the disclosure of \(shot.rawValue) is not recognized or not in connections: \(raw)")
            }
            guard sheetDirection != nil else { throw ManifestError.invalid("\(shot.rawValue) has a disclosure but is not an engine sheet page") }
            disclosure = kind
        }
        return SettingsStage(
            catalog: catalog,
            connections: connections,
            dictationEngine: dictationEngine,
            realtime: realtime,
            sheetDirection: sheetDirection,
            scrollTo: scrollTo,
            realtimeNotice: realtimeNotice,
            disclosure: disclosure
        )
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
    }
}
#endif
