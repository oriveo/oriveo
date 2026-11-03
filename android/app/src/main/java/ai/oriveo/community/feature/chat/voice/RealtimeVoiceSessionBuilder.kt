package ai.oriveo.community.feature.chat.voice

import android.os.SystemClock
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.data.repository.ContextCheckpointRecord
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.RealtimeSessionFingerprint
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.data.repository.RealtimeSessionProjector
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.hostRecognitionLanguage
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.SpeechProbSource
import ai.oriveo.community.core.voice.conversation.StartFailure
import ai.oriveo.community.core.voice.conversation.VoiceConversationForeground
import ai.oriveo.community.core.voice.conversation.VoiceConversationService
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.realtime.RealtimeAudioIO
import ai.oriveo.community.core.voice.realtime.RealtimeConversationSink
import ai.oriveo.community.core.voice.realtime.RealtimeDrafts
import ai.oriveo.community.core.voice.realtime.RealtimeEndReason
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.core.voice.realtime.RealtimeReopenError
import ai.oriveo.community.core.voice.realtime.RealtimeSelection
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import ai.oriveo.community.core.voice.realtime.RealtimeVoiceConversationController
import ai.oriveo.community.core.voice.realtime.wire.RealtimeEndpoint
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionTransport
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransportFactory
import java.net.URI
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import ai.oriveo.community.core.voice.realtime.RealtimeVoiceLog
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

/** What entering a voice conversation runs on. */
internal sealed interface RealtimeVoiceSessionChoice {
    /** The cascade conversation (≋ without a realtime model selected); a realtime selection never falls back to it. */
    data object Cascade : RealtimeVoiceSessionChoice

    class Realtime(val engine: RealtimeVoiceConversationEngine) : RealtimeVoiceSessionChoice

    /** The conversation's realtime model did not open: the stage shows [failure] with the orb at rest; no cascade. */
    data class Failed(val failure: RealtimeFailure) : RealtimeVoiceSessionChoice

    /** The realtime disclosure of [providerKind] is not accepted yet: show it before opening anything. */
    data class Disclosure(val providerKind: ProviderKind) : RealtimeVoiceSessionChoice
}

/**
 * Opens a realtime session for the realtime model selected as the chat's / home pill's model (contract P3-U3
 * items 1–3, 5; S4b): resolve the selection → plan → endpoint → [RealtimeTransportFactory.make] → [RealtimeAudioIO] →
 * [RealtimeVoiceConversationEngine]. ≋ without such a selection is always the cascade; the old engine setting is only
 * read by [migration]. One per app (Koin single).
 */
internal class RealtimeVoiceSessionBuilder(
    private val settings: VoiceEngineSettings,
    private val catalog: suspend () -> VoiceCatalog?,
    /**
     * The voice catalog fetched again from the server (not the cache), asked after a failed connect to tell a removed
     * model (model_gone); null = could not load. Defaults to [catalog] for hosts without a catalog client.
     */
    private val refreshedCatalog: suspend () -> VoiceCatalog? = catalog,
    private val providers: suspend () -> List<Provider>,
    private val conversation: suspend (String) -> Conversation?,
    /** (conversation id or null when there is no row yet, conversation creator, attribution) → sink. */
    private val sinkFor: (String?, suspend () -> String?, RealtimeMessageAttribution) -> RealtimeConversationSink,
    /**
     * Target output route the realtime audio will select on start, sampled when a connection opens; the default
     * stands for a host without audio routing.
     */
    private val outputRoute: () -> ConversationRoute = { ConversationRoute.SPEAKER },
    private val transport: (RealtimeTransportKind, RealtimeEndpoint) -> RealtimeSessionTransport =
        { kind, endpoint -> RealtimeTransportFactory.make(kind, endpoint, route = outputRoute) },
    /**
     * Recognition language (raw BCP-47 tag) sent with each connection: the voice settings choice, else the app UI
     * language — the same fallback as dictation. Null = let the provider detect.
     */
    private val language: () -> String? = { hostRecognitionLanguage(settings) },
    private val audio: () -> RealtimeAudioIO,
    private val scope: CoroutineScope,
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
    /** (conversation id, covered history) → the newest valid stored checkpoint, same lookup as the chat send. */
    private val latestCheckpoint: suspend (String, List<CheckpointCoveredMessage>) -> ContextCheckpointRecord? =
        { _, _ -> null },
    /** Where a turn-boundary replan runs (off the main thread). */
    private val replanContext: CoroutineContext = Dispatchers.IO,
    /** Speech probability model for the speaker uplink gate, loaded per session; null = energy gate. */
    private val speechProbs: SpeechProbSource? = null,
    /**
     * The microphone foreground service the session runs under, same as the cascade (E-454): background / lock screen
     * keep the session, the notification's End ends it as the user. The default stands for a host without one.
     */
    private val foreground: VoiceConversationForeground = NoConversationForeground,
) {
    private var current: RealtimeVoiceConversationEngine? = null

    /** A realtime session is running: message read-aloud buttons do nothing meanwhile. */
    val realtimeActive: Boolean get() = current?.active?.value == true

    /** The realtime engine still running, for the chat page taking a home session over. */
    val running: RealtimeVoiceConversationEngine? get() = current?.takeIf { it.active.value }

    /**
     * [conversationId] null = no conversation row yet: the plan
     * is built from [newConversation] (the conversation the first send would create: the page's model and pending
     * instructions; null = none, stay on the cascade) and the first persist calls [createConversation], which
     * creates it. [contextRequest] = the chat send's context request of the conversation (memory, skill, pinned
     * notes); home passes [newConversationContextRequest].
     */
    suspend fun prepare(
        conversationId: String?,
        contextRequest: suspend (Conversation) -> ChatContextRequest,
        newConversation: (suspend () -> Conversation?)? = null,
        createConversation: suspend () -> String? = { null },
        selected: VoiceEngineSelection.Cloud? = null,
        /** false = session opened by typing: only playback starts (no microphone); the foreground service starts with mediaPlayback, and [RealtimeVoiceConversationEngine.startCapture] enables capture later. */
        capture: Boolean = true,
    ): RealtimeVoiceSessionChoice {
        // ≋ with a text model is always the cascade; the old engine setting no longer opens anything (S4b).
        if (selected == null) return RealtimeVoiceSessionChoice.Cascade
        val route = when (val resolved = selectedRoute(selected)) {
            is Route.Done -> return resolved.choice
            is Route.Ready -> resolved
        }
        val (provider, entry, voice) = route
        val providerKind = provider.kind
        // A model selected as the conversation's never falls back to the cascade: what does not open shows a failure.
        val miss: (String) -> RealtimeVoiceSessionChoice = { category -> failed(category, selected, provider) }
        val kind = RealtimeTransportKind.fromRawValue(entry.transport.rawValue)
            ?: return miss(RealtimeModel.CATEGORY_UNKNOWN)
        val host = hostOf(EndpointResolver.resolveBaseUrl(provider)) ?: return miss(RealtimeModel.CATEGORY_UNKNOWN)
        // The conversation the plan is projected from; a reopen asks again for the one the sink writes to.
        val chatOf: suspend (String?) -> Conversation? = { id ->
            when {
                id != null -> conversation(id)
                newConversation != null -> newConversation()
                else -> Conversation(
                    id = "",
                    title = "",
                    providerID = provider.id,
                    providerKind = provider.kind,
                    modelID = entry.model,
                )
            }
        }
        val chat = chatOf(conversationId) ?: return miss(RealtimeModel.CATEGORY_UNKNOWN)
        val target = SessionTarget(
            kind = kind,
            endpoint = RealtimeEndpoint(
                host = host,
                apiKey = ProviderCredentialResolver.apiKey(provider, null),
                model = entry.model,
                path = entry.path,
                voice = voice,
                inputTranscriptionModel = entry.inputTranscriptionModel,
                language = language(),
            ),
            contextWindow = entry.contextWindow.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            contextRequest = contextRequest,
        )
        val (connection, planned) = planAndConnect(target, chat) ?: return miss(RealtimeModel.CATEGORY_UNKNOWN)
        val attribution = RealtimeMessageAttribution(
            providerID = provider.id,
            providerKind = provider.kind,
            providerName = provider.displayName,
            model = entry.model,
        )
        val sink = sinkFor(conversationId, createConversation, attribution)
        val transcripts = sink as? RepositoryRealtimeTranscriptSink
        // The open session (realtime-session.v1): its id and the transcripts already in its opening plan; a reopen
        // starts a new one.
        val open = AtomicReference(OpenSession(generateUuidString(), emptySet()))
        val engine = RealtimeVoiceConversationEngine(
            connection = connection,
            audio = audio(),
            plan = planned,
            sink = sink,
            attribution = attribution,
            scope = scope,
            clock = clock,
            speechProbs = speechProbs,
            maxSessionSec = entry.maxSessionSec,
            // After a failed connect: is the model still a realtime entry of the voice catalog fetched again.
            catalogHasModel = {
                refreshedCatalog()?.let { fresh ->
                    fresh.entry(providerKind, VoiceDirection.Realtime, entry.model) is VoiceRealtimeEntry
                }
            },
            // Contract B item 4: same target and projection, history of the conversation the sink writes to once
            // its queued turns landed; no notice, no settings change, same sink.
            reopen = {
                val written = transcripts?.drain()
                val latest = chatOf(written ?: conversationId) ?: throw RealtimeReopenError()
                val inPlan = transcripts?.writtenIds().orEmpty()
                (planAndConnect(target, latest) ?: throw RealtimeReopenError())
                    .also { open.set(OpenSession(generateUuidString(), inPlan)) }
            },
            // Turn boundary: the same projection with this session's own transcripts left out, once its queued
            // turns landed; the controller compares the fingerprint with the open session's.
            replan = replan@{
                val session = open.get()
                val written = transcripts?.drain()
                val latest = chatOf(written ?: conversationId) ?: return@replan null
                val own = transcripts?.writtenIds().orEmpty() - session.inPlan
                plan(target, latest, session.id, own).fingerprint
            },
            replanContext = replanContext,
            foreground = foreground,
            capture = capture,
            failureSubject = RealtimeFailureSubject(
                providerId = provider.id,
                providerName = provider.displayName,
                model = entry.model,
            ),
        )
        current = engine
        // A realtime model selected as the conversation's / pill's is never written as last used (E-500).
        return RealtimeVoiceSessionChoice.Realtime(engine)
    }

    /** Where [prepare] stands after resolving what to connect to. */
    private sealed interface Route {
        class Done(val choice: RealtimeVoiceSessionChoice) : Route

        /** [voice] = the catalog entry's default voice. */
        data class Ready(
            val provider: Provider,
            val entry: VoiceRealtimeEntry,
            val voice: String,
        ) : Route
    }

    /**
     * The conversation's own realtime model ([selected]): the realtime disclosure first, then its connection and
     * catalog entry (one rule, [RealtimeSelection]); never rewrites the engine settings, never falls back.
     */
    private suspend fun selectedRoute(selected: VoiceEngineSelection.Cloud): Route {
        if (!settings.disclosure.isAccepted(selected.providerKind, VoiceDirection.Realtime)) {
            return Route.Done(RealtimeVoiceSessionChoice.Disclosure(selected.providerKind))
        }
        val connections = providers()
        val provider = connections.firstOrNull { it.id == selected.connectionId }
            ?: return Route.Done(failed(RealtimeModel.CATEGORY_MODEL_GONE, selected, null))
        val voiceCatalog = catalog() ?: return Route.Done(failed(RealtimeModel.CATEGORY_UNKNOWN, selected, provider))
        val entry = RealtimeSelection.realtimeEntry(provider, selected.model, voiceCatalog)
            ?: return Route.Done(failed(RealtimeModel.CATEGORY_MODEL_GONE, selected, provider))
        return Route.Ready(provider, entry, entry.defaultVoice.id)
    }

    private fun failed(category: String, selected: VoiceEngineSelection.Cloud, provider: Provider?) =
        RealtimeVoiceSessionChoice.Failed(
            RealtimeFailure(
                category = category,
                providerId = selected.connectionId,
                providerName = provider?.displayName.orEmpty(),
                model = selected.model,
            ),
        )

    /**
     * The user agreed to [providerKind]'s realtime disclosure on the voice stage. Its text names the provider the
     * audio goes to, so it also counts as that provider's disclosure (E-694); the store's hook records that for
     * every entry that accepts a realtime disclosure, this one included.
     */
    fun acceptDisclosure(providerKind: ProviderKind) {
        settings.disclosure.markAccepted(providerKind, VoiceDirection.Realtime)
    }

    /** The upgrade migration of the old engine setting, asked on the first ≋ tap (E-455, E-490). */
    fun migration(): RealtimeVoiceMigration = RealtimeVoiceMigration(settings, catalog, providers)

    /** What one session connects to, fixed at prepare; a reopen reuses it without resolving again. */
    private class SessionTarget(
        val kind: RealtimeTransportKind,
        val endpoint: RealtimeEndpoint,
        val contextWindow: Int,
        val contextRequest: suspend (Conversation) -> ChatContextRequest,
    )

    /**
     * Projects [chat] into the opening plan and makes a connection for it: the one path of the first open and a
     * reopen. null = the plan was rejected.
     */
    private suspend fun planAndConnect(
        target: SessionTarget,
        chat: Conversation,
    ): Pair<RealtimeSessionTransport, PlannedRealtimeSession>? {
        val planned = PlannedRealtimeSession.from(plan(target, chat)) ?: return null
        return transport(target.kind, target.endpoint) to planned
    }

    /**
     * The one projection of the opening plan and a turn-boundary replan: [sessionId] null = a new session; otherwise
     * the open session, whose own messages [sessionMessageIds] stay out of the history (realtime-session.v1).
     */
    private suspend fun plan(
        target: SessionTarget,
        chat: Conversation,
        sessionId: String? = null,
        sessionMessageIds: Set<String> = emptySet(),
    ) = RealtimeSessionProjector.projectOpening(
        request = target.contextRequest(chat),
        conversationId = chat.id,
        rawMessages = chat.messages,
        contextWindow = target.contextWindow,
        latestValid = latestCheckpoint,
        currentSessionId = sessionId,
        sessionMessageIds = sessionMessageIds,
    )

    /** [id] of the open realtime session; [inPlan] = transcripts its opening plan already carries as history. */
    private class OpenSession(val id: String, val inPlan: Set<String>)

    private fun hostOf(baseUrl: String): String? =
        runCatching { URI(baseUrl).host }.getOrNull()?.takeIf { it.isNotEmpty() }
}

/**
 * Context of a home realtime plan (no chat page yet): a new conversation carries nothing but memory, injected per
 * the new conversation's memory switch.
 */
internal fun newConversationContextRequest(
    conversation: Conversation,
    memoryItems: List<MemoryItem>,
): ChatContextRequest = ChatContextRequest(
    conversation = ContextConversation(
        id = conversation.id,
        useMemory = conversation.useMemory,
        instructions = conversation.instructions,
    ),
    memoryItems = ChatContextRequest.memoryItems(
        useMemory = conversation.useMemory,
        items = memoryItems,
        conversationId = conversation.id,
        folderId = conversation.folderID,
        now = java.time.Instant.now(),
    ),
)

/**
 * [VoiceConversationEngine] over one [RealtimeVoiceConversationController] session: same status / level types and
 * the same [VoiceConversationEvent]s as the cascade; turns go to the sink, never through the chat port.
 * Single use; public methods on the [scope]'s thread.
 */
internal class RealtimeVoiceConversationEngine(
    private val connection: RealtimeSessionTransport,
    private val audio: RealtimeAudioIO,
    plan: PlannedRealtimeSession,
    private val sink: RealtimeConversationSink,
    /** Who this session's stored turns are attributed to; the live bubbles show the same header. */
    val attribution: RealtimeMessageAttribution? = null,
    private val scope: CoroutineScope,
    private val clock: () -> Long,
    /** New connection + plan after an expiry or a turn-boundary plan change; null makes a reopen fail. */
    reopen: (suspend () -> Pair<RealtimeSessionTransport, PlannedRealtimeSession>)? = null,
    /** Turn-boundary replan of the open session → its fingerprint (realtime-session.v1); null = never reopens on it. */
    replan: (suspend () -> RealtimeSessionFingerprint?)? = null,
    replanContext: CoroutineContext = Dispatchers.IO,
    speechProbs: SpeechProbSource? = null,
    /** Catalog single-session limit (s) of the voice model; null = none. */
    maxSessionSec: Long? = null,
    /** After a failed connect: the model is still in the refreshed voice catalog; null = unknown. */
    catalogHasModel: suspend () -> Boolean? = { null },
    /** Connection and model a failure card names (copy placeholder, open-connection action). */
    private val failureSubject: RealtimeFailureSubject = RealtimeFailureSubject("", "", ""),
    /** The foreground service the host started before [start]; stopped when the session ends. */
    private val foreground: VoiceConversationForeground = NoConversationForeground,
    /** false = only playback, no microphone (session opened by typing): waits for the mediaPlayback foreground service; when [startCapture] returns to the voice stage, capture is enabled and waits for the service to switch to microphone. */
    capture: Boolean = true,
) : VoiceConversationEngine {
    /** Notification End taps of this session; cancelled when it ends (the service's flow outlives the session). */
    private var endRequests: Job? = null
    private val _active = MutableStateFlow(false)
    private val _failure = MutableStateFlow<RealtimeFailure?>(null)
    private val _events = MutableSharedFlow<VoiceConversationEvent>(extraBufferCapacity = 16)
    private var started = false
    private var errorCode: String? = null
    private var startedAt: Long? = null
    private val _capturing = MutableStateFlow(capture)

    // Sentences sent by typing that are not yet persisted (in send order), each with its outcome callback.
    private val typedPending = ArrayDeque<Pair<String, (String) -> Unit>>()

    private val controller = RealtimeVoiceConversationController(
        connection = connection,
        audio = audio,
        plan = plan,
        sink = object : RealtimeConversationSink {
            override fun appendUser(text: String) {
                sink.appendUser(text)
                typedPersisted(text)
            }

            override fun appendAssistant(text: String) {
                sink.appendAssistant(text)
            }

            override suspend fun ensureConversation() = sink.ensureConversation()
        },
        scope = scope,
        onError = { errorCode = it },
        onEnded = ::onEnded,
        clock = clock,
        reopen = reopen,
        replan = replan,
        replanContext = replanContext,
        speechProbs = speechProbs,
        maxSessionSec = maxSessionSec,
        catalogHasModel = catalogHasModel,
        capture = capture,
    )

    override val statusKey: StateFlow<ConversationStatusKey?> = controller.statusKey
    override val level: StateFlow<Float> = controller.level

    /** Stage caption: the assistant's revealed text while it speaks, else the user's live transcript; "" = none. */
    val caption: StateFlow<String> = controller.caption

    /** Live chat-list bubbles of the turn in progress (user transcript, revealed assistant text). */
    val drafts: StateFlow<RealtimeDrafts> = controller.drafts

    /** Ids of the messages this session stored (none for a sink that does not store): the live bubbles' handover. */
    val callMessageIds: StateFlow<Set<String>> =
        (sink as? RepositoryRealtimeTranscriptSink)?.callMessageIds ?: MutableStateFlow(emptySet<String>()).asStateFlow()
    override val active: StateFlow<Boolean> = _active.asStateFlow()

    /** Microphone is on (fully on, or a playback-only session that has since enabled it); false = a session opened by typing: the page stays in typing mode and does not enter the voice stage. */
    val capturing: StateFlow<Boolean> = _capturing.asStateFlow()
    override val events: SharedFlow<VoiceConversationEvent> = _events.asSharedFlow()

    /**
     * The failure this session ended on (set before Ended is emitted); the stage keeps showing it with the orb at
     * rest until [dismissFailure] or a new session. Never toasted.
     */
    val failure: StateFlow<RealtimeFailure?> = _failure.asStateFlow()

    /** The user closed the failure (✕ or a way out that leaves the stage). */
    fun dismissFailure() {
        _failure.value = null
    }

    override fun start(chat: VoiceConversationChatPort) {
        if (started) return
        started = true
        _active.value = true
        // Same as the cascade: the session starts once the service runs in the foreground (E-109 / E-454).
        scope.launch {
            // A playback-only session is started by the same foreground service with mediaPlayback: it keeps running in background and on the lock screen (fixture lifecycle = continue).
            if (!foreground.awaitStarted(serviceKind())) {
                _failure.value = unknownFailure()
                return@launch endBeforeStart(null)
            }
            if (!_active.value) return@launch
            watchEndRequests()
            startedAt = clock()
            controller.start()
        }
    }

    private fun serviceKind() =
        if (_capturing.value) VoiceConversationService.Kind.Microphone else VoiceConversationService.Kind.MediaPlayback

    /** The in-stage card a realtime entry shows when the foreground service did not start: unknown, never a toast. */
    fun unknownFailure() = RealtimeFailure(
        category = RealtimeModel.CATEGORY_UNKNOWN,
        providerId = failureSubject.providerId,
        providerName = failureSubject.providerName,
        model = failureSubject.model,
    )

    /**
     * When capture is enabled late and the foreground service has not switched to microphone (the host's service start was rejected, or the service did not reach the foreground): the stage shows an unknown failure card, no toast;
     * the service has stopped with it, so a playback-only session is torn down too.
     */
    fun captureStartFailed() {
        _capturing.value = false
        if (!_active.value) return
        _failure.value = unknownFailure()
        if (startedAt == null) return endBeforeStart(EndReason.ERROR)
        controller.systemInterruption()
    }

    private fun watchEndRequests() {
        endRequests = scope.launch { foreground.endRequests.collect { end(EndReason.USER) } }
    }

    /**
     * A playback-only session returns to the voice stage: the host has already switched the same foreground service to microphone; after it switches, capture is enabled on the same connection.
     * If it has not switched, capture is not enabled and the failure card in the stage is shown per [captureStartFailed]. Does nothing when already capturing or already ended.
     */
    fun startCapture() {
        if (!_active.value || _capturing.value) return
        _capturing.value = true
        scope.launch {
            if (!foreground.awaitStarted(VoiceConversationService.Kind.Microphone)) return@launch captureStartFailed()
            if (!_active.value) return@launch
            controller.startCapture()
        }
    }

    /**
     * A sentence sent from typing mode (dispatched by the controller in fixture order: start, stop, final transcript persisted once), then sent over the connection;
     * when the AI is speaking, a speech start interrupts it (truncated by the played ms first), without MCP tools.
     */
    fun sendTyped(text: String, onOutcome: (String) -> Unit = {}) {
        if (!_active.value) return onOutcome(RealtimeModel.TYPED_ENDED_BEFORE_PERSIST)
        synchronized(typedPending) { typedPending.addLast(text.trim() to onOutcome) }
        controller.sendUserText(text)
    }

    /** The sentence's user message was persisted: reports persisted, and the host clears the input box on this. Spoken transcripts are not in the queue and are not reported. */
    private fun typedPersisted(text: String) {
        val report = synchronized(typedPending) {
            val index = typedPending.indexOfFirst { it.first == text }
            if (index < 0) null else typedPending.removeAt(index).second
        }
        report?.invoke(RealtimeModel.TYPED_PERSISTED)
    }

    /** Sentences not yet persisted when the session ends: reports endedBeforePersist, and the original text stays in the input box. */
    private fun typedEnded() {
        val reports = synchronized(typedPending) { typedPending.map { it.second }.also { typedPending.clear() } }
        reports.forEach { it(RealtimeModel.TYPED_ENDED_BEFORE_PERSIST) }
    }

    /**
     * Ends before the session started (waiting for the foreground service): [reason] null = the service never ran,
     * refused before entering and nothing reported (same as the cascade); otherwise ended as [reason].
     */
    private fun endBeforeStart(reason: EndReason?) {
        if (!_active.value) return
        _active.value = false
        connection.close()
        closeSink()
        foreground.stop()
        typedEnded()
        _events.tryEmit(
            reason?.let { VoiceConversationEvent.Ended(it, null) }
                ?: VoiceConversationEvent.StartFailed(StartFailure.FOREGROUND),
        )
    }

    override fun tapOrb() = controller.tapOrb()

    override fun toggleMute() = controller.toggleMute()

    override fun screenReaderSpeaking(speaking: Boolean) = controller.screenReaderSpeaking(speaking)

    override fun end(reason: EndReason) {
        if (!_active.value) return
        if (startedAt == null) return endBeforeStart(reason)
        if (reason == EndReason.USER) controller.end() else controller.systemInterruption()
    }

    /** Leaving the page keeps the half-spoken transcript as a draft (same as iOS and the cascade): it takes the user end. */
    override fun endLeavingPage() {
        if (!_active.value) return
        if (startedAt == null) return endBeforeStart(EndReason.SYSTEM)
        controller.end()
    }

    /** Entering failed after [RealtimeVoiceSessionBuilder.prepare] (never started): releases the sink. */
    fun discard() {
        if (!started) closeSink()
    }

    private fun closeSink() {
        (sink as? AutoCloseable)?.close()
    }

    /** Call, Siri or permanent audio focus loss (E-454; background and lock screen keep the session): closes the connection. */
    fun systemInterruption() {
        if (!_active.value) return
        if (startedAt == null) return endBeforeStart(EndReason.SYSTEM)
        controller.systemInterruption()
    }

    private fun onEnded(reason: RealtimeEndReason, draft: String?) {
        if (!_active.value) return
        _active.value = false
        endRequests?.cancel()
        endRequests = null
        closeSink()
        foreground.stop()
        val endReason = when (reason) {
            RealtimeEndReason.USER -> EndReason.USER
            RealtimeEndReason.SYSTEM -> EndReason.SYSTEM
            RealtimeEndReason.IDLE -> EndReason.IDLE
            RealtimeEndReason.ERROR -> EndReason.ERROR
        }
        if (endReason == EndReason.ERROR) {
            _failure.value = RealtimeFailure(
                category = errorCode?.takeIf { it in RealtimeModel.CATEGORIES } ?: RealtimeModel.CATEGORY_UNKNOWN,
                providerId = failureSubject.providerId,
                providerName = failureSubject.providerName,
                model = failureSubject.model,
            )
        }
        typedEnded()
        draft?.takeIf { it.isNotBlank() }?.let { _events.tryEmit(VoiceConversationEvent.DraftTranscript(it)) }
        _events.tryEmit(VoiceConversationEvent.Ended(endReason, if (endReason == EndReason.ERROR) errorCode else null))
    }
}

/** A host without a foreground service: always started, no notification. */
internal object NoConversationForeground : VoiceConversationForeground {
    override suspend fun awaitStarted() = true

    override val endRequests: Flow<Unit> = emptyFlow()

    override fun stop() = Unit
}
