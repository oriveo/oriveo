package ai.oriveo.community.core.voice

import android.Manifest
import android.content.Context
import android.media.AudioAttributes
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.voice.conversation.SystemConversationTts
import ai.oriveo.community.core.voice.conversation.TtsOutcome
import ai.oriveo.community.core.voice.conversation.VOICE_COMMUNICATION_ATTRIBUTES
import java.io.File
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Playback probe for the system TTS voice path on a real device.
 *
 * systemTtsLongPause: production SystemConversationTts speaks a Chinese passage of 8 s or more. A baseline round
 * measures first-audio to played-out; the pause round pauses 1.5 s after the first audio, holds 30 s, resumes and
 * measures resume to played-out (close to the baseline = restarted from the sentence start). A cancel round pauses
 * the same way and cancels mid-hold, timing the cancel. A main-thread Handler heartbeat counts gaps over 200 ms.
 * Gate: the paused sentence finishes from where it was held, cancel returns within 1 s, zero main-thread stalls.
 *
 * visualizerOnVoiceCommunication: MediaChunkPlayer with the conversation's USAGE_VOICE_COMMUNICATION attributes
 * plays getExternalFilesDir("s5")/conv/conv-zh-CN-11.wav and counts level callbacks (total / non-zero), with a
 * USAGE_MEDIA control round. Recorded only.
 *
 * Both write into getExternalFilesDir("s5-results")/playback.json and log a summary line under tag VoiceS5.
 */
@RunWith(AndroidJUnit4::class)
class VoiceS5PlaybackProbeTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private data class TtsRound(
        val outcome: TtsOutcome?,
        val firstAudioMs: Long?,
        val resumeToDoneMs: Long?,
        val levelsDuringHold: Int,
        val cancelMs: Long?,
        val levels: Int = 0,
        val levelsBeforeHold: Int = 0,
    )

    @Test
    fun systemTtsLongPause(): Unit = runBlocking {
        val tts = SystemConversationTts(
            context = context,
            speechRate = { 1.0 },
            localeFor = { Locale.SIMPLIFIED_CHINESE },
            tempDir = File(context.cacheDir, "s5-tts"),
        )
        val heartbeat = MainHeartbeat().also { it.start() }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val baseline = ttsRound(scope, tts, pauseAtMs = null, holdMs = 0, cancelInHold = false)
            val baselineMs = baseline.resumeToDoneMs
            val paused = ttsRound(scope, tts, pauseAtMs = PAUSE_AT_MS, holdMs = HOLD_MS, cancelInHold = false)
            val cancelled = ttsRound(scope, tts, pauseAtMs = PAUSE_AT_MS, holdMs = CANCEL_AT_MS, cancelInHold = true)
            heartbeat.stop()

            val resumeMs = paused.resumeToDoneMs
            // Restarted from the sentence start = the tail after resume takes about the whole baseline.
            val fromStart = if (baselineMs != null && resumeMs != null) resumeMs > baselineMs - PAUSE_AT_MS / 2 else null
            // Finished from where it was held = the tail after resume plays roughly the rest of the baseline.
            val expectedRestMs = baselineMs?.let { it - PAUSE_AT_MS }
            val truncated = if (expectedRestMs != null && resumeMs != null) resumeMs < expectedRestMs - REST_TOLERANCE_MS else null
            val resumedDone = paused.outcome?.done == true
            val summary = JSONObject()
                .put("baselineDone", baseline.outcome?.done == true)
                .put("baselineMs", baselineMs ?: JSONObject.NULL)
                .put("pauseAtMs", PAUSE_AT_MS)
                .put("holdMs", HOLD_MS)
                .put("resumedDone", resumedDone)
                .put("resumeToDoneMs", resumeMs ?: JSONObject.NULL)
                .put("fromStart", fromStart ?: JSONObject.NULL)
                .put("expectedRestMs", expectedRestMs ?: JSONObject.NULL)
                .put("truncated", truncated ?: JSONObject.NULL)
                .put("baselineLevels", baseline.levels)
                .put("pausedLevelsBeforeHold", paused.levelsBeforeHold)
                .put("pausedLevels", paused.levels)
                .put("levelsDuringHold", paused.levelsDuringHold)
                .put("cancelAtHoldMs", CANCEL_AT_MS)
                .put("cancelMs", cancelled.cancelMs ?: JSONObject.NULL)
                .put("cancelOutcomeDone", cancelled.outcome?.done ?: JSONObject.NULL)
                .put("mainStalls", heartbeat.stalls.get())
                .put("mainMaxGapMs", heartbeat.maxGap.get())
            writeResult("systemTtsLongPause", summary)
            Log.i(
                TAG,
                "VOICE-S5 playback tts baselineMs=${baselineMs ?: "n/a"} resumedDone=$resumedDone " +
                    "resumeToDoneMs=${resumeMs ?: "n/a"} fromStart=${fromStart ?: "n/a"} " +
                    "expectedRestMs=${expectedRestMs ?: "n/a"} truncated=${truncated ?: "n/a"} " +
                    "levels=${baseline.levels}/${paused.levelsBeforeHold}+${paused.levels - paused.levelsBeforeHold} " +
                    "levelsDuringHold=${paused.levelsDuringHold} cancelMs=${cancelled.cancelMs ?: "n/a"} " +
                    "mainStalls=${heartbeat.stalls.get()} mainMaxGapMs=${heartbeat.maxGap.get()}",
            )

            assertTrue("baseline passage must be 8 s or more: $baselineMs", (baselineMs ?: 0) >= MIN_PASSAGE_MS)
            assertTrue("paused sentence did not finish: ${paused.outcome}", resumedDone)
            assertEquals("restarted from the sentence start: resume=$resumeMs baseline=$baselineMs", false, fromStart)
            assertEquals("rest cut short: resume=$resumeMs expected=$expectedRestMs", false, truncated)
            assertTrue("cancel took ${cancelled.cancelMs} ms", (cancelled.cancelMs ?: Long.MAX_VALUE) <= MAX_CANCEL_MS)
            assertEquals("main-thread gaps over $STALL_MS ms (max ${heartbeat.maxGap.get()})", 0, heartbeat.stalls.get())
        } finally {
            heartbeat.stop()
            scope.cancel()
            tts.release()
        }
    }

    /**
     * One speak of [PASSAGE]. [pauseAtMs] null = straight through; resumeToDoneMs is then first audio to played-out.
     * Otherwise pauses that long after the first audio and holds [holdMs]; then resumes, or cancels when [cancelInHold].
     */
    private suspend fun ttsRound(
        scope: CoroutineScope,
        tts: SystemConversationTts,
        pauseAtMs: Long?,
        holdMs: Long,
        cancelInHold: Boolean,
    ): TtsRound {
        val firstAudio = CompletableDeferred<Long>()
        val levels = AtomicInteger()
        val startedAt = SystemClock.elapsedRealtime()
        val job = scope.async {
            tts.speak(PASSAGE) {
                levels.incrementAndGet()
                if (!firstAudio.isCompleted) firstAudio.complete(SystemClock.elapsedRealtime())
            }
        }
        val firstAt = withTimeoutOrNull(FIRST_AUDIO_TIMEOUT_MS) { firstAudio.await() }
        if (firstAt == null) {
            job.cancel()
            return TtsRound(outcome = null, firstAudioMs = null, resumeToDoneMs = null, levelsDuringHold = 0, cancelMs = null)
        }
        val firstAudioMs = firstAt - startedAt
        if (pauseAtMs == null) {
            val outcome = withTimeout(SPEAK_TIMEOUT_MS) { job.await() }
            val doneAt = outcome.endedAtMs ?: SystemClock.elapsedRealtime()
            return TtsRound(outcome, firstAudioMs, doneAt - firstAt, levelsDuringHold = 0, cancelMs = null, levels = levels.get())
        }
        delay((firstAt + pauseAtMs - SystemClock.elapsedRealtime()).coerceAtLeast(0))
        tts.pause()
        // Let the track buffer stop taking writes before counting levels that arrive during the hold.
        delay(HOLD_SETTLE_MS)
        val levelsAtHold = levels.get()
        delay(holdMs - HOLD_SETTLE_MS)
        val levelsBeforeResume = levels.get()
        val levelsDuringHold = levelsBeforeResume - levelsAtHold
        if (cancelInHold) {
            val t0 = SystemClock.elapsedRealtime()
            job.cancel()
            runCatching { job.await() }
            val cancelMs = SystemClock.elapsedRealtime() - t0
            return TtsRound(outcome = null, firstAudioMs, resumeToDoneMs = null, levelsDuringHold, cancelMs = cancelMs)
        }
        val resumedAt = SystemClock.elapsedRealtime()
        tts.resume()
        val outcome = withTimeoutOrNull(SPEAK_TIMEOUT_MS) { job.await() }
        if (outcome == null) job.cancel()
        val doneAt = outcome?.endedAtMs ?: SystemClock.elapsedRealtime()
        return TtsRound(outcome, firstAudioMs, doneAt - resumedAt, levelsDuringHold, cancelMs = null, levels = levels.get(), levelsBeforeHold = levelsBeforeResume)
    }

    @Test
    fun visualizerOnVoiceCommunication(): Unit = runBlocking {
        val file = File(context.getExternalFilesDir("s5"), "conv/conv-zh-CN-11.wav")
        assumeTrue("no s5 conversation corpus file: $file", file.exists())
        // Visualizer on another session needs RECORD_AUDIO.
        InstrumentationRegistry.getInstrumentation().uiAutomation
            .grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)
        val media = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val voice = visualizerRound(VOICE_COMMUNICATION_ATTRIBUTES, file)
        val control = visualizerRound(media, file)
        writeResult(
            "visualizer",
            JSONObject()
                .put("file", file.name)
                .put("voiceCommunication", voice)
                .put("media", control),
        )
        Log.i(
            TAG,
            "VOICE-S5 playback visualizer voice ok=${voice.getBoolean("ok")} levels=${voice.getInt("levels")} " +
                "nonZero=${voice.getInt("nonZero")} media ok=${control.getBoolean("ok")} " +
                "levels=${control.getInt("levels")} nonZero=${control.getInt("nonZero")}",
        )
    }

    private suspend fun visualizerRound(attributes: AudioAttributes, file: File): JSONObject {
        val levels = AtomicInteger()
        val nonZero = AtomicInteger()
        val peak = AtomicLong()
        val player = MediaChunkPlayer(attributes) { level ->
            levels.incrementAndGet()
            if (level > 0f) nonZero.incrementAndGet()
            val milli = (level * 1000).toLong()
            if (milli > peak.get()) peak.set(milli)
        }
        val t0 = SystemClock.elapsedRealtime()
        val ok = withTimeoutOrNull(SPEAK_TIMEOUT_MS) { player.play(file) }
        if (ok == null) player.stop()
        return JSONObject()
            .put("ok", ok == true)
            .put("playMs", SystemClock.elapsedRealtime() - t0)
            .put("levels", levels.get())
            .put("nonZero", nonZero.get())
            .put("peakLevel", peak.get() / 1000.0)
    }

    /** Merges [section] into playback.json so each test keeps the other's result. */
    @Synchronized
    private fun writeResult(section: String, value: JSONObject) {
        val out = File(context.getExternalFilesDir("s5-results"), "playback.json")
        val json = runCatching { JSONObject(out.readText()) }.getOrElse { JSONObject() }
        json.put(section, value)
        out.writeText(json.toString(2))
    }

    /** Main-thread heartbeat: a self-reposting Handler message every [BEAT_MS]; gaps over [STALL_MS] count as stalls. */
    private class MainHeartbeat {
        private val handler = Handler(Looper.getMainLooper())
        val stalls = AtomicInteger()
        val maxGap = AtomicLong()
        @Volatile private var last = 0L
        @Volatile private var running = false
        private val beat = object : Runnable {
            override fun run() {
                if (!running) return
                val now = SystemClock.uptimeMillis()
                val gap = now - last
                if (gap > maxGap.get()) maxGap.set(gap)
                if (gap > STALL_MS) stalls.incrementAndGet()
                last = now
                handler.postDelayed(this, BEAT_MS)
            }
        }

        fun start() {
            running = true
            last = SystemClock.uptimeMillis()
            handler.postDelayed(beat, BEAT_MS)
        }

        fun stop() {
            running = false
            handler.removeCallbacks(beat)
        }
    }

    private companion object {
        const val TAG = "VoiceS5"
        const val PASSAGE =
            "\u4ECA\u5929\u4E0B\u5348\u4E09\u70B9\uFF0C\u6211\u4EEC\u5728\u4E09\u697C\u4F1A\u8BAE\u5BA4\u8BA8\u8BBA\u4E0B\u4E2A\u5B63\u5EA6\u7684\u4EA7\u54C1\u8BA1\u5212\u3002\u8BF7\u5927\u5BB6\u63D0\u524D\u51C6\u5907\u597D\u5404\u81EA\u8D1F\u8D23\u6A21\u5757\u7684\u8FDB\u5EA6\u62A5\u544A\uFF0C" +
                "\u5305\u62EC\u5DF2\u7ECF\u5B8C\u6210\u7684\u529F\u80FD\u3001\u9047\u5230\u7684\u4E3B\u8981\u95EE\u9898\u4EE5\u53CA\u9700\u8981\u5176\u4ED6\u56E2\u961F\u914D\u5408\u7684\u4E8B\u9879\u3002\u4F1A\u8BAE\u9884\u8BA1\u6301\u7EED\u4E00\u4E2A\u534A\u5C0F\u65F6\uFF0C\u7ED3\u675F\u540E\u4F1A\u6574\u7406\u7EAA\u8981\u53D1\u7ED9\u6BCF\u4F4D\u53C2\u4F1A\u8005\u3002"
        const val PAUSE_AT_MS = 1_500L
        const val HOLD_MS = 30_000L
        const val CANCEL_AT_MS = 15_000L
        const val HOLD_SETTLE_MS = 500L
        const val MIN_PASSAGE_MS = 8_000L
        const val REST_TOLERANCE_MS = 1_500L
        const val MAX_CANCEL_MS = 1_000L
        const val FIRST_AUDIO_TIMEOUT_MS = 10_000L
        const val SPEAK_TIMEOUT_MS = 60_000L
        const val BEAT_MS = 50L
        const val STALL_MS = 200L
    }
}
