package ai.oriveo.community.core.voice.conversation

import android.content.Context
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Random
import kotlin.math.sqrt

/**
 * Real-model acceptance for SileroVad:
 * - Speech segments: each dictation clip in getExternalFilesDir("s5")/manifest.json is fed in. A chunk whose RMS is at least -20 dB of
 *   that clip's peak chunk RMS counts as speech, and at least 80% of those chunks must have prob >= 0.5.
 * - Silence segments: 3 s of synthetic digital silence plus 3 s of about -60 dBFS white noise; at least 95% of chunks must have prob < 0.35.
 */
@RunWith(AndroidJUnit4::class)
class SileroVadDeviceTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun speechChunksScoreHighAndSilenceScoresLow() {
        val root = context.getExternalFilesDir("s5")
        val manifest = File(root, "manifest.json")
        assumeTrue("no s5 corpus manifest", manifest.exists())
        val array = JSONObject(manifest.readText()).optJSONArray("dictation")
        assumeTrue("empty dictation corpus", array != null && array.length() > 0)

        SileroVad.create(context).use { vad ->
            var speechChunks = 0
            var speechHits = 0
            var maxNanos = 0L
            var totalNanos = 0L
            var inferred = 0L
            for (index in 0 until array!!.length()) {
                val entry = array.getJSONObject(index)
                val samples = parseWav(File(root, entry.getString("file")).readBytes())
                val probs = probsPerChunk(vad, samples) { nanos ->
                    maxNanos = maxOf(maxNanos, nanos)
                    totalNanos += nanos
                    inferred++
                }
                val rms = DoubleArray(probs.size) { chunkRms(samples, it) }
                val gate = (rms.maxOrNull() ?: 0.0) * SPEECH_RMS_RATIO
                var chunks = 0
                var hits = 0
                for (chunk in probs.indices) {
                    if (rms[chunk] < gate) continue
                    chunks++
                    if (probs[chunk] >= SPEECH_PROB) hits++
                }
                Log.i(TAG, "speech id=${entry.getString("id")} chunks=$chunks hits=$hits")
                speechChunks += chunks
                speechHits += hits
            }

            val silence = ShortArray(SILENCE_SAMPLES * 2)
            val random = Random(7)
            for (at in SILENCE_SAMPLES until silence.size) silence[at] = (random.nextGaussian() * NOISE_SIGMA).toInt().toShort()
            val silenceProbs = probsPerChunk(vad, silence) {}
            val silenceHits = silenceProbs.count { it < SILENCE_PROB }

            val speechRatio = speechHits.toDouble() / speechChunks
            val silenceRatio = silenceHits.toDouble() / silenceProbs.size
            Log.i(
                TAG,
                "SILERO speech=$speechHits/$speechChunks (${"%.3f".format(speechRatio)}) " +
                    "silence=$silenceHits/${silenceProbs.size} (${"%.3f".format(silenceRatio)}) " +
                    "inferMeanUs=${if (inferred > 0) totalNanos / inferred / 1_000 else 0} inferMaxUs=${maxNanos / 1_000}",
            )
            assertTrue("speech chunks must exist", speechChunks > 0)
            assertTrue("speech prob>=0.5 ratio $speechRatio < 0.80", speechRatio >= 0.80)
            assertTrue("silence prob<0.35 ratio $silenceRatio < 0.95", silenceRatio >= 0.95)
        }
    }

    /** After reset, feeds 160-sample (10 ms) batches and collects each chunk's latestProb after inference. */
    private fun probsPerChunk(vad: SileroVad, samples: ShortArray, onInfer: (Long) -> Unit): FloatArray {
        vad.reset()
        val probs = FloatArray(samples.size / SileroVad.CHUNK)
        val batch = ShortArray(FEED_BATCH)
        var at = 0
        while (at < samples.size) {
            val count = minOf(FEED_BATCH, samples.size - at)
            System.arraycopy(samples, at, batch, 0, count)
            val before = vad.chunkCount
            vad.feed(batch, count)
            if (vad.chunkCount != before) {
                probs[(vad.chunkCount - 1).toInt()] = vad.latestProb
                onInfer(vad.lastInferenceNanos)
            }
            at += count
        }
        return probs
    }

    private fun chunkRms(samples: ShortArray, chunk: Int): Double {
        var sum = 0.0
        val start = chunk * SileroVad.CHUNK
        for (at in start until start + SileroVad.CHUNK) sum += samples[at].toDouble() * samples[at]
        return sqrt(sum / SileroVad.CHUNK)
    }

    /** Reads the data chunk by walking RIFF chunks; requires 16 kHz mono 16-bit. */
    private fun parseWav(wav: ByteArray): ShortArray {
        val bytes = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        var at = 12
        while (at + 8 <= wav.size) {
            val id = String(wav, at, 4, Charsets.US_ASCII)
            val length = bytes.getInt(at + 4)
            val body = at + 8
            if (id == "fmt ") {
                val channels = bytes.getShort(body + 2).toInt()
                val rate = bytes.getInt(body + 4)
                val bits = bytes.getShort(body + 14).toInt()
                require(channels == 1 && rate == SileroVad.SAMPLE_RATE && bits == 16) { "expected 16 kHz mono 16-bit" }
            } else if (id == "data") {
                val count = minOf(length, wav.size - body) / 2
                return ShortArray(count) { bytes.getShort(body + it * 2) }
            }
            at = body + length + (length and 1)
        }
        error("no data chunk")
    }

    private companion object {
        const val TAG = "SileroVadDeviceTest"
        const val FEED_BATCH = 160
        const val SPEECH_PROB = 0.5f
        const val SILENCE_PROB = 0.35f
        const val SPEECH_RMS_RATIO = 0.1
        const val SILENCE_SAMPLES = 3 * SileroVad.SAMPLE_RATE
        const val NOISE_SIGMA = 33.0
    }
}
