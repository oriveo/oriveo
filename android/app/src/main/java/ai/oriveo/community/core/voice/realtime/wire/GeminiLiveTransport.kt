package ai.oriveo.community.core.voice.realtime.wire

import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.RealtimeTransportKind
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CopyableThrowable
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/** Connection parameters for one Gemini Live model entry. */
internal data class GeminiLiveConfig(
    val host: String,
    val path: String,
    val model: String,
    val voice: String,
    val apiKey: String,
) {
    override fun toString(): String = "GeminiLiveConfig(host=$host, path=$path, model=$model, voice=$voice, apiKey=***)"
}

/** Minimal text socket; [receive] returning null or throwing means the connection is closed. */
internal interface GeminiLiveSocket {
    suspend fun send(text: String)

    suspend fun receive(): String?

    /** WebSocket close code sent by the server, once it has closed the connection; null otherwise. */
    val closeCode: Int? get() = null

    /** WebSocket close reason sent by the server with [closeCode]; null when none. */
    val closeReason: String? get() = null

    /** Bytes handed to [send] but not yet transmitted (OkHttp `WebSocket.queueSize()`); 0 when not tracked. */
    val queueSize: Long get() = 0L

    fun close()

    /** Drops the connection at once without flushing queued frames; defaults to [close]. */
    fun cancel() = close()
}

internal fun interface GeminiLiveSocketFactory {
    suspend fun connect(url: String): GeminiLiveSocket
}

/**
 * The Gemini Live connection closed or failed in a way that ends the session with an error.
 * Carries no cause and never the URL: the URL holds the API key as ?key=.
 * Opts out of coroutine stack-trace recovery, which would otherwise wrap a copy around it as cause.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class GeminiLiveClosedException(message: String) :
    IOException(message),
    CopyableThrowable<GeminiLiveClosedException> {
    override fun createCopy(): GeminiLiveClosedException? = null
}

/**
 * The server closed a Gemini Live session with 1008 after it was ready (first or resumed connection): the session
 * expired, so resuming with the handle cannot succeed. Ends the stream without reconnecting; no cause, no URL.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class GeminiLiveSessionExpiredException(message: String) :
    IOException(message),
    CopyableThrowable<GeminiLiveSessionExpiredException> {
    override fun createCopy(): GeminiLiveSessionExpiredException? = null
}

/**
 * Default factory: bare OkHttp WebSocket over a shared lazy client, like [OkHttpRealtimeSocketFactory].
 * The Ktor WebSockets layer is not used: over it the server saw uplink activity ~15 s late and never answered.
 */
internal object OkHttpGeminiLiveSocketFactory : GeminiLiveSocketFactory {
    /**
     * No WebSocket ping  and no uplink while the user is silent : an idle session may expire, and an
     * expiry while muted sleeps and reopens a new session on unmute.
     */
    internal val client: OkHttpClient by lazy { realtimeOkHttpClient() }

    override suspend fun connect(url: String): GeminiLiveSocket {
        val socket = OkHttpGeminiLiveSocket()
        val webSocket = client.newWebSocket(Request.Builder().url(url).build(), socket.listener)
        socket.bind(webSocket)
        try {
            socket.opened.await()
        } catch (e: Throwable) {
            webSocket.cancel()
            throw e
        }
        return socket
    }
}

/** Messages are buffered in an unbounded channel; Binary frames are decoded as UTF-8 JSON like Text frames. */
private class OkHttpGeminiLiveSocket : GeminiLiveSocket {
    private val incoming = Channel<String>(Channel.UNLIMITED)
    val opened = CompletableDeferred<Unit>()

    @Volatile
    private var webSocket: WebSocket? = null

    fun bind(socket: WebSocket) {
        webSocket = socket
    }

    override suspend fun send(text: String) {
        if (webSocket?.send(text) != true) throw IOException("Gemini Live socket closed")
    }

    override suspend fun receive(): String? = incoming.receiveCatching().getOrNull()

    @Volatile
    override var closeCode: Int? = null
        private set

    @Volatile
    override var closeReason: String? = null
        private set

    override val queueSize: Long get() = webSocket?.queueSize() ?: 0L

    override fun close() {
        webSocket?.close(1000, null)
    }

    override fun cancel() {
        webSocket?.cancel()
    }

    val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            opened.complete(Unit)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            incoming.trySend(text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            incoming.trySend(bytes.utf8())
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            // Recorded before the channel closes so the reader sees it with the end of stream.
            closeCode = code
            closeReason = reason
            webSocket.close(code, null)
            incoming.close()
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            incoming.close()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            // No cause and no URL: the URL carries the API key as ?key=.
            opened.completeExceptionally(IOException("Gemini Live socket failed (${t::class.java.simpleName})"))
            incoming.close()
        }
    }
}

/**
 * Gemini Live transport: opens the session, maps server messages,
 * and transparently resumes on goAway with the latest resumable handle ; an unexpected close
 * (not host-initiated, not during a goAway switch) also reconnects with that handle when one is known.
 * The host feeds microphone audio via [appendAudio] and ends the session with [close].
 */
internal class GeminiLiveTransport(
    private val config: GeminiLiveConfig,
    private val resumeHandle: String? = null,
    internal val socketFactory: GeminiLiveSocketFactory = OkHttpGeminiLiveSocketFactory,
    private val wait: suspend (Long) -> Unit = { delay(it) },
) : RealtimeTransport {

    override val kind: RealtimeTransportKind = RealtimeTransportKind.GeminiLive

    /** Latest resumable handle seen (or the one this transport was opened with). */
    @Volatile
    var lastResumeHandle: String? = resumeHandle?.takeIf { it.isNotEmpty() }
        private set

    private val current = AtomicReference<Channel<Signal>?>(null)

    @Volatile
    private var closed = false

    /** Completed by [close]; lets a reconnect backoff end at once instead of waiting it out. */
    private val hostClosed = CompletableDeferred<Unit>()

    /** Audio waiting for a ready connection (before the first ready and while switching), newest kept. */
    private val pending = PendingAudio()

    override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> = channelFlow {
        if (closed) return@channelFlow
        val signals = Channel<Signal>(Channel.UNLIMITED)
        current.set(signals)
        // close() may have raced with registration: it is sticky, so honour it.
        if (closed) signals.trySend(Signal.HostClose)
        try {
            Session(this, transport, signals).run()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // Close with the cause instead of throwing: a failing producer would drop the events already
            // buffered (e.g. user text flushed right before the error); closing delivers them, then the error.
            close(e)
        } finally {
            current.compareAndSet(signals, null)
            signals.close()
        }
    }.buffer(Channel.UNLIMITED)

    /** One base64 chunk of 16 kHz PCM16; buffered until a connection is ready (also before collection starts). */
    fun appendAudio(base64: String) {
        if (closed) return
        val signals = current.get()
        if (signals == null || !signals.trySend(Signal.Audio(base64)).isSuccess) pending.add(base64)
    }

    /** Sticky: closes the socket and completes the flow normally without emitting an event; later opens end at once. */
    fun close() {
        closed = true
        hostClosed.complete(Unit)
        current.get()?.trySend(Signal.HostClose)
    }

    /** Ordered base64 chunks capped at [MAX_PENDING_AUDIO_CHARS] total characters, dropping the oldest. */
    private class PendingAudio {
        private val chunks = ArrayDeque<String>()
        private var chars = 0

        @Synchronized
        fun add(base64: String) {
            chunks.addLast(base64)
            chars += base64.length
            while (chars > MAX_PENDING_AUDIO_CHARS && chunks.isNotEmpty()) chars -= chunks.removeFirst().length
        }

        /** Puts chunks back ahead of anything queued since, keeping order; the cap still drops the oldest. */
        @Synchronized
        fun prepend(base64s: List<String>) {
            for (base64 in base64s.asReversed()) {
                chunks.addFirst(base64)
                chars += base64.length
            }
            while (chars > MAX_PENDING_AUDIO_CHARS && chunks.isNotEmpty()) chars -= chunks.removeFirst().length
        }

        @Synchronized
        fun drain(): List<String> {
            val out = chunks.toList()
            chunks.clear()
            chars = 0
            return out
        }
    }

    private sealed interface Signal {
        class Message(val connection: Connection, val message: JsonObject) : Signal

        class Closed(val connection: Connection, val error: Throwable?, val code: Int? = null) : Signal

        class Deadline(val connection: Connection) : Signal

        class Audio(val base64: String) : Signal

        data object HostClose : Signal
    }

    private class Connection(val socket: GeminiLiveSocket, val isSwitch: Boolean, val afterReady: List<JsonObject>) {
        val mapper = GeminiLiveEventMapper()
        var ready = false
        var reader: Job? = null
        /** Set when the uplink stalled: drop the socket without flushing its backlog. */
        var stalled = false
        /** Audio most recently handed to this socket, newest kept; resent after a stall since the queue is lost. */
        val recentAudio = PendingAudio()

        fun close() {
            reader?.cancel()
            socket.close()
            // Stalled: the close frame queues behind the backlog, so tear down right after .
            if (stalled) socket.cancel()
        }
    }

    private inner class Session(
        private val scope: ProducerScope<RealtimeSessionEvent>,
        private val input: RealtimeTransportInput,
        private val signals: Channel<Signal>,
    ) {
        private lateinit var connection: Connection
        private var goAwayPending = false
        private var endOnClose = false
        /** True until the current connection is ready: before the first ready and while switching. */
        private var buffering = true
        private var deadline: Job? = null
        /** True while a reconnect after an unexpected close has not reached ready yet. */
        private var recovering = false
        private var reconnectAttempts = 0
        /** The unexpected-close error that started the current reconnect run; the session ends with it. */
        private var reconnectError: GeminiLiveClosedException? = null

        suspend fun run() {
            try {
                connection = connect(lastResumeHandle, isSwitch = false)
                for (signal in signals) {
                    val finished = when (signal) {
                        is Signal.Message -> signal.connection === connection && onMessage(signal.message)
                        is Signal.Closed -> signal.connection === connection && onClosed(signal.error, signal.code)
                        is Signal.Deadline -> signal.connection === connection && goAwayPending && switchNow()
                        is Signal.Audio -> onAudio(signal.base64)
                        Signal.HostClose -> true
                    }
                    if (finished) return
                }
            } finally {
                deadline?.cancel()
                if (::connection.isInitialized) connection.close()
            }
        }

        private suspend fun connect(handle: String?, isSwitch: Boolean): Connection {
            val url = GeminiLiveWire.authenticatedUrl(config.host, config.path, config.apiKey)
            val opening = GeminiLiveWire.openingMessages(input.instructions, input.history, config.model, config.voice, handle)
            val socket = try {
                socketFactory.connect(url)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw GeminiLiveClosedException(failure(if (isSwitch) "resumed connection failed to open" else "connection failed to open", e))
            }
            val opened = Connection(socket, isSwitch, opening.afterReady)
            try {
                opened.reader = scope.launch { readLoop(opened) }
                for (message in opening.beforeReady) send(opened, message.toString())
            } catch (e: Throwable) {
                // Not yet the session's connection: close it here so a failed or cancelled setup never leaks it.
                opened.close()
                throw e
            }
            return opened
        }

        private suspend fun readLoop(target: Connection) {
            while (true) {
                val text = try {
                    target.socket.receive()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    signals.send(Signal.Closed(target, e))
                    return
                }
                if (text == null) {
                    signals.send(Signal.Closed(target, null, target.socket.closeCode))
                    return
                }
                // Non-JSON or non-object frames carry no contract event and are skipped.
                val message = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: continue
                signals.send(Signal.Message(target, message))
            }
        }

        private suspend fun send(target: Connection, text: String) {
            try {
                target.socket.send(text)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val stage = if (target.ready) "send failed" else "send failed before setupComplete"
                throw GeminiLiveClosedException(failure(stage, e))
            }
        }

        /** Returns true when the session finished normally. */
        private suspend fun onMessage(message: JsonObject): Boolean {
            val target = connection
            for (event in target.mapper.map(message)) {
                when (event) {
                    RealtimeSessionEvent.Ready -> {
                        if (target.ready) continue
                        target.ready = true
                        if (!target.isSwitch) {
                            scope.send(event)
                            for (after in target.afterReady) send(target, after.toString())
                        }
                        buffering = false
                        recovering = false
                        // Attempts are not reset here: only the first serverContent after ready proves the
                        // connection works, so "ready, then dropped" keeps counting toward the limit.
                        reconnectError = null
                        val queued = pending.drain()
                        for ((index, base64) in queued.withIndex()) {
                            try {
                                send(target, GeminiLiveWire.audioAppendMessage(base64).toString())
                                target.recentAudio.add(base64)
                            } catch (e: GeminiLiveClosedException) {
                                // Same rule as a send failure in onAudio: keep the unsent chunks in order and resume.
                                if (lastResumeHandle == null) throw flushedBeforeEnd(e)
                                pending.prepend(queued.subList(index, queued.size))
                                reconnectError = e
                                return reconnect()
                            }
                        }
                    }
                    is RealtimeSessionEvent.Resumable -> {
                        lastResumeHandle = event.handle
                        scope.send(event)
                    }
                    is RealtimeSessionEvent.GoAway -> {
                        scope.send(event)
                        goAwayPending = true
                        deadline?.cancel()
                        deadline = event.timeLeftMs?.let { timeLeft ->
                            scope.launch {
                                wait(maxOf(timeLeft - GO_AWAY_MARGIN_MS, 0))
                                signals.send(Signal.Deadline(target))
                            }
                        }
                    }
                    else -> scope.send(event)
                }
            }
            if (target.ready && message.containsKey("serverContent")) reconnectAttempts = 0
            return goAwayPending && !target.mapper.midTurn && switchNow()
        }

        /** Returns true when the session finished normally; throws when it ends with an error. */
        private suspend fun onClosed(error: Throwable?, code: Int?): Boolean {
            val target = connection
            // 1008 once the session was ready (a ready connection, or any resumed one): session not found or expired.
            // Checked before a handle-less goAway's normal end, like iOS.
            if (code == SESSION_REJECTED_CODE && (target.ready || target.isSwitch)) {
                throw flushedBeforeEnd(
                    GeminiLiveSessionExpiredException(
                        failure("session expired ($code)", null) + closeReasonSuffix(target.socket.closeReason),
                    ),
                )
            }
            if (endOnClose) return endGoAway()
            if (recovering) return reconnect()
            if (target.isSwitch && !target.ready) {
                throw GeminiLiveClosedException(failure("resumed connection closed before setupComplete", error))
            }
            if (goAwayPending) {
                // Old connection closed by the server: switch now, or end if there is no handle.
                if (lastResumeHandle == null) return endGoAway()
                return switchNow()
            }
            val unexpected = GeminiLiveClosedException(failure("connection closed unexpectedly", error))
            if (lastResumeHandle == null) throw flushedBeforeEnd(unexpected)
            reconnectError = unexpected
            return reconnect()
        }

        /**
         * Reconnects with the latest handle after an unexpected close, like a goAway switch (no history resent).
         * Each attempt first waits [RECONNECT_BACKOFF_MS] (rides out a brief network outage); after all attempts
         * fail to reach a working connection, ends with the original error. The first serverContent after ready
         * resets attempts and backoff.
         * Returns true only when the host closed during the backoff.
         */
        private suspend fun reconnect(): Boolean {
            val original = checkNotNull(reconnectError)
            val handle = lastResumeHandle ?: throw original
            if (reconnectAttempts >= RECONNECT_BACKOFF_MS.size) throw original
            val backoff = RECONNECT_BACKOFF_MS[reconnectAttempts]
            reconnectAttempts++
            flushPendingUser()
            connection.close()
            buffering = true
            recovering = true
            if (backoffInterruptedByClose(backoff) || closed) return true
            connection = try {
                connect(handle, isSwitch = true)
            } catch (e: GeminiLiveClosedException) {
                return reconnect()
            }
            return false
        }

        /** Waits [backoff] ms via the injected wait; returns true as soon as the host closes, cancelling the wait. */
        private suspend fun backoffInterruptedByClose(backoff: Long): Boolean = coroutineScope {
            val sleeper = async { wait(backoff) }
            try {
                select {
                    hostClosed.onAwait { true }
                    sleeper.onAwait { false }
                }
            } finally {
                sleeper.cancel()
            }
        }

                /** Describes a failure by stage and error type only: error messages may echo the keyed URL. */
        private fun failure(stage: String, error: Throwable?): String =
            "Gemini Live $stage" + (error?.let { " (${it::class.java.simpleName})" } ?: "")

        /**
         * ": <reason>" with URLs, key parameters, the API key and its percent-encoding removed, cut to
         * [CLOSE_REASON_LIMIT] chars; empty when blank.
         */
        private fun closeReasonSuffix(reason: String?): String {
            var text = reason.orEmpty()
                .replace(URL_PATTERN, "<url>")
                .replace(KEY_PATTERN, "key=<redacted>")
            val key = config.apiKey
            if (key.isNotEmpty()) {
                text = text.replace(key, "<redacted>").replace(GeminiLiveWire.percentEncodeUnreserved(key), "<redacted>")
            }
            val clean = text.trim().take(CLOSE_REASON_LIMIT)
            return if (clean.isEmpty()) "" else ": $clean"
        }

        /** Ends normally; pending user text (including text that arrived while waiting for the close) goes out final first. */
        private suspend fun endGoAway(): Boolean {
            flushPendingUser()
            scope.send(RealtimeSessionEvent.SessionEnded(GO_AWAY_REASON))
            return true
        }

        /** Before ending with [error] (no handle to resume, or the session expired): pending user text goes out final first. */
        private suspend fun <E : IOException> flushedBeforeEnd(error: E): E {
            flushPendingUser()
            return error
        }

        /** Before the current mapper is replaced: emits its pending user text as final (realtime-events rules.map). */
        private suspend fun flushPendingUser() {
            for (event in connection.mapper.flushPendingUser()) scope.send(event)
        }

        /** Switches to a resumed connection; without a handle waits for the old one to close. Always false. */
        private suspend fun switchNow(): Boolean {
            goAwayPending = false
            deadline?.cancel()
            deadline = null
            val handle = lastResumeHandle
            if (handle == null) {
                endOnClose = true
                return false
            }
            flushPendingUser()
            connection.close()
            buffering = true
            connection = connect(handle, isSwitch = true)
            return false
        }

        /**
         * While waiting for the server to close after a handle-less goAway, audio still goes to the old connection.
         * A send failure on a ready connection counts as an unexpected close: with a handle the chunk is kept
         * for the resumed connection and the session reconnects; without one it ends with the error. During a
         * handle-less goAway it ends the session normally, as the server close would. False unless it ended.
         */
        private suspend fun onAudio(base64: String): Boolean {
            if (buffering) {
                pending.add(base64)
                return false
            }
            val target = connection
            val message = GeminiLiveWire.audioAppendMessage(base64).toString()
            try {
                send(target, message)
            } catch (e: GeminiLiveClosedException) {
                if (endOnClose) return endGoAway()
                if (lastResumeHandle == null) throw flushedBeforeEnd(e)
                pending.add(base64)
                reconnectError = e
                return reconnect()
            }
            target.recentAudio.add(base64)
            if (!uplinkStalled(target, base64.length, message.length)) return false
            // Contract E: a backlog over 8 s of audio means the connection is stuck; treat it as an unexpected
            // close. Queued frames die with the socket, so the newest ~5 s handed to it (the pending cap) are kept for the resume.
            target.stalled = true
            val stalled = GeminiLiveClosedException(failure("uplink stalled", null))
            if (endOnClose) return endGoAway()
            // Without a handle it ends with the error; run() then drops the socket.
            if (lastResumeHandle == null) throw flushedBeforeEnd(stalled)
            pending.prepend(target.recentAudio.drain())
            reconnectError = stalled
            return reconnect()
        }

        /**
         * Estimates the audio bytes still queued on [target] from its byte backlog, scaled by this frame's
         * base64-to-message ratio (base64 is 4/3 of the PCM bytes); true when it exceeds [STALL_AUDIO_BYTES].
         */
        private fun uplinkStalled(target: Connection, base64Chars: Int, messageChars: Int): Boolean {
            val queued = target.socket.queueSize
            if (queued <= 0L || messageChars <= 0) return false
            val audioBytes = queued * base64Chars / messageChars * 3 / 4
            return audioBytes > STALL_AUDIO_BYTES
        }
    }

    private companion object {
        const val GO_AWAY_MARGIN_MS = 1_000L
        const val GO_AWAY_REASON = "go_away"
        /** Close code of a resume refused because the session no longer exists or has expired. */
        const val SESSION_REJECTED_CODE = 1008

        /** Close reason kept in the expiry message and diagnostics (contract F item 1). */
        const val CLOSE_REASON_LIMIT = 200
        private val URL_PATTERN = Regex("""[A-Za-z][A-Za-z0-9+.-]*://\S*""")
        private val KEY_PATTERN = Regex("""(?i)key=\S*""")
        const val MAX_PENDING_AUDIO_CHARS = 220_000
        /**
         * Contract E: queued uplink audio above 8 s (sample rate × 2 bytes × 8) marks the connection as stuck.
         * Kept above [MAX_PENDING_AUDIO_CHARS] (~5.16 s) so flushing a full buffer after a resume cannot trip it.
         */
        const val STALL_AUDIO_BYTES = GeminiLiveWire.INPUT_SAMPLE_RATE_HZ * 2L * 8
        /** Wait before each reconnect attempt after an unexpected close; its size is the attempt limit. */
        val RECONNECT_BACKOFF_MS = longArrayOf(0L, 1_000L, 2_000L, 4_000L)
    }
}
