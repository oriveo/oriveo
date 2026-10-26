package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.voice.realtime.wire.GARealtimeCodec
import ai.oriveo.community.core.voice.realtime.wire.GARealtimeTransport
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionControl
import ai.oriveo.community.core.voice.realtime.wire.RealtimeEndpoint
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocket
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketClosedException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketListener
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransportFactory
import java.io.IOException
import java.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** GARealtimeTransport over a fake socket: connection parameters, opening order, frame mapping and how the stream ends. */
@OptIn(ExperimentalCoroutinesApi::class)
class GARealtimeTransportTest {

    private class FakeSocket : RealtimeSocket {
        val sent = mutableListOf<JsonObject>()
        val closes = mutableListOf<Int>()

        override fun send(text: String): Boolean {
            sent += Json.parseToJsonElement(text).jsonObject
            return true
        }

        override fun close(code: Int, reason: String?) {
            closes += code
        }
    }

    private class FakeFactory : RealtimeSocketFactory {
        val socket = FakeSocket()
        var url: String? = null
        var headers: Map<String, String> = emptyMap()
        lateinit var listener: RealtimeSocketListener

        override fun connect(url: String, headers: Map<String, String>, listener: RealtimeSocketListener): RealtimeSocket {
            this.url = url
            this.headers = headers
            this.listener = listener
            return socket
        }

        fun open() = listener.onOpen(socket)

        fun frame(json: String) = listener.onMessage(json)
    }

    private class Collected(val job: Job) {
        val events = mutableListOf<RealtimeSessionEvent>()
        var failure: Throwable? = null
        var completed = false
    }

    private val endpoint = RealtimeEndpoint(
        host = "api.openai.com",
        apiKey = "sk-test",
        model = "gpt-realtime",
        path = "/v1/realtime",
        voice = "marin",
        inputTranscriptionModel = "gpt-4o-transcribe",
    )

    private val input = RealtimeTransportInput(
        instructions = "Be brief.",
        history = listOf(RealtimeHistoryItem(ChatRole.User, "hi"), RealtimeHistoryItem(ChatRole.Assistant, "hello")),
    )

    private fun TestScope.collect(transport: GARealtimeTransport): Collected {
        lateinit var collected: Collected
        val job = CoroutineScope(UnconfinedTestDispatcher(testScheduler)).launch {
            try {
                transport.openRealtimeSession(input).collect { collected.events += it }
                collected.completed = true
            } catch (error: Throwable) {
                collected.failure = error
            }
        }
        collected = Collected(job)
        testScheduler.runCurrent()
        return collected
    }

    private fun transport(kind: RealtimeTransportKind = RealtimeTransportKind.OpenAiRealtime): Pair<GARealtimeTransport, FakeFactory> {
        val factory = FakeFactory()
        return GARealtimeTransport(kind, endpoint, factory) to factory
    }

    @Test
    fun connects_with_bearer_and_url() = runTest {
        val (transport, factory) = transport()
        val collected = collect(transport)
        assertEquals("wss://api.openai.com/v1/realtime?model=gpt-realtime", factory.url)
        assertEquals("Bearer sk-test", factory.headers["Authorization"])
        assertTrue(factory.socket.sent.isEmpty())
        transport.close()
        testScheduler.runCurrent()
        assertTrue(collected.completed)
    }

    @Test
    fun opening_sent_before_ready_audio_after_ready() = runTest {
        val (transport, factory) = transport()
        val collected = collect(transport)
        val pcm = byteArrayOf(1, 0, 2, 0)
        transport.sendAudio(pcm)
        factory.open()
        val opening = GARealtimeCodec.openingMessages(
            RealtimeTransportKind.OpenAiRealtime, input.instructions, input.history, "marin", "gpt-4o-transcribe",
        )
        assertEquals(opening, factory.socket.sent)
        assertEquals(3, factory.socket.sent.size)

        transport.sendAudio(pcm)
        assertEquals(3, factory.socket.sent.size)

        factory.frame("""{"type":"session.created"}""")
        testScheduler.runCurrent()
        assertEquals(listOf<RealtimeSessionEvent>(RealtimeSessionEvent.Ready), collected.events)
        transport.sendAudio(pcm)
        assertEquals(
            GARealtimeCodec.append(RealtimeTransportKind.OpenAiRealtime, Base64.getEncoder().encodeToString(pcm)),
            factory.socket.sent.last(),
        )

        transport.truncate(null, 0, 500.0)
        assertEquals(4, factory.socket.sent.size)
        transport.truncate("item_1", 0, 1234.7)
        assertEquals(
            GARealtimeCodec.truncate(RealtimeTransportKind.OpenAiRealtime, "item_1", 0, 1234.7),
            factory.socket.sent.last(),
        )
        transport.close()
    }

    @Test
    fun server_frames_mapped_in_order() = runTest {
        val (transport, factory) = transport()
        val collected = collect(transport)
        factory.open()
        val frames = listOf(
            """{"type":"session.created"}""",
            """{"type":"input_audio_buffer.speech_started","item_id":"u1"}""",
            """{"type":"conversation.item.input_audio_transcription.delta","item_id":"u1","delta":"he"}""",
            """{"type":"conversation.item.input_audio_transcription.delta","item_id":"u1","delta":"llo"}""",
            "not json",
            """{"type":"rate_limits.updated"}""",
            """{"type":"input_audio_buffer.speech_stopped","item_id":"u1"}""",
        )
        val state = GARealtimeCodec.State()
        val expected = frames.flatMap { text ->
            val message = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return@flatMap emptyList()
            GARealtimeCodec.map(RealtimeTransportKind.OpenAiRealtime, message, state)
        }
        frames.forEach(factory::frame)
        testScheduler.runCurrent()
        assertEquals(5, expected.size)
        assertEquals(expected, collected.events)
        assertEquals(RealtimeSessionEvent.UserTranscript("u1", "hello", final = false), collected.events[3])
        transport.close()
    }

    @Test
    fun error_event_does_not_end_stream() = runTest {
        val (transport, factory) = transport()
        val collected = collect(transport)
        factory.open()
        factory.frame("""{"type":"error","error":{"type":"invalid_request_error","code":"bad","message":"nope"}}""")
        factory.frame("""{"type":"session.created"}""")
        testScheduler.runCurrent()
        assertEquals(
            listOf(RealtimeSessionEvent.Error("bad", "nope"), RealtimeSessionEvent.Ready),
            collected.events,
        )
        assertTrue(collected.job.isActive)
        assertFalse(collected.completed)
        assertTrue(factory.socket.closes.isEmpty())
        transport.close()
    }

    @Test
    fun unexpected_close_fails_stream() = runTest {
        val (transport, factory) = transport()
        val collected = collect(transport)
        factory.open()
        factory.listener.onClosed(1006, "gone")
        testScheduler.runCurrent()
        assertFalse(collected.completed)
        val closed = collected.failure as? RealtimeSocketClosedException
        assertNotNull(closed)
        assertEquals(1006, closed!!.code)

        val (failing, failingFactory) = transport()
        val failed = collect(failing)
        val network = IOException("reset")
        failingFactory.listener.onFailure(network)
        testScheduler.runCurrent()
        assertFalse(failed.completed)
        assertEquals("reset", failed.failure?.message)
    }

    @Test
    fun close_ends_stream() = runTest {
        val (transport, factory) = transport()
        val collected = collect(transport)
        factory.open()
        transport.close()
        testScheduler.runCurrent()
        assertTrue(collected.completed)
        assertNull(collected.failure)
        assertEquals(listOf(1000), factory.socket.closes)
        // Frames after the end and a peer close no longer affect the stream.
        factory.listener.onClosed(1000, "")
        assertEquals(listOf(1000), factory.socket.closes)

        // xAI's max_duration maps to sessionEnded: after emitting it the socket is closed and the stream ends normally.
        val (xai, xaiFactory) = transport(RealtimeTransportKind.XaiRealtime)
        val ended = collect(xai)
        xaiFactory.open()
        xaiFactory.frame("""{"type":"error","error":{"type":"max_duration","message":"limit"}}""")
        testScheduler.runCurrent()
        assertEquals(listOf<RealtimeSessionEvent>(RealtimeSessionEvent.SessionEnded("max_duration")), ended.events)
        assertTrue(ended.completed)
        assertEquals(listOf(1000), xaiFactory.socket.closes)

        // Cancelling collection closes the socket.
        val (cancelled, cancelledFactory) = transport()
        val cancelledRun = collect(cancelled)
        cancelledFactory.open()
        cancelledRun.job.cancel()
        testScheduler.runCurrent()
        assertEquals(listOf(1000), cancelledFactory.socket.closes)
    }

    @Test
    fun factory_gemini_returns_session_control() {
        val gemini = RealtimeTransportFactory.make(
            RealtimeTransportKind.GeminiLive, endpoint, resumeHandle = "h0", socketFactory = FakeFactory(),
        )
        assertTrue(gemini is GeminiLiveSessionControl)
        assertEquals(RealtimeTransportKind.GeminiLive, gemini.kind)
        assertEquals("h0", (gemini as GeminiLiveSessionControl).lastResumeHandle)
        val fresh = RealtimeTransportFactory.make(RealtimeTransportKind.GeminiLive, endpoint, socketFactory = FakeFactory())
        assertNull((fresh as GeminiLiveSessionControl).lastResumeHandle)
        val openAi = RealtimeTransportFactory.make(RealtimeTransportKind.OpenAiRealtime, endpoint, socketFactory = FakeFactory())
        assertTrue(openAi is GARealtimeTransport)
        assertEquals(RealtimeTransportKind.OpenAiRealtime, openAi.kind)
        val xai = RealtimeTransportFactory.make(RealtimeTransportKind.XaiRealtime, endpoint, socketFactory = FakeFactory())
        assertEquals(RealtimeTransportKind.XaiRealtime, xai.kind)
    }
}
