import AVFoundation
import Foundation
import OriveoProviderKit

extension RealtimeVoiceConversationController: VoiceConversationSurface {}

/// Audio for the realtime session: forwarded to VPIO, and also provides the real current route for analytics.
final class RealtimeVoiceAudio: RealtimeAudioIO, SessionLeaseAwareAudio {
    private let inner: any RealtimeAudioIO
    private let currentRoute: () -> VoiceConversationLogic.Route

    init(_ inner: any RealtimeAudioIO, route: @escaping () -> VoiceConversationLogic.Route) {
        self.inner = inner
        self.currentRoute = route
    }

    /// The actual current route of the realtime audio (analytics route).
    var route: VoiceConversationLogic.Route { currentRoute() }

    func prepareSession() async throws {
        try await inner.prepareSession()
    }

    func startRealtime(
        uplinkSampleRate: Double,
        onFrame: @escaping (Data) -> Void,
        onInterruption: @escaping () -> Void
    ) throws {
        try inner.startRealtime(uplinkSampleRate: uplinkSampleRate, onFrame: onFrame, onInterruption: onInterruption)
    }

    func startRealtimePlayback(onInterruption: @escaping () -> Void) throws {
        try inner.startRealtimePlayback(onInterruption: onInterruption)
    }

    func startRealtimeCapture(uplinkSampleRate: Double, onFrame: @escaping (Data) -> Void) throws {
        try inner.startRealtimeCapture(uplinkSampleRate: uplinkSampleRate, onFrame: onFrame)
    }

    func enqueue(pcm16: Data, itemId: String) { inner.enqueue(pcm16: pcm16, itemId: itemId) }
    func playedMs(itemId: String) -> Int { inner.playedMs(itemId: itemId) }
    var isPlaying: Bool { inner.isPlaying }
    var onPlaybackDrained: (() -> Void)? {
        get { inner.onPlaybackDrained }
        set { inner.onPlaybackDrained = newValue }
    }
    var onOutputLevel: ((Double) -> Void)? {
        get { inner.onOutputLevel }
        set { inner.onOutputLevel = newValue }
    }
    var onRouteChanged: ((VoiceConversationLogic.Route) -> Void)? {
        get { inner.onRouteChanged }
        set { inner.onRouteChanged = newValue }
    }
    func stopRealtimePlayback() { inner.stopRealtimePlayback() }
    func stopRealtime() {
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
    /// For failure classification and copy: provider display name, catalog model, and the catalog's per-session limit.
    var failureContext = RealtimeFailureContext()
    /// When a failure happens before this connection was ever ready, re-fetch the catalog and answer whether the model is still in the realtime catalog (nil = unavailable).
    var catalogHasModel: RealtimeVoiceConversationController.CatalogCheck?
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
    /// Realtime selection is active but cannot open: the stage reports the failure in place (copy and way out), without cascading or toasting.
    case failed(RealtimeVoiceFailure)
    /// Realtime selection is active but the provider's realtime direction has not yet consented to the disclosure (e.g. restored from backup): the page shows the disclosure first and opens after consent (no cascade).
    case needsDisclosure(RealtimeModelSelection)
}

/// Realtime selection from the picker (AppState.realtimeModelSelection) → realtime session parts: disclosure gate, catalog entry, opening plan, endpoint, transport and audio.
/// No longer reads the old conversation engine choice in VoiceEngineSettings (only for migration reads).
struct RealtimeVoiceSessionBuilder {
    typealias Reopen = (_ conversationID: UUID?) async throws -> RealtimeVoiceOpening

    /// Realtime selection for this conversation (nil on the home page); nil = a text model is selected, so cascade.
    var selection: (_ conversationID: UUID?) -> RealtimeModelSelection?
    /// Disclosure consent record for the realtime direction (the same one written when a realtime row is picked in the picker).
    var disclosures: VoiceDisclosureStore
    var catalog: @MainActor @Sendable () async -> VoiceCatalog?
    /// Catalog re-fetch used for failure classification (network refresh, not cache-first), also bounded by catalogLimit.
    var refreshCatalog: @MainActor @Sendable () async -> VoiceCatalog?
    var providers: () -> [Provider]
    /// Source of the opening input, shared with chat sending (ChatManager.prepareRequestSnapshot → realtimeSessionSource): the main thread only takes a snapshot,
    /// assembly happens in RealtimeSessionSource.input; with a nil conversation id (home page) it uses new-conversation defaults + the current memory items.
    var sessionSource: @MainActor @Sendable (_ conversationID: UUID?) -> RealtimeSessionSource?
    var makeConnection: (_ kind: RealtimeTransportKind, _ endpoint: RealtimeEndpoint) -> (any RealtimeTransport & RealtimeSessionControl)?
    var makeAudio: () -> RealtimeVoiceAudio
    var makeSink: (_ conversationID: UUID?, _ attribution: RealtimeVoiceAttribution) -> AppStateRealtimeTranscriptSink
    /// Upper bound on fetching the catalog before entering (network refresh on cold start); on timeout the model is unavailable: the stage reports unknown and settings are not changed.
    var catalogLimit: Duration = DictationEngineSource.catalogLimit
    /// Recognition language setting (same one as dictation); the transcription language uses it, and if empty, the UI language.
    var voiceSettings = VoiceEngineSettings()
    /// App UI language; read each time a connection opens.
    var uiLocale: () -> Locale = { AppLocalization.currentLanguage.locale }

    static var fallbackToast: String {
        L10n.tr("Your conversation engine isn't available anymore, so this conversation uses the current model.", table: .voice)
    }

    /// audioSession is passed in through VoiceConversationSession.Dependencies (the same instance as its audioSession).
    static func production(appState: AppState, audioSession: VoiceAudioSessionOwner) -> RealtimeVoiceSessionBuilder {
        RealtimeVoiceSessionBuilder(
            selection: { [weak appState] id in appState?.realtimeModelSelection(for: id) },
            disclosures: VoiceDisclosureStore(),
            catalog: { await DictationEngineSource.sharedCatalog()?.catalog },
            refreshCatalog: { await VoiceCatalogClient.shared.refresh().catalog },
            providers: { [weak appState] in appState?.providers ?? [] },
            sessionSource: { [weak appState] id in
                guard let appState else { return nil }
                guard let id else { return appState.chatManager.realtimeSessionSourceForNewConversation() }
                return appState.chatManager.realtimeSessionSource(in: id)
            },
            makeConnection: { kind, endpoint in
                RealtimeTransportFactory.make(kind: kind, endpoint: endpoint, route: { Self.currentOutputRoute() })
            },
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

    /// Output route at the moment the connection opens, mapped like the VPIO engine. Called on the transport layer in the background: reading currentRoute does not require the main thread,
    /// and must not synchronously wait for the main thread (which may itself be waiting for the coordinator or the transport layer).
    nonisolated static func currentOutputRoute() -> VoiceConversationLogic.Route {
        VPIOConversationAudioEngine.route(of: AVAudioSession.sharedInstance().currentRoute)
    }

    func prepare(conversationID: UUID?) async -> RealtimeVoiceStart {
        guard let selected = selection(conversationID) else { return .cascade(toast: nil) }
        // The selection takes effect only after consent; without consent (e.g. restored from backup): hand off to the page to show the disclosure first, no cascade, and do not clear the selection.
        guard disclosures.hasAccepted(selected.providerKind, direction: .realtime) else { return .needsDisclosure(selected) }
        let selectedProvider = providers().first(where: { $0.id == selected.providerID })
        // Catalog fetch failed / timed out: the stage reports unknown (only a connection or catalog missing the model is model_gone), no cascade.
        let catalog = self.catalog
        guard let catalog = await VoiceDeadline.value(within: catalogLimit, { await catalog() }) ?? nil else {
            return .failed(RealtimeVoiceConversationController.failure(
                category: .unknown,
                context: RealtimeFailureContext(providerName: selectedProvider?.displayName, model: selected.model)
            ))
        }
        // Selected connection deleted / catalog delisted the model / no usable voice: the stage reports model_gone, no cascade.
        guard let provider = selectedProvider,
              let entry = catalog.realtimeEntries(selected.providerKind).first(where: { $0.model == selected.model }),
              let voice = entry.defaultVoice?.id
        else {
            return .failed(RealtimeVoiceConversationController.failure(
                category: .modelGone,
                context: RealtimeFailureContext(providerName: selectedProvider?.displayName, model: selected.model)
            ))
        }
        let target = RealtimeVoiceTarget(provider: provider, entry: entry, voice: voice)
        let attribution = RealtimeVoiceAttribution(
            providerID: provider.id,
            providerKind: provider.kind,
            providerName: provider.displayName,
            model: entry.model
        )
        let sink = makeSink(conversationID, attribution)
        let failureContext = RealtimeFailureContext(
            providerName: provider.displayName,
            model: entry.model,
            maxSessionSec: entry.maxSessionSec.map(Double.init)
        )
        // Opening plan rejected / connection address missing: there is no handshake signal at all, so classifyFailure's empty signal maps it to unknown, and the stage reports the failure.
        guard let opening = try? await open(target, conversationID: conversationID, transcript: sink) else {
            let category = RealtimeModelPolicy.classifyFailure(RealtimeModelPolicy.FailureSignal()).category
            return .failed(RealtimeVoiceConversationController.failure(category: category, context: failureContext))
        }
        return .realtime(RealtimeVoiceSessionParts(
            connection: opening.connection,
            audio: makeAudio(),
            plan: opening.plan,
            sink: sink,
            attribution: attribution,
            reopen: { id in try await open(target, conversationID: id, transcript: sink) },
            replanFingerprint: replanFingerprint(transcript: sink, contextWindow: entry.contextWindow),
            failureContext: failureContext,
            catalogHasModel: catalogHasModel(selected.providerKind, model: entry.model)
        ))
    }

    /// After a failure, re-fetch the catalog: whether the new catalog's realtime[kind] still contains the model; nil if unavailable or timed out; cancellation is rethrown.
    func catalogHasModel(_ kind: ProviderKind, model: String) -> RealtimeVoiceConversationController.CatalogCheck {
        let refresh = refreshCatalog
        let limit = catalogLimit
        return {
            let fetched = await VoiceDeadline.value(within: limit, { await refresh() }) ?? nil
            try Task.checkCancellation()
            guard let fetched else { return nil }
            return fetched.realtimeEntries(kind).contains { $0.model == model }
        }
    }

    /// Produces only the plan + connection: the opening input takes the conversation's current content (including transcripts already persisted by earlier connections) → assemble → endpoint → transport.
    /// Shared by the first open and reopen; each time a new realtime session id is issued (transcript.beginSession), with no prompt, settings or audio side effects.
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
            inputTranscriptionModel: target.entry.inputTranscriptionModel,
            language: DictationController.recognitionLanguageID(voiceSettings.recognitionLanguage, uiLocale: uiLocale())
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
