package ai.oriveo.community.core.voice.realtime.wire

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** Minimal text WebSocket used by realtime transports; replaced by a fake in tests. */
internal interface RealtimeSocket {
    fun send(text: String): Boolean

    fun close(code: Int, reason: String?)
}

/** Socket callbacks; [onClosed] means the peer closed the connection. */
internal interface RealtimeSocketListener {
    fun onOpen(socket: RealtimeSocket)

    fun onMessage(text: String)

    fun onClosed(code: Int, reason: String)

    fun onFailure(error: Throwable)
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
        val webSocket = client.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
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
                    listener.onFailure(t)
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
