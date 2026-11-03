package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.realtime.wire.GARealtimeCodec
import ai.oriveo.community.core.voice.realtime.wire.GARealtimeTransport
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionControl
import ai.oriveo.community.core.voice.realtime.wire.RealtimeEndpoint
import ai.oriveo.community.core.voice.realtime.wire.RealtimeFailureDetail
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
import kotlinx.serialization.json.jsonPrimitive
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
        override var queueSize: Long = 0L

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

    private fun userTextItem(text: String): JsonObject = Json.parseToJsonElement(
        """{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_text","text":"$text"}]}}""",
    ).jsonObject

    private val responseCreate: JsonObject = Json.parseToJsonElement("""{"type":"response.create"}""").jsonObject

    @Test
    fun send_user_text_after_ready_sends_item_then_response() = runTest {
        val (transport, factory) = transport()
        collect(transport)
        factory.open()
        factory.frame("""{"type":"session.created"}""")
        val before = factory.socket.sent.size
        transport.sendUserText("what time is it")
        // Typed message: user item + response.create without output_modalities; speaks and shows text as usual
        assertEquals(listOf(userTextItem("what time is it"), responseCreate), factory.socket.sent.drop(before))
        transport.close()
    }

    @Test
    fun send_user_text_before_ready_held_until_ready() = runTest {
        val (transport, factory) = transport(RealtimeTransportKind.XaiRealtime)
        collect(transport)
        factory.open()
        val opening = factory.socket.sent.toList()
        transport.sendUserText("one")
        transport.sendUserText("two")
        assertEquals(opening, factory.socket.sent)
        factory.frame("""{"type":"session.created"}""")
        assertEquals(
            // Several staged typed messages are merged into one reply: items are sent in order, with only one response.create at the end
            listOf(userTextItem("one"), userTextItem("two"), responseCreate),
            factory.socket.sent.drop(opening.size),
        )
        transport.close()
    }

    private val responseCancel: JsonObject = Json.parseToJsonElement("""{"type":"response.cancel"}""").jsonObject

    @Test
    fun typed_text_during_active_response_cancels_then_creates_after_done() = runTest {
        val (transport, factory) = transport()
        collect(transport)
        factory.open()
        factory.frame("""{"type":"session.created"}""")
        factory.frame("""{"type":"response.created","response":{"id":"r1","status":"in_progress"}}""")
        val before = factory.socket.sent.size
        transport.sendUserText("stop")
        // Response in progress: cancel first, then write the user item; response.create is held
        assertEquals(listOf(responseCancel, userTextItem("stop")), factory.socket.sent.drop(before))
        // Another message before done: no repeated cancel, only append the item
        transport.sendUserText("again")
        assertEquals(
            listOf(responseCancel, userTextItem("stop"), userTextItem("again")),
            factory.socket.sent.drop(before),
        )
        factory.frame("""{"type":"response.done","response":{"id":"r1","status":"cancelled"}}""")
        assertEquals(
            listOf(responseCancel, userTextItem("stop"), userTextItem("again"), responseCreate),
            factory.socket.sent.drop(before),
        )
        // A deferred create also counts as in progress; once its response ends, return to idle: typing afterwards sends item + create directly
        factory.frame("""{"type":"response.created","response":{"id":"r2"}}""")
        factory.frame("""{"type":"response.done","response":{"id":"r2","status":"completed"}}""")
        val afterDone = factory.socket.sent.size
        transport.sendUserText("next")
        assertEquals(listOf(userTextItem("next"), responseCreate), factory.socket.sent.drop(afterDone))
        transport.close()
    }

    @Test
    fun typed_text_when_idle_sends_create_immediately() = runTest {
        val (transport, factory) = transport(RealtimeTransportKind.XaiRealtime)
        collect(transport)
        factory.open()
        factory.frame("""{"type":"session.created"}""")
        factory.frame("""{"type":"response.created","response":{"id":"r1"}}""")
        factory.frame("""{"type":"response.done","response":{"id":"r1","status":"completed"}}""")
        val before = factory.socket.sent.size
        transport.sendUserText("hello")
        assertEquals(listOf(userTextItem("hello"), responseCreate), factory.socket.sent.drop(before))
        transport.close()
    }

    @Test
    fun typed_text_after_local_create_before_created_cancels_first() = runTest {
        val (transport, factory) = transport()
        collect(transport)
        factory.open()
        factory.frame("""{"type":"session.created"}""")
        val before = factory.socket.sent.size
        transport.sendUserText("one")
        // Sending response.create locally already counts as in progress: typing before response.created arrives also cancels first and holds the create
        transport.sendUserText("two")
        assertEquals(
            listOf(userTextItem("one"), responseCreate, responseCancel, userTextItem("two")),
            factory.socket.sent.drop(before),
        )
        factory.frame("""{"type":"response.created","response":{"id":"r1"}}""")
        assertEquals(before + 4, factory.socket.sent.size)
        factory.frame("""{"type":"response.done","response":{"id":"r1","status":"cancelled"}}""")
        assertEquals(responseCreate, factory.socket.sent.last())
        assertEquals(before + 5, factory.socket.sent.size)
        transport.close()
    }

    @Test
    fun pending_create_dropped_on_close() = runTest {
        val (transport, factory) = transport()
        val collected = collect(transport)
        factory.open()
        factory.frame("""{"type":"session.created"}""")
        factory.frame("""{"type":"response.created","response":{"id":"r1"}}""")
        transport.sendUserText("stop")
        val sentAtClose = factory.socket.sent.toList()
        assertEquals(responseCancel, sentAtClose[sentAtClose.size - 2])
        transport.close()
        testScheduler.runCurrent()
        assertTrue(collected.completed)
        // A done arriving after close does not send the held response.create
        factory.frame("""{"type":"response.done","response":{"id":"r1","status":"cancelled"}}""")
        assertEquals(sentAtClose, factory.socket.sent)
        transport.close()
    }

    @Test
    fun route_change_sends_session_update() = runTest {
        val (transport, factory) = transport()
        collect(transport)
        factory.open()
        factory.frame("""{"type":"session.created"}""")
        val before = factory.socket.sent.size
        transport.updateOutputRoute(ConversationRoute.HEADPHONES)
        val update = factory.socket.sent.drop(before).single()
        assertEquals("session.update", update["type"]!!.jsonPrimitive.content)
        val session = update["session"]!!.jsonObject
        // Only carries audio.input.noise_reduction (touches no other field beyond the session.type that GA requires)
        assertEquals(setOf("type", "audio"), session.keys)
        assertEquals("realtime", session["type"]!!.jsonPrimitive.content)
        val audio = session["audio"]!!.jsonObject
        assertEquals(setOf("input"), audio.keys)
        val audioInput = audio["input"]!!.jsonObject
        assertEquals(setOf("noise_reduction"), audioInput.keys)
        assertEquals("near_field", audioInput["noise_reduction"]!!.jsonObject["type"]!!.jsonPrimitive.content)

        // Knob value unchanged (earphones and Bluetooth both map to near_field): not resent; switching back to speaker sends far_field
        transport.updateOutputRoute(ConversationRoute.BLUETOOTH)
        transport.updateOutputRoute(ConversationRoute.HEADPHONES)
        assertEquals(before + 1, factory.socket.sent.size)
        transport.updateOutputRoute(ConversationRoute.SPEAKER)
        val back = factory.socket.sent.last()["session"]!!.jsonObject["audio"]!!.jsonObject["input"]!!.jsonObject
        assertEquals("far_field", back["noise_reduction"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        transport.close()
    }

    @Test
    fun route_change_before_ready_retunes_at_ready() = runTest {
        val (transport, factory) = transport()
        collect(transport)
        factory.open()
        val opening = factory.socket.sent.size
        transport.updateOutputRoute(ConversationRoute.HEADPHONES)
        assertEquals(opening, factory.socket.sent.size)
        factory.frame("""{"type":"session.created"}""")
        val update = factory.socket.sent.drop(opening).single()
        val audioInput = update["session"]!!.jsonObject["audio"]!!.jsonObject["input"]!!.jsonObject
        assertEquals("near_field", audioInput["noise_reduction"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        transport.close()
    }

    @Test
    fun route_change_on_xai_sends_nothing() = runTest {
        val (transport, factory) = transport(RealtimeTransportKind.XaiRealtime)
        collect(transport)
        factory.open()
        factory.frame("""{"type":"session.created"}""")
        val before = factory.socket.sent.size
        // xAI does not accept noise_reduction: a route change does not send session.update
        transport.updateOutputRoute(ConversationRoute.HEADPHONES)
        assertEquals(before, factory.socket.sent.size)
        transport.close()
    }

    @Test
    fun headphones_route_sends_near_field() = runTest {
        val factory = FakeFactory()
        var samples = 0
        val transport = GARealtimeTransport(
            RealtimeTransportKind.OpenAiRealtime, endpoint, factory,
            route = { samples++; ConversationRoute.HEADPHONES },
        )
        collect(transport)
        factory.open()
        // Route is read once when the session opens; with earphones the opening message is encoded with near_field
        assertEquals(1, samples)
        val opening = GARealtimeCodec.openingMessages(
            RealtimeTransportKind.OpenAiRealtime, input.instructions, input.history, "marin", "gpt-4o-transcribe",
            route = ConversationRoute.HEADPHONES,
        )
        assertEquals(opening, factory.socket.sent)
        val noiseReduction = factory.socket.sent.first()["session"]!!.jsonObject["audio"]!!.jsonObject["input"]!!
            .jsonObject["noise_reduction"]!!.jsonObject
        assertEquals("near_field", noiseReduction["type"]!!.jsonPrimitive.content)
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

    /** After ready, send one 100 ms (4800 bytes) audio frame; after sending, the socket queue holds [frames] frames of the same size. */
    private fun TestScope.sendWithBacklog(frames: Long): Pair<Collected, FakeFactory> {
        val (transport, factory) = transport()
        val collected = collect(transport)
        factory.open()
        factory.frame("""{"type":"session.created"}""")
        testScheduler.runCurrent()
        val pcm = ByteArray(4_800) { (it % 7).toByte() }
        val message = GARealtimeCodec.append(RealtimeTransportKind.OpenAiRealtime, Base64.getEncoder().encodeToString(pcm))
        factory.socket.queueSize = message.toString().length * frames
        transport.sendAudio(pcm)
        testScheduler.runCurrent()
        return collected to factory
    }

    @Test
    fun uplink_backlog_over_8s_fails_with_backlog_ms() = runTest {
        val (collected, factory) = sendWithBacklog(81)
        assertFalse(collected.completed)
        val detail = collected.failure as? RealtimeFailureDetail
        assertNotNull(detail)
        assertEquals(8_100.0, detail!!.uplinkBacklogMs!!, 0.0)
        assertEquals(listOf(1000), factory.socket.closes)
    }

    @Test
    fun uplink_backlog_at_8s_does_not_fail() = runTest {
        val (collected, factory) = sendWithBacklog(80)
        assertNull(collected.failure)
        assertFalse(collected.completed)
        assertTrue(factory.socket.closes.isEmpty())
        collected.job.cancel()
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
