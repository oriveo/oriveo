package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.data.repository.RealtimeTransportInput
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveConfig
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSessionControl
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocket
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveSocketFactory
import ai.oriveo.community.core.voice.realtime.wire.GeminiLiveTransport
import java.util.Base64
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** GeminiLiveSessionControl: declares a 16 kHz uplink, hands microphone frames to GeminiLiveTransport as base64 in order, unchanged; truncate is a no-op and close is forwarded. */
@OptIn(ExperimentalCoroutinesApi::class)
class GeminiLiveSessionControlTest {

    private class FakeSocket : GeminiLiveSocket {
        val sent = mutableListOf<JsonObject>()
        private val incoming = Channel<String>(Channel.UNLIMITED)
        var closed = false

        override suspend fun send(text: String) {
            sent += Json.parseToJsonElement(text).jsonObject
        }

        override suspend fun receive(): String? = incoming.receiveCatching().getOrNull()

        override fun close() {
            closed = true
            incoming.close()
        }

        fun server(json: String) {
            incoming.trySend(json)
        }
    }

    private class FakeFactory : GeminiLiveSocketFactory {
        val sockets = mutableListOf<FakeSocket>()

        override suspend fun connect(url: String): GeminiLiveSocket = FakeSocket().also { sockets += it }
    }

    private val config = GeminiLiveConfig(
        host = "generativelanguage.googleapis.com",
        path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
        model = "models/gemini-live",
        voice = "Puck",
        apiKey = "g-key",
    )

    private val input = RealtimeTransportInput(instructions = "Be brief.", history = emptyList())

    private class Collected(val job: Job) {
        val events = mutableListOf<RealtimeSessionEvent>()
        var completed = false
    }

    private fun TestScope.collect(control: GeminiLiveSessionControl): Collected {
        lateinit var collected: Collected
        val job = launch {
            control.openRealtimeSession(input).collect { collected.events += it }
            collected.completed = true
        }
        collected = Collected(job)
        runCurrent()
        return collected
    }

    private fun le(vararg samples: Int): ByteArray = RealtimePCM.toLittleEndian(ShortArray(samples.size) { samples[it].toShort() })

    private fun FakeSocket.audioChunks(): List<String> = sent.mapNotNull { message ->
        message["realtimeInput"]?.jsonObject?.get("audio")?.jsonObject?.get("data")?.jsonPrimitive?.content
    }

    @Test
    fun send_audio_base64_in_order() = runTest {
        val factory = FakeFactory()
        val control = GeminiLiveSessionControl(GeminiLiveTransport(config, socketFactory = factory))
        val run = collect(control)
        control.sendAudio(le(0, 100, 200))
        control.sendAudio(le(300, 400, 500))
        val socket = factory.sockets.single()
        socket.server("""{"setupComplete":{}}""")
        runCurrent()
        control.sendAudio(le(600, 700, 800))
        runCurrent()
        val decoded = socket.audioChunks().map { RealtimePCM.fromLittleEndian(Base64.getDecoder().decode(it)).toList() }
        assertEquals(
            listOf(listOf<Short>(0, 100, 200), listOf<Short>(300, 400, 500), listOf<Short>(600, 700, 800)),
            decoded,
        )
        control.close()
        runCurrent()
        assertTrue(run.completed)
    }

    @Test
    fun gemini_uplink_16k_passthrough() = runTest {
        val factory = FakeFactory()
        val control = GeminiLiveSessionControl(GeminiLiveTransport(config, socketFactory = factory))
        // Declares 16 kHz: capture emits frames at this rate, with no 16k→24k→16k round trip.
        assertEquals(16_000, control.uplinkSampleRateHz)
        val run = collect(control)
        val socket = factory.sockets.single()
        socket.server("""{"setupComplete":{}}""")
        runCurrent()
        // A 20 ms 16k frame (including positive and negative extremes) is encoded unchanged, sample for sample.
        val frame = ShortArray(320) { (it * 211 - 33_000).coerceIn(-32_768, 32_767).toShort() }
        val pcm = RealtimePCM.toLittleEndian(frame)
        control.sendAudio(pcm)
        // A trailing half sample is dropped and not joined into the next frame.
        control.sendAudio(pcm + byteArrayOf(7))
        control.sendAudio(byteArrayOf(9))
        runCurrent()
        val chunks = socket.audioChunks().map { Base64.getDecoder().decode(it) }
        assertEquals(2, chunks.size)
        chunks.forEach { chunk ->
            assertArrayEquals(pcm, chunk)
            assertArrayEquals(frame, RealtimePCM.fromLittleEndian(chunk))
        }
        assertEquals("audio/pcm;rate=16000", socket.sent.last()["realtimeInput"]!!.jsonObject["audio"]!!.jsonObject["mimeType"]!!.jsonPrimitive.content)
        control.close()
        runCurrent()
        assertTrue(run.completed)
    }

    @Test
    fun truncate_sends_nothing() = runTest {
        val factory = FakeFactory()
        val control = GeminiLiveSessionControl(GeminiLiveTransport(config, socketFactory = factory))
        val run = collect(control)
        val socket = factory.sockets.single()
        socket.server("""{"setupComplete":{}}""")
        runCurrent()
        val before = socket.sent.size
        control.truncate("item-1", 0, 1200.0)
        control.truncate(null, 0, 0.0)
        runCurrent()
        assertEquals(before, socket.sent.size)
        control.close()
        runCurrent()
        assertTrue(run.completed)
    }

    @Test
    fun close_forwards() = runTest {
        val factory = FakeFactory()
        val control = GeminiLiveSessionControl(GeminiLiveTransport(config, resumeHandle = "h0", socketFactory = factory))
        assertEquals(RealtimeTransportKind.GeminiLive, control.kind)
        assertEquals("h0", control.lastResumeHandle)
        val run = collect(control)
        val socket = factory.sockets.single()
        control.close()
        runCurrent()
        assertTrue(socket.closed)
        assertTrue(run.completed)
        assertTrue(run.events.isEmpty())
    }
}
