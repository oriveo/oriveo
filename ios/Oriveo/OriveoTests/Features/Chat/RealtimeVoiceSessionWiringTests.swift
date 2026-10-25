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
    private let notifications = NotificationCenter()
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

    private func selectGemini() {
        settings.setSelection(.cloud(VoiceCloudEngine(
            providerKind: .gemini,
            connectionID: geminiProvider.id.uuidString,
            model: "gemini-3.8-live",
            voice: "Kore"
        )), for: .realtime)
        settings.disclosures.markAccepted(.gemini, direction: .realtime)
    }

    private func selectRealtime(connectionID: String? = nil, voice: String? = "cedar", accept: Bool = true) {
        settings.setSelection(.cloud(VoiceCloudEngine(
            providerKind: .openAI,
            connectionID: connectionID ?? provider.id.uuidString,
            model: "gpt-realtime",
            voice: voice
        )), for: .realtime)
        if accept { settings.disclosures.markAccepted(.openAI, direction: .realtime) }
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
            settings: settings,
            catalog: { Self.catalog(contextWindow: contextWindow) },
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
                guard kind == .geminiLive else { return connection }
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
            }
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
        wrapAudio: ((any RealtimeAudioIO) -> any RealtimeAudioIO)? = nil
    ) -> VoiceConversationSession {
        var deps = probe.dependencies(listening: listening)
        deps.audioSession = audioSession
        if let onAnnounce {
            let announce = deps.announce
            deps.announce = { announce($0); onAnnounce($0) }
        }
        deps.grantMicrophone = { true }
        let builder = builder(contextWindow: contextWindow, appState: appState, wrapAudio: wrapAudio)
        deps.makeRealtime = { id, _ in await builder.prepare(conversationID: id) }
        let opened = opened
        deps.recordRealtimeStart = { id, _ in opened.recordedStarts.append(id) }
        deps.makeRealtimeController = { parts, reopener, onError, onEnded in
            RealtimeVoiceConversationController(
                connection: parts.connection, audio: parts.audio, plan: parts.plan, sink: parts.sink,
                clock: clock, reopener: reopener,
                replanner: replan ? parts.replanFingerprint : nil, onError: onError, onEnded: onEnded
            )
        }
        deps.notificationCenter = notifications
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
        #expect(endpoint.voice == "cedar")
        #expect(endpoint.inputTranscriptionModel == "gpt-4o-mini-transcribe")
        #expect(probe.toasts.isEmpty)
    }

    /// A realtime session only needs the microphone: realtime can still open when system dictation + speech recognition is denied (the dictation engine's preparation does not pass).
    @Test func realtime_entry_requests_microphone_only() async throws {
        selectRealtime()
        let session = session(listening: nil)
        #expect(await start(session))
        #expect(session.isRealtime)
        _ = try await listening(session)
        #expect(opened.endpoints.count == 1)
    }

    /// The catalog cold fetch never returns: give up within the limit and treat the catalog as unavailable - go to the cascade, show no hint, change no setting, open no connection.
    @Test func catalog_refresh_that_never_returns_uses_cascade() async {
        let hang = NeverReturningCall()
        defer { hang.releaseAll() }
        selectRealtime()
        let stored = settings.selection(for: .realtime)
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
        guard case .cascade(let toast) = start else {
            Issue.record("expected cascade, got \(start)")
            return
        }
        #expect(toast == nil)
        #expect(settings.selection(for: .realtime) == stored)
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
        settings.setSelection(.system, for: .realtime)
        let session = session()
        #expect(await start(session))
        #expect(opened.recordedStarts.isEmpty)
    }

    @Test func system_selection_keeps_cascade() async {
        settings.setSelection(.system, for: .realtime)
        let session = session()
        #expect(await start(session))
        #expect(!session.isRealtime)
        #expect(session.controller != nil)
        #expect(opened.endpoints.isEmpty)
        #expect(probe.toasts.isEmpty)
    }

    @Test func fallback_consumes_use_notice_and_uses_cascade() async {
        selectRealtime(connectionID: UUID().uuidString)
        let session = session()
        #expect(await start(session))
        #expect(!session.isRealtime)
        #expect(session.controller != nil)
        #expect(opened.endpoints.isEmpty)
        #expect(probe.toasts == [RealtimeVoiceSessionBuilder.fallbackToast])
        #expect(settings.selection(for: .realtime) == .system)

        session.end(.user)
        await untilInactive(session)
        #expect(await start(session))
        #expect(probe.toasts == [RealtimeVoiceSessionBuilder.fallbackToast])
    }

    @Test func plan_rejected_toasts_and_uses_cascade() async {
        selectRealtime()
        let session = session(contextWindow: 0)
        #expect(await start(session))
        #expect(!session.isRealtime)
        #expect(session.controller != nil)
        #expect(opened.endpoints.isEmpty)
        #expect(probe.toasts == [VoiceConversationCopy.startFailedToast])
    }

    @Test func undisclosed_selection_uses_cascade_silently() async {
        selectRealtime(accept: false)
        let session = session()
        #expect(await start(session))
        #expect(!session.isRealtime)
        #expect(opened.endpoints.isEmpty)
        #expect(probe.toasts.isEmpty)
        #expect(settings.selection(for: .realtime) != .system)
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

    /// A realtime session that ends with an error shows one toast, reusing the error status text.
    @Test func realtimeErrorShowsToastOnce() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let realtime = try await listening(session)
        connection.continuation.finish(throwing: URLError(.networkConnectionLost))
        await untilInactive(session)
        realtime.end()
        #expect(probe.toasts == [VoiceConversationCopy.status(.error)])
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

    @Test func background_closes_realtime() async throws {
        selectRealtime()
        let session = session()
        #expect(await start(session))
        let realtime = try #require(session.realtime)
        connection.continuation.yield(.ready)
        await waitStatus(realtime, .listening)

        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await untilInactive(session)
        #expect(connection.closeCount >= 1)
        #expect(!session.isActive)
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

    /// A conversation was created but nothing was persisted before the end: delete this empty conversation.
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
        #expect(probe.toasts == [VoiceConversationCopy.status(.error)])
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
