package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import java.io.IOException
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CopyableThrowable
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/** The peer closed the realtime socket before the session ended. */
internal class RealtimeSocketClosedException(val code: Int, reason: String) :
    IOException("realtime socket closed by peer: $code $reason")

/**
 * The uplink stopped draining: more than 8 s of audio sat unsent in the socket queue, so the session ends with
 * [uplinkBacklogMs] for the controller to classify. Opts out of coroutine stack-trace recovery, which would
 * otherwise wrap a copy around it as cause.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class RealtimeUplinkStalledException(override val uplinkBacklogMs: Double) :
    IOException("realtime uplink stalled"),
    RealtimeFailureDetail,
    CopyableThrowable<RealtimeUplinkStalledException> {
    override fun createCopy(): RealtimeUplinkStalledException? = null
}

/**
 * WebSocket transport for the GA realtime APIs (OpenAI / xAI).
 * Each collection of [openRealtimeSession] opens one connection; [RealtimeSessionControl] acts on the latest one.
 */
internal class GARealtimeTransport(
    override val kind: RealtimeTransportKind,
    private val endpoint: RealtimeEndpoint,
    private val socketFactory: RealtimeSocketFactory = OkHttpRealtimeSocketFactory(),
    /** Target output route, sampled once per opened connection. */
    private val route: () -> ConversationRoute = { ConversationRoute.SPEAKER },
) : RealtimeSessionTransport {

    init {
        require(kind == RealtimeTransportKind.OpenAiRealtime || kind == RealtimeTransportKind.XaiRealtime) {
            "GARealtimeTransport only supports GA transports, got ${kind.rawValue}"
        }
    }

    private val current = AtomicReference<Session?>(null)

    /** Latest route reported by [updateOutputRoute]; null = sample [route]. */
    @Volatile private var latestRoute: ConversationRoute? = null

    override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> = callbackFlow {
        val openedRoute = latestRoute ?: route()
        val session = Session(this, openedRoute)
        current.set(session)
        val opening = GARealtimeCodec.openingMessages(
            kind = kind,
            instructions = transport.instructions,
            history = transport.history,
            voice = endpoint.voice,
            inputTranscriptionModel = endpoint.inputTranscriptionModel,
            route = openedRoute,
            language = endpoint.language,
        )
        val url = requireNotNull(GARealtimeCodec.connectUrl(kind, endpoint.host, endpoint.path, endpoint.model))
        val listener = object : RealtimeSocketListener {
            override fun onOpen(socket: RealtimeSocket) {
                session.socket.set(socket)
                opening.forEach { socket.send(it.toString()) }
            }

            override fun onMessage(text: String) = session.receive(text)

            override fun onClosed(code: Int, reason: String) {
                session.end(RealtimeSocketClosedException(code, reason), closeSocket = false)
            }

            override fun onFailure(error: Throwable) = session.end(error, closeSocket = false)
        }
        val socket = socketFactory.connect(url, mapOf("Authorization" to "Bearer ${endpoint.apiKey}"), listener)
        session.socket.compareAndSet(null, socket)
        awaitClose {
            session.closeSocket()
            current.compareAndSet(session, null)
        }
    }.buffer(Channel.UNLIMITED)

    override fun sendAudio(pcm: ByteArray) {
        val session = current.get() ?: return
        if (!session.ready.get()) return
        val base64 = Base64.getEncoder().encodeToString(pcm)
        val message = GARealtimeCodec.append(kind, base64) ?: return
        session.sendAudio(message.toString(), base64.length)
    }

    override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
        val message = GARealtimeCodec.truncate(kind, itemId, contentIndex, playedMs) ?: return
        current.get()?.send(message)
    }

    override fun sendUserText(text: String) {
        current.get()?.sendUserText(text)
    }

    override fun updateOutputRoute(route: ConversationRoute) {
        latestRoute = route
        current.get()?.retune(route)
    }

    override fun close() {
        current.get()?.end(null, closeSocket = true)
    }

    private inner class Session(
        private val scope: ProducerScope<RealtimeSessionEvent>,
        /** Route the opening session.update was built for; guarded by [held] after that. */
        private var sentRoute: ConversationRoute,
    ) {
        val socket = AtomicReference<RealtimeSocket?>(null)
        val ready = AtomicBoolean(false)

        // Typed user items waiting for ready, in call order; the lock also orders them against the ready flush.
        // They are answered by a single response.create at ready.
        private val held = ArrayList<JsonObject>()

        // Guarded by [held]: a typed item was sent during an active response, so its response.create waits for
        // that response's response.done (only one response may write the default conversation at a time).
        private var pendingCreate = false
        private val ended = AtomicBoolean(false)
        private val socketClosed = AtomicBoolean(false)
        private val state = GARealtimeCodec.State()

        fun send(message: JsonObject) {
            if (ended.get()) return
            socket.get()?.send(message.toString())
        }

        /** Sends one audio frame, then ends the session when the uplink backlog exceeds 8 s of audio. */
        fun sendAudio(message: String, base64Chars: Int) {
            if (ended.get()) return
            val target = socket.get() ?: return
            target.send(message)
            val backlogMs = uplinkStalled(target, base64Chars, message.length) ?: return
            end(RealtimeUplinkStalledException(backlogMs), closeSocket = true)
        }

        /**
         * Estimates the audio bytes still queued on [target] from its byte backlog, scaled by this frame's
         * base64-to-message ratio (base64 is 4/3 of the PCM bytes); its duration in ms when it exceeds
         * [STALL_AUDIO_BYTES], null otherwise.
         */
        private fun uplinkStalled(target: RealtimeSocket, base64Chars: Int, messageChars: Int): Double? {
            val queued = target.queueSize
            if (queued <= 0L || messageChars <= 0) return null
            val audioBytes = queued * base64Chars / messageChars * 3 / 4
            if (audioBytes <= STALL_AUDIO_BYTES) return null
            return audioBytes * 1000.0 / (GARealtimeCodec.INPUT_SAMPLE_RATE_HZ * 2L)
        }

        fun receive(text: String) {
            if (ended.get()) return
            // Non-JSON or non-object frames carry no contract event and are skipped.
            val message = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return
            for (event in GARealtimeCodec.map(kind, message, state)) {
                if (event == RealtimeSessionEvent.Ready) onReady()
                scope.trySend(event)
                if (event is RealtimeSessionEvent.AssistantTurnDone) onResponseDone()
                if (event is RealtimeSessionEvent.SessionEnded) {
                    end(null, closeSocket = true)
                    return
                }
            }
        }

        /**
         * A typed message. Before ready its item is held (one response.create follows the flush). When ready
         * with a response in progress: response.cancel (once), the item, and the response.create deferred to
         * response.done. Otherwise item + response.create right away.
         */
        fun sendUserText(text: String) {
            val item = GARealtimeCodec.userItem(kind, text) ?: return
            // Sent under the lock so a message never overtakes the ones flushed at ready or at response.done.
            synchronized(held) {
                when {
                    !ready.get() -> held += item
                    state.responseActive || pendingCreate -> {
                        if (!pendingCreate) GARealtimeCodec.responseCancel(kind)?.let(::send)
                        send(item)
                        pendingCreate = true
                    }
                    else -> {
                        send(item)
                        sendCreateLocked()
                    }
                }
            }
        }

        /** response.done: sends the deferred response.create, if any. */
        private fun onResponseDone() {
            synchronized(held) {
                if (!pendingCreate) return
                pendingCreate = false
                sendCreateLocked()
            }
        }

        /**
         * Under [held]: sends response.create and counts the response as in progress from this moment, so a typed
         * message before its response.created still cancels first.
         */
        private fun sendCreateLocked() {
            GARealtimeCodec.responseCreate(kind)?.let(::send)
            state.responseActive = true
        }

        /** A route change: session.update now when ready and the knob differs from what the session was tuned for. */
        fun retune(route: ConversationRoute) {
            synchronized(held) {
                if (ready.get()) retuneLocked(route)
            }
        }

        /** Under [held]: sends the update only when its noise_reduction differs from the last one sent. */
        private fun retuneLocked(route: ConversationRoute) {
            val update = GARealtimeCodec.routeUpdate(kind, route)
            val previous = GARealtimeCodec.routeUpdate(kind, sentRoute)
            sentRoute = route
            if (update != null && update != previous) send(update)
        }

        private fun onReady() {
            synchronized(held) {
                if (ready.getAndSet(true)) return
                // A route change while connecting: retune before the held messages are answered.
                latestRoute?.let(::retuneLocked)
                held.forEach(::send)
                // All held items share one response.create: a second one would hit the active response.
                if (held.isNotEmpty()) sendCreateLocked()
                held.clear()
            }
        }

        /** Ends the flow once: [error] null completes normally, otherwise the flow fails with it. */
        fun end(error: Throwable?, closeSocket: Boolean) {
            if (!ended.compareAndSet(false, true)) return
            // The connection is gone: deferred and held messages are dropped.
            synchronized(held) {
                pendingCreate = false
                held.clear()
            }
            if (closeSocket) closeSocket() else socketClosed.set(true)
            scope.channel.close(error)
        }

        fun closeSocket() {
            if (!socketClosed.compareAndSet(false, true)) return
            socket.get()?.close(NORMAL_CLOSURE, null)
        }
    }

    private companion object {
        const val NORMAL_CLOSURE = 1000
        /** Contract E: 8 s of 16-bit mono input audio; a larger uplink backlog ends the session. */
        const val STALL_AUDIO_BYTES = GARealtimeCodec.INPUT_SAMPLE_RATE_HZ * 2L * 8
    }
}
