import Combine
import Foundation
import Observation
import UIKit

/// Voice conversation copy (Voice table; keys are the English source text).
enum VoiceConversationCopy {
    /// Status line for the voice bar: caption state shows live captions; falls back to listening when the caption is empty.
    static func status(_ key: VoiceConversationLogic.StatusKey, caption: String?) -> String {
        if key == .caption, let caption, !caption.isEmpty { return caption }
        return status(key)
    }

    static func status(_ key: VoiceConversationLogic.StatusKey) -> String {
        switch key {
        // The captions themselves come from caption; the caption status copy currently matches listening.
        case .listening, .caption: return L10n.tr("Listening", table: .voice)
        case .thinking: return L10n.tr("Thinking", table: .voice)
        case .speaking: return L10n.tr("Speaking", table: .voice)
        case .speakingTapToInterrupt: return L10n.tr("Speaking · tap to interrupt", table: .voice)
        case .muted: return L10n.tr("Muted", table: .voice)
        case .awaitingApproval: return L10n.tr("Waiting for you", table: .voice)
        case .sayAgain: return L10n.tr("Didn’t catch that — say it again", table: .voice)
        // Also shows the recognition language capsule.
        case .checkLanguage: return L10n.tr("Didn’t catch that", table: .voice)
        case .error: return L10n.tr("Something went wrong", table: .voice)
        }
    }

    /// Screen reader hint for the status orb: only given in the three tappable states.
    static func orbHint(_ state: VoiceConversationLogic.DisplayState?) -> String? {
        switch state {
        case .listening, .userSpeaking, .sayAgain, .checkLanguage: return L10n.tr("Tap when you're done", table: .voice)
        case .thinking: return L10n.tr("Tap to stop", table: .voice)
        case .speaking: return L10n.tr("Tap to stop speaking", table: .voice)
        case .muted: return L10n.tr("Unmute microphone", table: .voice)
        case .awaitingApproval, .error, nil: return nil
        }
    }

    /// Idle-state hint of the resident voice stage (key voice_realtime_tap_to_start).
    static var tapToStartHint: String { L10n.tr("Tap to start talking", table: .voice) }
    /// VoiceOver label of the keyboard button on the voice stage (key voice_realtime_switch_to_keyboard).
    static var switchToTypingA11y: String { L10n.tr("Switch to Typing", table: .voice) }
    /// VoiceOver label of the button that returns from typing to the voice stage (key voice_realtime_back_to_stage).
    static var backToStageA11y: String { L10n.tr("Back to Voice", table: .voice) }
    static var startA11y: String { L10n.tr("Start voice conversation", table: .voice) }
    static var endA11y: String { L10n.tr("End voice conversation", table: .voice) }
    static var muteA11y: String { L10n.tr("Mute microphone", table: .voice) }
    static var unmuteA11y: String { L10n.tr("Unmute microphone", table: .voice) }
    static var startFailedToast: String { L10n.tr("Couldn't start the voice conversation. Try again.", table: .voice) }
    /// Engine-switch status line (p3-copy voice_realtime_switched_to); the cross-platform %1$s placeholder is replaced directly with the model display name
    /// (String(format:)'s %s reads a C string and cannot take a Swift String).
    static func switchedTo(_ modelName: String) -> String {
        L10n.tr("Switched to %1$s", table: .voice).replacingOccurrences(of: "%1$s", with: modelName)
    }

    /// Status text on the stage for a failed realtime session (fetched by copyKey, keys are English source text); the placeholder takes the provider display name or the catalog model.
    static func failure(_ failure: RealtimeVoiceFailure) -> String {
        let value = failure.copyArgValue ?? ""
        switch failure.classification.copyKey {
        case RealtimeModelPolicy.copyKey(for: .auth):
            return L10n.format(L10n.tr("The %1$@ key is invalid or doesn't have realtime voice access.", table: .voice), value)
        case RealtimeModelPolicy.copyKey(for: .quota):
            return L10n.format(L10n.tr("%1$@ quota is used up, or there were too many requests.", table: .voice), value)
        case RealtimeModelPolicy.copyKey(for: .modelGone):
            return L10n.format(L10n.tr("%1$@ is no longer available.", table: .voice), value)
        case RealtimeModelPolicy.copyKey(for: .maxDuration):
            return L10n.tr("This realtime call reached its length limit. Tap to continue.", table: .voice)
        case RealtimeModelPolicy.copyKey(for: .network):
            return L10n.format(L10n.tr("Can't reach %1$@. Check your network.", table: .voice), value)
        case RealtimeVoiceFailure.catalogUnavailable.classification.copyKey:
            // Catalog load failure of the home voice stage (same copy key as the retry row on the chat page).
            return ChatRealtimeCatalogRetryRow().message
        default:
            return L10n.format(L10n.tr("Can't reach %1$@.", table: .voice), value)
        }
    }

    /// Label of the failure exit buttons; continueWithHistory is the orb tap itself and has no button (nil).
    static func failureAction(_ action: RealtimeModelPolicy.FailureAction) -> String? {
        switch action {
        case .openConnection: return L10n.tr("Open Connection", table: .voice)
        case .retry: return L10n.tr("Try Again", table: .voice)
        case .switchModel: return L10n.tr("Switch Model", table: .voice)
        case .continueWithHistory: return nil
        }
    }

    /// Prompts to be spoken aloud; placeholder sentences reuse the read-aloud placeholder copy.
    static func prompt(_ prompt: VoicePrompt) -> String {
        switch prompt {
        case .didNotCatch: return L10n.tr("Sorry, I didn't catch that.", table: .voice)
        case .approvalNeeded: return L10n.tr("Please confirm on the screen.", table: .voice)
        case .sayAgain: return L10n.tr("I didn’t catch that. Could you say it again?", table: .voice)
        case .checkLanguage:
            return L10n.tr(
                "I still didn’t catch that. If you’re speaking another language, tap Recognition Language to change it.",
                table: .voice
            )
        case .echoHint: return L10n.tr("There’s an echo from the speaker. Headphones will work better.", table: .voice)
        case .placeholder(let kind): return L10n.tr(ReadAloudController.placeholderKey(kind), table: .voice)
        }
    }
}

/// The only voice conversation in the app: it survives across pages (the home → chat handoff is not a return); pages only read it to decide which voice bar to show.
/// Page navigation for the voice stage's failure exits (only these three exits): to the connection page → open the selected connection; change model → open the model picker,
/// when model_gone, first reset the selected state back to the text model; retry is the idle stage's orb tap (onIdleTap, reopens per the selected state), not handled here.
struct RealtimeFailureNavigation {
    var openConnection: (_ providerID: UUID?) -> Void
    var openModelPicker: () -> Void
    var clearRealtimeSelection: () -> Void

    func perform(
        _ action: RealtimeModelPolicy.FailureAction,
        failure: RealtimeVoiceFailure?,
        selection: RealtimeModelSelection?
    ) {
        switch action {
        case .openConnection:
            openConnection(selection?.providerID)
        case .switchModel:
            if failure?.classification.category == .modelGone { clearRealtimeSelection() }
            openModelPicker()
        case .retry, .continueWithHistory:
            break
        }
    }
}

@MainActor
@Observable
final class VoiceConversationSession {
    static let shared = VoiceConversationSession()

    /// Which page a voice conversation was started from.
    enum Origin: Sendable {
        case chat
        case home
    }

    /// Key of the host page: a conversation id when there is one; the home page and the chat page's compose state share draft.
    enum HostKey: Hashable {
        case draft
        case conversation(UUID)

        init(_ conversationID: UUID?) {
            self = conversationID.map(HostKey.conversation) ?? .draft
        }
    }

    /// The delivery of one ending: the page picks up the draft write-back by token.
    struct EndDelivery: Equatable {
        let token: UUID
        let conversationID: UUID?
        let draft: String?
    }

    /// The realtime session failure and the page it belongs to.
    struct HostedRealtimeFailure: Equatable {
        let host: HostKey
        let failure: RealtimeVoiceFailure
        /// The realtime selection in effect when the failed session opened; once the page changes its selection (another realtime or text model) the failure is no longer shown.
        let selection: RealtimeModelSelection?
    }

    struct Dependencies {
        /// Prepares the listening engine (microphone / recognition authorization / on-device model, the same path as dictation); nil = do not enter.
        var prepareListening: () async -> DictationEngineChoice?
        var makeController: (_ listening: DictationEngineChoice, _ port: VoiceConversationChatPort) -> VoiceConversationController
        var toast: (String) -> Void
        var isVoiceOverRunning: () -> Bool
        var announce: (String) -> Void
        /// How long to wait after all pages have left before deciding the user went back (switching carriers and the home → chat handoff leave first and appear again).
        var leaveGraceNanoseconds: UInt64
        /// Clock for the engine-switch notice deadline; injected so tests control time.
        var now: () -> Date
        /// Decides from the conversation engine selection whether this run is a realtime session or the cascade (the conversation id is nil when entered from the home page); defaults to the cascade.
        var makeRealtime: (_ conversationID: UUID?, _ host: VoiceConversationChatHost) async -> RealtimeVoiceStart = { _, _ in
            .cascade(toast: nil)
        }
        var makeRealtimeController: (_ parts: RealtimeVoiceSessionParts,
                                     _ reopener: RealtimeVoiceConversationController.Reopener?,
                                     _ onError: @escaping (String) -> Void,
                                     _ onEnded: @escaping (RealtimeConversationLogic.EndReason, String?) -> Void)
            -> RealtimeVoiceConversationController = { parts, reopener, onError, onEnded in
                RealtimeVoiceConversationController(
                    connection: parts.connection, audio: parts.audio, plan: parts.plan, sink: parts.sink,
                    reopener: reopener, replanner: parts.replanFingerprint, catalogCheck: parts.catalogHasModel,
                    failureContext: parts.failureContext,
                    onError: onError, onEnded: onEnded
                )
            }
        /// Records last-used when a realtime call starts; the conversation id is nil when entered from the home page.
        var recordRealtimeStart: (_ conversationID: UUID?, _ host: VoiceConversationChatHost) -> Void = { _, _ in }
        /// Realtime selection snapshot of the conversation at opening (nil on home), kept with the failure so the failure is dismissed when the selection changes.
        var realtimeSelection: (_ conversationID: UUID?, _ host: VoiceConversationChatHost) -> RealtimeModelSelection? = { _, _ in nil }
        /// Before entering a realtime session only microphone authorization is required (no dictation engine preparation, no speech recognition authorization); false = do not enter.
        var grantMicrophone: () async -> Bool = {
            guard let dictation = DictationHub.shared.controller else { return false }
            return await dictation.prepareConversationMicrophone()
        }
        /// Audio session ownership shared with dictation (realtime sessions claim / return it here; the cascade claims / returns it through SessionLeasedConversationAudio).
        /// Each set of dependencies gets its own instance by default; production uses .shared.
        var audioSession = VoiceAudioSessionOwner()
        /// Haptics for the reducer; the system haptic switch is honored by the UIKit generator itself, and test-injected closures never touch hardware.
        var haptic: (VoiceConversationLogic.Haptic) -> Void = { _ in OriveoHaptic.tap() }
        /// Stop read-aloud and preview before entering a realtime session (the cascade stops them in VoiceConversationController.prepareAudioSession).
        var stopReadAloud: () -> Void = {
            ReadAloudController.shared.stop(.interrupted)
            ReadAloudController.shared.stopPreview()
        }

        static var production: Dependencies { production(audioSession: .shared) }

        /// The owner for the cascade / realtime engines and the audioSession they return are the same instance (single source).
        static func production(
            audioSession: VoiceAudioSessionOwner, settings: VoiceEngineSettings = VoiceEngineSettings()
        ) -> Dependencies {
            Dependencies(
                prepareListening: {
                    guard let dictation = DictationHub.shared.controller else { return nil }
                    return await dictation.prepareConversationListening()
                },
                makeController: { listening, port in
                    VoiceConversationController(
                        audio: SessionLeasedConversationAudio(
                            VPIOConversationAudioEngine(owner: audioSession), owner: audioSession
                        ),
                        dictation: DictationEngineSource { listening },
                        readAloud: .resolving(
                            catalog: { ReadAloudCatalogSnapshot.shared.current() },
                            providers: { ReadAloudController.providers() },
                            system: SystemSpeechEngine()
                        ),
                        chat: port,
                        prompt: VoiceConversationCopy.prompt,
                        // Same source as dictation; the conversation does not send the language-pack hint.
                        sttLanguage: { settings.recognitionLanguage }
                    )
                },
                toast: { ToastManager.shared.show($0, style: .error) },
                isVoiceOverRunning: { UIAccessibility.isVoiceOverRunning },
                announce: { UIAccessibility.post(notification: .announcement, argument: $0) },
                leaveGraceNanoseconds: 400_000_000,
                now: Date.init,
                makeRealtime: { conversationID, host in
                    guard let appState = host as? AppState else { return .cascade(toast: nil) }
                    return await RealtimeVoiceSessionBuilder.production(appState: appState, audioSession: audioSession)
                        .prepare(conversationID: conversationID)
                },
                recordRealtimeStart: { conversationID, host in
                    (host as? AppState)?.recordLastUsedForRealtimeVoice(conversationID: conversationID)
                },
                realtimeSelection: { conversationID, host in
                    (host as? AppState)?.realtimeModelSelection(for: conversationID)
                },
                audioSession: audioSession
            )
        }
    }

    /// Live caption of the cascade conversation (the voice bar's status line reads it); the realtime engine does not provide one, so it is always nil.
    private(set) var caption: String?
    /// Number of light shakes of the cascade conversation's orb during this run (animation is driven by the UI).
    private(set) var nudgeCount = 0
    /// Draft bubble of the realtime controller (the temporary bubble at the end of the list reads it); nil when there is no realtime session.
    private(set) var realtimeDrafts: RealtimeDrafts?

    /// Cascade controller: used internally and by read-aloud (playMessage); the voice bar goes through the surface.
    private(set) var controller: VoiceConversationController?
    /// Realtime session controller (when the conversation engine is set to a cloud one); at most one of it and controller is non-nil.
    private(set) var realtime: RealtimeVoiceConversationController?
    /// The seam the active session offers the voice bar.
    var surface: (any VoiceConversationSurface)? { realtime ?? controller }
    private(set) var port: AppStateVoiceChatPort?
    private(set) var origin: Origin = .chat
    /// The conversation the dialogue lives in; nil when entered from the home page, before the first send.
    private(set) var conversationID: UUID?
    private(set) var isStarting = false

    /// A conversation started from the home page has been handed to the chat page: set on the same tick the first sentence creates the conversation (before the chat page opens) and never rolled back within this run.
    private(set) var homeHandedOff = false

    /// The controller the home voice bar observes: a conversation started on the home page that has not been handed off yet. Ownership depends only on the handoff event, not on whether conversationID has been written back.
    var homeVoiceSurface: (any VoiceConversationSurface)? {
        guard origin == .home, !homeHandedOff else { return nil }
        if let engineSwitch, engineSwitch.host == .draft { return engineSwitch }
        return surface
    }

    /// How long the "switched to <model>" status line stays after an engine switch (realtime-model.v1 composer.engineSwitchMidSession).
    static let engineSwitchNoticeSeconds: TimeInterval = 1.6
    /// Transition stage during a voice conversation when the responder changes: from the old run closing until the new run ends, the stage stays on that page.
    private(set) var engineSwitch: EngineSwitchStageSurface?
    @ObservationIgnored private var engineSwitchNoticeTask: Task<Void, Never>?

    /// Whether this page is in an engine-switch transition (the stage does not collapse).
    func isEngineSwitching(in conversationID: UUID?) -> Bool {
        engineSwitch?.host == HostKey(conversationID)
    }

    private func clearEngineSwitch() {
        engineSwitch = nil
        engineSwitchNoticeTask?.cancel()
        engineSwitchNoticeTask = nil
    }

    /// One run ended: the transition is removed only if it is the run the transition is attached to (the old run's ending does not remove it).
    private func endEngineSwitchIfLive(serial: Int) {
        guard let engineSwitch, engineSwitch.liveSerial == serial else { return }
        clearEngineSwitch()
    }

    /// After an engine switch, if the new opening succeeds on the same page it attaches to the transition stage; if it failed to open (pending notice / failure) or opened on another page, the transition is removed,
    /// and the stage returns to the idle stage / notice card / collapsed.
    private func settleEngineSwitch(opened: Bool, host: HostKey) {
        guard let engineSwitch, engineSwitch.liveSerial == nil else { return }
        guard opened, engineSwitch.host == host, let surface else {
            clearEngineSwitch()
            return
        }
        engineSwitch.attach(surface, serial: sessionSerial)
    }
    /// The most recent ending; the page takes the draft by token.
    private(set) var lastEnd: EndDelivery?

    /// Delivery token whose draft a page has already taken; carried to the new token along with the draft when the delivery is replaced, so one ending is delivered only once.
    @ObservationIgnored private var consumedEndToken: UUID?

    /// A page receives the end draft: only the current delivery counts (a replaced old token is void), it must point at this page (same host key), and this ending must not have been taken yet.
    func consumeEndDraft(_ end: EndDelivery, host conversationID: UUID?) -> String? {
        guard let current = lastEnd, current.token == end.token, consumedEndToken != end.token,
              let draft = end.draft, HostKey(end.conversationID) == HostKey(conversationID) else { return nil }
        consumedEndToken = end.token
        return draft
    }

    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var hostCounts: [HostKey: Int] = [:]
    @ObservationIgnored private var leaveCheck: Task<Void, Never>?
    /// +1 for every run opened; an in-flight draft is delivered only while it is still its own run and no new run has started.
    @ObservationIgnored private var sessionSerial = 0
    /// Cascade opening generation: +1 per opening, and +1 when ended while opening; if the generation changed when the session is ready, no conversation starts.
    @ObservationIgnored private var openingGeneration = 0
    /// The host while opening (start in progress, no controller yet); its disappearance is judged by this.
    @ObservationIgnored private var openingHost: HostKey?
    @ObservationIgnored private var statusObservation: Task<Void, Never>?
    /// Synchronous forwarding of the cascade controller's caption and shake counts (published values arrive immediately, not via async).
    @ObservationIgnored private var feedbackSubscriptions: [AnyCancellable] = []
    @ObservationIgnored private var announcementObserver: NSObjectProtocol?
    @ObservationIgnored private var lastAnnouncedStatus: VoiceConversationLogic.StatusKey?
    /// The screen reader is announcing a status line.
    @ObservationIgnored private var screenReaderSpeaking = false
    /// The language recognition picker is open on the stage.
    @ObservationIgnored private(set) var languagePickerOpen = false
    @ObservationIgnored private var realtimeAudio: RealtimeVoiceAudio?
    /// The audio session lease held by the realtime session; released at teardown (after the controller has stopped audio).
    @ObservationIgnored private var realtimeLease: VoiceAudioSessionOwner.Lease?
    @ObservationIgnored private var realtimeTranscript: AppStateRealtimeTranscriptSink?
    /// The most recent realtime session failure and the page it belongs to; cleared when a new run starts.
    private var lastRealtimeFailure: HostedRealtimeFailure?
    /// The realtime selection in effect when the in-progress run opened (kept with the failure on an error ending).
    @ObservationIgnored private var realtimeSelectionAtStart: RealtimeModelSelection?
    init(dependencies: Dependencies? = nil) {
        self.deps = dependencies ?? .production
    }

    var isActive: Bool { controller != nil || realtime != nil }

    /// A realtime session is in progress (the read-aloud button on messages does not respond).
    var isRealtime: Bool { realtime != nil }

    /// Whether this page (a conversation id or the compose state) is currently showing the voice bar.
    func isPresented(in conversationID: UUID?) -> Bool {
        guard isActive else { return false }
        return HostKey(self.conversationID) == HostKey(conversationID)
    }

    // MARK: Entering

    /// This page's voice stage seam, in two steps: if the page has a realtime selection but no run in progress, it shows the idle stage first (not connected, mic not open);
    /// the orb tap goes through onIdleTap (the page's entry path, which calls start and opens a realtime session per the selection). While this page shows a conversation, the surface is given to it;
    /// after the conversation ends, if the selection is still there, it returns to the idle stage.
    /// If the previous run failed on this page, the idle stage carries the failure copy and exits: retry = onIdleTap; switch connection / change model go through onFailureAction.
    /// realtimeSelection is this page's current realtime selection: if it differs from the one that failed (the model changed), the failure is not shown.
    func stageSurface(
        in conversationID: UUID?,
        realtimeSelected: Bool,
        realtimeSelection: RealtimeModelSelection? = nil,
        onIdleTap: @escaping () -> Void,
        onFailureAction: @escaping (RealtimeModelPolicy.FailureAction) -> Void = { _ in },
        onSwitchToTyping: @escaping () -> Void = {}
    ) -> (any VoiceConversationSurface)? {
        if let engineSwitch, engineSwitch.host == HostKey(conversationID) { return engineSwitch }
        if isPresented(in: conversationID), let surface { return surface }
        guard realtimeSelected else { return nil }
        return RealtimeIdleStageSurface(
            failure: realtimeFailure(in: conversationID, selection: realtimeSelection),
            onTap: onIdleTap,
            onFailureAction: onFailureAction,
            onSwitchToTyping: onSwitchToTyping
        )
    }

    /// The previous realtime run's failure on this page (nil for the home page or a draft); nil when there is no failure, a new run has started,
    /// or the page changed its selection (chose another realtime or text model, so selection differs from the failed run).
    func realtimeFailure(in conversationID: UUID?, selection: RealtimeModelSelection? = nil) -> RealtimeVoiceFailure? {
        guard let lastRealtimeFailure, lastRealtimeFailure.host == HostKey(conversationID),
              lastRealtimeFailure.selection == selection else { return nil }
        return lastRealtimeFailure.failure
    }

    /// The page clears its own gates first; here the microphone and recognition preparation proceed, then listening starts.
    /// send is provided by the page: it carries the page's send parameters and delivery: .voice.
    @discardableResult
    func start(
        origin: Origin,
        conversationID: UUID?,
        host: VoiceConversationChatHost,
        onNeedsRealtimeDisclosure: @escaping (RealtimeModelSelection) -> Void = { _ in },
        send: @escaping AppStateVoiceChatPort.Send
    ) async -> Bool {
        await open(
            origin: origin, conversationID: conversationID, host: host,
            onNeedsRealtimeDisclosure: onNeedsRealtimeDisclosure, typed: nil, send: send
        )
    }

    /// Realtime typed send: if this page already has a realtime session, hand the sentence to it; otherwise open a realtime session per this page's selection,
    /// the controller cold-starts in play-only mode (no capture) and emits the sentence once ready. If this page's selection is not realtime (judged cascade / failed / pending notice), no conversation opens.
    /// Returns false = not handed off (empty text, another page is conversing, or no realtime session could open); the page can return the text to the input box.
    /// origin: a run opened by typing on the home page passes .home (the home voice stage observes it and hands it off once the first persisted message creates the conversation); the chat page defaults to .chat.
    @discardableResult
    func sendRealtimeTyped(
        _ text: String,
        conversationID: UUID?,
        host: VoiceConversationChatHost,
        origin: Origin = .chat,
        onNeedsRealtimeDisclosure: @escaping (RealtimeModelSelection) -> Void = { _ in }
    ) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let realtime {
            guard HostKey(self.conversationID) == HostKey(conversationID) else { return false }
            realtime.sendTypedText(text)
            return true
        }
        return await open(
            origin: origin, conversationID: conversationID, host: host,
            onNeedsRealtimeDisclosure: onNeedsRealtimeDisclosure, typed: text, send: nil
        )
    }

    /// Whether this page has a realtime session (a play-only session opened by typing counts too); the page uses this to decide whether to reopen capture before returning to the voice stage.
    func hasRealtime(in conversationID: UUID?) -> Bool {
        realtime != nil && HostKey(self.conversationID) == HostKey(conversationID)
    }

    /// Return to the voice stage from typing: if this page has a realtime session, first request the microphone (typed opening did not request it), then reopen capture on the same connection
    /// (cut playback first if it is playing); if refused, handle it the same as a voice entry refusal: do not reopen, the page stays in the typed state.
    /// With no realtime session it does nothing (the page only returns to the idle stage, without connecting). Returns whether this page's realtime session was reopened.
    @discardableResult
    func resumeRealtimeVoice(in conversationID: UUID?) async -> Bool {
        guard let realtime, hasRealtime(in: conversationID) else { return false }
        let granted = await deps.grantMicrophone()
        // The run ended or was replaced during authorization: do not reopen.
        guard granted, self.realtime === realtime else { return false }
        realtime.resumeVoiceCapture()
        return true
    }

    /// typed non-nil = typed opening: realtime only (cold-start in play-only mode, then emit the sentence); no cascade; send is used only by the cascade.
    private func open(
        origin: Origin,
        conversationID: UUID?,
        host: VoiceConversationChatHost,
        onNeedsRealtimeDisclosure: @escaping (RealtimeModelSelection) -> Void,
        typed: String?,
        send: AppStateVoiceChatPort.Send?
    ) async -> Bool {
        guard !isActive, !isStarting else { return false }
        let opened = await openSession(
            origin: origin, conversationID: conversationID, host: host,
            onNeedsRealtimeDisclosure: onNeedsRealtimeDisclosure, typed: typed, send: send
        )
        settleEngineSwitch(opened: opened, host: HostKey(conversationID))
        return opened
    }

    private func openSession(
        origin: Origin,
        conversationID: UUID?,
        host: VoiceConversationChatHost,
        onNeedsRealtimeDisclosure: @escaping (RealtimeModelSelection) -> Void,
        typed: String?,
        send: AppStateVoiceChatPort.Send?
    ) async -> Bool {
        isStarting = true
        openingGeneration += 1
        let opening = openingGeneration
        openingHost = HostKey(conversationID)
        // Opening a new run dismisses the previous run's in-stage failure.
        lastRealtimeFailure = nil
        let selection = deps.realtimeSelection(conversationID, host)
        realtimeSelectionAtStart = selection
        defer {
            isStarting = false
            openingHost = nil
        }
        switch await deps.makeRealtime(conversationID, host) {
        case .realtime(let parts):
            // Ended or host left during opening: do not start the conversation; close the connection already opened.
            guard openingGeneration == opening else {
                parts.connection.close()
                return false
            }
            return await startRealtime(
                parts, opening: opening, origin: origin, conversationID: conversationID, host: host, typed: typed
            )
        case .failed(let failure):
            // The selection cannot be resolved / the opening plan cannot be built: report the failure in the stage; no cascade, no toast.
            guard openingGeneration == opening else { return false }
            lastRealtimeFailure = HostedRealtimeFailure(host: HostKey(conversationID), failure: failure, selection: selection)
            return false
        case .needsDisclosure(let pending):
            // The selection has not been acknowledged yet: the page shows the notice first and opens after consent; no cascade.
            guard openingGeneration == opening else { return false }
            onNeedsRealtimeDisclosure(pending)
            return false
        case .cascade(let toast):
            // Typed opening only accepts realtime: if judged cascade, do not start a conversation and do not prompt.
            guard send != nil else { return false }
            if let toast { deps.toast(toast) }
        }
        guard let send else { return false }
        guard let listening = await deps.prepareListening() else { return false }
        if listening.fallback != nil {
            deps.toast(L10n.tr("The selected dictation engine is unavailable. Using system dictation.", table: .voice))
        }
        let port = AppStateVoiceChatPort(host: host, conversationID: conversationID, send: send)
        let controller = deps.makeController(listening, port)
        port.onHandedOff = { [weak self] in self?.homeHandedOff = true }
        port.onConversationChanged = { [weak self] id in self?.conversationID = id }
        controller.onEnded = { [weak self, weak controller] end in
            guard let self, let controller, self.controller === controller else { return }
            self.finish(controller: controller, end: end)
        }
        controller.onCloudFallbackNotice = { [deps] providerName in
            deps.toast(ReadAloudToast.cloudFallback(providerName: providerName).localizedText)
        }
        controller.onTTSEngineFallback = { [deps] _ in
            deps.toast(ReadAloudToast.engineUnavailable.localizedText)
        }
        controller.onHaptic = { [deps] in deps.haptic($0) }
        do {
            // Session configuration and activation first complete on the coordinator queue; the main thread only waits.
            try await controller.prepareAudioSession()
            // Ended during preparation: do not start the conversation; return the lease and deactivate.
            guard openingGeneration == opening else {
                controller.abandonPreparedSession()
                return false
            }
            try controller.start()
        } catch {
            // Opening ended or host left: no failure prompt.
            if openingGeneration == opening { deps.toast(VoiceConversationCopy.startFailedToast) }
            return false
        }
        self.port = port
        self.controller = controller
        sessionSerial += 1
        self.origin = origin
        self.homeHandedOff = false
        self.conversationID = conversationID
        self.lastEnd = nil
        observeStatus(controller.$statusKey)
        feedbackSubscriptions = [
            controller.$caption.sink { [weak self] in self?.caption = $0 },
            controller.$nudgeCount.sink { [weak self] in self?.nudgeCount = $0 },
        ]
        return true
    }

    /// Realtime session: voice opening requests only the microphone (refused means do not enter), then opens the connection; it does not go through dictation engine preparation or speech recognition authorization.
    /// Typed opening (typed non-nil) does not request the microphone (users who only type should not get the microphone permission prompt); it is requested before returning to the voice stage to reopen capture.
    private func startRealtime(
        _ parts: RealtimeVoiceSessionParts,
        opening: Int,
        origin: Origin,
        conversationID: UUID?,
        host: VoiceConversationChatHost,
        typed: String?
    ) async -> Bool {
        var granted = true
        if typed == nil { granted = await deps.grantMicrophone() }
        // Ended or host left during authorization: the same opening is void; close the connection and do not start the conversation.
        guard granted, openingGeneration == opening else {
            parts.connection.close()
            return false
        }
        // Home entry: after the first persisted message creates the conversation, follow the new conversation id (same as the cascade port); after an empty conversation is deleted at the end, go back to nil.
        let transcript = parts.sink as? AppStateRealtimeTranscriptSink
        // Only the home entry creates a conversation on the first turn event and deletes an empty one; the chat page (draft / existing conversation) does neither.
        transcript?.isHomeEntry = origin == .home
        // A reopen takes the current conversation's history; on home entry, use the conversation id created after the sink persists.
        let reopener: RealtimeVoiceConversationController.Reopener? = parts.reopen.map { reopen in
            { [weak transcript] in
                let opening = try await reopen(transcript?.conversationID ?? conversationID)
                return (connection: opening.connection, plan: opening.plan)
            }
        }
        var ended: ((RealtimeConversationLogic.EndReason, String?) -> Void)?
        // An error ending shows no toast: failures are shown inside the voice stage (the controller's failure; it stays on the idle stage after ending).
        let controller = deps.makeRealtimeController(
            parts, reopener,
            { _ in },
            { reason, draft in ended?(reason, draft) }
        )
        ended = { [weak self, weak controller] reason, draft in
            guard let self, let controller, self.realtime === controller else { return }
            self.finishRealtime(reason: reason, draft: draft)
        }
        self.realtime = controller
        sessionSerial += 1
        let serial = sessionSerial
        // Deleting an empty home conversation completes asynchronously on the write queue, so the callback may arrive after this run ended or even after the next run began: only this run counts.
        transcript?.onConversationChanged = { [weak self] id in
            guard let self, self.sessionSerial == serial else { return }
            let previous = self.conversationID
            // Creating the conversation hands it off (the sink calls back synchronously before the chat page opens); returning to nil after deleting an empty conversation does not take it back.
            if id != nil { self.homeHandedOff = true }
            self.conversationID = id
            // The end delivery already recorded the deleted conversation: replace it with a new delivery pointing at the home page (same draft, fresh token), so the draft is not handed to a deleted conversation.
            guard id == nil, let previous, let end = self.lastEnd, end.conversationID == previous else { return }
            let replacement = EndDelivery(token: UUID(), conversationID: nil, draft: end.draft)
            // The old delivery's draft was already taken by the chat page: the new delivery counts as taken too, so the home page does not receive it a second time.
            if self.consumedEndToken == end.token { self.consumedEndToken = replacement.token }
            self.lastEnd = replacement
        }
        self.realtimeTranscript = transcript
        self.realtimeAudio = parts.audio
        self.origin = origin
        self.homeHandedOff = false
        self.conversationID = conversationID
        self.lastEnd = nil
        // Read-aloud and the realtime session share the audio session: stop read-aloud before claiming the lease.
        deps.stopReadAloud()
        let lease = deps.audioSession.claim(.conversation)
        realtimeLease = lease
        parts.audio.sessionLease = lease
        // Typed opening: the controller cold-starts in play-only mode and emits the sentence once ready; otherwise open the mic as usual.
        if let typed { controller.sendTypedText(typed) } else { controller.start() }
        deps.recordRealtimeStart(conversationID, host)
        observeStatus(controller.$statusKey)
        feedbackSubscriptions = [
            controller.$drafts.sink { [weak self] in self?.realtimeDrafts = $0 },
        ]
        return true
    }

    /// Input for the temporary bubble in the list from this page's realtime session (draft + persisted row attribution + ids persisted in this run); nil when this page has no realtime session.
    func realtimeLiveInput(in conversationID: UUID?) -> ChatCollectionProjectionBuilder.RealtimeLiveInput? {
        guard hasRealtime(in: conversationID), let drafts = realtimeDrafts, let transcript = realtimeTranscript else {
            return nil
        }
        return ChatCollectionProjectionBuilder.RealtimeLiveInput(
            drafts: drafts, attribution: transcript.attribution, callMessageIDs: transcript.callMessageIDs
        )
    }

    // MARK: Ending

    /// ✕ = user; switching conversations / going back = system.
    func end(_ reason: VoiceConversationLogic.EndReason) {
        // In transition, the new run has not attached yet and end was pressed: remove the transition; once attached, that run's end removes it.
        if engineSwitch?.liveSerial == nil { clearEngineSwitch() }
        if let realtime {
            realtime.end()
            return
        }
        guard let controller else {
            // Cascade opening in progress (session preparation has not returned): void this opening.
            if isStarting { openingGeneration += 1 }
            return
        }
        controller.end(reason)
    }

    /// The responder changed during a voice conversation: when cascading and a realtime engine is selected, or realtime and the selection differs from the opening run (another realtime or text),
    /// pressing ✕ ends this run (the transcript is still persisted), and the page reopens with the new engine on the same conversation after collapsing.
    /// If the page has no conversation in progress (idle / another page / opening) or the engine did not change, it returns false and does nothing.
    /// The page's stage becomes the transition stage at the same time as the end (not collapsed): the status line "switched to newModelName" shows for engineSwitchNoticeSeconds and VoiceOver announces it once;
    /// newModelName = the new model name shown in the top bar; nil uses the model of the realtime selection; if neither exists, no notice is shown.
    /// A realtime session kept open only by typing (play-only, mic not open): only this run ends; no transition stage is attached, returns false (the page does not reopen,
    /// the mic is not opened, the stage returns to idle); the next typed sentence reconnects with the new model.
    /// Returns true = the page should reopen with the new engine after collapsing.
    @discardableResult
    func endForEngineChange(
        in conversationID: UUID?,
        newSelection: RealtimeModelSelection?,
        newModelName: String? = nil
    ) -> Bool {
        guard isPresented(in: conversationID) else { return false }
        let changed = isRealtime ? realtimeSelectionAtStart != newSelection : newSelection != nil
        guard changed else { return false }
        let typedOnly = realtime?.isTypedOnly == true
        end(.user)
        clearEngineSwitch()
        // The user did not speak: do not start a paid connection for the engine switch.
        if typedOnly { return false }
        let notice = (newModelName ?? newSelection?.model).map(VoiceConversationCopy.switchedTo)
        let stage = EngineSwitchStageSurface(
            host: HostKey(conversationID),
            notice: notice,
            noticeUntil: deps.now().addingTimeInterval(Self.engineSwitchNoticeSeconds),
            now: deps.now
        )
        engineSwitch = stage
        if let notice, deps.isVoiceOverRunning() { deps.announce(notice) }
        if notice != nil {
            engineSwitchNoticeTask = Task { [weak stage] in
                try? await Task.sleep(nanoseconds: UInt64(Self.engineSwitchNoticeSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                stage?.noticeExpired()
            }
        }
        return true
    }

    /// Page appear / leave registration: if all keys of a page have left and it has not returned after the grace period (and not in a home-page conversation handoff), it counts as a return and ends.
    func hostAppeared(_ conversationID: UUID?) {
        hostCounts[HostKey(conversationID), default: 0] += 1
    }

    func hostDisappeared(_ conversationID: UUID?) {
        let key = HostKey(conversationID)
        hostCounts[key] = max(0, (hostCounts[key] ?? 0) - 1)
        guard isActive || openingHost != nil || engineSwitch != nil else { return }
        leaveCheck?.cancel()
        let grace = deps.leaveGraceNanoseconds
        leaveCheck = Task { [weak self] in
            if grace > 0 { try? await Task.sleep(nanoseconds: grace) }
            guard !Task.isCancelled else { return }
            self?.endIfHostGone()
        }
    }

    /// The conversation page switched to another conversation (the same page changing id).
    func hostSwitched(from old: UUID?, to new: UUID?) {
        guard HostKey(old) != HostKey(new) else { return }
        hostAppeared(new)
        hostDisappeared(old)
    }

    func endIfHostGone() {
        // Engine-switch transition in progress (new run not yet opened) and the page has left: remove the transition; do not hold the stage for that page.
        if !isActive, openingHost == nil, let engineSwitch, (hostCounts[engineSwitch.host] ?? 0) == 0 {
            clearEngineSwitch()
            return
        }
        // Opening in progress (no controller yet) and the host left: void this opening; do not start the conversation when session preparation returns.
        if !isActive, let openingHost {
            if (hostCounts[openingHost] ?? 0) == 0 { openingGeneration += 1 }
            return
        }
        guard isActive, port?.isCreatingConversation != true,
              realtimeTranscript?.isCreatingConversation != true else { return }
        guard (hostCounts[HostKey(conversationID)] ?? 0) == 0 else { return }
        end(.system)
    }

    private func finish(controller: VoiceConversationController, end: VoiceConversationEnd) {
        // Draft in flight: the session closes first and the draft is delivered under the same token once the transcript arrives; with no draft, nothing is delivered.
        let token = UUID()
        let host = conversationID
        let serial = sessionSerial
        if end.draftPending {
            controller.onDraft = { [weak self] draft in
                // A new run was opened before the draft arrived: the old run's draft is not written into the new run's lastEnd.
                guard let self, let draft, self.sessionSerial == serial else { return }
                self.lastEnd = EndDelivery(token: token, conversationID: host, draft: draft)
            }
        } else if let draft = end.draft {
            lastEnd = EndDelivery(token: token, conversationID: host, draft: draft)
        }
        teardown()
    }

    private func finishRealtime(reason: RealtimeConversationLogic.EndReason, draft: String?) {
        lastEnd = EndDelivery(token: UUID(), conversationID: conversationID, draft: draft)
        // Failed ending: the failure stays on this page's voice stage (shown after returning to the idle stage with its copy and exits); cleared when the next run starts.
        if reason == .error, let failure = realtime?.failure {
            lastRealtimeFailure = HostedRealtimeFailure(
                host: HostKey(conversationID), failure: failure, selection: realtimeSelectionAtStart
            )
        }
        teardown()
    }

    private func teardown() {
        endEngineSwitchIfLive(serial: sessionSerial)
        statusObservation?.cancel()
        statusObservation = nil
        feedbackSubscriptions = []
        realtimeDrafts = nil
        caption = nil
        nudgeCount = 0
        if let announcementObserver { NotificationCenter.default.removeObserver(announcementObserver) }
        announcementObserver = nil
        lastAnnouncedStatus = nil
        screenReaderSpeaking = false
        languagePickerOpen = false
        leaveCheck?.cancel()
        leaveCheck = nil
        controller = nil
        realtime = nil
        realtimeTranscript = nil
        realtimeAudio = nil
        if let realtimeLease { deps.audioSession.release(realtimeLease) }
        realtimeLease = nil
        port = nil
    }

    // MARK: Screen reader

    /// Announces a status change only once, and does not process capture while announcing; streaming body text is not announced.
    /// `$statusKey.values` demands only one value at a time: a value published before the consumer is back at next() on the previous one is
    /// dropped by Published (connecting → listening falling into that gap would never announce "listening" and the uplink would stay paused).
    /// So each publish is first buffered with unbounded demand and then handled one by one asynchronously: nothing is lost, order is kept, and publishing never re-enters dispatch.
    private func observeStatus<Keys: Publisher>(_ statusKeys: Keys)
        where Keys.Output == VoiceConversationLogic.StatusKey?, Keys.Failure == Never {
        let keys = statusKeys.buffer(size: .max, prefetch: .keepFull, whenFull: .dropOldest).values
        announcementObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.announcementFinished() }
        }
        statusObservation = Task { [weak self] in
            for await key in keys {
                guard !Task.isCancelled else { return }
                self?.statusChanged(key)
            }
        }
    }

    func statusChanged(_ key: VoiceConversationLogic.StatusKey?) {
        guard let key, key != lastAnnouncedStatus else { return }
        lastAnnouncedStatus = key
        guard deps.isVoiceOverRunning(), isActive else { return }
        screenReaderSpeaking = true
        applyCapturePause()
        deps.announce(VoiceConversationCopy.status(key))
    }

    func announcementFinished() {
        screenReaderSpeaking = false
        applyCapturePause()
    }

    /// Language picker on the stage open / closed: while open, capture is not processed; closing (even unchanged) resumes; it overlaps with the screen-reader pause, and capture resumes only when both end.
    func setLanguagePickerOpen(_ open: Bool) {
        guard languagePickerOpen != open else { return }
        languagePickerOpen = open
        guard isActive else { return }
        applyCapturePause()
    }

    /// Capture pause = the screen reader is speaking or the language picker is open; the merged value goes to the controller.
    private func applyCapturePause() {
        let paused = screenReaderSpeaking || languagePickerOpen
        controller?.setScreenReaderSpeaking(paused)
        realtime?.setScreenReaderSpeaking(paused)
    }
}

/// Audio for a cascade conversation: claims the conversation lease before start and releases it after stop completes (including the delayed stop after the ending earcon); a failed start releases it immediately.
/// Dictation starts capture only after this lease is released, so a conversation teardown's deactivation does not stop dictation.
final class SessionLeasedConversationAudio: ConversationAudioEngine {
    private let inner: ConversationAudioEngine
    private let owner: VoiceAudioSessionOwner
    private var lease: VoiceAudioSessionOwner.Lease?

    init(_ inner: ConversationAudioEngine, owner: VoiceAudioSessionOwner) {
        self.inner = inner
        self.owner = owner
    }

    var sessionOwner: VoiceAudioSessionOwner { owner }
    var engine: ConversationAudioEngine { inner }

    /// Released without reaching stop (the controller is released before the delayed stop): return the lease too, so dictation does not wait forever.
    deinit {
        if let lease { owner.release(lease) }
    }

    var delegate: ConversationAudioEngineDelegate? {
        get { inner.delegate }
        set { inner.delegate = newValue }
    }
    var route: VoiceConversationLogic.Route { inner.route }
    var isSpeakerRoute: Bool { inner.isSpeakerRoute }

    /// First claim the lease (dictation waits for its release before opening capture), then prepare the session on the coordinator; a failed preparation releases it.
    func prepareSession() async throws {
        let lease = self.lease ?? owner.claim(.conversation)
        self.lease = lease
        (inner as? SessionLeaseAwareAudio)?.sessionLease = lease
        do {
            try await inner.prepareSession()
        } catch {
            if self.lease == lease { self.lease = nil }
            owner.release(lease)
            throw error
        }
    }

    /// The lease claimed by prepareSession is reused and not claimed again.
    func start() throws {
        let lease = self.lease ?? owner.claim(.conversation)
        self.lease = lease
        (inner as? SessionLeaseAwareAudio)?.sessionLease = lease
        do {
            try inner.start()
        } catch {
            self.lease = nil
            owner.release(lease)
            throw error
        }
    }

    /// The lease has been taken over by a later claimant (a conversation was reopened / dictation started before the delayed stop of an idle ending arrived): do not call the engine's stop,
    /// so its teardown does not deactivate someone else's session; an engine that can tear down just its graph does so first, closing the microphone at once. Only the graph is torn down, VPIO stays open
    /// (it is nearly a process-wide singleton, and closing it would take the later claimant's echo cancellation down with it).
    func stop() {
        let lease = self.lease
        self.lease = nil
        if let lease, owner.current != lease {
            (inner as? SessionLeaseAwareAudio)?.tearDownGraph()
            return
        }
        defer { if let lease { owner.release(lease) } }
        inner.stop()
    }

    func setCaptureMuted(_ muted: Bool) { inner.setCaptureMuted(muted) }
    func pauseCapture() { inner.pauseCapture() }
    func resumeCapture() { inner.resumeCapture() }
    func beginUtterance(fromFrame frame: Int) { inner.beginUtterance(fromFrame: frame) }
    func beginUtterance(fromFrame frame: Int, live: ConversationLiveSink?) {
        inner.beginUtterance(fromFrame: frame, live: live)
    }
    func finishUtterance(_ completion: @escaping @MainActor @Sendable (RecordingResult?) -> Void) {
        inner.finishUtterance(completion)
    }
    func discardUtterance() { inner.discardUtterance() }
    func speak(_ text: String, language: String?) async -> ConversationPlaybackOutcome {
        await inner.speak(text, language: language)
    }
    func play(audio: Data, fileExtension: String) async -> ConversationPlaybackOutcome {
        await inner.play(audio: audio, fileExtension: fileExtension)
    }
    func pausePlayback() { inner.pausePlayback() }
    func resumePlayback(fromSentenceStart: Bool) { inner.resumePlayback(fromSentenceStart: fromSentenceStart) }
    func stopPlayback() { inner.stopPlayback() }
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { inner.playEarcon(earcon) }
}
