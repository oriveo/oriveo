package ai.oriveo.community.core.voice.realtime

import android.content.Context
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import java.io.File
import kotlin.math.PI
import kotlin.math.sin
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.mp.KoinPlatform

/**
 * Diagnostic probe: production realtime playback [AndroidRealtimeAudio] opens playback only, not the mic. It enqueues two
 * 3 s 24 kHz PCM segments (itemId a / b). From the first enqueue, it samples playedMs / playhead / getTimestamp frame count /
 * playState every 100 ms, writes getExternalFilesDir("voice-realtime-head")/playback-head-probe.json, and logs each point
 * under logcat TAG RealtimeHeadProbe. Asserts playedMs(a) > 0 within 2 s of the first enqueue. Uses local PCM only; no Provider.
 */
@RunWith(AndroidJUnit4::class)
class RealtimePlaybackHeadProbeTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun playback_head_advances_on_device() {
        val audio = AndroidRealtimeAudio(context, KoinPlatform.getKoin().get<AndroidAudioSessionCoordinator>())
        val samples = JSONArray()
        var firstPlayedAtMs = -1L
        try {
            onMain {
                audio.startPlayback(
                    onInterruption = { Log.w(TAG, "audio interruption") },
                    onActivationFailed = { Log.w(TAG, "activation failed: $it") },
                )
            }
            // In production, downlink audio arrives only after the session is Ready: wait until the playback track exists (playState non-null) before enqueueing.
            val trackDeadline = System.currentTimeMillis() + TRACK_TIMEOUT_MS
            while (audio.headProbe(ITEM_A).playState == null && System.currentTimeMillis() < trackDeadline) {
                Thread.sleep(SAMPLE_MS / 4)
            }
            val trackReady = audio.headProbe(ITEM_A).playState != null
            Log.i(TAG, "trackReady=$trackReady")

            val startedAt = System.currentTimeMillis()
            for (item in listOf(ITEM_A, ITEM_B)) {
                val pcm = tone(ITEM_MS)
                // Slice into 100 ms chunks at the downlink delta cadence, and enqueue them all at once.
                var offset = 0
                while (offset < pcm.size) {
                    val size = minOf(CHUNK_BYTES, pcm.size - offset)
                    val chunk = pcm.copyOfRange(offset, offset + size)
                    onMain { audio.enqueue(chunk, item) }
                    offset += size
                }
            }
            while (true) {
                val t = System.currentTimeMillis() - startedAt
                if (t > SAMPLE_WINDOW_MS) break
                val a = audio.headProbe(ITEM_A)
                val b = audio.headProbe(ITEM_B)
                val playedA = audio.playedMs(ITEM_A)
                val playedB = audio.playedMs(ITEM_B)
                if (firstPlayedAtMs < 0 && playedA > 0) firstPlayedAtMs = t
                val point = JSONObject()
                    .put("t", t)
                    .put("head", a.head)
                    .put("playedMsA", playedA)
                    .put("playedMsB", playedB)
                    .put("timestampFrames", a.timestampFrames)
                    .put("playState", a.playState ?: JSONObject.NULL)
                    .put("framesQueued", a.framesQueued)
                    .put("rangeA", JSONArray(listOf(a.rangeStart, a.rangeEnd)))
                    .put("rangeB", JSONArray(listOf(b.rangeStart, b.rangeEnd)))
                    .put("isPlaying", audio.isPlaying)
                samples.put(point)
                Log.i(TAG, "sample $point")
                Thread.sleep(SAMPLE_MS)
            }
        } finally {
            onMain { audio.stop() }
        }
        val dir = context.getExternalFilesDir("voice-realtime-head")!!.apply { mkdirs() }
        val result = JSONObject()
            .put("schema", "realtime-playback-head-probe/v1")
            .put("itemMs", ITEM_MS)
            .put("sampleRate", RealtimePCM.OUTPUT_RATE)
            .put("firstPlayedAtMs", firstPlayedAtMs)
            .put("samples", samples)
        File(dir, "playback-head-probe.json").writeText(result.toString(2))
        Log.i(TAG, "summary firstPlayedAtMs=$firstPlayedAtMs samples=${samples.length()}")
        assertTrue(
            "playedMs($ITEM_A) stayed 0 for 2 s after enqueue (firstPlayedAtMs=$firstPlayedAtMs)",
            firstPlayedAtMs in 0..ASSERT_WITHIN_MS,
        )
    }

    /** Sine tone at 440 Hz for [ms] milliseconds (about -12 dBFS), PCM16 LE. */
    private fun tone(ms: Int): ByteArray {
        val frames = RealtimePCM.OUTPUT_RATE * ms / 1000
        val out = ByteArray(frames * 2)
        for (i in 0 until frames) {
            val v = (sin(2 * PI * 440.0 * i / RealtimePCM.OUTPUT_RATE) * 8000).toInt()
            out[2 * i] = (v and 0xff).toByte()
            out[2 * i + 1] = ((v shr 8) and 0xff).toByte()
        }
        return out
    }

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    private companion object {
        const val TAG = "RealtimeHeadProbe"
        const val ITEM_A = "a"
        const val ITEM_B = "b"
        const val ITEM_MS = 3_000
        const val CHUNK_BYTES = RealtimePCM.OUTPUT_RATE / 10 * 2
        const val SAMPLE_MS = 100L
        const val SAMPLE_WINDOW_MS = 7_000L
        const val ASSERT_WITHIN_MS = 2_000L
        const val TRACK_TIMEOUT_MS = 3_000L
    }
}
