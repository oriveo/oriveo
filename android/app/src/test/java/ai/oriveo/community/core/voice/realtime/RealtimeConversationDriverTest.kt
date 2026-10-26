package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.RealtimeSessionInput
import ai.oriveo.community.core.context.assembleRealtimeSession
import ai.oriveo.community.core.data.repository.PlannedRealtimeSession
import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.realtime.wire.GARealtimeCodec
import ai.oriveo.community.core.voice.realtime.wire.GARealtimeTransport
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionExpiredException
import ai.oriveo.community.core.voice.realtime.wire.RealtimeEndpoint
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSessionControl
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocket
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.RealtimeSocketListener
import ai.oriveo.community.core.voice.realtime.wire.RealtimeTransport
import java.io.File
import java.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** RealtimeConversationDriver: real GARealtimeTransport + fake socket + fake audio. */
@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeConversationDriverTest {

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
        lateinit var listener: RealtimeSocketListener

        override fun connect(url: String, headers: Map<String, String>, listener: RealtimeSocketListener): RealtimeSocket {
            this.listener = listener
            return socket
        }

        fun open() = listener.onOpen(socket)

        fun frame(json: String) = listener.onMessage(json)
    }

    private class FakeAudio(private val played: Long = 0L) : RealtimeAudioIO {
        val calls = mutableListOf<String>()
        val enqueued = mutableListOf<Pair<ByteArray, String>>()
        var onFrame: ((ByteArray) -> Unit)? = null
        var onInterruption: (() -> Unit)? = null

        override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) {
            calls += "start"
            this.onFrame = onFrame
            this.onInterruption = onInterruption
        }

        override fun enqueue(pcm16: ByteArray, itemId: String) {
            calls += "enqueue:$itemId"
            enqueued += pcm16 to itemId
        }

        override fun playedMs(itemId: String): Long {
            calls += "playedMs:$itemId"
            return played
        }

        override val isPlaying: Boolean
            get() = enqueued.isNotEmpty() && "stopPlayback" !in calls

        override fun stopPlayback() {
            calls += "stopPlayback"
        }

        override fun stop() {
            calls += "stop"
        }
    }

    /** A connection without item ids (Gemini shape): the test pushes unified events directly and records truncate calls. */
    private class FakeConnection : RealtimeTransport, RealtimeSessionControl {
        val events = Channel<RealtimeSessionEvent>(Channel.UNLIMITED)
        val truncates = mutableListOf<String?>()
        override val kind = RealtimeTransportKind.GeminiLive

        override fun openRealtimeSession(transport: RealtimeTransportInput): Flow<RealtimeSessionEvent> =
            events.consumeAsFlow()

        override fun sendAudio(pcm: ByteArray) = Unit

        override fun truncate(itemId: String?, contentIndex: Int, playedMs: Double) {
            truncates += itemId
        }

        override fun close() {
            events.close()
        }
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
    )

    private val plan: PlannedRealtimeSession = PlannedRealtimeSession.from(
        assembleRealtimeSession(
            RealtimeSessionInput(
                contextWindow = 128_000,
                conversation = ContextConversation(id = "c1", useMemory = false),
                history = emptyList(),
            ),
        ),
    )!!

    private fun <C> TestScope.run(driver: RealtimeConversationDriver<C>): Collected
        where C : RealtimeTransport, C : RealtimeSessionControl {
        lateinit var collected: Collected
        val job = CoroutineScope(UnconfinedTestDispatcher(testScheduler)).launch {
            try {
                driver.run(plan).collect { collected.events += it }
                collected.completed = true
            } catch (error: Throwable) {
                collected.failure = error
            }
        }
        collected = Collected(job)
        testScheduler.runCurrent()
        return collected
    }

    private class Rig(
        val transport: GARealtimeTransport,
        val factory: FakeFactory,
        val audio: FakeAudio,
        val driver: RealtimeConversationDriver<GARealtimeTransport>,
    )

    private fun rig(
        kind: RealtimeTransportKind = RealtimeTransportKind.OpenAiRealtime,
        played: Long = 0L,
    ): Rig {
        val factory = FakeFactory()
        val transport = GARealtimeTransport(kind, endpoint, factory)
        val audio = FakeAudio(played)
        return Rig(transport, factory, audio, RealtimeConversationDriver(transport, audio))
    }

    @Test
    fun mic_sent_after_ready_at_24k() = runTest {
        val r = rig()
        val collected = run(r.driver)
        r.factory.open()
        testScheduler.runCurrent()
        assertTrue(r.audio.calls.isEmpty())
        val opening = r.factory.socket.sent.size

        r.factory.frame("""{"type":"session.created"}""")
        testScheduler.runCurrent()
        assertEquals(listOf("start"), r.audio.calls)
        assertEquals(listOf<RealtimeSessionEvent>(RealtimeSessionEvent.Ready), collected.events)

        // 24 kHz PCM16 LE frames from the audio layer are sent uplink unchanged.
        val frame = RealtimePCM.toLittleEndian(RealtimePCM.resample16kTo24k(shortArrayOf(100, 200, 300, 400)))
        assertEquals(12, frame.size)
        r.audio.onFrame!!(frame)
        assertEquals(opening + 1, r.factory.socket.sent.size)
        assertEquals(
            GARealtimeCodec.append(RealtimeTransportKind.OpenAiRealtime, Base64.getEncoder().encodeToString(frame)),
            r.factory.socket.sent.last(),
        )
        r.transport.close()
    }

    @Test
    fun assistant_audio_played() = runTest {
        val r = rig()
        val collected = run(r.driver)
        r.factory.open()
        r.factory.frame("""{"type":"session.created"}""")
        val pcm = byteArrayOf(1, 0, 2, 0, 3, 0)
        val b64 = Base64.getEncoder().encodeToString(pcm)
        r.factory.frame(
            """{"type":"response.output_audio.delta","response_id":"r1","item_id":"msg_1","output_index":0,"content_index":0,"delta":"$b64"}""",
        )
        testScheduler.runCurrent()
        assertEquals(1, r.audio.enqueued.size)
        assertArrayEquals(pcm, r.audio.enqueued[0].first)
        assertEquals("msg_1", r.audio.enqueued[0].second)
        assertEquals(
            listOf(RealtimeSessionEvent.Ready, RealtimeSessionEvent.AssistantAudio("msg_1", 0, b64, 24_000)),
            collected.events,
        )
        r.transport.close()
    }

    @Test
    fun barge_in_stops_and_truncates_played_ms() = runTest {
        val case = fixture["mapCases"]!!.jsonArray.map { it.jsonObject }
            .first { (it["id"] as JsonPrimitive).content == "openai_turn_detected_cancel_is_interrupted" }
        val messages = case["input"]!!.jsonObject["messages"]!!.jsonArray
        val expected = case["expected"]!!.jsonArray.map { it.jsonObject }

        val r = rig(played = 1500L)
        val collected = run(r.driver)
        r.factory.open()
        r.factory.frame("""{"type":"session.created"}""")
        messages.forEach { r.factory.frame(it.toString()) }
        testScheduler.runCurrent()

        assertEquals(
            listOf("start", "enqueue:msg_010", "playedMs:msg_010", "stopPlayback"),
            r.audio.calls,
        )
        val truncate = GARealtimeCodec.truncate(RealtimeTransportKind.OpenAiRealtime, "msg_010", 0, 1500.0)!!
        assertEquals(truncate, r.factory.socket.sent.last())
        assertEquals("msg_010", (truncate["item_id"] as JsonPrimitive).content)
        assertEquals("1500", (truncate["audio_end_ms"] as JsonPrimitive).content)
        // Events pass through unchanged: after Ready they equal the fixture's expected, key by key.
        assertEquals(RealtimeSessionEvent.Ready, collected.events.first())
        assertEquals(expected, collected.events.drop(1).map { it.toJson() })
        r.transport.close()
    }

    @Test
    fun barge_in_drops_late_audio_of_truncated_item() = runTest {
        val case = fixture["mapCases"]!!.jsonArray.map { it.jsonObject }
            .first { (it["id"] as JsonPrimitive).content == "openai_turn_detected_cancel_is_interrupted" }
        val messages = case["input"]!!.jsonObject["messages"]!!.jsonArray

        val r = rig(played = 1500L)
        val collected = run(r.driver)
        r.factory.open()
        r.factory.frame("""{"type":"session.created"}""")
        messages.take(3).forEach { r.factory.frame(it.toString()) }
        // Late audio for the same item after an interruption: not queued, no further truncate, and events still pass through.
        r.factory.frame(
            """{"type":"response.output_audio.delta","response_id":"resp_002","item_id":"msg_010","output_index":0,"content_index":0,"delta":"CCCC"}""",
        )
        testScheduler.runCurrent()

        assertEquals(listOf("msg_010"), r.audio.enqueued.map { it.second })
        assertEquals(1, r.factory.socket.sent.count { (it["type"] as JsonPrimitive).content == "conversation.item.truncate" })
        assertEquals(RealtimeSessionEvent.AssistantAudio("msg_010", 0, "CCCC", 24_000), collected.events.last())
        assertNull(collected.failure)
        r.transport.close()
    }

    @Test
    fun barge_in_null_item_drops_until_interrupted() = runTest {
        val connection = FakeConnection()
        val audio = FakeAudio(played = 800L)
        val collected = run(RealtimeConversationDriver(connection, audio))
        val chunk = { b64: String -> RealtimeSessionEvent.AssistantAudio(null, 0, b64, 24_000) }
        connection.events.trySend(RealtimeSessionEvent.Ready)
        connection.events.trySend(chunk("AQA="))
        connection.events.trySend(RealtimeSessionEvent.UserSpeechStarted(null))
        // Late item-less audio after the interruption and before interrupted is all dropped.
        connection.events.trySend(chunk("AgA="))
        connection.events.trySend(chunk("AwA="))
        testScheduler.runCurrent()
        assertEquals(listOf("start", "enqueue:", "playedMs:", "stopPlayback"), audio.calls)
        assertTrue(connection.truncates.isEmpty())

        connection.events.trySend(RealtimeSessionEvent.Interrupted)
        connection.events.trySend(chunk("BAA="))
        testScheduler.runCurrent()
        assertArrayEquals(byteArrayOf(4, 0), audio.enqueued.last().first)
        assertEquals(2, audio.enqueued.size)
        assertTrue(connection.truncates.isEmpty())
        // Events pass through unchanged, including the dropped audio events.
        assertEquals(7, collected.events.size)
        assertEquals(chunk("AwA="), collected.events[4])
        assertNull(collected.failure)
        connection.close()
    }

    @Test
    fun interrupt_playback_stops_and_truncates() = runTest {
        val r = rig(played = 900L)
        val collected = run(r.driver)
        r.factory.open()
        r.factory.frame("""{"type":"session.created"}""")
        r.factory.frame(
            """{"type":"response.output_audio.delta","response_id":"r1","item_id":"msg_1","output_index":0,"content_index":0,"delta":"AQA="}""",
        )
        testScheduler.runCurrent()
        r.driver.interruptPlayback()
        assertEquals(listOf("start", "enqueue:msg_1", "playedMs:msg_1", "stopPlayback"), r.audio.calls)
        assertEquals(
            GARealtimeCodec.truncate(RealtimeTransportKind.OpenAiRealtime, "msg_1", 0, 900.0)!!,
            r.factory.socket.sent.last(),
        )
        // Same path as the userSpeechStarted interruption: late audio for that item is no longer queued.
        r.factory.frame(
            """{"type":"response.output_audio.delta","response_id":"r1","item_id":"msg_1","output_index":0,"content_index":0,"delta":"AgA="}""",
        )
        testScheduler.runCurrent()
        assertEquals(1, r.audio.enqueued.size)
        assertEquals(RealtimeSessionEvent.AssistantAudio("msg_1", 0, "AgA=", 24_000), collected.events.last())
        r.transport.close()
    }

    @Test
    fun interrupt_playback_when_idle_noop() = runTest {
        val r = rig()
        val collected = run(r.driver)
        r.factory.open()
        r.factory.frame("""{"type":"session.created"}""")
        testScheduler.runCurrent()
        val sent = r.factory.socket.sent.size
        r.driver.interruptPlayback()
        testScheduler.runCurrent()
        assertEquals(listOf("start"), r.audio.calls)
        assertEquals(sent, r.factory.socket.sent.size)
        assertEquals(listOf<RealtimeSessionEvent>(RealtimeSessionEvent.Ready), collected.events)
        r.transport.close()
    }

    @Test
    fun bad_base64_audio_skipped() = runTest {
        val r = rig()
        val collected = run(r.driver)
        r.factory.open()
        r.factory.frame("""{"type":"session.created"}""")
        r.factory.frame(
            """{"type":"response.output_audio.delta","response_id":"r1","item_id":"msg_1","output_index":0,"content_index":0,"delta":"not*base64!"}""",
        )
        val pcm = byteArrayOf(1, 0, 2, 0)
        val b64 = Base64.getEncoder().encodeToString(pcm)
        r.factory.frame(
            """{"type":"response.output_audio.delta","response_id":"r1","item_id":"msg_1","output_index":0,"content_index":0,"delta":"$b64"}""",
        )
        testScheduler.runCurrent()

        // A bad chunk is skipped without ending the stream, and later good chunks are queued as usual.
        assertNull(collected.failure)
        assertFalse(collected.completed)
        assertEquals(1, r.audio.enqueued.size)
        assertArrayEquals(pcm, r.audio.enqueued[0].first)
        assertEquals(3, collected.events.size)
        r.transport.close()
    }

    @Test
    fun system_interruption_closes() = runTest {
        val r = rig()
        val collected = run(r.driver)
        r.factory.open()
        r.factory.frame("""{"type":"session.created"}""")
        testScheduler.runCurrent()
        r.audio.onInterruption!!()
        testScheduler.runCurrent()
        assertEquals(listOf(1000), r.factory.socket.closes)
        assertTrue(collected.completed)
        assertNull(collected.failure)
        assertTrue("stop" in r.audio.calls)
    }

    @Test
    fun session_ended_stops_audio() = runTest {
        val r = rig(RealtimeTransportKind.XaiRealtime)
        val collected = run(r.driver)
        r.factory.open()
        r.factory.frame("""{"type":"session.created"}""")
        r.factory.frame("""{"type":"error","error":{"type":"max_duration","message":"limit"}}""")
        testScheduler.runCurrent()
        assertEquals(
            listOf(RealtimeSessionEvent.Ready, RealtimeSessionEvent.SessionEnded("max_duration")),
            collected.events,
        )
        assertTrue(collected.completed)
        assertEquals("stop", r.audio.calls.last())

        // Audio stops both when the stream ends with an error and when collection is cancelled.
        val failing = rig()
        val failed = run(failing.driver)
        failing.factory.open()
        failing.factory.listener.onClosed(1006, "gone")
        testScheduler.runCurrent()
        assertFalse(failed.completed)
        assertTrue(failed.failure != null)
        assertEquals(listOf("stop"), failing.audio.calls)

        val cancelled = rig()
        val cancelledRun = run(cancelled.driver)
        cancelled.factory.open()
        cancelled.factory.frame("""{"type":"session.created"}""")
        testScheduler.runCurrent()
        cancelledRun.job.cancel()
        testScheduler.runCurrent()
        assertEquals(listOf("start", "stop"), cancelled.audio.calls)
    }

    @Test
    fun session_expired_keeps_audio_running() = runTest {
        // A session-expiry end does not stop audio (the controller reuses it when reopening after dormancy), and the error is still thrown
        val connection = FakeConnection()
        val audio = FakeAudio()
        val collected = run(RealtimeConversationDriver(connection, audio))
        connection.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        connection.events.close(GeminiLiveSessionExpiredException("Gemini Live session expired (1008)"))
        testScheduler.runCurrent()
        assertTrue(collected.failure is GeminiLiveSessionExpiredException)
        assertEquals(listOf("start"), audio.calls)

        // Other errors still stop audio
        val other = FakeConnection()
        val otherAudio = FakeAudio()
        val otherRun = run(RealtimeConversationDriver(other, otherAudio))
        other.events.trySend(RealtimeSessionEvent.Ready)
        testScheduler.runCurrent()
        other.events.close(IllegalStateException("gone"))
        testScheduler.runCurrent()
        assertTrue(otherRun.failure is IllegalStateException)
        assertEquals(listOf("start", "stop"), otherAudio.calls)
    }

    private val fixture: JsonObject by lazy {
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/realtime-events.v1.json").readText()).jsonObject
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Cannot find $relative")
    }
}
