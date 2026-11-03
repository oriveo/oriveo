package ai.oriveo.community.core.voice.realtime.wire

import java.io.IOException
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** Minimal text WebSocket used by realtime transports; replaced by a fake in tests. */
internal interface RealtimeSocket {
    fun send(text: String): Boolean

    /** Bytes handed to [send] but not yet transmitted (OkHttp `WebSocket.queueSize()`); 0 when not tracked. */
    val queueSize: Long get() = 0L

    fun close(code: Int, reason: String?)
}

/** Socket callbacks; [onClosed] means the peer closed the connection. */
internal interface RealtimeSocketListener {
    fun onOpen(socket: RealtimeSocket)

    fun onMessage(text: String)

    fun onClosed(code: Int, reason: String)

    fun onFailure(error: Throwable)
}

/**
 * Normalized failure facts a realtime transport attaches to the error a session ends with, read by the controller to
 * classify the failure (E-453). Never carries the URL or the key.
 */
internal interface RealtimeFailureDetail {
    /** HTTP status of the WebSocket handshake response; null when none arrived. */
    val httpStatus: Int? get() = null

    /** The connection failed to open (handshake failed or never completed). */
    val connectFailed: Boolean get() = false

    /** The transport's own reconnects (Gemini resume handle) were all used up without a working connection. */
    val reconnectsExhausted: Boolean get() = false

    /** Estimated audio still queued on the uplink when the session gave up on it, in ms. */
    val uplinkBacklogMs: Double? get() = null
}

/**
 * A realtime WebSocket failed before it opened. [httpStatus] is the handshake response status when the server
 * answered (401 / 403 / 404 / 429 …). Carries only the failure type name: messages may echo the keyed URL.
 */
internal class RealtimeHandshakeException(override val httpStatus: Int?, causeType: String) :
    IOException("realtime socket failed to open (${httpStatus ?: "no response"}, $causeType)"),
    RealtimeFailureDetail {
    override val connectFailed: Boolean get() = true
}

internal fun interface RealtimeSocketFactory {
    fun connect(url: String, headers: Map<String, String>, listener: RealtimeSocketListener): RealtimeSocket
}

/** OkHttp WebSocket implementation. */
internal class OkHttpRealtimeSocketFactory(
    private val client: OkHttpClient = sharedClient,
) : RealtimeSocketFactory {
    override fun connect(url: String, headers: Map<String, String>, listener: RealtimeSocketListener): RealtimeSocket {
        val request = Request.Builder()
            .url(url)
            .apply { headers.forEach { (name, value) -> header(name, value) } }
            .build()
        val socket = OkHttpRealtimeSocket()
        // Written on OkHttp's thread only: a failure before onOpen is a handshake failure.
        var opened = false
        val webSocket = client.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    opened = true
                    socket.bind(webSocket)
                    listener.onOpen(socket)
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    listener.onMessage(text)
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(code, null)
                    listener.onClosed(code, reason)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    listener.onClosed(code, reason)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    listener.onFailure(
                        if (opened) t else RealtimeHandshakeException(response?.code, t::class.java.simpleName),
                    )
                }
            },
        )
        socket.bind(webSocket)
        return socket
    }

    private class OkHttpRealtimeSocket : RealtimeSocket {
        @Volatile private var webSocket: WebSocket? = null

        fun bind(socket: WebSocket) {
            webSocket = socket
        }

        override fun send(text: String): Boolean = webSocket?.send(text) ?: false

        override val queueSize: Long get() = webSocket?.queueSize() ?: 0L

        override fun close(code: Int, reason: String?) {
            webSocket?.close(code, reason)
        }
    }

    internal companion object {
        val sharedClient: OkHttpClient by lazy { realtimeOkHttpClient() }
    }
}

/**
 * OkHttp client for realtime WebSockets, without WebSocket pings: the observed drop of a silent session is the
 * server closing the idle session (1008), which pings do not prevent.
 */
internal fun realtimeOkHttpClient(): OkHttpClient = OkHttpClient.Builder().build()
