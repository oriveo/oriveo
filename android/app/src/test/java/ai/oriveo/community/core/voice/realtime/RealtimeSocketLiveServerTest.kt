package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveConfig
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveTransport
import ai.oriveo.community.core.voice.realtime.wire.OkHttpGeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.OkHttpRealtimeSocketFactory
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Real OkHttp against a local WebSocket server: after an unexpected Gemini disconnect it reconnects with the handle, and the new connection establishes, receives setupComplete,
 * and uplink and the event stream continue (the equivalent iOS path hit ENOTCONN within 1 s on a new socket; this checks Android does not share that problem); both realtime sockets enable a 20 s ping.
 */
class RealtimeSocketLiveServerTest {

    private val server = MockWebServer()

    @After
    fun tearDown() {
        server.shutdown()
    }

    /** One connection on the server side: received frames are queued in order, and onOpen hands out the server WebSocket. */
    private class ServerConnection : WebSocketListener() {
        val received = LinkedBlockingQueue<JsonObject>()
        val socket = CompletableDeferred<WebSocket>()

        override fun onOpen(webSocket: WebSocket, response: Response) {
            socket.complete(webSocket)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            received.put(Json.parseToJsonElement(text).jsonObject)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, null)
        }

        /** The next client frame; time-limited, so a timeout fails instead of hanging. */
        fun next(): JsonObject = received.poll(TIMEOUT_S, TimeUnit.SECONDS) ?: throw AssertionError("no client frame within timeout")

        /** Skips non-audio frames and takes the data of the next realtimeInput audio. */
        fun nextAudio(): String {
            while (true) {
                val frame = next()
                val audio = frame["realtimeInput"]?.jsonObject?.get("audio")?.jsonObject ?: continue
                return audio["data"]!!.jsonPrimitive.content
            }
        }
    }

    private val setupComplete = """{"setupComplete":{}}"""
    private fun resumable(handle: String) = """{"sessionResumptionUpdate":{"newHandle":"$handle","resumable":true}}"""

    @Test
    fun `unexpected_close_reconnects_with_handle_over_real_okhttp`() = runBlocking {
        val first = ServerConnection()
        val second = ServerConnection()
        server.enqueue(MockResponse().withWebSocketUpgrade(first))
        server.enqueue(MockResponse().withWebSocketUpgrade(second))
        server.start()

        val config = GeminiLiveConfig(
            host = "${server.hostName}:${server.port}",
            path = "/ws/live",
            model = "gemini-live",
            voice = "Kore",
            apiKey = "test-key",
        )
        // The transport always builds wss://; the local server is plaintext, so only the scheme is changed and the rest is left to the real OkHttpGeminiLiveSocketFactory.
        val factory = GeminiLiveSocketFactory { url -> OkHttpGeminiLiveSocketFactory.connect(url.replaceFirst("wss://", "ws://")) }
        val transport = GeminiLiveTransport(config, socketFactory = factory)
        val events = Channel<RealtimeSessionEvent>(Channel.UNLIMITED)
        val error = CompletableDeferred<Throwable?>()
        val job = launch(Dispatchers.IO) {
            try {
                transport.openRealtimeSession(RealtimeTransportInput(instructions = "Be brief.", history = emptyList()))
                    .collect { events.send(it) }
                error.complete(null)
            } catch (e: Throwable) {
                error.complete(e)
            }
        }
        suspend fun nextEvent(): RealtimeSessionEvent = withTimeout(TIMEOUT_S * 1000) { events.receive() }

        // First connection: setup carries no handle; after replying setupComplete and a resumable handle the server closes with 1011 (server-side RealWebSocket.cancel is unavailable)
        val firstSetup = first.next()
        assertNotNull(firstSetup["setup"])
        assertNull(firstSetup["setup"]!!.jsonObject["sessionResumption"]?.jsonObject?.get("handle"))
        val firstSocket = withTimeout(TIMEOUT_S * 1000) { first.socket.await() }
        firstSocket.send(setupComplete)
        firstSocket.send(resumable("h1"))
        assertEquals(RealtimeSessionEvent.Ready, nextEvent())
        assertEquals(RealtimeSessionEvent.Resumable("h1"), nextEvent())
        firstSocket.close(1011, null)

        // Second connection: setup carries handle h1, and after setupComplete uplink and the event stream continue
        val secondSetup = second.next()
        assertEquals("h1", secondSetup["setup"]!!.jsonObject["sessionResumption"]!!.jsonObject["handle"]!!.jsonPrimitive.content)
        val secondSocket = withTimeout(TIMEOUT_S * 1000) { second.socket.await() }
        secondSocket.send(setupComplete)
        secondSocket.send(resumable("h2"))
        assertEquals(RealtimeSessionEvent.Resumable("h2"), nextEvent())
        transport.appendAudio("AAAA")
        assertEquals("AAAA", second.nextAudio())
        // The new connection can still send uplink after 1 s (iOS hit ENOTCONN here)
        delay(1_500)
        transport.appendAudio("BBBB")
        assertEquals("BBBB", second.nextAudio())
        secondSocket.send("""{"serverContent":{"inputTranscription":{"text":"Hey"}}}""")
        var transcript: RealtimeSessionEvent
        do transcript = nextEvent() while (transcript !is RealtimeSessionEvent.UserTranscript)
        assertEquals("Hey", (transcript as RealtimeSessionEvent.UserTranscript).text)

        transport.close()
        assertNull(withTimeout(TIMEOUT_S * 1000) { error.await() })
        job.join()
        assertEquals("h2", transport.lastResumeHandle)
        assertEquals(2, server.requestCount)
        assertEquals("/ws/live?key=test-key", server.takeRequest().path)
        assertEquals("/ws/live?key=test-key", server.takeRequest().path)
    }

    @Test
    fun `realtime_socket_clients_do_not_ping`() {
        // The observed disconnect is the server's idle-session expiry (1008), which a ping cannot prevent, so no ping is set
        assertEquals(0, OkHttpGeminiLiveSocketFactory.client.pingIntervalMillis)
        assertEquals(0, OkHttpRealtimeSocketFactory.sharedClient.pingIntervalMillis)
    }

    private companion object {
        const val TIMEOUT_S = 5L
    }
}
