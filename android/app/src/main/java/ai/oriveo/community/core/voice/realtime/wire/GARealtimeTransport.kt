package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import java.io.IOException
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
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
 * WebSocket transport for the GA realtime APIs (OpenAI / xAI).
 * Each collection of [openRealtimeSession] opens one connection; [RealtimeSessionControl] acts on the latest one.
 */
internal class GARealtimeTransport(
    override val kind: RealtimeTransportKind,
    private val endpoint: RealtimeEndpoint,
    private val socketFactory: RealtimeSocketFactory = OkHttpRealtimeSocketFactory(),
) : RealtimeSessionTransport {

    init {
        require(kind == RealtimeTransportKind.OpenAiRealtime || kind == RealtimeTransportKind.XaiRealtime) {
            "GARealtimeTransport only supports GA transports, got ${kind.rawValue}"
        }
    }

    private val current = AtomicReference<Session?>(null)

    override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> = callbackFlow {
        val session = Session(this)
        current.set(session)
        val opening = GARealtimeCodec.openingMessages(
            kind = kind,
            instructions = transport.instructions,
            history = transport.history,
            voice = endpoint.voice,
            inputTranscriptionModel = endpoint.inputTranscriptionModel,
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
        val message = GARealtimeCodec.append(kind, Base64.getEncoder().encodeToString(pcm)) ?: return
        session.send(message)
    }

    override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
        val message = GARealtimeCodec.truncate(kind, itemId, contentIndex, playedMs) ?: return
        current.get()?.send(message)
    }

    override fun close() {
        current.get()?.end(null, closeSocket = true)
    }

    private inner class Session(private val scope: ProducerScope<RealtimeSessionEvent>) {
        val socket = AtomicReference<RealtimeSocket?>(null)
        val ready = AtomicBoolean(false)
        private val ended = AtomicBoolean(false)
        private val socketClosed = AtomicBoolean(false)
        private val state = GARealtimeCodec.State()

        fun send(message: JsonObject) {
            if (ended.get()) return
            socket.get()?.send(message.toString())
        }

        fun receive(text: String) {
            if (ended.get()) return
            // Non-JSON or non-object frames carry no contract event and are skipped.
            val message = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return
            for (event in GARealtimeCodec.map(kind, message, state)) {
                if (event == RealtimeSessionEvent.Ready) ready.set(true)
                scope.trySend(event)
                if (event is RealtimeSessionEvent.SessionEnded) {
                    end(null, closeSocket = true)
                    return
                }
            }
        }

        /** Ends the flow once: [error] null completes normally, otherwise the flow fails with it. */
        fun end(error: Throwable?, closeSocket: Boolean) {
            if (!ended.compareAndSet(false, true)) return
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
    }
}
