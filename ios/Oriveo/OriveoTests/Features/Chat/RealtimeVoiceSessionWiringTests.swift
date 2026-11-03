import AVFoundation
import Combine
import Observation
import Foundation
import OriveoProviderKit
import Testing
import UIKit
@testable import Oriveo

/// Session wiring: the chat page's ≋ opens a realtime session or goes through the cascade according to the conversation engine selection;
/// the home page's empty-draft ≋ also goes through a realtime session, and the conversation is created only when the first message is persisted.
@Suite("RealtimeVoiceSessionWiring", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RealtimeVoiceSessionWiringTests {
    typealias Fakes = RealtimeVoiceConversationControllerTests

    private let conversationID = UUID()
    private let provider = TestFactories.makeProvider(kind: .openAI, apiKey: "sk-realtime", baseURLText: "https://api.openai.com/v1")
    private let geminiProvider = TestFactories.makeProvider(
        kind: .gemini, apiKey: "g-realtime", baseURLText: "https://generativelanguage.googleapis.com"
    )
    private let defaults = UserDefaults(suiteName: "realtime-wiring-\(UUID())")!
    private let probe = SessionProbe()
    private let connection = Fakes.FakeConnection()
    private let audio = Fakes.FakeAudio()

    /// The (kind, endpoint) received by every makeConnection.
    final class Opened {
        var endpoints: [(RealtimeTransportKind, RealtimeEndpoint)] = []
        var written: [ChatMessage] = []
        /// The conversation id each persisted write was made into.
        var writtenIDs: [UUID] = []
        /// The conversation id received by the opening plan (nil on home).
        var inputIDs: [UUID?] = []
        /// The conversation created before the first persisted message of a home realtime session.
        var created: [UUID] = []
        /// Host action during conversation creation (simulates the home -> chat page handoff).
        var onCreate: ((UUID) -> Void)?
        /// How many times conversation creation was called (including failures to create).
        var createAttempts = 0
        /// Conversation creation fails (for example home has no sendable model).
        var createFails = false
        /// The conversation id received when the last-used write happens at call start (nil on home).
        var recordedStarts: [UUID?] = []
        /// Fake sockets used by gemini_live connections (in the order they were opened).
        let geminiSockets = WiringGeminiSockets()
        /// Typed turns that already exist before the call (ids are fixed so fingerprints are comparable).
        let typed = TestFactories.makeMessage(role: .user, text: "Typed question")
        /// Messages written into the conversation elsewhere during the call (another device / typing), placed after this call's transcripts.
        var external: [ChatMessage] = []
        /// Whether fetching the conversation snapshot and reading the checkpoint (assembly) each run on the main thread.
        let threads = WiringThreads()
        /// GA connections take the one here first (a reopen needs a new connection), then return to the shared connection.
        var nextConnections: [Fakes.FakeConnection] = []
        /// Realtime selection state in the picker (same as AppState.realtimeModelSelections; the home key is nil).
        var selections: [UUID?: RealtimeModelSelection] = [:]
        /// UI language read by the builder when it opens a connection.
        var uiLocale = Locale(identifier: "en-US")
    }

    private let opened = Opened()

    private var settings: VoiceEngineSettings { VoiceEngineSettings(defaults: defaults) }

    private static func catalog(contextWindow: Int = 128_000) -> VoiceCatalog {
        VoiceCatalog(schemaVersion: 2, revision: "r1", providers: [
            .openAI: VoiceProviderEntries(realtime: [VoiceRealtimeEntry(
                model: "gpt-realtime",
                transport: .openaiRealtime,
                path: "/v1/realtime",
                contextWindow: contextWindow,
                voices: [VoiceCatalogVoice(id: "marin", isDefault: true), VoiceCatalogVoice(id: "cedar", isDefault: false)],
                maxSessionSec: nil,
                inputTranscriptionModel: "gpt-4o-mini-transcribe",
                isDefault: true
            )]),
            .gemini: VoiceProviderEntries(realtime: [VoiceRealtimeEntry(
                model: "gemini-3.8-live",
                transport: .geminiLive,
                path: "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
                contextWindow: contextWindow,
                voices: [VoiceCatalogVoice(id: "Kore", isDefault: true)],
                maxSessionSec: nil,
                inputTranscriptionModel: nil,
                isDefault: true
            )]),
        ])
    }

    /// The selection state is written to this conversation's key and the home key (both chat and home entries can read it); disclosure consent writes the same record the test suite uses.
    private func select(_ selection: RealtimeModelSelection, accept: Bool) {
        opened.selections[conversationID] = selection
        opened.selections[nil] = selection
        if accept { settings.disclosures.markAccepted(selection.providerKind, direction: .realtime) }
    }

    private func selectGemini() {
        select(RealtimeModelSelection(providerID: geminiProvider.id, providerKind: .gemini, model: "gemini-3.8-live"), accept: true)
    }

    private func selectRealtime(providerID: UUID? = nil, accept: Bool = true) {
        select(
            RealtimeModelSelection(providerID: providerID ?? provider.id, providerKind: .openAI, model: "gpt-realtime"),
            accept: accept
        )
    }

    private func builder(
        contextWindow: Int = 128_000,
        appState: AppState? = nil,
        wrapAudio: ((any RealtimeAudioIO) -> any RealtimeAudioIO)? = nil
    ) -> RealtimeVoiceSessionBuilder {
        let opened = opened
        let connection = connection
        let audio = audio
        let provider = provider
        let geminiProvider = geminiProvider
        return RealtimeVoiceSessionBuilder(
            selection: { opened.selections[$0] },
            disclosures: settings.disclosures,
            catalog: { Self.catalog(contextWindow: contextWindow) },
            refreshCatalog: { Self.catalog(contextWindow: contextWindow) },
            providers: { [provider, geminiProvider] },
            sessionSource: { id in
                opened.inputIDs.append(id)
                let threads = opened.threads
                threads.record(snapshot: Thread.isMainThread)
                // Same as ChatManager reading the in-memory conversation: this call's transcripts that are already persisted are in the history too.
                let snapshot = ChatRequestSnapshot(
                    conversation: ChatRequestConversationSnapshot(id: id ?? UUID(), useMemory: false, skillID: nil, instructions: "Be brief."),
                    messages: [opened.typed] + opened.written + opened.external,
                    preferences: ChatRequestPreferencesSnapshot(),
                    skill: nil,
                    sendPath: .send(excludingMessageID: nil)
                )
                return RealtimeSessionSource(snapshot: snapshot) { _ in
                    threads.record(checkpoint: Thread.isMainThread)
                    return nil
                }
            },
            makeConnection: { kind, endpoint in
                opened.endpoints.append((kind, endpoint))
                guard kind == .geminiLive else {
                    return opened.nextConnections.isEmpty ? connection : opened.nextConnections.removeFirst()
                }
                let sockets = opened.geminiSockets
                return GeminiLiveSessionControl(transport: GeminiLiveTransport(
                    config: GeminiLiveSessionControl.config(for: endpoint),
                    socketFactory: { _ in sockets.open() }
                ))
            },
            makeAudio: { RealtimeVoiceAudio(wrapAudio?(audio) ?? audio, route: { .speaker }) },
            makeSink: { id, attribution in
                // The real AppState: the production sink factory (creating a conversation means presentChat, persisting goes through ChatManager, empty conversations are deleted).
                if let appState { return AppStateRealtimeTranscriptSink.appState(appState, conversationID: id, attribution: attribution) }
                return AppStateRealtimeTranscriptSink(
                    conversationID: id,
                    attribution: attribution,
                    createConversation: {
                        opened.createAttempts += 1
                        guard !opened.createFails else { return nil }
                        let created = UUID()
                        opened.onCreate?(created)
                        opened.created.append(created)
                        return created
                    }
                ) { message, id in
                    opened.written.append(message)
                    opened.writtenIDs.append(id)
                }
            },
            voiceSettings: settings,
            uiLocale: { opened.uiLocale }
        )
    }

    private func session(
        contextWindow: Int = 128_000,
        replan: Bool = false,
        appState: AppState? = nil,
        clock: Fakes.ManualClock = Fakes.ManualClock(),
        listening: DictationEngineChoice? = DictationEngineChoice(engine: SilentSTT(), isSystem: true, fallback: nil),
        audioSession: VoiceAudioSessionOwner = VoiceAudioSessionOwner(),
        onAnnounce: ((String) -> Void)? = nil,
        wrapAudio: ((any RealtimeAudioIO) -> any RealtimeAudioIO)? = nil,
        beforeMakeRealtime: (() async -> Void)? = nil,
        stopReadAloud: @escaping () -> Void = {},
        tracksSelection: Bool = false,
        now: (() -> Date)? = nil,
        grantMicrophone: (() async -> Bool)? = nil
    ) -> VoiceConversationSession {
        var deps = probe.dependencies(listening: listening)
        if let now { deps.now = now }
        if tracksSelection {
            let opened = opened
            deps.realtimeSelection = { id, _ in opened.selections[id] }
        }
        deps.audioSession = audioSession
        deps.stopReadAloud = stopReadAloud
        if let onAnnounce {
            let announce = deps.announce
            deps.announce = { announce($0); onAnnounce($0) }
        }
        deps.grantMicrophone = grantMicrophone ?? { true }
        let builder = builder(contextWindow: contextWindow, appState: appState, wrapAudio: wrapAudio)
        deps.makeRealtime = { id, _ in
            await beforeMakeRealtime?()
            return await builder.prepare(conversationID: id)
        }
        let opened = opened
        deps.recordRealtimeStart = { id, _ in opened.recordedStarts.append(id) }
        deps.makeRealtimeController = { parts, reopener, onError, onEnded in
            RealtimeVoiceConversationController(
                connection: parts.connection, audio: parts.audio, plan: parts.plan, sink: parts.sink,
                clock: clock, reopener: reopener,
                replanner: replan ? parts.replanFingerprint : nil, failureContext: parts.failureContext,
                onError: onError, onEnded: onEnded
            )
        }
        return VoiceConversationSession(dependencies: deps)
    }

    private func start(_ session: VoiceConversationSession) async -> Bool {
        await session.start(origin: .chat, conversationID: conversationID, host: FakeVoiceChatHost()) { _, _ in .refused }
    }

    private func startHome(_ session: VoiceConversationSession) async -> Bool {
        await session.start(origin: .home, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in .refused }
    }

    private func listening(_ session: VoiceConversationSession) async throws -> RealtimeVoiceConversationController {
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        await waitStatus(realtime, .listening)
        return realtime
    }

    private func speakUser(_ text: String, item: String) {
        for event: RealtimeSessionEvent in [
            .userSpeechStarted(itemId: item),
            .userSpeechStopped(itemId: item),
            .userTranscript(itemId: item, text: text, final: true),
        ] {
            connection.continuation.yield(event)
        }
    }

    /// Wait until the session closes (isActive is derived from observed properties of the controller / realtime), without betting on scheduling counts.
    private func untilInactive(_ session: VoiceConversationSession) async {
        await until { !session.isActive }
    }

    /// The condition must read observed properties that change; it is re-evaluated after every change until it holds. When the task is cancelled (timeLimit) it returns immediately and records a failure.
    private func until(_ condition: @escaping () -> Bool) async {
        defer {
            // Cancellation is always recorded as a failure (whether or not the condition already held): a timeout is never let through silently.
            if Task.isCancelled { Issue.record("until: cancelled") }
        }
        while !condition() {
            guard !Task.isCancelled else { return }
            let wake = OnceContinuation()
            withObservationTracking { _ = condition() } onChange: { wake.resume() }
            await withTaskCancellationHandler {
                await wake.wait()
            } onCancel: {
                wake.resume()
            }
        }
    }

    private func waitStatus(_ controller: RealtimeVoiceConversationController, _ key: VoiceConversationLogic.StatusKey) async {
        for await value in controller.$statusKey.values where value == key { return }
    }

    /// Speaker-output routing: the transport layer takes the output route when it opens a connection in the background and must not wait synchronously on the main thread (the main thread may be waiting on the coordinator or the transport layer)
    /// The production audio proxy (RealtimeVoiceAudio) hands route changes during a session to the controller, which disarms the uplink gate on the spot.
    @Test func route_change_through_production_audio_reaches_gate() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let realtime = try await listening(session)
        let onFrame = try #require(audio.onFrame)
        yield([.userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio])
        await waitStatus(realtime, .speaking)
        #expect(audio.isPlaying)
        let frame = Data(count: Int(RealtimePCM.sampleRate) / 50 * 2)
        let before = connection.sent.count
        for _ in 0..<3 { onFrame(frame) }
        // Speaker playback in progress: the silent frame is held by the gate
        #expect(connection.sent.count == before)
        audio.changeRoute(.headphones)
        onFrame(frame)
        #expect(Array(connection.sent[before...]) == [frame])
    }

    /// The production VPIO engine in realtime mode hands this session's routeChange to the realtime callback (taking the route at that time); routes sent by other sessions do not count;
    /// the observer is removed along with the graph teardown.
    @Test func vpio_engine_hands_route_change_to_realtime_callback() {
        let avSession = AVAudioSession.sharedInstance()
        let center = NotificationCenter()
        let engine = VPIOConversationAudioEngine(session: avSession, notificationCenter: center)
        let audio = RealtimeVoiceAudio(engine, route: { engine.route })
        var routes: [VoiceConversationLogic.Route] = []
        audio.onRouteChanged = { routes.append($0) }
        engine.enterRunningStateForTesting()
        let info = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        center.post(name: AVAudioSession.routeChangeNotification, object: NSObject(), userInfo: info)
        #expect(routes.isEmpty)
        center.post(name: AVAudioSession.routeChangeNotification, object: avSession, userInfo: info)
        #expect(routes == [engine.route])
        engine.tearDownGraph()
        #expect(engine.observerCountForTesting == 0)
        center.post(name: AVAudioSession.routeChangeNotification, object: avSession, userInfo: info)
        #expect(routes.count == 1)
    }

    @Test func output_route_sampling_never_waits_on_main_thread() {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = RealtimeVoiceSessionBuilder.currentOutputRoute()
            done.signal()
        }
        // The main thread blocks here: if sampling went through DispatchQueue.main.sync it would wait until the timeout
        #expect(done.wait(timeout: .now() + 2) == .success)
    }

    @Test func realtime_selection_starts_realtime() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        #expect(session.isRealtime)
        #expect(session.controller == nil)
        let realtime = try #require(session.realtime)
        #expect(session.surface as AnyObject === realtime)
        connection.continuation.yield(.ready)
        await waitStatus(realtime, .listening)
        #expect(audio.log.first == "startRealtime")
        let (kind, endpoint) = try #require(opened.endpoints.first)
        #expect(kind == .openaiRealtime)
        #expect(endpoint.host == "api.openai.com")
        #expect(endpoint.apiKey == "sk-realtime")
        #expect(endpoint.model == "gpt-realtime")
        #expect(endpoint.path == "/v1/realtime")
        // The selection carries no voice: use the catalog's default voice.
        #expect(endpoint.voice == "marin")
        #expect(endpoint.inputTranscriptionModel == "gpt-4o-mini-transcribe")
        #expect(probe.toasts.isEmpty)
    }

    // MARK: Transcript language

    @Test func endpoint_language_uses_recognition_language_setting() async throws {
        settings.recognitionLanguage = "ja-JP"
        opened.uiLocale = Locale(identifier: "zh-Hans-CN")
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let (_, endpoint) = try #require(opened.endpoints.first)
        #expect(endpoint.language == "ja-JP")
    }

    @Test func endpoint_language_falls_back_to_ui_language() async throws {
        settings.recognitionLanguage = nil
        opened.uiLocale = Locale(identifier: "zh-Hans-CN")
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let (_, endpoint) = try #require(opened.endpoints.first)
        #expect(endpoint.language == "zh-Hans-CN")
    }

    // MARK: Persistent voice panel

    private func stage(
        _ session: VoiceConversationSession,
        onSwitchToTyping: @escaping () -> Void = {},
        onIdleTap: @escaping () -> Void = {}
    ) -> (any VoiceConversationSurface)? {
        session.stageSurface(
            in: conversationID,
            realtimeSelected: opened.selections[conversationID] != nil,
            onIdleTap: onIdleTap,
            onSwitchToTyping: onSwitchToTyping
        )
    }

    /// Selecting realtime shows the idle panel: the orb stays still with "Tap to start speaking"; no connection, no mic, the session is inactive; nothing is shown without a selection.
    @Test func selection_shows_idle_stage_without_connecting() async throws {
        let session = session()
        #expect(stage(session) == nil)

        selectRealtime()
        let idle = try #require(stage(session) as? RealtimeIdleStageSurface)
        #expect(idle.statusKey == nil)
        #expect(idle.displayState == nil)
        #expect(idle.level == 0)
        #expect(idle.idleHint == VoiceConversationCopy.tapToStartHint)
        #expect(!session.isActive)
        #expect(opened.endpoints.isEmpty)
        #expect(audio.log.isEmpty)
        #expect(probe.toasts.isEmpty)
    }

    /// The idle panel shows a keyboard button on the left (switches to typing), and neither ✕ nor mute (mute only exists during a session); tapping the keyboard only hands off to the page to switch,
    /// without opening a connection or the mic. During a session it is unchanged: has ✕ and mute, no keyboard.
    @Test func idle_stage_has_keyboard_and_no_end_button() async throws {
        let session = session()
        selectRealtime()
        var switched = 0
        let idle = try #require(stage(session, onSwitchToTyping: { switched += 1 }) as? RealtimeIdleStageSurface)
        #expect(idle.showsTypingSwitch)
        #expect(!idle.showsEndButton)
        #expect(!idle.showsMuteButton)
        // The idle panel's bottom row has only a centered "Edit typing" pill, 36 pt high, on the same center line as the mute / end buttons during a session.
        let idleSlots = VoiceConversationBarContent.controlSlots(
            showsTypingSwitch: idle.showsTypingSwitch,
            showsMuteButton: idle.showsMuteButton,
            showsEndButton: idle.showsEndButton
        )
        let capsule = try #require(idleSlots.first)
        #expect(idleSlots.count == 1)
        #expect(capsule.kind == .typingCapsule)
        #expect(capsule.placement == .center)
        #expect(capsule.height == 36)
        #expect(VoiceConversationBarContent.typingCapsuleTitle == L10n.tr("Switch to Typing", table: .voice))
        idle.switchToTyping()
        #expect(switched == 1)
        #expect(!session.isActive)
        #expect(opened.endpoints.isEmpty)
        #expect(audio.log.isEmpty)

        #expect(await start(session))
        let live = try #require(stage(session))
        #expect(!(live is RealtimeIdleStageSurface))
        #expect(!live.showsTypingSwitch)
        #expect(live.showsEndButton)
        #expect(live.showsMuteButton)
        let liveSlots = VoiceConversationBarContent.controlSlots(
            showsTypingSwitch: live.showsTypingSwitch,
            showsMuteButton: live.showsMuteButton,
            showsEndButton: live.showsEndButton
        )
        #expect(liveSlots.map(\.kind) == [.mute, .end])
        #expect(liveSlots.map(\.placement) == [.leading, .trailing])
        #expect(liveSlots.map(\.height) == [64, 64])
        #expect(liveSlots.allSatisfy { $0.centerFromBottom == capsule.centerFromBottom })
    }

    /// Tapping the idle panel's orb opens a realtime session by the selection (VoiceEngineSettings is not read); the voice panel swaps to the realtime controller.
    @Test func idle_tap_opens_session_with_selected_model() async throws {
        selectGemini()
        let session = session()
        var opening: Task<Bool, Never>?
        let idle = try #require(stage(session) {
            opening = Task { await start(session) }
        })
        idle.tapOrb()
        let task = try #require(opening)
        #expect(await task.value)
        #expect(session.isRealtime)
        let realtime = try #require(session.realtime)
        #expect(stage(session) as AnyObject === realtime)
        let (kind, endpoint) = try #require(opened.endpoints.first)
        #expect(kind == .geminiLive)
        #expect(endpoint.model == "gemini-3.8-live")
        #expect(endpoint.apiKey == "g-realtime")
        #expect(endpoint.voice == "Kore")
        #expect(probe.toasts.isEmpty)
    }

    // MARK: Stage line

    /// The realtime panel's stage text takes stageLine: the listening status word; once the user's speech has text, the user caption appears (even when statusKey is not caption).
    @Test func realtime_stage_text_follows_stage_line() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let realtime = try await listening(session)
        let live = try #require(stage(session))
        #expect(live.stageLine == .status(key: "listening"))
        #expect(VoiceConversationBarContent.stageCaption(
            statusKey: live.statusKey, caption: live.caption, stageLine: live.stageLine
        ) == nil)

        connection.continuation.yield(.userSpeechStarted(itemId: "u1"))
        connection.continuation.yield(.userTranscript(itemId: "u1", text: "What time", final: false))
        for await value in realtime.$caption.values where value == "What time" { break }
        #expect(live.statusKey != .caption)
        #expect(live.stageLine == .user("What time"))
        #expect(VoiceConversationBarContent.stageCaption(
            statusKey: live.statusKey, caption: live.caption, stageLine: live.stageLine
        ) == "What time")
    }

    // MARK: Typing state back to voice panel

    /// After typing opened a realtime session (playback only), returning to the voice panel: the same connection opens capture, and the voice panel shows this session.
    @Test func back_to_stage_resumes_capture_when_session_open() async throws {
        selectRealtime()
        let session = session()
        #expect(await session.sendRealtimeTyped("Hello", conversationID: conversationID, host: FakeVoiceChatHost()))
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(realtime, .speaking)
        #expect(connection.texts == ["Hello"])
        #expect(!audio.log.contains("startRealtimeCapture"))

        #expect(await session.resumeRealtimeVoice(in: conversationID))
        #expect(audio.log.filter { $0 == "startRealtimeCapture" }.count == 1)
        #expect(realtime.statusKey == .listening)
        #expect(opened.endpoints.count == 1)
        #expect(connection.closeCount == 0)
        #expect(stage(session) as AnyObject === realtime)
        session.end(.user)
        await untilInactive(session)
    }

    /// With no realtime session in this conversation, returning to the voice panel: no connection and no mic; the voice panel is the idle panel.
    @Test func back_to_stage_without_session_does_not_connect() async throws {
        selectRealtime()
        let session = session()
        #expect(!(await session.resumeRealtimeVoice(in: conversationID)))
        #expect(!session.isActive)
        #expect(opened.endpoints.isEmpty)
        #expect(audio.log.isEmpty)
        #expect(stage(session) is RealtimeIdleStageSurface)
    }

    /// Reset rule for the conversation page's typing state: it resets as soon as the selected model changes in this conversation, whether switching to another realtime model or canceling realtime;
    /// nothing changes when the model stays the same or only the conversation changes (each conversation stores its typing state separately).
    @Test func typing_resets_when_switching_to_another_realtime_model() {
        let other = UUID()
        let mini = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime-mini")
        let full = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        typealias Key = RealtimeTypingReset.Key
        var hosts: Set<UUID?> = [conversationID, other]

        RealtimeTypingReset.apply(
            old: Key(conversationID: conversationID, selection: mini),
            new: Key(conversationID: conversationID, selection: mini),
            hosts: &hosts
        )
        #expect(hosts == [conversationID, other])

        RealtimeTypingReset.apply(
            old: Key(conversationID: other, selection: mini),
            new: Key(conversationID: conversationID, selection: full),
            hosts: &hosts
        )
        #expect(hosts == [conversationID, other])

        RealtimeTypingReset.apply(
            old: Key(conversationID: conversationID, selection: mini),
            new: Key(conversationID: conversationID, selection: full),
            hosts: &hosts
        )
        #expect(hosts == [other])

        RealtimeTypingReset.apply(
            old: Key(conversationID: other, selection: mini),
            new: Key(conversationID: other, selection: nil),
            hosts: &hosts
        )
        #expect(hosts.isEmpty)
    }

    /// A cold typing start meets a selection without disclosure consent (first-time disclosure): the page shows the disclosure, with no connection, no mic, and no text sent; returning false means the page gives the text back.
    @Test func typed_send_without_disclosure_consent_does_not_connect() async throws {
        selectRealtime(accept: false)
        let session = session()
        var asked: [RealtimeModelSelection] = []
        let sent = await session.sendRealtimeTyped(
            "Hello", conversationID: conversationID, host: FakeVoiceChatHost(),
            onNeedsRealtimeDisclosure: { asked.append($0) }
        )
        #expect(!sent)
        #expect(asked.map(\.model) == ["gpt-realtime"])
        #expect(!session.isActive)
        #expect(!session.hasRealtime(in: conversationID))
        #expect(opened.endpoints.isEmpty)
        #expect(connection.texts.isEmpty)
        #expect(audio.log.isEmpty)
        #expect(probe.toasts.isEmpty)
        #expect(session.realtimeFailure(in: conversationID) == nil)
    }

    // MARK: Send after disclosure consent

    /// When a cold typing start shows the disclosure, this sentence is held; after consent (same conversation) it is sent without another tap; switching conversations discards it.
    @Test func typed_send_after_disclosure_consent_sends_pending_text() async throws {
        selectRealtime(accept: false)
        let session = session()
        var pending: RealtimeTypedPendingSend?
        let first = await session.sendRealtimeTyped(
            "Hello", conversationID: conversationID, host: FakeVoiceChatHost(),
            onNeedsRealtimeDisclosure: { selection in
                pending = RealtimeTypedPendingSend(
                    text: "Hello",
                    request: RealtimeModelDisclosureRequest(selection: selection, conversationID: conversationID)
                )
            }
        )
        #expect(!first)
        #expect(opened.endpoints.isEmpty)
        let held = try #require(pending)
        #expect(held.request.selection.model == "gpt-realtime")
        #expect(held.textToSend(accepted: true, activeConversationID: UUID()) == nil)

        // Consent: record the disclosure, then send the held text.
        let text = try #require(held.textToSend(accepted: true, activeConversationID: conversationID))
        selectRealtime(accept: true)
        var askedAgain = 0
        let sent = await session.sendRealtimeTyped(
            text, conversationID: conversationID, host: FakeVoiceChatHost(),
            onNeedsRealtimeDisclosure: { _ in askedAgain += 1 }
        )
        #expect(sent)
        #expect(askedAgain == 0)
        #expect(opened.endpoints.count == 1)
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(realtime, .speaking)
        #expect(connection.texts == ["Hello"])
        #expect(session.hasRealtime(in: conversationID))
        #expect(!audio.log.contains("startRealtimeCapture"))
        session.end(.user)
        await untilInactive(session)
    }

    /// Disclosure declined or dismissed: the held text is not sent and no connection opens; the text returns to the input box if it is still empty (not overwritten when the box already has new text).
    @Test func typed_send_disclosure_declined_keeps_text_in_input() async throws {
        selectRealtime(accept: false)
        let session = session()
        var pending: RealtimeTypedPendingSend?
        let sent = await session.sendRealtimeTyped(
            "Hello", conversationID: conversationID, host: FakeVoiceChatHost(),
            onNeedsRealtimeDisclosure: { selection in
                pending = RealtimeTypedPendingSend(
                    text: "Hello",
                    request: RealtimeModelDisclosureRequest(selection: selection, conversationID: conversationID)
                )
            }
        )
        #expect(!sent)
        // Not cleared on send: if it was never handed off, the original text stays in the box; disclosureDeclined keeps it as is, without concatenation.
        #expect(!sent)
        #expect(RealtimeTypedPendingSend.inputText("Hello", sent: "Hello", outcome: .disclosureDeclined) == "Hello")
        #expect(RealtimeTypedPendingSend.inputText("Hello New", sent: "Hello", outcome: .openFailed) == "Hello New")
        let held = try #require(pending)
        #expect(held.textToSend(accepted: false, activeConversationID: conversationID) == nil)
        #expect(!session.isActive)
        #expect(!session.hasRealtime(in: conversationID))
        #expect(opened.endpoints.isEmpty)
        #expect(connection.texts.isEmpty)
        #expect(audio.log.isEmpty)
    }

    // MARK: Conversation page: realtime typing is cleared only after it is persisted, plus in-flight duplicate-send protection

    /// After hand-off the box still holds the original text; it is cleared only when the first sentence is persisted (the number of user sentences this page's realtime session persisted exceeds the baseline); characters edited while waiting are left alone.
    @Test func typed_send_keeps_text_until_persisted() async throws {
        selectRealtime()
        let session = session()
        var composer = "Hello"
        let inFlight = try #require(RealtimeTypedInFlight.begin(nil, text: "Hello", conversationID: conversationID, session: session))
        #expect(inFlight.persistedBaseline == 0)
        #expect(await session.sendRealtimeTyped(composer, conversationID: conversationID, host: FakeVoiceChatHost()))
        // Handed off but not persisted: no outcome yet, the box still holds the original text.
        #expect(inFlight.outcome(userPersisted: session.realtimeDrafts?.userPersisted) == nil)
        #expect(composer == "Hello")
        #expect(inFlight.outcome(host: conversationID) == nil)

        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(realtime, .speaking)
        #expect(connection.texts == ["Hello"])
        let outcome = try #require(inFlight.outcome(userPersisted: session.realtimeDrafts?.userPersisted))
        #expect(outcome == .persisted)
        #expect(inFlight.inputText("New", outcome: outcome) == "New")
        composer = inFlight.inputText(composer, outcome: outcome)
        #expect(composer == "")

        // This page already has a realtime session: the next sentence's baseline is the persisted sentence count; handed off but not persisted does not count as an outcome.
        let next = try #require(RealtimeTypedInFlight.begin(nil, text: "Again", conversationID: conversationID, session: session))
        #expect(next.persistedBaseline == 1)
        #expect(next.outcome(userPersisted: session.realtimeDrafts?.userPersisted) == nil)
        session.end(.user)
        await untilInactive(session)
    }

    /// The session ends before persisting (endedBeforePersist) or the page is replaced (hostLeft): the original text stays in the box, without concatenation.
    @Test func typed_send_ended_before_persist_keeps_text_without_concat() async throws {
        selectRealtime()
        let session = session()
        var composer = "Hello"
        let inFlight = try #require(RealtimeTypedInFlight.begin(nil, text: "Hello", conversationID: conversationID, session: session))
        #expect(await session.sendRealtimeTyped(composer, conversationID: conversationID, host: FakeVoiceChatHost()))
        #expect(connection.texts.isEmpty)
        session.end(.user)
        await untilInactive(session)
        let end = try #require(session.lastEnd)
        #expect(inFlight.outcome(userPersisted: session.realtimeDrafts?.userPersisted) == nil)
        composer = inFlight.inputText(composer, outcome: .endedBeforePersist)
        // The end handoff does not carry this sentence: when the input bar collects its draft, the original text is not concatenated again.
        if let draft = session.consumeEndDraft(end, host: conversationID) {
            composer = composer.isEmpty ? draft : composer + " " + draft
        }
        #expect(composer == "Hello")
        #expect(opened.written.isEmpty)

        let other = UUID()
        let outcome = try #require(inFlight.outcome(host: other))
        #expect(outcome == .hostLeft)
        #expect(inFlight.inputText("Hello", outcome: outcome) == "Hello")
    }

    /// Sending again while a sentence is in flight (handed off, not settled): no new sentence is handed off, and the connection receives only the first one.
    @Test func typed_send_in_flight_blocks_second_handoff() async throws {
        selectRealtime()
        let session = session()
        let inFlight = try #require(RealtimeTypedInFlight.begin(nil, text: "Hello", conversationID: conversationID, session: session))
        #expect(await session.sendRealtimeTyped("Hello", conversationID: conversationID, host: FakeVoiceChatHost()))
        #expect(RealtimeTypedInFlight.begin(inFlight, text: "Second", conversationID: conversationID, session: session) == nil)
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        await waitStatus(realtime, .speaking)
        #expect(connection.texts == ["Hello"])
        // Release the next sentence after settlement.
        #expect(inFlight.outcome(userPersisted: session.realtimeDrafts?.userPersisted) == .persisted)
        #expect(RealtimeTypedInFlight.begin(nil, text: "Second", conversationID: conversationID, session: session) != nil)
        session.end(.user)
        await untilInactive(session)
    }

    /// The selection remains after the realtime session ends: the voice panel returns to the idle state, not connected.
    @Test func end_returns_to_idle_stage() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        _ = try await listening(session)
        session.end(.user)
        await untilInactive(session)
        let idle = try #require(stage(session) as? RealtimeIdleStageSurface)
        // Back to the idle panel that includes the "Edit typing" pill.
        #expect(VoiceConversationBarContent.controlSlots(
            showsTypingSwitch: idle.showsTypingSwitch,
            showsMuteButton: idle.showsMuteButton,
            showsEndButton: idle.showsEndButton
        ).map(\.kind) == [.typingCapsule])
        #expect(opened.endpoints.count == 1)

        // Switching back to a text model: the voice panel disappears and the normal input area returns.
        opened.selections = [:]
        #expect(stage(session) == nil)
    }

    // MARK: Switch responder during voice playback

    @Test func cascade_active_then_realtime_selected_ends_cascade() async throws {
        let session = session(tracksSelection: true)
        #expect(await start(session))
        #expect(session.controller != nil)
        selectRealtime()
        #expect(session.endForEngineChange(in: conversationID, newSelection: opened.selections[conversationID]))
        await untilInactive(session)
        #expect(!session.isActive)
        #expect(opened.endpoints.isEmpty)
    }

    @Test func realtime_active_then_text_selected_ends_realtime() async throws {
        selectRealtime()
        let session = session(tracksSelection: true)
        #expect(await start(session))
        _ = try await listening(session)
        speakUser("Hello there", item: "u1")
        while opened.written.isEmpty { await Task.yield() }
        opened.selections = [:]
        #expect(session.endForEngineChange(in: conversationID, newSelection: nil))
        await untilInactive(session)
        #expect(!session.isActive)
        #expect(!session.isRealtime)
        #expect(opened.written.map(\.text) == ["Hello there"])
        #expect(opened.writtenIDs == [conversationID])
    }

    @Test func realtime_active_then_other_realtime_ends() async throws {
        selectRealtime()
        let session = session(tracksSelection: true)
        #expect(await start(session))
        _ = try await listening(session)
        selectGemini()
        #expect(session.endForEngineChange(in: conversationID, newSelection: opened.selections[conversationID]))
        await untilInactive(session)
        #expect(!session.isActive)
        #expect(!session.isRealtime)
        #expect(opened.endpoints.count == 1)
    }

    @Test func same_realtime_selection_keeps_session() async throws {
        selectRealtime()
        let session = session(tracksSelection: true)
        #expect(await start(session))
        let realtime = try await listening(session)
        #expect(!session.endForEngineChange(in: conversationID, newSelection: opened.selections[conversationID]))
        // A selection change on another page does not affect this page's session.
        #expect(!session.endForEngineChange(in: UUID(), newSelection: nil))
        #expect(session.isActive)
        #expect(session.isRealtime)
        #expect(session.realtime === realtime)
    }

    @Test func idle_engine_change_does_not_open() async throws {
        selectRealtime()
        let session = session(tracksSelection: true)
        #expect(stage(session) is RealtimeIdleStageSurface)
        #expect(!session.endForEngineChange(in: conversationID, newSelection: opened.selections[conversationID]))
        opened.selections = [:]
        #expect(!session.endForEngineChange(in: conversationID, newSelection: nil))
        #expect(!session.isActive)
        #expect(!session.isRealtime)
        #expect(opened.endpoints.isEmpty)
    }

    // MARK: Engine switch transition

    /// Realtime → text: the old session collapses and the new one takes over; this page's panel stays throughout (the same transition panel, never falling back to nil);
    /// the status line first shows "Switched to <model>" and is read aloud once, then after 1.6 s returns to the new session's normal status line; the orb keeps moving with the connection.
    @Test func switch_keeps_stage_and_shows_switched_to() async throws {
        let now = WiringNow()
        probe.voiceOver = true
        selectRealtime()
        let session = session(tracksSelection: true, now: { now.value })
        #expect(await start(session))
        _ = try await listening(session)
        opened.selections = [:]
        #expect(session.endForEngineChange(in: conversationID, newSelection: nil, newModelName: "GPT-5 Mini"))
        let notice = VoiceConversationCopy.switchedTo("GPT-5 Mini")
        #expect(notice.contains("GPT-5 Mini"))
        #expect(!notice.contains("%"))
        let transition = try #require(stage(session))
        #expect(transition.stageLine == .notice(notice))
        #expect(VoiceConversationBarContent.stageCaption(
            statusKey: transition.statusKey, caption: transition.caption, stageLine: transition.stageLine
        ) == notice)
        #expect(transition.displayState == .thinking)
        #expect(transition.showsEndButton)
        #expect(!transition.showsTypingSwitch)

        await untilInactive(session)
        // The old session has collapsed and the new one has not opened yet: without a realtime selection the panel is not collapsed either.
        #expect(stage(session).map { ObjectIdentifier($0) } == ObjectIdentifier(transition))
        #expect(VoiceStageChrome.isShown(session: session, conversationID: conversationID))

        #expect(await start(session))
        #expect(session.controller != nil)
        let live = try #require(session.surface)
        #expect(stage(session).map { ObjectIdentifier($0) } == ObjectIdentifier(transition))
        #expect(transition.stageLine == .notice(notice))
        #expect(transition.statusKey == live.statusKey)

        now.value += VoiceConversationSession.engineSwitchNoticeSeconds
        #expect(transition.stageLine == live.stageLine)
        #expect(transition.stageLine != .notice(notice))
        #expect(VoiceConversationBarContent.stageCaption(
            statusKey: transition.statusKey, caption: transition.caption, stageLine: transition.stageLine
        ) != notice)
        #expect(probe.announcements.filter { $0 == notice }.count == 1)

        session.end(.user)
        await untilInactive(session)
        #expect(stage(session) == nil)
    }

    /// Responder switched while only a typing-opened realtime session (playback only, no mic) is open: only the old session ends, and transcripts already produced are still persisted as usual;
    /// it does not reopen on the spot, does not request the microphone, and does not show the transition panel; the panel returns to the idle panel, and the connection opens with the new model only when the next sentence is typed.
    @Test func typed_only_switch_ends_without_reopen() async throws {
        let mic = WiringCounter()
        selectRealtime()
        let session = session(tracksSelection: true, grantMicrophone: { mic.count += 1; return true })
        #expect(await session.sendRealtimeTyped("Hello", conversationID: conversationID, host: FakeVoiceChatHost()))
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        while opened.written.isEmpty { await Task.yield() }
        #expect(connection.texts == ["Hello"])
        selectGemini()
        #expect(!session.endForEngineChange(
            in: conversationID, newSelection: opened.selections[conversationID], newModelName: "gemini-3.8-live"
        ))
        await untilInactive(session)
        #expect(session.realtime == nil)
        #expect(realtime.stageLine == nil)
        #expect(!session.isEngineSwitching(in: conversationID))
        #expect(stage(session) is RealtimeIdleStageSurface)
        #expect(opened.written.map(\.text) == ["Hello"])
        #expect(opened.endpoints.count == 1)
        #expect(mic.count == 0)
        #expect(probe.announcements.isEmpty)
    }

    /// Home → chat page handoff: the conversation id changes from nil to a new conversation, and the selection moving with the conversation does not count as an engine switch; no transition panel and no end.
    @Test func home_handoff_not_engine_change() async throws {
        selectRealtime()
        let session = session(tracksSelection: true)
        session.hostAppeared(nil)
        #expect(await startHome(session))
        let realtime = try await listening(session)
        opened.onCreate = { [weak session] id in
            session?.hostDisappeared(nil)
            session?.endIfHostGone()
            session?.hostAppeared(id)
        }
        speakUser("Hello from home", item: "u1")
        while opened.written.isEmpty { await Task.yield() }
        await until { session.conversationID != nil }
        let created = try #require(opened.created.first)
        let moved = opened.selections[nil]
        opened.selections[created] = moved
        #expect(!session.endForEngineChange(in: created, newSelection: moved, newModelName: moved?.model))
        #expect(!session.isEngineSwitching(in: created))
        #expect(!session.isEngineSwitching(in: nil))
        #expect(session.isActive)
        #expect(session.realtime === realtime)
        let shown = session.stageSurface(in: created, realtimeSelected: true, onIdleTap: {})
        #expect(shown.map { ObjectIdentifier($0) } == ObjectIdentifier(realtime))
        #expect(shown?.stageLine != nil)
        if case .notice = shown?.stageLine { Issue.record("handoff must not show the switched notice") }
        session.end(.user)
        await untilInactive(session)
    }

    /// The realtime session only needs the microphone: realtime can still open when system dictation + speech recognition is denied (the dictation engine's preparation fails).
    @Test func realtime_entry_requests_microphone_only() async throws {
        selectRealtime()
        let session = session(listening: nil)
        #expect(await start(session))
        #expect(session.isRealtime)
        _ = try await listening(session)
        #expect(opened.endpoints.count == 1)
    }

    /// A cold catalog fetch never returns: give up within the limit and report unknown in the panel (no cascade), with no settings change and no connection.
    @Test func catalog_refresh_that_never_returns_fails_with_unknown() async {
        let hang = NeverReturningCall()
        defer { hang.releaseAll() }
        selectRealtime()
        var builder = builder()
        builder.catalog = {
            await hang.hang()
            return Self.catalog()
        }
        builder.catalogLimit = .milliseconds(50)

        let started = ContinuousClock.now
        let start = await builder.prepare(conversationID: conversationID)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(hang.callCount == 1)
        guard case .failed(let failure) = start else {
            Issue.record("expected failed, got \(start)")
            return
        }
        #expect(failure.classification.category == .unknown)
        #expect(failure.classification.actions == [.retry, .switchModel])
        #expect(failure.copyArgValue == "gpt-realtime")
        #expect(opened.selections[conversationID] != nil)
        #expect(opened.endpoints.isEmpty)
    }

    /// The catalog re-fetch carried by parts reads the new catalog from refreshCatalog and answers whether that provider's realtime still includes the selected model; nil when unavailable.
    @Test func parts_catalog_check_reads_refetched_catalog() async throws {
        selectRealtime()
        var builder = builder()
        guard case .realtime(let parts) = await builder.prepare(conversationID: conversationID) else {
            Issue.record("expected realtime")
            return
        }
        let check = try #require(parts.catalogHasModel)
        #expect(try await check() == true)

        builder.refreshCatalog = { VoiceCatalog(schemaVersion: 2, revision: "r2", providers: [:]) }
        guard case .realtime(let removed) = await builder.prepare(conversationID: conversationID) else {
            Issue.record("expected realtime")
            return
        }
        let removedCheck = try #require(removed.catalogHasModel)
        #expect(try await removedCheck() == false)

        builder.refreshCatalog = { nil }
        guard case .realtime(let missing) = await builder.prepare(conversationID: conversationID) else {
            Issue.record("expected realtime")
            return
        }
        let missingCheck = try #require(missing.catalogHasModel)
        #expect(try await missingCheck() == nil)
    }

    /// Catalog unavailable: it is not a connection problem or a missing model in the catalog, so it is classified as unknown rather than network; no settings change and no connection.
    @Test func catalog_unavailable_at_prepare_is_unknown() async {
        selectRealtime()
        var builder = builder()
        builder.catalog = { nil }
        let start = await builder.prepare(conversationID: conversationID)
        guard case .failed(let failure) = start else {
            Issue.record("expected failed, got \(start)")
            return
        }
        #expect(failure.classification.category == .unknown)
        #expect(failure.classification.actions == [.retry, .switchModel])
        #expect(failure.copyArgValue == "gpt-realtime")
        #expect(opened.selections[conversationID] != nil)
        #expect(opened.endpoints.isEmpty)
    }

    /// Starting a realtime call writes last-used right away: the existing conversation passes its id, home passes nil; the first persisted message does not write it again.
    @Test func realtime_start_records_last_used() async {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        #expect(opened.recordedStarts == [conversationID])
    }

    @Test func home_realtime_start_records_last_used_once() async throws {
        selectRealtime()
        let session = session()
        #expect(await startHome(session))
        #expect(opened.recordedStarts == [nil])
        _ = try await listening(session)
        speakUser("Hello from home", item: "u1")
        while opened.written.isEmpty { await Task.yield() }
        #expect(opened.recordedStarts == [nil])
    }

    @Test func cascade_start_does_not_record_realtime_last_used() async {
        let session = session()
        #expect(await start(session))
        #expect(opened.recordedStarts.isEmpty)
    }

    @Test func no_selection_keeps_cascade() async {
        let session = session()
        #expect(await start(session))
        #expect(!session.isRealtime)
        #expect(session.controller != nil)
        #expect(opened.endpoints.isEmpty)
        #expect(probe.toasts.isEmpty)
    }

    /// The selected connection was deleted → the panel reports model_gone (change model); no cascade, no toast.
    @Test func selected_connection_gone_reports_model_gone_on_stage() async throws {
        selectRealtime(providerID: UUID())
        let session = session()
        #expect(!(await start(session)))
        #expect(!session.isActive)
        #expect(opened.endpoints.isEmpty)
        #expect(probe.toasts.isEmpty)
        let failure = try #require(failedStage(session).failure)
        #expect(failure.classification.category == .modelGone)
        #expect(failure.classification.actions == [.switchModel])
        #expect(VoiceConversationCopy.failure(failure)
            == L10n.format(L10n.tr("%1$@ is no longer available.", table: .voice), "gpt-realtime"))
        // The selection stays in memory and is not rewritten: the next entry still judges by it.
        #expect(opened.selections[conversationID] != nil)
    }

    /// The opening plan cannot be built: there is no handshake signal, so it is classified as unknown and reported in the panel (retry / change model); no cascade, no toast.
    @Test func plan_rejected_reports_failure_on_stage() async throws {
        selectRealtime()
        let session = session(contextWindow: 0)
        #expect(!(await start(session)))
        #expect(!session.isActive)
        #expect(opened.endpoints.isEmpty)
        #expect(probe.toasts.isEmpty)
        let failure = try #require(failedStage(session).failure)
        #expect(failure.classification.category == .unknown)
        #expect(failure.classification.actions == [.retry, .switchModel])
    }

    // MARK: Failure exits within the voice panel

    /// This page's idle panel (after a failed session it carries the failure text and exits); actions are recorded in actions, and taps / retries are counted in taps.
    private func failedStage(
        _ session: VoiceConversationSession,
        taps: WiringCounter = WiringCounter(),
        actions: WiringActions = WiringActions()
    ) throws -> RealtimeIdleStageSurface {
        let surface = session.stageSurface(
            in: conversationID,
            realtimeSelected: true,
            onIdleTap: { taps.count += 1 },
            onFailureAction: { actions.list.append($0) }
        )
        return try #require(surface as? RealtimeIdleStageSurface)
    }

    /// After the handshake is rejected the session collapses, and the voice panel returns to the idle panel with the failure.
    private func handshakeRejected(_ status: Int, _ session: VoiceConversationSession) async {
        connection.continuation.finish(throwing: RealtimeHandshakeError(httpStatus: status))
        await untilInactive(session)
    }

    /// The failure text contains no URL or key.
    private func expectSafeCopy(_ text: String) {
        #expect(!text.contains("sk-realtime"))
        #expect(!text.contains("://"))
        #expect(!text.contains("api.openai.com"))
    }

    @Test func auth_failure_shows_copy_and_open_connection_on_stage() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        await handshakeRejected(401, session)
        let actions = WiringActions()
        let idle = try failedStage(session, actions: actions)
        let failure = try #require(idle.failure)
        #expect(failure.classification.category == .auth)
        let text = VoiceConversationCopy.failure(failure)
        #expect(text == L10n.format(
            L10n.tr("The %1$@ key is invalid or doesn't have realtime voice access.", table: .voice), provider.displayName
        ))
        expectSafeCopy(text)
        #expect(idle.idleHint == nil)
        #expect(VoiceConversationBarContent.failureButtons(failure) == [.openConnection])
        idle.performFailureAction(.openConnection)
        #expect(actions.list == [.openConnection])
        #expect(opened.endpoints.count == 1)
        #expect(probe.toasts.isEmpty)
    }

    @Test func quota_failure_shows_copy_retry_and_switch_model_on_stage() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        await handshakeRejected(429, session)
        let taps = WiringCounter()
        let actions = WiringActions()
        let idle = try failedStage(session, taps: taps, actions: actions)
        let failure = try #require(idle.failure)
        #expect(failure.classification.category == .quota)
        let text = VoiceConversationCopy.failure(failure)
        #expect(text == L10n.format(
            L10n.tr("%1$@ quota is used up, or there were too many requests.", table: .voice), provider.displayName
        ))
        expectSafeCopy(text)
        // Primary action (retry) on the right: buttons from left to right follow buttonCopyKeys.
        #expect(VoiceConversationBarContent.failureButtons(failure) == [.switchModel, .retry])
        #expect(
            VoiceConversationBarContent.failureButtons(failure).compactMap(RealtimeModelPolicy.copyKey(for:))
                == failure.classification.buttonCopyKeys
        )
        // Failure card geometry: 24 corner radius, 40 amber circular background + waveform 19, title 17, button height 40.
        #expect(VoiceConversationBarContent.failureCardRadius == 24)
        #expect(VoiceConversationBarContent.failureIconSize == 40)
        #expect(VoiceConversationBarContent.failureGlyphSize == 19)
        #expect(VoiceConversationBarContent.failureTitleSize == 17)
        #expect(VoiceConversationBarContent.failureButtonHeight == 40)
        // Retry takes the same path as tapping the orb (the page-entry path); changing the model is handed to the page.
        idle.performFailureAction(.retry)
        #expect(taps.count == 1)
        idle.performFailureAction(.switchModel)
        #expect(actions.list == [.switchModel])
        #expect(probe.toasts.isEmpty)
    }

    @Test func model_gone_failure_shows_copy_and_switch_model_on_stage() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        await handshakeRejected(404, session)
        let actions = WiringActions()
        let idle = try failedStage(session, actions: actions)
        let failure = try #require(idle.failure)
        #expect(failure.classification.category == .modelGone)
        let text = VoiceConversationCopy.failure(failure)
        #expect(text == L10n.format(L10n.tr("%1$@ is no longer available.", table: .voice), "gpt-realtime"))
        expectSafeCopy(text)
        #expect(VoiceConversationBarContent.failureButtons(failure) == [.switchModel])
        idle.performFailureAction(.switchModel)
        #expect(actions.list == [.switchModel])
        // No silent model switch: after a failure no cascade opens and no second session opens.
        #expect(session.controller == nil)
        #expect(opened.endpoints.count == 1)
        #expect(probe.toasts.isEmpty)
    }

    /// max_duration: the panel shows "Reached the limit, tap to continue" with no button; tapping the orb = opens a new session with history, and a failure collapses it immediately.
    @Test func max_duration_shows_tap_to_continue_and_tap_reopens_with_history() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        _ = try await listening(session)
        connection.continuation.yield(.sessionEnded(reason: "max_duration"))
        await untilInactive(session)
        var reopening: Task<Bool, Never>?
        let idle = try #require(session.stageSurface(
            in: conversationID,
            realtimeSelected: true,
            onIdleTap: { reopening = Task { await start(session) } }
        ) as? RealtimeIdleStageSurface)
        let failure = try #require(idle.failure)
        #expect(failure.classification.category == .maxDuration)
        #expect(VoiceConversationCopy.failure(failure)
            == L10n.tr("This realtime call reached its length limit. Tap to continue.", table: .voice))
        #expect(VoiceConversationBarContent.failureButtons(failure).isEmpty)
        #expect(probe.toasts.isEmpty)

        idle.tapOrb()
        let task = try #require(reopening)
        #expect(await task.value)
        #expect(session.isRealtime)
        #expect(opened.endpoints.count == 2)
        // The new session's opening plan takes the same conversation's history.
        #expect(opened.inputIDs.suffix(1) == [conversationID])
        #expect(session.realtimeFailure(in: conversationID) == nil)
    }

    /// Selection without disclosure consent: no cascade and no connection; the page shows the disclosure first (it opens only on consent).
    @Test func undisclosed_selection_asks_page_for_disclosure() async {
        selectRealtime(accept: false)
        let session = session()
        var asked: [RealtimeModelSelection] = []
        let started = await session.start(
            origin: .chat,
            conversationID: conversationID,
            host: FakeVoiceChatHost(),
            onNeedsRealtimeDisclosure: { asked.append($0) }
        ) { _, _ in .refused }
        #expect(!started)
        #expect(asked == [opened.selections[conversationID]].compactMap { $0 })
        #expect(asked.first?.model == "gpt-realtime")
        #expect(!session.isActive)
        #expect(opened.endpoints.isEmpty)
        #expect(probe.toasts.isEmpty)
        #expect(opened.selections[conversationID] != nil)
        #expect(session.realtimeFailure(in: conversationID) == nil)
    }

    /// Three exits each call their callback: retry = tap the orb to reopen, go to the connections page with the selected connection, change model opens the picker (non-model_gone does not clear the selection).
    @Test func failureActionsReachPageCallbacks() throws {
        let selection = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        var taps = 0
        var openedConnections: [UUID?] = []
        var pickers = 0
        var clears = 0
        let navigation = RealtimeFailureNavigation(
            openConnection: { openedConnections.append($0) },
            openModelPicker: { pickers += 1 },
            clearRealtimeSelection: { clears += 1 }
        )
        let quota = RealtimeVoiceConversationController.failure(
            category: .quota,
            context: RealtimeFailureContext(providerName: provider.displayName, model: selection.model)
        )
        let idle = RealtimeIdleStageSurface(
            failure: quota,
            onTap: { taps += 1 },
            onFailureAction: { navigation.perform($0, failure: quota, selection: selection) }
        )
        idle.performFailureAction(.retry)
        #expect(taps == 1)
        #expect(openedConnections.isEmpty && pickers == 0)

        idle.performFailureAction(.openConnection)
        #expect(openedConnections == [provider.id])

        idle.performFailureAction(.switchModel)
        #expect(pickers == 1)
        #expect(clears == 0)
        #expect(taps == 1)
    }

    /// model_gone (the catalog has removed the selected model): "Change model" first clears the selection back to a text model, then opens the picker.
    @Test func modelGoneSwitchModelClearsRealtimeSelection() async throws {
        select(RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-gone"), accept: true)
        let session = session(tracksSelection: true)
        #expect(!(await start(session)))
        let selection = try #require(opened.selections[conversationID])
        var pickers = 0
        let store = opened
        let pageID = conversationID
        let navigation = RealtimeFailureNavigation(
            openConnection: { _ in Issue.record("model_gone has no open-connection action") },
            openModelPicker: { pickers += 1 },
            clearRealtimeSelection: { store.selections[pageID] = nil }
        )
        let failure = try #require(session.realtimeFailure(in: conversationID, selection: selection))
        let idle = try #require(session.stageSurface(
            in: conversationID,
            realtimeSelected: true,
            realtimeSelection: selection,
            onIdleTap: { Issue.record("switch model must not reopen") },
            onFailureAction: { navigation.perform($0, failure: failure, selection: selection) }
        ) as? RealtimeIdleStageSurface)
        #expect(idle.failure?.classification.category == .modelGone)
        #expect(VoiceConversationBarContent.failureButtons(failure).count == 1)

        idle.performFailureAction(.switchModel)
        #expect(opened.selections[conversationID] == nil)
        #expect(pickers == 1)
        #expect(opened.endpoints.isEmpty)
    }

    /// After changing the selection (another realtime model or a text model), the previous session's in-panel failure is no longer shown; it does not reappear on other models before switching back to the original model.
    @Test func changingSelectionHidesPreviousFailure() async throws {
        select(RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-gone"), accept: true)
        let session = session(tracksSelection: true)
        #expect(!(await start(session)))
        let failed = try #require(opened.selections[conversationID])
        #expect(session.realtimeFailure(in: conversationID, selection: failed) != nil)

        let other = RealtimeModelSelection(providerID: geminiProvider.id, providerKind: .gemini, model: "gemini-3.8-live")
        #expect(session.realtimeFailure(in: conversationID, selection: other) == nil)
        #expect(session.realtimeFailure(in: conversationID, selection: nil) == nil)
        let idle = try #require(session.stageSurface(
            in: conversationID,
            realtimeSelected: true,
            realtimeSelection: other,
            onIdleTap: {}
        ) as? RealtimeIdleStageSurface)
        #expect(idle.failure == nil)
    }

    @Test func assistant_attributed_to_realtime_model() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        await waitStatus(realtime, .listening)
        for event: RealtimeSessionEvent in [
            .userSpeechStarted(itemId: "u1"),
            .userSpeechStopped(itemId: "u1"),
            .userTranscript(itemId: "u1", text: "Hello there", final: true),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Hi!"),
        ] {
            connection.continuation.yield(event)
        }
        while opened.written.count < 2 { await Task.yield() }
        let user = opened.written[0]
        let assistant = opened.written[1]
        #expect(user.role == .user)
        #expect(user.text == "Hello there")
        #expect(assistant.role == .assistant)
        #expect(assistant.text == "Hi!")
        #expect(assistant.state == .delivered)
        #expect(assistant.providerID == provider.id)
        #expect(assistant.providerKind == .openAI)
        #expect(assistant.providerName == provider.displayName)
        #expect(assistant.modelID == "gpt-realtime")
        #expect(assistant.modelName == "gpt-realtime")
        #expect(assistant.estimatedCost == 0)
        #expect(try #require(assistant.createdAt) > (try #require(user.createdAt)))

        session.end(.user)
        await untilInactive(session)
    }

    /// An error-ended session shows no toast; the failure stays in the voice panel.
    @Test func realtimeErrorShowsFailureOnStage() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let realtime = try await listening(session)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await untilInactive(session)
        realtime.end()
        #expect(probe.toasts.isEmpty)
        #expect(session.realtimeFailure(in: conversationID) != nil)
    }

    /// While VoiceOver announces the status text the realtime uplink pauses and resumes when the announcement ends; this does not count as muting.
    @Test func statusAnnouncementPausesRealtimeUplink() async throws {
        selectRealtime()
        probe.voiceOver = true
        let announced = WiringSignal()
        let listeningText = VoiceConversationCopy.status(.listening)
        let session = session(onAnnounce: { if $0 == listeningText { announced.fire() } })
        #expect(await start(session))
        let realtime = try await listening(session)
        await announced.wait()
        #expect(probe.announcements.last == VoiceConversationCopy.status(.listening))
        #expect(realtime.statusKey == .listening)
        let frame = Data(repeating: 1, count: 480)
        let onFrame = try #require(audio.onFrame)
        onFrame(frame)
        #expect(connection.sent.isEmpty)

        session.announcementFinished()
        onFrame(frame)
        #expect(connection.sent == [frame])
        #expect(probe.toasts.isEmpty)
    }

    /// Before opening the connection a realtime session takes the conversation lease and releases it when it ends, after the audio has stopped; the next one is a new generation.
    @Test func realtime_claims_and_releases_audio_session() async throws {
        selectRealtime()
        let owner = VoiceAudioSessionOwner()
        let session = session(audioSession: owner)
        #expect(await start(session))
        let first = try #require(owner.current)
        #expect(first.client == .conversation)
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        await waitStatus(realtime, .listening)
        #expect(audio.startCount == 1)
        #expect(owner.current == first)

        session.end(.user)
        await owner.waitForConversationRelease()
        #expect(!session.isActive)
        #expect(audio.stopCount == 1)
        #expect(owner.current == nil)
        #expect(!owner.release(first))

        #expect(await start(session))
        let second = try #require(owner.current)
        #expect(second.client == .conversation)
        #expect(second.generation == first.generation + 1)
    }

    /// If the conversation has been taken over by a new one before the end, the realtime engine's teardown does not deactivate the new session.
    @Test func realtime_staleLease_doesNotDeactivateNewSession() async throws {
        selectRealtime()
        let owner = VoiceAudioSessionOwner()
        let gated = LeaseGatedAudios()
        let session = session(audioSession: owner, wrapAudio: { inner in
            let audio = LeaseGatedRealtimeAudio(inner, owner: owner)
            gated.items.append(audio)
            return audio
        })
        #expect(await start(session))
        let audioIO = try #require(gated.items.last)
        let lease = try #require(owner.current)
        #expect(audioIO.sessionLease == lease)
        _ = try await listening(session)

        let fresh = owner.claim(.conversation)
        session.end(.user)
        await untilInactive(session)
        #expect(!session.isActive)
        #expect(audio.stopCount == 1)
        #expect(audioIO.deactivations == 0)
        #expect(owner.current == fresh)
    }

    /// The control for the above: when the lease is still current, teardown deactivates once and then releases.
    @Test func realtime_currentLease_deactivatesOnTeardown() async throws {
        selectRealtime()
        let owner = VoiceAudioSessionOwner()
        let gated = LeaseGatedAudios()
        let session = session(audioSession: owner, wrapAudio: { inner in
            let audio = LeaseGatedRealtimeAudio(inner, owner: owner)
            gated.items.append(audio)
            return audio
        })
        #expect(await start(session))
        let audioIO = try #require(gated.items.last)
        _ = try await listening(session)

        session.end(.user)
        await owner.waitForConversationRelease()
        #expect(audio.stopCount == 1)
        #expect(audioIO.deactivations == 1)
        #expect(owner.current == nil)
    }

    /// Ending while the preparing session is suspended → after release no engine starts, and the inner audio is stopped once.
    @Test func end_during_prepare_session_skips_engine_and_stops_inner() async throws {
        selectRealtime()
        var holding: PrepareHoldingRealtimeAudio?
        let session = session(wrapAudio: { inner in
            let audio = PrepareHoldingRealtimeAudio(inner)
            holding = audio
            return audio
        })
        #expect(await start(session))
        let held = try #require(holding)
        connection.continuation.yield(.ready)
        await held.entered.wait()

        session.end(.user)
        await untilInactive(session)
        held.release.resume()
        await held.settled.wait()
        #expect(audio.startCount == 0)
        #expect(audio.stopCount == 1)
    }

    /// Ending while the opening (makeRealtime) is suspended → returning starts no conversation, and the connection closes.
    @Test func end_during_make_realtime_skips_conversation_and_closes_connection() async throws {
        selectRealtime()
        let entered = OnceContinuation()
        let release = OnceContinuation()
        let session = session(beforeMakeRealtime: {
            entered.resume()
            await release.wait()
        })
        let starting = Task { await start(session) }
        await entered.wait()

        session.end(.user)
        release.resume()
        #expect(await starting.value == false)
        #expect(session.realtime == nil)
        #expect(!session.isActive)
        #expect(connection.closeCount == 1)
        #expect(audio.startCount == 0)
    }

    /// Entering realtime while reading aloud → stop reading before taking the session lease.
    @Test func realtime_start_stops_read_aloud_before_claiming_session() async throws {
        selectRealtime()
        let owner = VoiceAudioSessionOwner()
        var leaseHeldAtStop: [Bool] = []
        let session = session(audioSession: owner, stopReadAloud: {
            leaseHeldAtStop.append(owner.current != nil)
        })
        #expect(await start(session))
        #expect(leaseHeldAtStop == [false])
        #expect(owner.current != nil)
    }

    @Test func wiringSignal_twoConcurrentWaiters_bothResume() async {
        let bothQueued = OnceContinuation()
        let signal = WiringSignal(onQueued: { if $0 == 2 { bothQueued.resume() } })
        let first = Task { await signal.wait() }
        let second = Task { await signal.wait() }
        await bothQueued.wait()
        signal.fire()
        await first.value
        await second.value
    }

    @Test func until_cancelled_recordsIssue() async {
        await withKnownIssue {
            let waiting = Task { await self.until { false } }
            waiting.cancel()
            await waiting.value
        }
    }

    /// Going to background / returning to foreground does not disconnect the realtime session (UIBackgroundModes audio keeps the foreground-opened session alive).
    @Test func background_keeps_realtime() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let realtime = try await listening(session)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await Task.yield()
        #expect(session.isActive)
        #expect(session.realtime === realtime)
        #expect(realtime.statusKey == .listening)
        #expect(connection.closeCount == 0)

        speakUser("Still there?", item: "u1")
        while opened.written.isEmpty { await Task.yield() }
        #expect(opened.written.map(\.text) == ["Still there?"])

        session.end(.user)
        await untilInactive(session)
    }

    /// In the background, 120 s without speech still ends the session automatically (end_reason=idle).
    @Test func background_idle_still_ends() async throws {
        selectRealtime()
        let clock = Fakes.ManualClock()
        let session = session(clock: clock)
        #expect(await start(session))
        _ = try await listening(session)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let idle = RealtimeConversationLogic.Constants.idleEndMs
        clock.advance(idle - 1)
        #expect(session.isActive)
        clock.advance(1)
        await untilInactive(session)
        #expect(connection.closeCount >= 1)
    }

    /// An incoming call / Siri (audio session interruption) still ends the session, going through systemInterruption (end_reason=interruption).
    @Test func phone_call_interruption_still_ends() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        _ = try await listening(session)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(session.isActive)
        let onInterruption = try #require(audio.onInterruption)
        onInterruption()
        await untilInactive(session)
        #expect(connection.closeCount >= 1)
    }

    // MARK: Home

    @Test func home_realtime_creates_conversation_on_first_persist() async throws {
        selectRealtime()
        let session = session()
        #expect(await startHome(session))
        #expect(session.isRealtime)
        #expect(opened.inputIDs == [nil])
        #expect(session.conversationID == nil)
        _ = try await listening(session)
        #expect(opened.created.isEmpty)

        speakUser("Hello from home", item: "u1")
        while opened.written.isEmpty { await Task.yield() }
        let created = try #require(opened.created.first)
        #expect(opened.created.count == 1)
        #expect(opened.writtenIDs == [created])
        #expect(opened.written.first?.text == "Hello from home")
        #expect(session.conversationID == created)
        #expect(session.isPresented(in: created))
        #expect(!session.isPresented(in: nil))
    }

    @Test func home_realtime_no_persist_leaves_no_conversation() async throws {
        selectRealtime()
        let session = session()
        #expect(await startHome(session))
        #expect(session.isRealtime)
        _ = try await listening(session)

        session.end(.user)
        await untilInactive(session)
        #expect(!session.isActive)
        #expect(opened.created.isEmpty)
        #expect(opened.written.isEmpty)
        #expect(session.conversationID == nil)
        #expect(session.lastEnd?.conversationID == nil)
    }

    @Test func home_realtime_continues_after_handoff() async throws {
        selectRealtime()
        let session = session()
        session.hostAppeared(nil)
        #expect(await startHome(session))
        _ = try await listening(session)
        // The home page leaves and the chat page appears while the conversation is being created: the handoff does not end it as a back.
        opened.onCreate = { [weak session] id in
            session?.hostDisappeared(nil)
            session?.endIfHostGone()
            session?.hostAppeared(id)
        }

        speakUser("Hello from home", item: "u1")
        while opened.written.isEmpty { await Task.yield() }
        await until { session.conversationID != nil }
        let created = try #require(opened.created.first)
        #expect(session.isActive)
        #expect(session.isRealtime)
        #expect(session.conversationID == created)

        connection.continuation.yield(.assistantTurnDone(itemId: "a1", status: .completed, text: "Hi!"))
        while opened.written.count < 2 { await Task.yield() }
        #expect(opened.created == [created])
        #expect(opened.writtenIDs == [created, created])
        #expect(opened.written.last?.role == .assistant)

        session.end(.user)
        await untilInactive(session)
        #expect(session.lastEnd?.conversationID == created)
    }
    // MARK: Home realtime: the first turn event creates the conversation (realtime-conversation rules.host)

    /// A real AppState with a sendable model (the home page creates the conversation using the pill's current model).
    private static func homeAppState() -> AppState {
        let state = AppState(seedDemoData: false, sessionUID: "realtime-wiring-home-\(UUID().uuidString)")
        let chatProvider = TestFactories.makeProvider(
            kind: .openAI,
            models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)]
        )
        state.providers = [chatProvider]
        state.setActiveModel(providerID: chatProvider.id, modelID: "gpt-4o")
        return state
    }

    /// The conversation id of the chat page the navigation currently shows (top of the compact stack / right column of regular).
    private static func presentedChat(_ state: AppState) -> UUID? {
        if case .chat(let id) = state.navigation.path.last { return id }
        return state.navigation.chatDetail.conversationID
    }

    /// The conversation the navigation shows each time statusKey is published: decides whether presentChat comes before speaking.
    final class StatusTrail {
        var entries: [(key: VoiceConversationLogic.StatusKey?, presented: UUID?)] = []
    }

    private func watch(_ realtime: RealtimeVoiceConversationController, _ state: AppState, into trail: StatusTrail) -> AnyCancellable {
        realtime.$statusKey.sink { key in trail.entries.append((key, Self.presentedChat(state))) }
    }

    private static let assistantAudio = RealtimeSessionEvent.assistantAudio(
        itemId: "a1", contentIndex: 0, base64: "AAAA", sampleRateHz: 24_000
    )

    private func yield(_ events: [RealtimeSessionEvent]) {
        events.forEach { connection.continuation.yield($0) }
    }

    private static func messages(_ state: AppState, _ id: UUID) -> [ChatMessage] {
        state.conversation(for: id)?.messages ?? []
    }

    /// The user transcript is missing: assistant audio arrives first, so the conversation is created and the chat page opened, speaking is published only on the chat page, and only the assistant message is persisted.
    @Test func home_realtime_assistant_first_moves_to_chat_before_speaking() async throws {
        selectRealtime()
        let state = Self.homeAppState()
        let session = session(appState: state)
        #expect(await startHome(session))
        let realtime = try await listening(session)
        #expect(Self.presentedChat(state) == nil)
        #expect(state.conversations.isEmpty)
        let trail = StatusTrail()
        let watching = watch(realtime, state, into: trail)
        defer { watching.cancel() }

        yield([.userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio])
        await waitStatus(realtime, .speaking)
        let created = try #require(session.conversationID)
        #expect(state.conversations.map(\.id) == [created])
        #expect(Self.presentedChat(state) == created)
        let speaking = try #require(trail.entries.first { $0.key == .speaking })
        #expect(speaking.presented == created)
        #expect(trail.entries.filter { $0.presented == nil }.allSatisfy { $0.key != .speaking })

        // The user transcript never arrives: the reply is held back and released by the end sequence (only the assistant is persisted); afterwards it does not count as an empty conversation and is not deleted.
        yield([.assistantTurnDone(itemId: "a1", status: .completed, text: "Sure.")])
        // Back to listening after playback = turnDone has been handled (the reply was held back).
        audio.finishPlayback()
        await waitStatus(realtime, .listening)
        #expect(Self.messages(state, created).isEmpty)

        session.end(.user)
        #expect(!session.isActive)
        #expect(Self.messages(state, created).map(\.role) == [.assistant])
        #expect(Self.messages(state, created).map(\.text) == ["Sure."])
        #expect(state.conversation(for: created) != nil)
        #expect(state.conversations.count == 1)
    }

    /// Assistant audio arrives first and the user transcript later (inside the hold window): the conversation is created and the chat page entered before speaking; the persisted user message comes first and the assistant second, with no duplicates;
    /// by the time end returns it has been dismissed, and opening another conversation afterwards succeeds.
    @Test func home_realtime_full_path_order_end_reopen() async throws {
        selectRealtime()
        let state = Self.homeAppState()
        let session = session(appState: state)
        #expect(await startHome(session))
        let realtime = try await listening(session)
        let trail = StatusTrail()
        let watching = watch(realtime, state, into: trail)
        defer { watching.cancel() }

        yield([
            .userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio,
            .assistantTranscript(itemId: "a1", text: "Sure, here it is.", final: false),
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Sure, here it is."),
        ])
        await waitStatus(realtime, .speaking)
        // The player finishes this downlink segment (a completed reply is released only after playback finishes).
        audio.finishPlayback()
        let created = try #require(session.conversationID)
        #expect(Self.presentedChat(state) == created)
        #expect(trail.entries.first { $0.key == .speaking }?.presented == created)
        // The reply is held back, waiting for the user transcript.
        #expect(Self.messages(state, created).isEmpty)

        yield([.userTranscript(itemId: "u1", text: "Tell me a joke", final: true)])
        while Self.messages(state, created).count < 2 { await Task.yield() }
        let messages = Self.messages(state, created)
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.map(\.text) == ["Tell me a joke", "Sure, here it is."])
        #expect(state.conversations.map(\.id) == [created])
        #expect(session.conversationID == created)

        session.end(.user)
        #expect(!session.isActive)
        #expect(!session.isPresented(in: created))
        #expect(state.conversation(for: created) != nil)
        #expect(Self.messages(state, created).count == 2)

        let other = try #require(state.createConversationForRealtimeVoice())
        #expect(other != created)
        #expect(Self.presentedChat(state) == other)
    }

    /// When an interjection interrupts, what gets persisted is the prefix the player has actually played so far, followed by the user's interjected words.
    @Test func home_realtime_barge_in_persists_played_prefix() async throws {
        selectRealtime()
        let state = Self.homeAppState()
        let session = session(appState: state)
        #expect(await startHome(session))
        let realtime = try await listening(session)
        let reply = "one two three four five six seven eight"

        yield([
            .userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"),
            .userTranscript(itemId: "u1", text: "Count please", final: true),
            .assistantTranscript(itemId: "a1", text: reply, final: false),
            .assistantAudio(itemId: "a1", contentIndex: 0, base64: Data(count: 48_000).base64EncodedString(), sampleRateHz: 24_000),
        ])
        await waitStatus(realtime, .speaking)
        let created = try #require(session.conversationID)
        audio.playedByItem["a1"] = 500
        yield([.userSpeechStarted(itemId: "u2"), .userTranscript(itemId: "u2", text: "Stop", final: true)])
        while Self.messages(state, created).count < 3 { await Task.yield() }
        let prefix = RealtimeConversationLogic.revealPrefix(text: reply, playedMs: 500, audioSamples: 24_000, sampleRateHz: 24_000)
        #expect(!prefix.isEmpty && prefix != reply)
        #expect(Self.messages(state, created).map(\.text) == ["Count please", prefix, "Stop"])
        #expect(Self.messages(state, created).map(\.role) == [.user, .assistant, .user])
    }

    /// The session was created but nothing was persisted before it ended: delete this empty session.
    @Test func home_realtime_empty_session_deletes_conversation() async throws {
        selectRealtime()
        let state = Self.homeAppState()
        let session = session(appState: state)
        #expect(await startHome(session))
        let realtime = try await listening(session)

        yield([.userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio])
        await waitStatus(realtime, .speaking)
        let created = try #require(session.conversationID)
        #expect(state.conversation(for: created) != nil)

        #expect(await endAwaitingEmptyDelete(session, state) == true)
        #expect(!session.isActive)
        #expect(state.conversation(for: created) == nil)
        #expect(state.conversations.isEmpty)
        // A deleted conversation id is not kept in the session: going back to the conversation later does not open a conversation that no longer exists.
        #expect(session.conversationID == nil)
        #expect(session.lastEnd?.conversationID == nil)
        #expect(session.lastEnd != nil)
    }

    /// Entering from the chat page's compose draft: the first turn event does not create a conversation, ending with zero persisted messages deletes no conversation, and the draft instruction is not lost.
    @Test func home_realtime_chat_draft_entry_never_deletes() async throws {
        selectRealtime()
        let state = Self.homeAppState()
        state.pendingDraftInstructions = "Answer in French."
        let session = session(appState: state)
        #expect(await session.start(origin: .chat, conversationID: nil, host: FakeVoiceChatHost()) { _, _ in .refused })
        let realtime = try await listening(session)

        yield([.userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio])
        await waitStatus(realtime, .speaking)
        #expect(state.conversations.isEmpty)
        #expect(session.conversationID == nil)

        session.end(.user)
        #expect(!session.isActive)
        #expect(state.conversations.isEmpty)
        #expect(state.pendingDraftInstructions == "Answer in French.")
        #expect(session.lastEnd?.conversationID == nil)
    }

    /// The home page tries to create the conversation only once; if it cannot, the session ends with the same error as a failed first send of the home cascade, the home bar never reaches speaking, and nothing is persisted.
    @Test func home_realtime_creation_failure_ends_with_error_not_speaking() async throws {
        selectRealtime()
        opened.createFails = true
        let session = session()
        #expect(await startHome(session))
        let realtime = try await listening(session)
        var keys: [VoiceConversationLogic.StatusKey?] = []
        let watching = realtime.$statusKey.sink { keys.append($0) }
        defer { watching.cancel() }

        yield([
            .userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio,
            .assistantTurnDone(itemId: "a1", status: .completed, text: "Sure."),
            .userTranscript(itemId: "u1", text: "Hello", final: true),
        ])
        await untilInactive(session)
        #expect(opened.createAttempts == 1)
        #expect(opened.written.isEmpty)
        #expect(!keys.contains(.speaking))
        #expect(probe.toasts.isEmpty)
        #expect(session.realtimeFailure(in: nil)?.classification.category == .unknown)
        #expect(session.conversationID == nil)
        #expect(session.lastEnd?.conversationID == nil)
    }

    /// Three conditions for deleting an empty conversation: created by this sink, this sink persisted nothing, and the database has no messages either; if messages were written elsewhere it is not deleted.
    @Test func home_realtime_empty_delete_requires_no_stored_messages() async throws {
        selectRealtime()
        let state = Self.homeAppState()
        let session = session(appState: state)
        #expect(await startHome(session))
        let realtime = try await listening(session)

        yield([.userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio])
        await waitStatus(realtime, .speaking)
        let created = try #require(session.conversationID)
        // During the call something elsewhere (typing / another device) wrote into this conversation.
        state.chatManager.appendCompletedTextMessage(
            TestFactories.makeMessage(role: .user, text: "Typed meanwhile"), in: created
        )

        session.end(.user)
        #expect(!session.isActive)
        #expect(state.conversation(for: created) != nil)
        // The database still has the conversation and that message (re-read after the write queue has drained).
        #expect(try Self.persisted(state, created) == ["user: Typed meanwhile"])
        #expect(session.conversationID == created)
        #expect(session.lastEnd?.conversationID == created)
    }

    /// After the empty conversation is deleted, back on home: the chat page no longer shows the deleted conversation.
    @Test func home_realtime_empty_delete_returns_home() async throws {
        selectRealtime()
        let state = Self.homeAppState()
        let session = session(appState: state)
        #expect(await startHome(session))
        let realtime = try await listening(session)

        yield([.userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio])
        await waitStatus(realtime, .speaking)
        let created = try #require(session.conversationID)
        #expect(Self.presentedChat(state) == created)

        #expect(await endAwaitingEmptyDelete(session, state) == true)
        #expect(state.conversation(for: created) == nil)
        #expect(Self.presentedChat(state) == nil)
        #expect(!state.navigation.path.contains(.chat(conversationID: created)))
    }

    /// An empty-conversation deletion racing with a new message: in neither order is a tombstone recorded for a conversation with messages, and no message is lost:
    /// a write through the production send path after it was removed from memory is rejected (the empty conversation is still deleted); if the send arrives first, memory is non-empty, nothing is deleted and nothing is queued.
    @Test func home_realtime_empty_delete_races_new_message_keeps_it() async throws {
        let state = Self.homeAppState()
        let (session, created) = try await homeSpeaking(state)
        var removedInSameTurn = false
        var sendAccepted = true
        let deleted = await endAwaitingEmptyDelete(session, state) {
            // Already removed from memory within the same main-thread turn: the send cannot find this conversation, so it does not write into the row that is about to be deleted.
            removedInSameTurn = state.conversation(for: created) == nil
            sendAccepted = state.chatManager.appendCompletedTextMessage(
                TestFactories.makeMessage(role: .user, text: "Sent after removal"), in: created
            )
        }
        #expect(deleted)
        #expect(removedInSameTurn)
        #expect(!sendAccepted)
        let stored = try state.conversationRuntimeBridge.fetchConversationProjections(
            ids: [created], uid: state.sessionPartitionUID, hydrateFilePayloads: false
        )
        #expect(stored.isEmpty)
        #expect(session.conversationID == nil)

        // The send arrives first: memory already has a message, and the deletion queues nothing.
        let other = try #require(state.createConversationForRealtimeVoice())
        #expect(state.chatManager.appendCompletedTextMessage(
            TestFactories.makeMessage(role: .user, text: "Sent first"), in: other
        ))
        let kept = await withCheckedContinuation { continuation in
            state.deleteConversationIfEmpty(id: other) { continuation.resume(returning: $0) }
        }
        #expect(kept == false)
        #expect(Self.messages(state, other).map(\.text) == ["Sent first"])
        #expect(try Self.persisted(state, other) == ["user: Sent first"])
        #expect(Self.presentedChat(state) == other)
        #expect(try Self.tombstones(state, other) == Tombstones(journaled: false))
    }

    /// Memory is empty while the database has messages (synced back in): nothing is deleted or tombstoned inside the transaction, and the conversation is read back into memory from the database.
    @Test func home_realtime_empty_delete_db_has_messages_no_tombstone() async throws {
        let state = Self.homeAppState()
        let (session, created) = try await homeSpeaking(state)
        state.flushConversationPersistQueue()
        var backfilled = try #require(state.conversation(for: created))
        backfilled.messages = [TestFactories.makeMessage(role: .user, text: "Synced in")]
        try state.conversationRuntimeBridge.upsertConversationWithoutReadback(
            backfilled, uid: state.sessionPartitionUID, deletingMessageIDs: []
        )

        #expect(await endAwaitingEmptyDelete(session, state) == false)
        #expect(try Self.persisted(state, created) == ["user: Synced in"])
        #expect(Self.messages(state, created).map(\.text) == ["Synced in"])
        #expect(try Self.tombstones(state, created) == Tombstones(journaled: false))
    }

    private struct Tombstones: Equatable {
        let journaled: Bool
    }

    private static func tombstones(_ state: AppState, _ id: UUID) throws -> Tombstones {
        state.flushConversationPersistQueue()
        let bridge = state.conversationRuntimeBridge
        let uid = state.sessionPartitionUID
        return Tombstones(
            journaled: try bridge.deletedConversationIDs(uid: uid).contains(id)
        )
    }

    /// The end draft of deleting an empty conversation on home: the chat page (the deleted conversation) and home each receive the current delivery, and in total it is received only once across the deletion.
    @Test func home_realtime_end_draft_delivered_once() async throws {
        let state = Self.homeAppState()
        let (session, created) = try await homeSpeaking(state)
        let realtime = try #require(session.realtime)
        let received = realtime.eventsReceivedForTesting
        yield([.userTranscript(itemId: "u2", text: "Half said", final: false)])
        while realtime.eventsReceivedForTesting <= received { await Task.yield() }

        var delivered: [String] = []
        // The chat page (that conversation) and home each receive the current delivery once.
        let offer = { (end: VoiceConversationSession.EndDelivery?) in
            guard let end else { return }
            for host in [created, nil] as [UUID?] {
                if let draft = session.consumeEndDraft(end, host: host) { delivered.append(draft) }
            }
        }
        let deleted = await withCheckedContinuation { continuation in
            state._testingAfterEmptyConversationDelete = { _, deleted in
                state._testingAfterEmptyConversationDelete = nil
                continuation.resume(returning: deleted)
            }
            session.end(.user)
            offer(session.lastEnd)
        }
        #expect(deleted == true)
        #expect(session.lastEnd?.conversationID == nil)
        offer(session.lastEnd)
        #expect(delivered == ["Half said"])
    }

    /// End the conversation and wait until the home empty-conversation deletion is done (after the AppState delete callback); returns whether it was really deleted.
    private func endAwaitingEmptyDelete(
        _ session: VoiceConversationSession, _ state: AppState, afterEnd: () -> Void = {}
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            state._testingAfterEmptyConversationDelete = { _, deleted in
                state._testingAfterEmptyConversationDelete = nil
                continuation.resume(returning: deleted)
            }
            session.end(.user)
            afterEnd()
        }
    }

    /// Home realtime creates the conversation, assistantAudio reaches speaking; returns the created conversation id.
    private func homeSpeaking(_ state: AppState) async throws -> (VoiceConversationSession, UUID) {
        selectRealtime()
        let session = session(appState: state)
        #expect(await startHome(session))
        let realtime = try await listening(session)
        yield([.userSpeechStarted(itemId: "u1"), .userSpeechStopped(itemId: "u1"), Self.assistantAudio])
        await waitStatus(realtime, .speaking)
        return (session, try #require(session.conversationID))
    }

    /// A conversation upsert (rename) queued just before the end sits ahead of the deletion: the deletion runs inside the write queue, so the database is not written back into this empty conversation.
    @Test func home_realtime_empty_delete_after_queued_upsert_not_resurrected() async throws {
        let state = Self.homeAppState()
        let (session, created) = try await homeSpeaking(state)
        state.renameConversation(id: created, newTitle: "Renamed")

        #expect(await endAwaitingEmptyDelete(session, state) == true)
        state.flushConversationPersistQueue()
        let stored = try state.conversationRuntimeBridge.fetchConversationProjections(
            ids: [created], uid: state.sessionPartitionUID, hydrateFilePayloads: false
        )
        #expect(stored.isEmpty)
        #expect(state.conversation(for: created) == nil)
        #expect(session.conversationID == nil)
    }

    /// At the end the database no longer has this conversation (deleted elsewhere): nothing is deleted from the database, memory is removed as usual, and we go back to home.
    @Test func home_realtime_empty_delete_db_row_missing_still_leaves_home() async throws {
        let state = Self.homeAppState()
        let (session, created) = try await homeSpeaking(state)
        state.flushConversationPersistQueue()
        try state.conversationRuntimeBridge.deleteConversation(id: created, uid: state.sessionPartitionUID)

        #expect(await endAwaitingEmptyDelete(session, state) == false)
        // Memory is removed first and we go back to home; the database does not have it either, so it is not read back.
        #expect(state.conversation(for: created) == nil)
        #expect(Self.presentedChat(state) == nil)
        #expect(session.conversationID == nil)
    }

    /// The delete write fails: memory was already removed and we went back to home; the conversation in the database was not deleted and no tombstone is recorded, and it is read back into memory from the database.
    @Test func home_realtime_empty_delete_db_failure_restores_from_store_no_tombstone() async throws {
        let state = Self.homeAppState()
        let (session, created) = try await homeSpeaking(state)
        state._testingEmptyConversationDeleteFailure = CocoaError(.fileWriteUnknown)

        #expect(await endAwaitingEmptyDelete(session, state) == false)
        #expect(state.conversation(for: created) != nil)
        #expect(Self.presentedChat(state) == nil)
        #expect(session.conversationID == nil)
        #expect(try Self.tombstones(state, created) == Tombstones(journaled: false))
    }

    /// By the time the deletion completes we have moved to another conversation page: the empty conversation is deleted but we stay on the current page and do not go back to home.
    @Test func home_realtime_empty_delete_not_on_that_chat_stays() async throws {
        let state = Self.homeAppState()
        let (session, created) = try await homeSpeaking(state)
        let other = UUID()
        state.navigation.presentChat(conversationID: other)
        #expect(Self.presentedChat(state) == other)

        #expect(await endAwaitingEmptyDelete(session, state) == true)
        #expect(state.conversation(for: created) == nil)
        #expect(Self.presentedChat(state) == other)
    }

    // MARK: Replaying real recordings (shared/voice-contracts/recordings/gemini-live-home-two-turn.v1.json)

    private static func recording(_ name: String = "gemini-live-home-two-turn.v1.json") throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/voice-contracts/recordings/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// (role, text) of the fixture's expectedMessages.
    private static func expectedMessages(_ recording: [String: Any]) throws -> [String] {
        let expected = try #require(recording["expectedMessages"] as? [[String: Any]])
        return expected.map { "\($0["role"] as? String ?? ""): \($0["text"] as? String ?? "")" }
    }

    private static func stored(_ state: AppState, _ id: UUID) -> [String] {
        messages(state, id).map { "\($0.role == .user ? "user" : "assistant"): \($0.text)" }
    }

    /// After the background write queue has drained, re-read from the database (not looking at the in-memory projection).
    private static func persisted(_ state: AppState, _ id: UUID) throws -> [String] {
        state.flushConversationPersistQueue()
        let fetched = try #require(try state.conversationRuntimeBridge.fetchConversationProjections(
            ids: [id], uid: state.sessionPartitionUID, hydrateFilePayloads: false
        ).first)
        return fetched.messages.map { "\($0.role == .user ? "user" : "assistant"): \($0.text)" }
    }

    /// {"audioBytes": n} is restored to the base64 of n bytes of silent PCM.
    private static func restoreAudio(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            if object.count == 1, let bytes = object["audioBytes"] as? Int { return Data(count: bytes).base64EncodedString() }
            return object.mapValues(restoreAudio)
        }
        if let array = value as? [Any] { return array.map(restoreAudio) }
        return value
    }

    /// Advance ManualClock by ms and push the server messages one by one; after each one, wait for the controller to finish handling the event it maps to (counted by the same production mapper) before pushing the next.
    /// After turnComplete is handled the player callback reports playback finished (in the recording the reply audio had already finished before turnComplete). after(i): after the i-th has been handled.
    private func replay(
        _ entries: [[String: Any]],
        socket: WiringGeminiSocket,
        clock: Fakes.ManualClock,
        realtime: RealtimeVoiceConversationController,
        after: (Int) throws -> Void = { _ in }
    ) async throws {
        // Ideal player: each item reports the played ms of received samples (following the voice-contracts-check replay).
        audio.idealPlayback = true
        var mapper = GeminiLiveEventMapper()
        var expected = 0
        for (index, entry) in entries.enumerated() {
            let ms = try #require(entry["ms"] as? Int)
            let message = try #require(Self.restoreAudio(entry["msg"] ?? [:]) as? [String: Any])
            if ms > clock.nowMs { clock.advance(ms - clock.nowMs) }
            expected += mapper.map(message).count
            socket.push(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self))
            // Bounded yielding: if the controller does not receive the mapped event, record a failure instead of spinning until the suite times out.
            var spins = 0
            while realtime.eventsReceivedForTesting < expected {
                spins += 1
                guard spins <= 10_000 else {
                    Issue.record("replay: entry \(index) events \(realtime.eventsReceivedForTesting)/\(expected)")
                    return
                }
                await Task.yield()
            }
            if (message["serverContent"] as? [String: Any])?["turnComplete"] as? Bool == true { audio.finishPlayback() }
            try after(index)
        }
    }

    /// The first socket opened by a home gemini session.
    private func homeGemini(_ state: AppState, clock: Fakes.ManualClock) async throws
        -> (VoiceConversationSession, RealtimeVoiceConversationController, WiringGeminiSocket) {
        selectGemini()
        let session = session(appState: state, clock: clock)
        #expect(await startHome(session))
        #expect(session.isRealtime)
        let realtime = try #require(session.realtime)
        var sockets = opened.geminiSockets.stream.makeAsyncIterator()
        let socket = try #require(await sockets.next())
        return (session, realtime, socket)
    }

    /// A real two-turn recording lands as 4 expectedMessages through the production mapper / controller / sink / a real AppState.
    @Test func home_realtime_replay_recorded_gemini_two_turn() async throws {
        let recording = try Self.recording()
        let state = Self.homeAppState()
        let clock = Fakes.ManualClock()
        let (session, realtime, socket) = try await homeGemini(state, clock: clock)

        try await replay(try #require(recording["messages"] as? [[String: Any]]), socket: socket, clock: clock, realtime: realtime)
        let created = try #require(session.conversationID)
        #expect(state.conversations.map(\.id) == [created])
        #expect(Self.presentedChat(state) == created)
        #expect(Self.stored(state, created) == (try Self.expectedMessages(recording)))
        #expect(try Self.persisted(state, created) == (try Self.expectedMessages(recording)))
        #expect(session.isActive)
    }

    /// Replay of a recorded barge-in: the user's long story request -> the interrupted assistant -> the user changes their mind -> a joke; persisted as the four expectedMessages of the recording.
    @Test func home_realtime_replay_recorded_gemini_barge_in() async throws {
        let recording = try Self.recording("gemini-live-barge-in.v1.json")
        let state = Self.homeAppState()
        let clock = Fakes.ManualClock()
        let (session, realtime, socket) = try await homeGemini(state, clock: clock)

        try await replay(try #require(recording["messages"] as? [[String: Any]]), socket: socket, clock: clock, realtime: realtime)
        let created = try #require(session.conversationID)
        #expect(state.conversations.map(\.id) == [created])
        #expect(try Self.persisted(state, created) == (try Self.expectedMessages(recording)))
    }

    /// A human-pause variant: the first turn's inputTranscription is split into three parts, the first earlier than modelTurn and creating the conversation right away; one user turn persists only one message, still 4.
    @Test func home_realtime_replay_human_pauses_fragments() async throws {
        let recording = try Self.recording()
        let variant = try #require((recording["variants"] as? [[String: Any]])?.first)
        #expect(variant["id"] as? String == "human_pauses_first_turn_three_fragments")
        let entries = try #require(variant["messages"] as? [[String: Any]])
        let firstFragment = try #require(entries.firstIndex {
            (($0["msg"] as? [String: Any])?["serverContent"] as? [String: Any])?["inputTranscription"] != nil
        })
        let state = Self.homeAppState()
        let clock = Fakes.ManualClock()
        let (session, realtime, socket) = try await homeGemini(state, clock: clock)

        try await replay(entries, socket: socket, clock: clock, realtime: realtime) { index in
            guard index == firstFragment else { return }
            // The first part creates the conversation and enters the chat page; events are then reduced as usual: the conversation is still there and it did not end as a failed creation.
            let created = try #require(session.conversationID)
            #expect(Self.presentedChat(state) == created)
            #expect(session.isActive)
            #expect(realtime.statusKey != .error)
            #expect(Self.messages(state, created).isEmpty)
        }
        let created = try #require(session.conversationID)
        #expect(state.conversations.map(\.id) == [created])
        #expect(Self.stored(state, created) == (try Self.expectedMessages(recording)))
        #expect(try Self.persisted(state, created) == (try Self.expectedMessages(recording)))
    }

    /// A speaker-echo variant: during the first turn's reply an ACTIVITY_START and an echo transcript appear; after the write queue drains, reading the database (sortOrder) shows every user turn before the assistant.
    @Test func home_realtime_replay_speaker_echo_during_first_reply() async throws {
        let recording = try Self.recording()
        let variant = try #require((recording["variants"] as? [[String: Any]])?.first {
            $0["id"] as? String == "speaker_echo_during_first_reply"
        })
        let entries = try #require(variant["messages"] as? [[String: Any]])
        let state = Self.homeAppState()
        let clock = Fakes.ManualClock()
        let (session, realtime, socket) = try await homeGemini(state, clock: clock)

        try await replay(entries, socket: socket, clock: clock, realtime: realtime)
        let created = try #require(session.conversationID)
        #expect(state.conversations.map(\.id) == [created])
        #expect(try Self.persisted(state, created) == (try Self.expectedMessages(variant)))
        #expect(Self.stored(state, created) == (try Self.expectedMessages(variant)))
    }

    /// Replay -> end: end returns as soon as it is dismissed, and both the conversation and the 4 messages are there; opening another conversation and then this one both succeed.
    @Test func home_realtime_full_path_end_then_open_conversation() async throws {
        let recording = try Self.recording()
        let state = Self.homeAppState()
        let clock = Fakes.ManualClock()
        let (session, realtime, socket) = try await homeGemini(state, clock: clock)
        try await replay(try #require(recording["messages"] as? [[String: Any]]), socket: socket, clock: clock, realtime: realtime)
        let created = try #require(session.conversationID)

        session.end(.user)
        #expect(!session.isActive)
        #expect(!session.isPresented(in: created))
        #expect(session.lastEnd?.conversationID == created)
        #expect(Self.stored(state, created) == (try Self.expectedMessages(recording)))

        let other = try #require(state.createConversationForRealtimeVoice())
        #expect(other != created)
        #expect(Self.presentedChat(state) == other)
        state.navigation.presentChat(conversationID: created)
        #expect(Self.presentedChat(state) == created)
        #expect(Self.stored(state, created).count == 4)
        #expect(try Self.persisted(state, created) == (try Self.expectedMessages(recording)))
    }

    // MARK: Muted session expires -> unmute and reopen, with the history including this call's transcripts

    private static let geminiTurn = [
        #"{"serverContent":{"inputTranscription":{"text":"What time is it?"}}}"#,
        #"{"serverContent":{"outputTranscription":{"text":"It's three."}}}"#,
        #"{"serverContent":{"turnComplete":true}}"#,
    ]

    private static let geminiNextTurn = [
        #"{"serverContent":{"inputTranscription":{"text":"And tomorrow?"}}}"#,
        #"{"serverContent":{"outputTranscription":{"text":"Sunny."}}}"#,
        #"{"serverContent":{"turnComplete":true}}"#,
    ]

    /// The history text (role: text) in the second connection's clientContent.
    private static func history(_ socket: WiringGeminiSocket) throws -> [String] {
        let frame = try #require(socket.sent.first { $0.contains("clientContent") })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let content = try #require(object["clientContent"] as? [String: Any])
        let turns = try #require(content["turns"] as? [[String: Any]])
        return turns.map { turn in
            let parts = turn["parts"] as? [[String: Any]] ?? []
            return "\(turn["role"] as? String ?? ""): " + parts.compactMap { $0["text"] as? String }.joined()
        }
    }

    /// One round persisted -> mute -> 1008 expiry -> no ended -> unmute -> the second connection carries the history -> one more round persisted after ready.
    private func expireAndReopen(_ session: VoiceConversationSession) async throws {
        var sockets = opened.geminiSockets.stream.makeAsyncIterator()
        let realtime = try #require(session.realtime)
        let first = try #require(await sockets.next())
        first.push(#"{"setupComplete":{}}"#)
        await waitStatus(realtime, .listening)
        Self.geminiTurn.forEach(first.push)
        while opened.written.count < 2 { await Task.yield() }
        #expect(opened.written.map(\.text) == ["What time is it?", "It's three."])

        realtime.toggleMute()
        #expect(realtime.statusKey == .muted)
        let firstStream = realtime.streamTask
        first.expire()
        await firstStream?.value
        // The expiry handling finishes synchronously inside the stream task: while muted no reopen may be scheduled (it would be non-nil if reopened by mistake).
        #expect(realtime.reopenTaskForTesting == nil)
        #expect(session.isActive)
        #expect(session.realtime === realtime)
        #expect(realtime.statusKey == .muted)
        #expect(opened.endpoints.count == 1)

        realtime.toggleMute()
        let second = try #require(await sockets.next())
        await second.waitSent(1)
        second.push(#"{"setupComplete":{}}"#)
        await waitStatus(realtime, .listening)
        await second.waitSent(2)
        let history = try Self.history(second)
        // The earlier unanswered input and this call's user transcript are composed into one user turn (the assembler's production behavior), followed by this call's answer.
        #expect(history.count == 2)
        #expect(history.first?.hasPrefix("user: ") == true)
        #expect(history.first?.hasSuffix("What time is it?") == true)
        #expect(history.last == "model: It's three.")
        #expect(opened.endpoints.count == 2)
        #expect(opened.endpoints.allSatisfy { $0.0 == .geminiLive && $0.1.voice == "Kore" })
        #expect(probe.toasts.isEmpty)

        Self.geminiNextTurn.forEach(second.push)
        while opened.written.count < 4 { await Task.yield() }
        #expect(opened.written.map(\.text) == ["What time is it?", "It's three.", "And tomorrow?", "Sunny."])
        #expect(Set(opened.writtenIDs).count == 1)
        #expect(session.isActive)

        session.end(.user)
        await untilInactive(session)
    }

    /// An unexpected disconnect auto-reopens once successfully: opens a new connection with history, the conversation continues, and no error.
    @Test func unexpected_drop_reopens_once_and_continues() async throws {
        selectRealtime()
        let first = connection
        let session = session()
        #expect(await start(session))
        let realtime = try await listening(session)
        let second = Fakes.FakeConnection()
        opened.nextConnections = [second]
        speakUser("What time is it?", item: "u1")
        yield([.assistantTurnDone(itemId: "a1", status: .completed, text: "It's three.")])
        while opened.written.count < 2 { await Task.yield() }

        let firstStream = realtime.streamTask
        first.continuation.finish(throwing: URLError(.networkConnectionLost))
        await firstStream?.value
        #expect(session.isActive)
        #expect(session.realtime === realtime)
        #expect(realtime.statusKey == .listening)
        while second.openCount == 0 { await Task.yield() }
        #expect(opened.endpoints.count == 2)
        #expect(opened.inputIDs == [conversationID, conversationID])

        for event: RealtimeSessionEvent in [
            .ready,
            .userSpeechStarted(itemId: "u2"), .userSpeechStopped(itemId: "u2"),
            .userTranscript(itemId: "u2", text: "And tomorrow?", final: true),
            .assistantTurnDone(itemId: "a2", status: .completed, text: "Sunny."),
        ] {
            second.continuation.yield(event)
        }
        while opened.written.count < 4 { await Task.yield() }
        #expect(opened.written.map(\.text) == ["What time is it?", "It's three.", "And tomorrow?", "Sunny."])
        #expect(Set(opened.writtenIDs) == [conversationID])
        #expect(probe.toasts.isEmpty)
        #expect(realtime.failure == nil)
        #expect(session.isActive)

        session.end(.user)
        await untilInactive(session)
        #expect(second.closeCount >= 1)
    }

    @Test func muted_session_expired_reopens_with_history() async throws {
        selectGemini()
        let session = session()
        #expect(await start(session))
        #expect(session.isRealtime)
        try await expireAndReopen(session)
        #expect(opened.inputIDs == [conversationID, conversationID])
        #expect(opened.writtenIDs.allSatisfy { $0 == conversationID })
    }

    @Test func home_muted_session_expired_reopens_with_history() async throws {
        selectGemini()
        let session = session()
        #expect(await startHome(session))
        #expect(session.isRealtime)
        try await expireAndReopen(session)
        // Home: the reopen takes the history from the conversation id created by the sink's persistence
        let created = try #require(opened.created.first)
        #expect(opened.created == [created])
        #expect(opened.inputIDs == [nil, created])
        #expect(opened.writtenIDs.allSatisfy { $0 == created })
    }

    // A late user text after the reply started -> 1008 -> silent reopen, and that user message is persisted without duplicates
    @Test func home_realtime_session_expired_keeps_pending_user_text() async throws {
        selectGemini()
        let session = session()
        #expect(await startHome(session))
        var sockets = opened.geminiSockets.stream.makeAsyncIterator()
        let realtime = try #require(session.realtime)
        let first = try #require(await sockets.next())
        first.push(#"{"setupComplete":{}}"#)
        await waitStatus(realtime, .listening)
        Self.geminiTurn.forEach(first.push)
        while opened.written.count < 2 { await Task.yield() }

        // The second reply starts first, the user transcript arrives late, then the 1008 expiry
        first.push(#"{"serverContent":{"outputTranscription":{"text":"Sun"}}}"#)
        first.push(#"{"serverContent":{"inputTranscription":{"text":"And tomorrow?"}}}"#)
        let firstStream = realtime.streamTask
        first.expire()
        await firstStream?.value
        let second = try #require(await sockets.next())
        await second.waitSent(1)
        second.push(#"{"setupComplete":{}}"#)
        await waitStatus(realtime, .listening)
        #expect(opened.written.map(\.text).filter { $0 == "And tomorrow?" }.count == 1)
        #expect(Array(opened.written.map(\.text).prefix(3)) == ["What time is it?", "It's three.", "And tomorrow?"])
        let created = try #require(opened.created.first)
        #expect(opened.created == [created])
        #expect(opened.writtenIDs.allSatisfy { $0 == created })

        session.end(.user)
        await untilInactive(session)
        #expect(opened.written.map(\.text).filter { $0 == "And tomorrow?" }.count == 1)
    }

    // MARK: realtime-session.v1 turn-boundary replanning (production wiring)

    private func realtimeParts() async throws -> RealtimeVoiceSessionParts {
        guard case .realtime(let parts) = await builder().prepare(conversationID: conversationID) else {
            throw RealtimeVoiceOpenError.planRejected
        }
        return parts
    }

    /// Wait for this round's turn-boundary replan to finish (previous = the previous round's replanTask).
    private func replanned(_ controller: RealtimeVoiceConversationController, after previous: Task<Void, Never>?) async {
        while controller.replanTask == nil || controller.replanTask == previous { await Task.yield() }
        await controller.replanTask?.value
    }

    @Test func own_transcripts_do_not_change_fingerprint() async throws {
        selectRealtime()
        let parts = try await realtimeParts()
        let replan = try #require(parts.replanFingerprint)
        let fingerprint = try #require(parts.plan.plan.fingerprint)
        #expect(fingerprint.lastHistoryId == opened.typed.id.uuidString)
        parts.sink.appendUser("Spoken question")
        parts.sink.appendAssistant("Spoken answer")
        #expect(opened.written.count == 2)
        // This session's own transcripts do not enter the plan: the fingerprint does not change, so it does not reopen every round
        #expect(await replan() == fingerprint)

        // The reopen switches to a new conversation id: earlier transcripts are ordinary history, and the replan and the reopen plan have the same fingerprint
        let reopen = try #require(parts.reopen)
        let reopened = try await reopen(conversationID)
        let reopenedFingerprint = try #require(reopened.plan.plan.fingerprint)
        #expect(reopenedFingerprint.lastHistoryId == opened.written.last?.id.uuidString)
        #expect(await replan() == reopenedFingerprint)
        parts.sink.appendUser("Next question")
        #expect(await replan() == reopenedFingerprint)
    }

    @Test func external_message_changes_fingerprint_and_reopens() async throws {
        selectGemini()
        let session = session(replan: true)
        #expect(await start(session))
        var sockets = opened.geminiSockets.stream.makeAsyncIterator()
        let realtime = try #require(session.realtime)
        let first = try #require(await sockets.next())
        first.push(#"{"setupComplete":{}}"#)
        await waitStatus(realtime, .listening)

        // Only this call's transcripts: the turn-boundary replan does not reopen
        Self.geminiTurn.forEach(first.push)
        while opened.written.count < 2 { await Task.yield() }
        await replanned(realtime, after: nil)
        let afterOwnTurn = realtime.replanTask
        #expect(opened.endpoints.count == 1)
        #expect(realtime.statusKey == .listening)

        // A message written elsewhere: at the next turn boundary the fingerprint changed, so the old connection is closed and reopened with the new plan
        let external = TestFactories.makeMessage(role: .user, text: "Typed on another device")
        opened.external.append(external)
        Self.geminiNextTurn.forEach(first.push)
        while opened.written.count < 4 { await Task.yield() }
        await replanned(realtime, after: afterOwnTurn)
        let second = try #require(await sockets.next())
        await second.waitSent(1)
        second.push(#"{"setupComplete":{}}"#)
        await waitStatus(realtime, .listening)
        await second.waitSent(2)
        let history = try Self.history(second)
        #expect(history.last?.hasSuffix("Typed on another device") == true)
        #expect(history.contains("model: Sunny."))
        #expect(opened.endpoints.count == 2)
        #expect(opened.inputIDs.allSatisfy { $0 == conversationID })
        #expect(session.isActive)
        #expect(session.realtime === realtime)
        #expect(probe.toasts.isEmpty)

        session.end(.user)
        await untilInactive(session)
    }

    @Test func replan_assembles_off_main() async throws {
        selectRealtime()
        let parts = try await realtimeParts()
        let replan = try #require(parts.replanFingerprint)
        #expect(opened.threads.snapshotOnMain == [true])
        #expect(opened.threads.checkpointOnMain == [false])
        _ = await replan()
        // The snapshot is taken on the main thread, while the checkpoint read and assembly are in the background
        #expect(opened.threads.snapshotOnMain == [true, true])
        #expect(opened.threads.checkpointOnMain == [false, false])
    }

    /// The first open and the expiry reopen both take the conversation snapshot only on the main thread, while the checkpoint read and assembly are in the background.
    @Test func open_reads_checkpoint_off_main() async throws {
        selectRealtime()
        let parts = try await realtimeParts()
        #expect(opened.threads.snapshotOnMain == [true])
        #expect(opened.threads.checkpointOnMain == [false])
        let reopen = try #require(parts.reopen)
        let reopened = try await reopen(conversationID)
        #expect(reopened.plan.plan.fingerprint != nil)
        #expect(opened.threads.snapshotOnMain == [true, true])
        #expect(opened.threads.checkpointOnMain == [false, false])
    }

    /// Home-page entry: the opening plan is assembled with new-conversation defaults (conversation id nil); after the first turn persists and creates the conversation,
    /// the turn-boundary replan assembles with the real conversation + this conversation id, this conversation's transcripts do not enter the plan, and the fingerprint equals the opening one, so it does not reopen.
    @Test func home_entry_first_turn_replan_keeps_fingerprint() async throws {
        selectRealtime()
        guard case .realtime(let parts) = await builder().prepare(conversationID: nil) else {
            throw RealtimeVoiceOpenError.planRejected
        }
        let replan = try #require(parts.replanFingerprint)
        let fingerprint = try #require(parts.plan.plan.fingerprint)
        #expect(opened.inputIDs == [nil])

        parts.sink.appendUser("Hello from home")
        parts.sink.appendAssistant("Hi there")
        let created = try #require(opened.created.first)
        #expect(opened.writtenIDs == [created, created])

        #expect(await replan() == fingerprint)
        #expect(opened.inputIDs == [nil, created])
    }

    /// Typing sent to the realtime model (GA): after ready, sendText sends two frames, an input_text user item and response.create; dropped before ready.
    @Test func typed_text_ga_sends_input_text_item_then_response_create() async throws {
        let box = GARealtimeTransportTests.SocketBox()
        let endpoint = RealtimeEndpoint(
            host: "api.openai.com", apiKey: "sk-test-secret", model: "gpt-realtime",
            path: "/v1/realtime", voice: "marin", inputTranscriptionModel: "gpt-4o-transcribe"
        )
        let transport = try #require(GARealtimeTransport(kind: .openaiRealtime, endpoint: endpoint, makeSocket: box.make))
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."),
            messages: [],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let sessionInput = ChatRequestBuilder.realtimeSessionInput(
            snapshot, contextWindow: 128_000, currentSessionId: "rt-1", sessionMessageIds: [], checkpoint: nil
        )
        let planned = try #require(PlannedRealtimeSession.from(ContextAssembler.assembleRealtimeSession(sessionInput)))
        var events = transport.openRealtimeSession(transport: planned.transportInput()).makeAsyncIterator()
        let opening = box.socket.sent.count

        transport.sendText("Before ready")
        #expect(box.socket.sent.count == opening)

        try box.socket.push(["type": "session.created"])
        guard case .ready = try await events.next() else {
            Issue.record("expected ready")
            return
        }
        transport.sendText("What time is it in Tokyo?")

        let frames = Array(box.socket.sent.dropFirst(opening))
        #expect(frames.map { $0["type"] as? String } == ["conversation.item.create", "response.create"])
        let item = try #require(frames.first?["item"] as? [String: Any])
        #expect(item["type"] as? String == "message")
        #expect(item["role"] as? String == "user")
        let content = try #require(item["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "What time is it in Tokyo?")
        #expect(frames.last?.count == 1)
        transport.close()
    }

    /// Typing sent to the realtime model (Gemini): one clientContent, a single user turn, turnComplete true.
    @Test func typed_text_gemini_is_client_content_turn_complete() throws {
        let message = GeminiLiveWire.userTextMessage("What time is it in Tokyo?")
        let data = try JSONSerialization.data(withJSONObject: message)
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Array(decoded.keys) == ["clientContent"])
        let content = try #require(decoded["clientContent"] as? [String: Any])
        #expect(content["turnComplete"] as? Bool == true)
        let turns = try #require(content["turns"] as? [[String: Any]])
        #expect(turns.count == 1)
        #expect(turns.first?["role"] as? String == "user")
        let parts = try #require(turns.first?["parts"] as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts.first?["text"] as? String == "What time is it in Tokyo?")
    }

    /// Frame kinds: audio / text:<typed content> / others (setup, etc.), keyed by their first key as is.
    private static func frameKinds(_ socket: WiringGatedGeminiSocket) throws -> [String] {
        try socket.sent.map { frame in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            if object["realtimeInput"] != nil { return "audio" }
            if let content = object["clientContent"] as? [String: Any],
               let turns = content["turns"] as? [[String: Any]],
               let parts = turns.first?["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                return "text:\(text)"
            }
            return object.keys.sorted().joined(separator: ",")
        }
    }

    /// Gemini via GeminiLiveSessionControl: text sent after ready while buffered audio is still flushing is not lost and is queued after the buffered audio;
    /// after resuming on a new connection, only the unsent item is resent; items already sent are not repeated.
    @Test func typed_text_gemini_queued_behind_buffered_audio_not_resent_after_resume() async throws {
        let sockets = WiringGatedGeminiSockets()
        let endpoint = RealtimeEndpoint(
            host: "generativelanguage.googleapis.com", apiKey: "g-realtime", model: "gemini-3.8-live",
            path: "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent", voice: "Puck"
        )
        let control = GeminiLiveSessionControl(transport: GeminiLiveTransport(
            config: GeminiLiveSessionControl.config(for: endpoint),
            socketFactory: { _ in sockets.open() }
        ))
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."),
            messages: [],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let plan = ContextAssembler.assembleRealtimeSession(ChatRequestBuilder.realtimeSessionInput(
            snapshot, contextWindow: 131_072, currentSessionId: nil, sessionMessageIds: [], checkpoint: nil
        ))
        let input = try #require(PlannedRealtimeSession.from(plan)).transportInput()
        let events = control.openRealtimeSession(transport: input)
        let reader = Task { for try await _ in events {} }
        defer {
            control.close()
            reader.cancel()
        }
        var opened = sockets.stream.makeAsyncIterator()
        let first = try #require(await opened.next())
        await first.waitSent(1)

        // Not ready: audio goes into the buffer.
        control.sendAudio(Data([1, 2, 3, 4]))
        await control.drainUplink()
        // After ready, the flush stalls on the first buffered audio chunk: audio and text arriving now are both between ready and audioReady.
        first.holdAudio()
        first.push(#"{"setupComplete":{}}"#)
        await first.waitHeld()
        control.sendAudio(Data([5, 6, 7, 8]))
        control.sendText("What time is it in Tokyo?")
        await control.drainUplink()
        first.release()
        await first.waitSent(4)
        #expect(try Self.frameKinds(first) == ["setup", "audio", "audio", "text:What time is it in Tokyo?"])

        // goAway resume: text typed during the reconnect is resent after the new connection is ready; the item the old connection already sent is not sent again.
        first.push(#"{"sessionResumptionUpdate":{"newHandle":"handle-1","resumable":true}}"#)
        first.push(#"{"goAway":{}}"#)
        let second = try #require(await opened.next())
        await second.waitSent(1)
        control.sendText("And tomorrow?")
        await control.drainUplink()
        second.push(#"{"setupComplete":{}}"#)
        await second.waitSent(2)
        control.sendAudio(Data([9, 10, 11, 12]))
        await control.drainUplink()
        await second.waitSent(3)
        #expect(try Self.frameKinds(second) == ["setup", "text:And tomorrow?", "audio"])
        #expect(try Self.frameKinds(first).filter { $0.hasPrefix("text:") } == ["text:What time is it in Tokyo?"])
    }
}

/// Open records of the gemini_live fake socket that can stall a send on an audio frame (handed to the tests in order).
nonisolated final class WiringGatedGeminiSockets: @unchecked Sendable {
    let stream: AsyncStream<WiringGatedGeminiSocket>
    private let sink: AsyncStream<WiringGatedGeminiSocket>.Continuation

    init() { (stream, sink) = AsyncStream<WiringGatedGeminiSocket>.makeStream() }

    func open() -> WiringGatedGeminiSocket {
        let socket = WiringGatedGeminiSocket()
        sink.yield(socket)
        return socket
    }
}

/// The send of the first audio frame after holdAudio() is suspended until release(); it is recorded in sent before suspending.
nonisolated final class WiringGatedGeminiSocket: GeminiLiveSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let inner = WiringGeminiSocket()
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    var sent: [String] { inner.sent }

    func push(_ text: String) { inner.push(text) }
    func waitSent(_ count: Int) async { await inner.waitSent(count) }

    func holdAudio() { lock.withLock { holding = true } }

    /// Waits until a send of an audio frame has been suspended.
    func waitHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if held != nil || released { return true }
                heldWaiter = continuation
                return false
            }
            if done { continuation.resume() }
        }
    }

    func release() {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            holding = false
            released = true
            defer { held = nil }
            return held
        }
        resume?.resume()
    }

    func send(_ text: String) async throws {
        try await inner.send(text)
        guard text.contains("realtimeInput") else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (hold, waiter): (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
                guard holding, held == nil else { return (false, nil) }
                held = continuation
                defer { heldWaiter = nil }
                return (true, heldWaiter)
            }
            waiter?.resume()
            if !hold { continuation.resume() }
        }
    }

    func receive() async throws -> String? { try await inner.receive() }

    func close() {
        inner.close()
        release()
    }
}

/// Whether the snapshot / checkpoint read happens on the main thread (replanning must take the snapshot only on the main thread).
nonisolated final class WiringThreads: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [Bool] = []
    private var checkpoints: [Bool] = []

    var snapshotOnMain: [Bool] { lock.withLock { snapshots } }
    var checkpointOnMain: [Bool] { lock.withLock { checkpoints } }

    func record(snapshot onMain: Bool) { lock.withLock { snapshots.append(onMain) } }
    func record(checkpoint onMain: Bool) { lock.withLock { checkpoints.append(onMain) } }
}

/// The fake socket open records of gemini_live: handed to the test in order.
nonisolated final class WiringGeminiSockets: @unchecked Sendable {
    let stream: AsyncStream<WiringGeminiSocket>
    private let sink: AsyncStream<WiringGeminiSocket>.Continuation

    init() { (stream, sink) = AsyncStream<WiringGeminiSocket>.makeStream() }

    func open() -> WiringGeminiSocket {
        let socket = WiringGeminiSocket()
        sink.yield(socket)
        return socket
    }
}

/// Replay fake socket: the test pushes server messages; expire() simulates the server's 1008 closing.
nonisolated final class WiringGeminiSocket: GeminiLiveSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var ended = false
    private var closeError: GeminiLiveSocketClosed?
    private var waiter: CheckedContinuation<String?, Never>?
    private var _sent: [String] = []
    private var sentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var sent: [String] { lock.withLock { _sent } }

    func push(_ text: String) { deliver(text) }

    func expire() {
        lock.withLock { closeError = GeminiLiveSocketClosed(code: 1008, reason: "session expired") }
        deliver(nil)
    }

    /// Wait until the number of frames sent reaches count.
    func waitSent(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if _sent.count >= count { return true }
                sentWaiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }

    func send(_ text: String) async throws {
        let due: [CheckedContinuation<Void, Never>] = lock.withLock {
            _sent.append(text)
            let count = _sent.count
            let due = sentWaiters.filter { $0.0 <= count }.map(\.1)
            sentWaiters.removeAll { $0.0 <= count }
            return due
        }
        due.forEach { $0.resume() }
    }

    func receive() async throws -> String? {
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let immediate: String?? = lock.withLock {
                if !inbox.isEmpty { return .some(inbox.removeFirst()) }
                if ended { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
        if text == nil, let error = lock.withLock({ closeError }) { throw error }
        return text
    }

    func close() { deliver(nil) }

    private func deliver(_ text: String?) {
        let resume: CheckedContinuation<String?, Never>? = lock.withLock {
            guard !ended else { return nil }
            if text == nil { ended = true }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            if let text { inbox.append(text) }
            return nil
        }
        resume?.resume(returning: text)
    }
}

/// A wake-up that resumes only once: a resume earlier than wait is not lost, and it can be called from any thread (cancellation handler / observation callback);
/// supports several waiters, all woken on resume. onQueued calls back with the current number of waiters when a waiter is queued (so the test can be sure concurrent waiters are suspended).
nonisolated final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let onQueued: (@Sendable (Int) -> Void)?

    init(onQueued: (@Sendable (Int) -> Void)? = nil) {
        self.onQueued = onQueued
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queued = lock.withLock { () -> Int? in
                if resumed { return nil }
                continuations.append(continuation)
                return continuations.count
            }
            guard let queued else {
                continuation.resume()
                return
            }
            onQueued?(queued)
        }
    }

    func resume() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !resumed else { return [] }
            resumed = true
            defer { continuations = [] }
            return continuations
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// A one-shot signal: a fire earlier than wait is not lost; several concurrent waiters are released together; a waiting task that gets cancelled (timeLimit) returns immediately and records a failure.
@MainActor
/// Advanceable clock the session depends on (the 1.6 s engine-switch transition is advanced by the test case).
final class WiringNow {
    var value = Date(timeIntervalSince1970: 1_000)
}

final class WiringSignal {
    private var fired = false
    private let wake: OnceContinuation

    init(onQueued: (@Sendable (Int) -> Void)? = nil) {
        wake = OnceContinuation(onQueued: onQueued)
    }

    func fire() {
        fired = true
        wake.resume()
    }

    func wait() async {
        guard !fired else { return }
        let wake = self.wake
        await withTaskCancellationHandler {
            await wake.wait()
        } onCancel: {
            wake.resume()
        }
        if !fired { Issue.record("WiringSignal: cancelled before fire") }
    }
}

@MainActor
final class LeaseGatedAudios {
    var items: [LeaseGatedRealtimeAudio] = []
}

/// Mirrors VPIO's semantics: on stopRealtime only a still-current lease deactivates (counted); the rest are handed to the inner fake audio.
@MainActor
final class LeaseGatedRealtimeAudio: RealtimeAudioIO, SessionLeaseAwareAudio {
    private let inner: any RealtimeAudioIO
    private let owner: VoiceAudioSessionOwner
    var sessionLease: VoiceAudioSessionOwner.Lease?
    private(set) var deactivations = 0

    init(_ inner: any RealtimeAudioIO, owner: VoiceAudioSessionOwner) {
        self.inner = inner
        self.owner = owner
    }

    func startRealtime(uplinkSampleRate: Double, onFrame: @escaping (Data) -> Void, onInterruption: @escaping () -> Void) throws {
        try inner.startRealtime(uplinkSampleRate: uplinkSampleRate, onFrame: onFrame, onInterruption: onInterruption)
    }
    func enqueue(pcm16: Data, itemId: String) { inner.enqueue(pcm16: pcm16, itemId: itemId) }
    func playedMs(itemId: String) -> Int { inner.playedMs(itemId: itemId) }
    var isPlaying: Bool { inner.isPlaying }
    var onPlaybackDrained: (() -> Void)? {
        get { inner.onPlaybackDrained }
        set { inner.onPlaybackDrained = newValue }
    }
    func stopRealtimePlayback() { inner.stopRealtimePlayback() }
    func stopRealtime() {
        inner.stopRealtime()
        if let sessionLease, owner.current == sessionLease { deactivations += 1 }
    }
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { inner.playEarcon(earcon) }
    func tearDownGraph() {}
    var sessionOwner: VoiceAudioSessionOwner? { owner }
}

/// The preparing session stays suspended until release; whichever of start-engine or stop-engine comes first settles it. The rest is forwarded to the inner fake audio.
@MainActor
final class PrepareHoldingRealtimeAudio: RealtimeAudioIO {
    private let inner: any RealtimeAudioIO
    let entered = OnceContinuation()
    let release = OnceContinuation()
    let settled = OnceContinuation()

    init(_ inner: any RealtimeAudioIO) {
        self.inner = inner
    }

    func prepareSession() async throws {
        entered.resume()
        await release.wait()
        try await inner.prepareSession()
    }
    func startRealtime(uplinkSampleRate: Double, onFrame: @escaping (Data) -> Void, onInterruption: @escaping () -> Void) throws {
        defer { settled.resume() }
        try inner.startRealtime(uplinkSampleRate: uplinkSampleRate, onFrame: onFrame, onInterruption: onInterruption)
    }
    func enqueue(pcm16: Data, itemId: String) { inner.enqueue(pcm16: pcm16, itemId: itemId) }
    func playedMs(itemId: String) -> Int { inner.playedMs(itemId: itemId) }
    var isPlaying: Bool { inner.isPlaying }
    var onPlaybackDrained: (() -> Void)? {
        get { inner.onPlaybackDrained }
        set { inner.onPlaybackDrained = newValue }
    }
    func stopRealtimePlayback() { inner.stopRealtimePlayback() }
    func stopRealtime() {
        inner.stopRealtime()
        settled.resume()
    }
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { inner.playEarcon(earcon) }
}

/// Actions received by the failure-panel exit callbacks.
final class WiringActions {
    var list: [RealtimeModelPolicy.FailureAction] = []
}

/// Idle-panel tap / retry counts.
final class WiringCounter {
    var count = 0
}
