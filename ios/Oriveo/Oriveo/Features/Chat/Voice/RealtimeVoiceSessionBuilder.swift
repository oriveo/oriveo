import Foundation
import OriveoProviderKit

extension RealtimeVoiceConversationController: VoiceConversationSurface {}

/// Audio for a realtime session: forwards to VPIO and also records the system-interruption callback, so the host (on going to the background) can trigger the same systemInterruption itself.
final class RealtimeVoiceAudio: RealtimeAudioIO, SessionLeaseAwareAudio {
    private let inner: any RealtimeAudioIO
    private let currentRoute: () -> VoiceConversationLogic.Route
    private var interruption: (() -> Void)?

    init(_ inner: any RealtimeAudioIO, route: @escaping () -> VoiceConversationLogic.Route) {
        self.inner = inner
        self.currentRoute = route
    }

    /// The actual current route of the realtime audio (analytics route).
    var route: VoiceConversationLogic.Route { currentRoute() }

    /// Host-side interruption such as going to the background: takes the same path as an incoming call / Siri (reducer input systemInterruption, closes the connection).
    /// Returns false when audio has not started yet (the connection is not ready), and the host ends the session itself.
    @discardableResult
    func interrupt() -> Bool {
        guard let interruption else { return false }
        interruption()
        return true
    }

    func startRealtime(
        uplinkSampleRate: Double,
        onFrame: @escaping (Data) -> Void,
        onInterruption: @escaping () -> Void
    ) throws {
        interruption = onInterruption
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
        interruption = nil
        inner.stopRealtime()
    }
    func playEarcon(_ earcon: VoiceConversationLogic.Earcon) { inner.playEarcon(earcon) }

    /// Hands the conversation lease the session obtained to the engine: engine teardown deactivates the session only while it still holds the current lease.
    var sessionLease: VoiceAudioSessionOwner.Lease? {
        get { (inner as? SessionLeaseAwareAudio)?.sessionLease }
        set { (inner as? SessionLeaseAwareAudio)?.sessionLease = newValue }
    }

    func tearDownGraph() { (inner as? SessionLeaseAwareAudio)?.tearDownGraph() }
    var sessionOwner: VoiceAudioSessionOwner? { (inner as? SessionLeaseAwareAudio)?.sessionOwner }
}

/// Everything needed to open a realtime session (the host builds the controller from these parts).
struct RealtimeVoiceSessionParts {
    let connection: any RealtimeTransport & RealtimeSessionControl
    let audio: RealtimeVoiceAudio
    let plan: PlannedRealtimeSession
    let sink: RealtimeConversationSink
    let attribution: RealtimeVoiceAttribution
    /// Reopener: produces a new plan + new connection for the current conversation id (on the home page, the id created once the sink persists),
    /// along the same projection path as the first open; shows no prompt, changes no settings, creates no new audio / sink.
    var reopen: RealtimeVoiceSessionBuilder.Reopen?
    /// Turn-boundary replan: reassembles the plan with the current conversation id and returns the new fingerprint (the session's own transcript stays out of the plan).
    var replanFingerprint: RealtimeVoiceConversationController.Replanner?
}

/// Projection result shared by the first open and reopen: the opening plan and the unopened connection.
struct RealtimeVoiceOpening {
    let connection: any RealtimeTransport & RealtimeSessionControl
    let plan: PlannedRealtimeSession
}

/// What a replan picks up on the main thread: the conversation snapshot + this session's id (nil for a new conversation) + the ids of messages this session already persisted.
nonisolated struct RealtimeReplanScope: Sendable {
    let source: RealtimeSessionSource
    let sessionID: String?
    let own: Set<UUID>
}

/// The resolved realtime session target (connection + catalog entry + voice); reopen reuses the one from the first open.
struct RealtimeVoiceTarget {
    let provider: Provider
    let entry: VoiceRealtimeEntry
    let voice: String
}

/// Projection failure: the opening plan was rejected, the connection address is missing, or the transport cannot be created.
enum RealtimeVoiceOpenError: Error {
    case planRejected
    case connectionUnavailable
}

/// The path chosen from the conversation engine selection when entering a voice conversation.
enum RealtimeVoiceStart {
    /// Use the cascade; a non-nil toast is shown once (fallback / opening plan rejected).
    case cascade(toast: String?)
    case realtime(RealtimeVoiceSessionParts)
}

/// Conversation engine (realtime) selection → realtime session parts: resolve fallback, disclosure gate, opening plan, endpoint, transport and audio.
struct RealtimeVoiceSessionBuilder {
    typealias Reopen = (_ conversationID: UUID?) async throws -> RealtimeVoiceOpening

    var settings: VoiceEngineSettings
    var catalog: @MainActor @Sendable () async -> VoiceCatalog?
    var providers: () -> [Provider]
    /// Source of the opening input, shared with chat sending (ChatManager.prepareRequestSnapshot → realtimeSessionSource): the main thread only takes a snapshot,
    /// assembly happens in RealtimeSessionSource.input; with a nil conversation id (home page) it uses new-conversation defaults + the current memory items.
    var sessionSource: @MainActor @Sendable (_ conversationID: UUID?) -> RealtimeSessionSource?
    var makeConnection: (_ kind: RealtimeTransportKind, _ endpoint: RealtimeEndpoint) -> (any RealtimeTransport & RealtimeSessionControl)?
    var makeAudio: () -> RealtimeVoiceAudio
    var makeSink: (_ conversationID: UUID?, _ attribution: RealtimeVoiceAttribution) -> AppStateRealtimeTranscriptSink
    /// Upper bound for fetching the catalog before entering (a cold start goes to the network to refresh); a timeout counts as the catalog being unavailable: this entry uses the cascade, shows no prompt and changes no settings.
    var catalogLimit: Duration = DictationEngineSource.catalogLimit

    static var fallbackToast: String {
        L10n.tr("Your conversation engine isn't available anymore, so this conversation uses the current model.", table: .voice)
    }

    /// audioSession is passed in through VoiceConversationSession.Dependencies (the same instance as its audioSession).
    static func production(appState: AppState, audioSession: VoiceAudioSessionOwner) -> RealtimeVoiceSessionBuilder {
        RealtimeVoiceSessionBuilder(
            settings: VoiceEngineSettings(),
            catalog: { await DictationEngineSource.sharedCatalog()?.catalog },
            providers: { [weak appState] in appState?.providers ?? [] },
            sessionSource: { [weak appState] id in
                guard let appState else { return nil }
                guard let id else { return appState.chatManager.realtimeSessionSourceForNewConversation() }
                return appState.chatManager.realtimeSessionSource(in: id)
            },
            makeConnection: { kind, endpoint in RealtimeTransportFactory.make(kind: kind, endpoint: endpoint) },
            makeAudio: {
                let engine = VPIOConversationAudioEngine(owner: audioSession)
                return RealtimeVoiceAudio(engine, route: { engine.route })
            },
            makeSink: { [weak appState] id, attribution in
                guard let appState else {
                    return AppStateRealtimeTranscriptSink(conversationID: id, attribution: attribution) { _, _ in }
                }
                return AppStateRealtimeTranscriptSink.appState(appState, conversationID: id, attribution: attribution)
            }
        )
    }

    func prepare(conversationID: UUID?) async -> RealtimeVoiceStart {
        // When the settings page noticed a fallback first and the selection was changed back to system, it left one pending notice here: taken and cleared on first read, so this entry shows it once.
        let pending = settings.takePendingNotice(site: .use, direction: .realtime)
        let pendingToast = pending == nil ? nil : Self.fallbackToast
        guard case .cloud(let stored) = settings.selection(for: .realtime) else { return .cascade(toast: pendingToast) }
        // The disclosure for this provider's conversation engine was never accepted (older version data / restored backup): this entry uses the cascade, with no dialog, no prompt and no settings change.
        guard settings.disclosures.hasAccepted(stored.providerKind, direction: .realtime) else { return .cascade(toast: nil) }
        let catalog = self.catalog
        guard let catalog = await VoiceDeadline.value(within: catalogLimit, { await catalog() }) ?? nil
        else { return .cascade(toast: nil) }
        let providers = providers()
        let resolution = settings.resolve(
            direction: .realtime,
            catalog: catalog,
            connections: providers.map(VoiceConnection.init(provider:)),
            site: .use
        )
        guard case .cloud(let selected) = resolution else {
            return .cascade(toast: resolution.notice ? Self.fallbackToast : pendingToast)
        }
        guard let provider = providers.first(where: { $0.id.uuidString == selected.connectionID }),
              let entry = catalog.realtimeEntries(selected.providerKind).first(where: { $0.model == selected.model }),
              let voice = selected.voice ?? entry.defaultVoice?.id
        else { return .cascade(toast: nil) }
        let target = RealtimeVoiceTarget(provider: provider, entry: entry, voice: voice)
        let attribution = RealtimeVoiceAttribution(
            providerID: provider.id,
            providerKind: provider.kind,
            providerName: provider.displayName,
            model: entry.model
        )
        let sink = makeSink(conversationID, attribution)
        guard let opening = try? await open(target, conversationID: conversationID, transcript: sink) else {
            return .cascade(toast: VoiceConversationCopy.startFailedToast)
        }
        return .realtime(RealtimeVoiceSessionParts(
            connection: opening.connection,
            audio: makeAudio(),
            plan: opening.plan,
            sink: sink,
            attribution: attribution,
            reopen: { id in try await open(target, conversationID: id, transcript: sink) },
            replanFingerprint: replanFingerprint(transcript: sink, contextWindow: entry.contextWindow)
        ))
    }

    /// Produces only plan + connection: the opening input takes the conversation's current content (including transcript persisted by earlier connections) → assemble → endpoint → transport.
    /// Shared by the first open and reopen; each call takes a fresh realtime session id (transcript.beginSession) and has no prompt, settings or audio side effects.
    /// The main thread only takes the conversation snapshot; checkpoint reads and assembly run in the background (same as replanFingerprint).
    func open(
        _ target: RealtimeVoiceTarget,
        conversationID: UUID?,
        transcript: AppStateRealtimeTranscriptSink
    ) async throws -> RealtimeVoiceOpening {
        let sessionID = transcript.beginSession()
        guard let source = sessionSource(conversationID) else { throw RealtimeVoiceOpenError.planRejected }
        let contextWindow = target.entry.contextWindow
        // A new conversation (home page) has no messages, is treated as ordinary history and carries no currentSessionId.
        let currentSessionId = conversationID == nil ? nil : sessionID
        let assembled = await Task.detached(priority: .userInitiated) {
            ContextAssembler.assembleRealtimeSession(source.input(
                contextWindow: contextWindow,
                currentSessionId: currentSessionId,
                sessionMessageIds: []
            ))
        }.value
        guard let plan = PlannedRealtimeSession.from(assembled) else { throw RealtimeVoiceOpenError.planRejected }
        guard let host = Self.host(target.provider) else { throw RealtimeVoiceOpenError.connectionUnavailable }
        let endpoint = RealtimeEndpoint(
            host: host,
            apiKey: ProviderCredentialResolver.apiKey(provider: target.provider, modelID: nil),
            model: target.entry.model,
            path: target.entry.path,
            voice: target.voice,
            inputTranscriptionModel: target.entry.inputTranscriptionModel
        )
        guard let connection = makeConnection(target.entry.transport, endpoint) else {
            throw RealtimeVoiceOpenError.connectionUnavailable
        }
        return RealtimeVoiceOpening(connection: connection, plan: plan)
    }

    /// Turn-boundary replan (called by the controller off the main thread): the main thread only takes the conversation snapshot and this session's id / persisted message ids,
    /// while checkpoint reads, assembly and the instructions sha run in the background; the session's own transcript stays out of the plan, so the fingerprint changes only with external changes.
    func replanFingerprint(
        transcript: AppStateRealtimeTranscriptSink,
        contextWindow: Int
    ) -> RealtimeVoiceConversationController.Replanner {
        let sessionSource = sessionSource
        return {
            let scope: RealtimeReplanScope? = await MainActor.run {
                let conversationID = transcript.conversationID
                guard let source = sessionSource(conversationID) else { return nil }
                return RealtimeReplanScope(
                    source: source,
                    sessionID: conversationID == nil ? nil : transcript.sessionID,
                    own: transcript.sessionMessageIDs
                )
            }
            guard let scope else { return nil }
            return await Task.detached(priority: .utility) {
                ContextAssembler.assembleRealtimeSession(scope.source.input(
                    contextWindow: contextWindow,
                    currentSessionId: scope.sessionID,
                    sessionMessageIds: scope.own
                )).fingerprint
            }.value
        }
    }

    /// Host of the connection address (a missing scheme is treated as https).
    static func host(_ provider: Provider) -> String? {
        guard let raw = provider.requestBaseURLText()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let text = raw.contains("://") ? raw : "https://\(raw)"
        guard let host = URLComponents(string: text)?.host, !host.isEmpty else { return nil }
        return host
    }
}
