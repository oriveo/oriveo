package ai.oriveo.community.e2e

import androidx.test.ext.junit.runners.AndroidJUnit4
import ai.oriveo.community.core.voice.realtime.RealtimePCM
import ai.oriveo.community.smoke.IdealReplayAudio
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Harness self-test: the injected source speaks zh-short into the fake Gemini Live server over the socket API the
 * production transport uses, and one turn comes back the way the fixture says.
 */
@RunWith(AndroidJUnit4::class)
class RealtimeE2EHarnessSelfTest {
    @Test
    fun fake_server_turn_roundtrip() {
        val scenario = E2EScenario("harness_self_test")
        scenario.step("roundtrip") {
            E2ECorpus.verify()
            val clip = E2EFixture.clip("zh-short")
            val server = FakeGeminiServer()
            val audio = InjectedPcmRealtimeAudio(IdealReplayAudio())
            val frames = runBlocking { roundtrip(server, audio, clip) }

            val transcripts = frames.mapNotNull { frame ->
                ((frame["serverContent"] as? JsonObject)?.get("inputTranscription") as? JsonObject)?.get("text")?.jsonPrimitive?.content
            }
            expectEquals("inputTranscription frames (one per segment)", clip.segments, transcripts)
            check(server.setup != null, "first setup recorded: ${server.setup}")
            check(server.uplinkMs > 1_000, "uplink ms received ${server.uplinkMs} > 1000")
            expectEquals("connections", 1, server.connections.get())
            check(frames.any { it.isVoiceActivity("ACTIVITY_END") }, "ACTIVITY_END sent")
        }
        scenario.finish()
    }

    /** setup → setupComplete → uplink PCM until the reply's turnComplete; returns every server frame of the turn. */
    private suspend fun roundtrip(server: FakeGeminiServer, audio: InjectedPcmRealtimeAudio, clip: E2EClip): List<JsonObject> =
        kotlinx.coroutines.coroutineScope {
            val socket = server.connect("wss://fake.e2e/ws")
            val received = Channel<JsonObject>(Channel.UNLIMITED)
            val reader = launch(Dispatchers.IO) {
                while (true) {
                    val text = socket.receive() ?: break
                    received.send(Json.parseToJsonElement(text).jsonObject)
                }
            }
            socket.send(setupMessage().toString())
            withTimeout(STEP_TIMEOUT_MS) {
                while (!received.receive().containsKey("setupComplete")) Unit
            }

            val uplink = Channel<ByteArray>(Channel.UNLIMITED)
            val pump = launch(Dispatchers.IO) {
                for (pcm in uplink) socket.send(audioMessage(pcm).toString())
            }
            audio.startCapture({ uplink.trySend(it) }, RealtimePCM.INPUT_RATE)
            E2EVoice(server, audio).speak(clip.id)

            val frames = mutableListOf<JsonObject>()
            try {
                withTimeout(STEP_TIMEOUT_MS) {
                    while (true) {
                        val frame = received.receive()
                        frames += frame
                        val content = frame["serverContent"] as? JsonObject
                        if (content?.get("turnComplete")?.jsonPrimitive?.booleanOrNull == true) break
                    }
                }
            } finally {
                audio.stop()
                uplink.close()
                socket.close()
                pump.cancel()
                reader.cancel()
            }
            frames
        }

    private fun JsonObject.isVoiceActivity(type: String): Boolean =
        (this["voiceActivity"] as? JsonObject)?.get("type")?.jsonPrimitive?.content == type

    /** The setup fields the harness reads: model and the input transcription language hint. */
    private fun setupMessage() = buildJsonObject {
        putJsonObject("setup") {
            put("model", "models/${E2EFixture.model}")
            putJsonObject("inputAudioTranscription") { putJsonArray("languageCodes") { add(kotlinx.serialization.json.JsonPrimitive("zh-Hans")) } }
            putJsonObject("outputAudioTranscription") {}
        }
    }

    private fun audioMessage(pcm: ByteArray) = buildJsonObject {
        putJsonObject("realtimeInput") {
            putJsonObject("audio") {
                put("data", Base64.getEncoder().encodeToString(pcm))
                put("mimeType", "audio/pcm;rate=${RealtimePCM.INPUT_RATE}")
            }
        }
    }

    private companion object {
        const val STEP_TIMEOUT_MS = 30_000L
    }
}
