import Combine
import Foundation
import Observation
import UIKit

/// Voice conversation copy (Voice table; keys are the English source text).
enum VoiceConversationCopy {
    static func status(_ key: VoiceConversationLogic.StatusKey) -> String {
        switch key {
        case .listening: return L10n.tr("Listening", table: .voice)
        case .thinking: return L10n.tr("Thinking", table: .voice)
        case .speaking: return L10n.tr("Speaking", table: .voice)
        case .speakingTapToInterrupt: return L10n.tr("Speaking · tap to interrupt", table: .voice)
        case .muted: return L10n.tr("Muted", table: .voice)
        case .awaitingApproval: return L10n.tr("Waiting for you", table: .voice)
        case .error: return L10n.tr("Something went wrong", table: .voice)
        }
    }

    /// Screen reader hint for the status orb: only given in the three tappable states.
    static func orbHint(_ state: VoiceConversationLogic.DisplayState?) -> String? {
        switch state {
        case .listening: return L10n.tr("Tap when you're done", table: .voice)
        case .thinking: return L10n.tr("Tap to stop", table: .voice)
        case .speaking: return L10n.tr("Tap to stop speaking", table: .voice)
        case .muted: return L10n.tr("Unmute microphone", table: .voice)
        case .awaitingApproval, .error, nil: return nil
        }
    }

    static var startA11y: String { L10n.tr("Start voice conversation", table: .voice) }
    static var endA11y: String { L10n.tr("End voice conversation", table: .voice) }
    static var muteA11y: String { L10n.tr("Mute microphone", table: .voice) }
    static var unmuteA11y: String { L10n.tr("Unmute microphone", table: .voice) }
    static var startFailedToast: String { L10n.tr("Couldn't start the voice conversation. Try again.", table: .voice) }

    /// Prompts to be spoken aloud; placeholder sentences reuse the read-aloud placeholder copy.
    static func prompt(_ prompt: VoicePrompt) -> String {
        switch prompt {
        case .didNotCatch: return L10n.tr("Sorry, I didn't catch that.", table: .voice)
        case .approvalNeeded: return L10n.tr("Please confirm on the screen.", table: .voice)
        case .placeholder(let kind): return L10n.tr(ReadAloudController.placeholderKey(kind), table: .voice)
        }
    }
}

/// The single voice conversation in the app: it survives across pages (a home → chat page handoff does not count as leaving), and pages only read it to decide whether to show the voice bar.
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

    struct Dependencies {
        /// Prepares the listening engine (microphone / recognition authorization / on-device model, the same path as dictation); nil = do not enter.
        var prepareListening: () async -> DictationEngineChoice?
        var makeController: (_ listening: DictationEngineChoice, _ port: VoiceConversationChatPort) -> VoiceConversationController
        var toast: (String) -> Void
        var isVoiceOverRunning: () -> Bool
        var announce: (String) -> Void
        /// How long to wait after all pages have left before deciding the user went back (switching carriers and the home → chat handoff leave first and appear again).
        var leaveGraceNanoseconds: UInt64
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
                    reopener: reopener, replanner: parts.replanFingerprint, onError: onError, onEnded: onEnded
                )
            }
        /// Records last-used when a realtime call starts; the conversation id is nil when entered from the home page.
        var recordRealtimeStart: (_ conversationID: UUID?, _ host: VoiceConversationChatHost) -> Void = { _, _ in }
        /// Source of the went-to-background notification (tests inject a private center).
        var notificationCenter: NotificationCenter = .default
        /// A realtime session needs only microphone authorization before entering (no dictation engine preparation, no speech recognition authorization); false = do not enter.
        var grantMicrophone: () async -> Bool = {
            guard let dictation = DictationHub.shared.controller else { return false }
            return await dictation.prepareConversationMicrophone()
        }
        /// Audio session ownership shared with dictation (realtime sessions claim / return it here; the cascade claims / returns it through SessionLeasedConversationAudio).
        /// Each set of dependencies gets its own instance by default; production uses .shared.
        var audioSession = VoiceAudioSessionOwner()

        static var production: Dependencies { production(audioSession: .shared) }

        /// The cascade / realtime engine owner is the same instance as the returned audioSession (single source).
        static func production(audioSession: VoiceAudioSessionOwner) -> Dependencies {
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
                        prompt: VoiceConversationCopy.prompt
                    )
                },
                toast: { ToastManager.shared.show($0, style: .error) },
                isVoiceOverRunning: { UIAccessibility.isVoiceOverRunning },
                announce: { UIAccessibility.post(notification: .announcement, argument: $0) },
                leaveGraceNanoseconds: 400_000_000,
                makeRealtime: { conversationID, host in
                    guard let appState = host as? AppState else { return .cascade(toast: nil) }
                    return await RealtimeVoiceSessionBuilder.production(appState: appState, audioSession: audioSession)
                        .prepare(conversationID: conversationID)
                },
                recordRealtimeStart: { conversationID, host in
                    (host as? AppState)?.recordLastUsedForRealtimeVoice(conversationID: conversationID)
                },
                audioSession: audioSession
            )
        }
    }

    /// Cascade controller: used inside the session and for read-aloud (playMessage); the voice bar goes through surface.
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
        return surface
    }
    /// The most recent ending; pages pick up the draft by token.
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
    @ObservationIgnored private var statusObservation: Task<Void, Never>?
    @ObservationIgnored private var announcementObserver: NSObjectProtocol?
    @ObservationIgnored private var lastAnnouncedStatus: VoiceConversationLogic.StatusKey?
    @ObservationIgnored private var realtimeAudio: RealtimeVoiceAudio?
    /// The audio session lease held by the realtime session; released at teardown (after the controller has stopped audio).
    @ObservationIgnored private var realtimeLease: VoiceAudioSessionOwner.Lease?
    @ObservationIgnored private var realtimeTranscript: AppStateRealtimeTranscriptSink?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

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

    /// The page runs the gates (such as the provider disclosure) first; this then prepares the microphone and recognition, and starts listening.
    /// The page supplies send: it carries this page's send parameters and delivery: .voice.
    @discardableResult
    func start(
        origin: Origin,
        conversationID: UUID?,
        host: VoiceConversationChatHost,
        send: @escaping AppStateVoiceChatPort.Send
    ) async -> Bool {
        guard !isActive, !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        switch await deps.makeRealtime(conversationID, host) {
        case .realtime(let parts):
            return await startRealtime(parts, origin: origin, conversationID: conversationID, host: host)
        case .cascade(let toast):
            if let toast { deps.toast(toast) }
        }
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
        do {
            try controller.start()
        } catch {
            deps.toast(VoiceConversationCopy.startFailedToast)
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
        return true
    }

    /// Realtime session: requests only the microphone (denied means do not enter), then opens the connection; skips dictation engine preparation and speech recognition authorization.
    private func startRealtime(_ parts: RealtimeVoiceSessionParts, origin: Origin, conversationID: UUID?, host: VoiceConversationChatHost) async -> Bool {
        guard await deps.grantMicrophone() else { return false }
        // Home entry: after the first persisted message creates the conversation, follow the new conversation id (same as the cascade port); once an empty conversation is deleted at the end, it goes back to nil.
        let transcript = parts.sink as? AppStateRealtimeTranscriptSink
        // Only the home entry creates a conversation on the first turn event and deletes an empty one; the chat page (draft / existing conversation) does neither.
        transcript?.isHomeEntry = origin == .home
        // The reopener's history comes from the current conversation; for a home entry it uses the conversation id the sink created once it persisted.
        let reopener: RealtimeVoiceConversationController.Reopener? = parts.reopen.map { reopen in
            { [weak transcript] in
                let opening = try await reopen(transcript?.conversationID ?? conversationID)
                return (connection: opening.connection, plan: opening.plan)
            }
        }
        var ended: ((RealtimeConversationLogic.EndReason, String?) -> Void)?
        // An error ending shows one toast, reusing the error status caption; once per session.
        var errorToasted = false
        let toast = deps.toast
        let controller = deps.makeRealtimeController(
            parts, reopener,
            { _ in
                guard !errorToasted else { return }
                errorToasted = true
                toast(VoiceConversationCopy.status(.error))
            },
            { reason, draft in ended?(reason, draft) }
        )
        ended = { [weak self, weak controller] _, draft in
            guard let self, let controller, self.realtime === controller else { return }
            self.finishRealtime(draft: draft)
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
        backgroundObserver = deps.notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.realtimeEnteredBackground() }
        }
        let lease = deps.audioSession.claim(.conversation)
        realtimeLease = lease
        parts.audio.sessionLease = lease
        controller.start()
        deps.recordRealtimeStart(conversationID, host)
        observeStatus(controller.$statusKey)
        return true
    }

    /// Going to the background: if audio has started, take the system interruption path (closes the connection); if it is still connecting, end directly.
    private func realtimeEnteredBackground() {
        guard let realtime, let realtimeAudio else { return }
        guard !realtimeAudio.interrupt() else { return }
        realtime.end()
    }

    // MARK: Ending

    /// ✕ = user; switching conversations / going back = system.
    func end(_ reason: VoiceConversationLogic.EndReason) {
        if let realtime {
            realtime.end()
            return
        }
        guard let controller else { return }
        controller.end(reason)
    }

    /// Page appear / leave registration: once all keys of a page have left and have not come back after the grace period (and no home conversation creation handoff is in progress), the conversation ends as a return.
    func hostAppeared(_ conversationID: UUID?) {
        hostCounts[HostKey(conversationID), default: 0] += 1
    }

    func hostDisappeared(_ conversationID: UUID?) {
        let key = HostKey(conversationID)
        hostCounts[key] = max(0, (hostCounts[key] ?? 0) - 1)
        guard isActive else { return }
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
        guard isActive, port?.isCreatingConversation != true,
              realtimeTranscript?.isCreatingConversation != true else { return }
        guard (hostCounts[HostKey(conversationID)] ?? 0) == 0 else { return }
        end(.system)
    }

    private func finish(controller: VoiceConversationController, end: VoiceConversationEnd) {
        // Draft in flight: the session closes first and the draft is delivered under the same token once the transcript arrives; with no draft nothing is delivered.
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

    private func finishRealtime(draft: String?) {
        lastEnd = EndDelivery(token: UUID(), conversationID: conversationID, draft: draft)
        teardown()
    }

    private func teardown() {
        statusObservation?.cancel()
        statusObservation = nil
        if let announcementObserver { NotificationCenter.default.removeObserver(announcementObserver) }
        announcementObserver = nil
        lastAnnouncedStatus = nil
        leaveCheck?.cancel()
        leaveCheck = nil
        if let backgroundObserver { deps.notificationCenter.removeObserver(backgroundObserver) }
        backgroundObserver = nil
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
        controller?.setScreenReaderSpeaking(true)
        realtime?.setScreenReaderSpeaking(true)
        deps.announce(VoiceConversationCopy.status(key))
    }

    func announcementFinished() {
        controller?.setScreenReaderSpeaking(false)
        realtime?.setScreenReaderSpeaking(false)
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

    func start() throws {
        let lease = owner.claim(.conversation)
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
