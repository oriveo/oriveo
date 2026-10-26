package ai.oriveo.community.feature.chat.voice

import android.os.SystemClock
import ai.oriveo.community.R
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
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.RelayModelFallback
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceConnection
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngine
import ai.oriveo.community.core.voice.VoiceEngineResolution
import ai.oriveo.community.core.voice.VoiceEngineResolver
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceFallbackReason
import ai.oriveo.community.core.voice.VoiceNoticeSite
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.realtime.RealtimeAudioIO
import ai.oriveo.community.core.voice.realtime.RealtimeConversationSink
import ai.oriveo.community.core.voice.realtime.RealtimeEndReason
import ai.oriveo.community.core.voice.realtime.RealtimeReopenError
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
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

/** What entering a voice conversation runs on. */
internal sealed interface RealtimeVoiceSessionChoice {
    /**
     * The cascade conversation. [fallback] = the realtime selection fell back (use-notice consumed here);
     * [planRejected] = the realtime plan was rejected for this conversation.
     */
    data class Cascade(
        val fallback: VoiceFallbackReason? = null,
        val planRejected: Boolean = false,
    ) : RealtimeVoiceSessionChoice {
        /** Toast to show before the cascade starts; null = none. A fallback is told once (its use notice). */
        val toast: Int? get() = when {
            planRejected -> R.string.voice_conversation_start_failed_toast
            fallback != null -> R.string.voice_realtime_engine_fallback_toast
            else -> null
        }
    }

    class Realtime(val engine: RealtimeVoiceConversationEngine) : RealtimeVoiceSessionChoice
}

/**
 * Opens a realtime session for a chat page's ≋ when the conversation engine selection is a cloud realtime model
 *: resolve the selection → plan → endpoint → [RealtimeTransportFactory.make] →
 * [RealtimeAudioIO] → [RealtimeVoiceConversationEngine]. Anything that does not resolve stays on the cascade.
 * No foreground service: the session closes when the app goes to the background. One per app (Koin single).
 */
internal class RealtimeVoiceSessionBuilder(
    private val settings: VoiceEngineSettings,
    private val catalog: suspend () -> VoiceCatalog?,
    private val providers: suspend () -> List<Provider>,
    private val conversation: suspend (String) -> Conversation?,
    /** (conversation id or null when there is no row yet, conversation creator, attribution) → sink. */
    private val sinkFor: (String?, suspend () -> String?, RealtimeMessageAttribution) -> RealtimeConversationSink,
    private val transport: (RealtimeTransportKind, RealtimeEndpoint) -> RealtimeSessionTransport =
        { kind, endpoint -> RealtimeTransportFactory.make(kind, endpoint) },
    private val audio: () -> RealtimeAudioIO,
    private val scope: CoroutineScope,
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
    /** Writes (connection id, stored model id) as last used; starting a realtime call counts as a send. */
    private val rememberLastUsed: suspend (String, String) -> Unit = { _, _ -> },
    /** (conversation id, covered history) → the newest valid stored checkpoint, same lookup as the chat send. */
    private val latestCheckpoint: suspend (String, List<CheckpointCoveredMessage>) -> ContextCheckpointRecord? =
        { _, _ -> null },
    /** Where a turn-boundary replan runs (off the main thread). */
    private val replanContext: CoroutineContext = Dispatchers.IO,
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
    ): RealtimeVoiceSessionChoice {
        val selection = settings.selection(VoiceDirection.Realtime) as? VoiceEngineSelection.Cloud
            ?: return RealtimeVoiceSessionChoice.Cascade(apply(VoiceEngineResolution(VoiceEngine.System)))
        // The stored provider's disclosure is not accepted: cascade this time without resolving — no rewrite, no notice.
        if (!settings.disclosure.isAccepted(selection.providerKind, VoiceDirection.Realtime)) {
            return RealtimeVoiceSessionChoice.Cascade()
        }
        val voiceCatalog = catalog() ?: return RealtimeVoiceSessionChoice.Cascade(apply(null))
        val connections = providers()
        val resolution = VoiceEngineResolver.resolve(
            catalog = voiceCatalog,
            direction = VoiceDirection.Realtime,
            selection = selection,
            connections = connections.map(VoiceConnection::from),
        )
        val reason = apply(resolution)
        val cascade = RealtimeVoiceSessionChoice.Cascade(reason)
        val resolved = resolution.engine as? VoiceEngine.Cloud ?: return cascade
        val provider = connections.firstOrNull { it.id == resolved.connectionId } ?: return cascade
        val entry = voiceCatalog.entry(resolved.providerKind, VoiceDirection.Realtime, resolved.model)
            as? VoiceRealtimeEntry ?: return cascade
        val kind = RealtimeTransportKind.fromRawValue(entry.transport.rawValue) ?: return cascade
        val host = hostOf(EndpointResolver.resolveBaseUrl(provider)) ?: return cascade
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
        val chat = chatOf(conversationId) ?: return cascade
        val target = SessionTarget(
            kind = kind,
            endpoint = RealtimeEndpoint(
                host = host,
                apiKey = ProviderCredentialResolver.apiKey(provider, null),
                model = entry.model,
                path = entry.path,
                voice = resolved.voice ?: entry.defaultVoice.id,
                inputTranscriptionModel = entry.inputTranscriptionModel,
            ),
            contextWindow = entry.contextWindow.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            contextRequest = contextRequest,
        )
        val (connection, planned) = planAndConnect(target, chat)
            ?: return RealtimeVoiceSessionChoice.Cascade(reason, planRejected = true)
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
            scope = scope,
            clock = clock,
            // Same target and projection, history of the conversation the sink writes to once
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
        )
        current = engine
        // The chat model of the conversation the call belongs to; the bare fallback row carries the voice model, not one.
        // A model the chat could not send on is not written.
        if ((conversationId != null || newConversation != null) && chatSendable(connections, chat)) {
            chat.modelID.takeIf { it.isNotBlank() }?.let { runCatching { rememberLastUsed(chat.providerID, it) } }
        }
        return RealtimeVoiceSessionChoice.Realtime(engine)
    }

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

    internal companion object {
        /**
         * The chat could send on [chat]'s model (same gates as the chat page's send): its connection still exists
         * the official model is not retired, the relay model is still enabled.
         */
        internal fun chatSendable(connections: List<Provider>, chat: Conversation): Boolean {
            val provider = connections.firstOrNull { it.id == chat.providerID }
                ?: return false
            if (ProviderSelectionSnapshot.modelRetirement(provider, chat.modelID)?.sendBlocked == true) return false
            return RelayModelFallback.removedConnectionName(provider, chat.modelID) == null
        }
    }

    private fun apply(resolution: VoiceEngineResolution?): VoiceFallbackReason? =
        settings.applyResolution(VoiceDirection.Realtime, resolution, VoiceNoticeSite.Use)

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
    connection: RealtimeSessionTransport,
    private val audio: RealtimeAudioIO,
    plan: PlannedRealtimeSession,
    private val sink: RealtimeConversationSink,
    scope: CoroutineScope,
    private val clock: () -> Long,
    /** New connection + plan after an expiry or a turn-boundary plan change; null makes a reopen fail. */
    reopen: (suspend () -> Pair<RealtimeSessionTransport, PlannedRealtimeSession>)? = null,
    /** Turn-boundary replan of the open session → its fingerprint (realtime-session.v1); null = never reopens on it. */
    replan: (suspend () -> RealtimeSessionFingerprint?)? = null,
    replanContext: CoroutineContext = Dispatchers.IO,
) : VoiceConversationEngine {
    private val _active = MutableStateFlow(false)
    private val _events = MutableSharedFlow<VoiceConversationEvent>(extraBufferCapacity = 16)
    private var started = false
    private var errorCode: String? = null

    private val controller = RealtimeVoiceConversationController(
        connection = connection,
        audio = audio,
        plan = plan,
        sink = object : RealtimeConversationSink {
            override fun appendUser(text: String) = sink.appendUser(text)

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
    )

    override val statusKey: StateFlow<ConversationStatusKey?> = controller.statusKey
    override val level: StateFlow<Float> = controller.level
    override val active: StateFlow<Boolean> = _active.asStateFlow()
    override val events: SharedFlow<VoiceConversationEvent> = _events.asSharedFlow()

    override fun start(chat: VoiceConversationChatPort) {
        if (started) return
        started = true
        _active.value = true
        controller.start()
    }

    override fun tapOrb() = controller.tapOrb()

    override fun toggleMute() = controller.toggleMute()

    override fun screenReaderSpeaking(speaking: Boolean) = controller.screenReaderSpeaking(speaking)

    override fun end(reason: EndReason) {
        if (!_active.value) return
        if (reason == EndReason.USER) controller.end() else controller.systemInterruption()
    }

    // Leaving the page keeps the half-spoken transcript as a draft (same as the cascade): it takes the user end.
    override fun endLeavingPage() {
        if (!_active.value) return
        controller.end()
    }

    /** Entering failed after [RealtimeVoiceSessionBuilder.prepare] (never started): releases the sink. */
    fun discard() {
        if (!started) closeSink()
    }

    private fun closeSink() {
        (sink as? AutoCloseable)?.close()
    }

    /** Background, call or Siri-like system takeover: closes the connection. */
    fun systemInterruption() {
        if (!_active.value) return
        controller.systemInterruption()
    }

    private fun onEnded(reason: RealtimeEndReason, draft: String?) {
        if (!_active.value) return
        _active.value = false
        closeSink()
        val endReason = when (reason) {
            RealtimeEndReason.USER -> EndReason.USER
            RealtimeEndReason.SYSTEM -> EndReason.SYSTEM
            RealtimeEndReason.IDLE -> EndReason.IDLE
            RealtimeEndReason.ERROR -> EndReason.ERROR
        }
        draft?.takeIf { it.isNotBlank() }?.let { _events.tryEmit(VoiceConversationEvent.DraftTranscript(it)) }
        _events.tryEmit(VoiceConversationEvent.Ended(endReason, if (endReason == EndReason.ERROR) errorCode else null))
    }
}
