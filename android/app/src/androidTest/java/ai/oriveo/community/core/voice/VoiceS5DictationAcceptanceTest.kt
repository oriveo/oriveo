package ai.oriveo.community.core.voice

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * S5 acceptance: production live dictation, N rounds (instrumentation
 * argument `rounds`, default 50) over the dictation corpus in getExternalFilesDir("s5")/manifest.json, in array
 * order. Each round plays the WAV at real-time pace plus 1.5 s trailing silence through AudioRecordCapture into the
 * recording slot and the pipe session, and settles via LiveDictationRules.dictationOutcome like the controller.
 * Gate: zero failed rounds (empty final or error). First-partial latency and CER / WER are recorded only, in
 * getExternalFilesDir("s5-results")/dictation.json and a summary line under tag VoiceS5.
 */
@RunWith(AndroidJUnit4::class)
class VoiceS5DictationAcceptanceTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private data class Item(val id: String, val lang: String, val text: String, val file: File, val leadMs: Long)

    private data class Round(
        val item: Item,
        val ok: Boolean,
        val firstPartialMs: Long?,
        val finalText: String,
        val err: String?,
    )

    @Test
    fun dictation50Rounds() = runBlocking {
        val root = context.getExternalFilesDir("s5")
        val manifest = File(root, "manifest.json")
        assumeTrue("no s5 corpus manifest", manifest.exists())
        val json = JSONObject(manifest.readText())
        val defaultLead = json.optLong("leadMs", DEFAULT_LEAD_MS)
        val array = json.optJSONArray("dictation") ?: JSONArray()
        val items = (0 until array.length()).map { index ->
            val entry = array.getJSONObject(index)
            Item(
                id = entry.getString("id"),
                lang = entry.getString("lang"),
                text = entry.getString("text"),
                file = File(root, entry.getString("file")),
                leadMs = entry.optLong("leadMs", defaultLead),
            )
        }
        assumeTrue("empty dictation corpus", items.isNotEmpty())
        val rounds = InstrumentationRegistry.getArguments().getString("rounds")?.toIntOrNull() ?: DEFAULT_ROUNDS

        val router = SystemSTTRouter(AndroidSystemSTTBackend(context))
        val engine = SystemSTTEngine(AndroidSystemSTTSessionBackend(context), routeFor = router::route)
        val results = ArrayList<Round>(rounds)
        repeat(rounds) { index ->
            val item = items[index % items.size]
            val round = runCatching { dictationRound(router, engine, item) }
                .getOrElse { Round(item, ok = false, firstPartialMs = null, finalText = "", err = it.toString()) }
            Log.i(TAG, "round=$index id=${item.id} ok=${round.ok} firstPartialMs=${round.firstPartialMs} err=${round.err} text=${round.finalText}")
            results += round
        }

        val fails = results.count { !it.ok }
        val zhP50 = p50(results.filter { isZh(it.item.lang) }.take(LATENCY_ROUNDS).mapNotNull { it.firstPartialMs })
        val enP50 = p50(results.filter { !isZh(it.item.lang) }.take(LATENCY_ROUNDS).mapNotNull { it.firstPartialMs })
        val zhCer = errorRate(results.filter { isZh(it.item.lang) }) { zhUnits(it) }
        val enWer = errorRate(results.filter { !isZh(it.item.lang) }) { enUnits(it) }

        val out = JSONObject()
            .put(
                "rounds",
                JSONArray().apply {
                    results.forEach { round ->
                        put(
                            JSONObject()
                                .put("id", round.item.id)
                                .put("lang", round.item.lang)
                                .put("ok", round.ok)
                                .put("firstPartialMs", round.firstPartialMs ?: JSONObject.NULL)
                                .put("finalText", round.finalText)
                                .put("err", round.err ?: JSONObject.NULL),
                        )
                    }
                },
            )
            .put(
                "summary",
                JSONObject()
                    .put("rounds", rounds)
                    .put("fails", fails)
                    .put("zhP50", zhP50 ?: JSONObject.NULL)
                    .put("enP50", enP50 ?: JSONObject.NULL)
                    .put("zhCer", zhCer ?: JSONObject.NULL)
                    .put("enWer", enWer ?: JSONObject.NULL),
            )
        val resultDir = context.getExternalFilesDir("s5-results")
        File(resultDir, "dictation.json").writeText(out.toString(2))
        Log.i(
            TAG,
            "VOICE-S5 dictation rounds=$rounds fails=$fails zhP50=${zhP50 ?: "n/a"} enP50=${enP50 ?: "n/a"} " +
                "zhCer=${zhCer?.let { "%.4f".format(it) } ?: "n/a"} enWer=${enWer?.let { "%.4f".format(it) } ?: "n/a"}",
        )
        assertEquals("failed rounds: ${results.filter { !it.ok }.map { "${it.item.id}:${it.err}" }}", 0, fails)
    }

    /** One production live round, same order as VoiceS0ProbeTest.replayRound and the controller. */
    private suspend fun dictationRound(router: SystemSTTRouter, engine: SystemSTTEngine, item: Item): Round {
        val route = router.route(item.lang)
        val session = engine.startSession(route) as? SystemSTTPipeSession
            ?: return Round(item, ok = false, firstPartialMs = null, finalText = "", err = "route=$route (not a pipe route)")
        val watchStart = SystemClock.uptimeMillis()
        val watch = LivePartialWatch(CoroutineScope(Dispatchers.Default), session.live)
        val storeRoot = File(context.cacheDir, "s5-prod").apply { deleteRecursively() }
        val store = RecordingStore(storeRoot)
        val slot = store.open(SLOT, SystemSTTEngine.ENGINE_NAME, MediaCodecAacEncoder())
        val source = WavPcmSource(item.file.readBytes(), trailingSilenceMs = TRAILING_SILENCE_MS)
        val capture = AudioRecordCapture({ source })
        val feedStart = SystemClock.uptimeMillis()
        capture.start(listOf(slot, session), object : AudioCaptureEvents {
            override fun onFailure(error: Throwable) = Unit
            override fun onInterrupted() = Unit
        })
        source.drained.await(60, TimeUnit.SECONDS)
        capture.stop()
        session.stop()
        slot.finish()
        val liveResult = withTimeoutOrNull(SystemSTTEngine.STOP_RESULT_TIMEOUT_MS) { session.await() }
            ?: SystemSTTEngine.TIMEOUT_RESULT
        watch.close()
        val transcript = session.live.value
        val live = when {
            liveResult is STTResult.Success -> LiveSessionResult(transcript.finals, transcript.partial, LiveEnded.Ok, hasRecording = true)
            (liveResult as STTResult.Failed).failure == DictationFailure.Timeout ->
                LiveSessionResult(transcript.finals, transcript.partial, LiveEnded.Timeout, hasRecording = true)
            else -> LiveSessionResult(transcript.finals, transcript.partial, LiveEnded.Failed, reportableKind(liveResult.failure), true)
        }
        val needFile = !(live.ended == LiveEnded.Ok && DictationRules.join(live.finals).isNotEmpty())
        val fileResult = if (needFile) {
            val meta = store.read(SLOT)
            val segment = STTSegment(
                aac = slot.audioFile,
                primingFrames = meta?.primingFrames ?: RecordingWriter.DEFAULT_PRIMING_FRAMES,
                envelope = meta?.envelope.orEmpty(),
            )
            when (val r = withTimeoutOrNull(30_000) { engine.transcribe(segment, item.lang) } ?: SystemSTTEngine.TIMEOUT_RESULT) {
                is STTResult.Success -> LiveFileResult.Text(r.text)
                is STTResult.Failed -> LiveFileResult.Failed(reportableKind(r.failure))
            }
        } else {
            null
        }
        store.complete(SLOT)
        val outcome = LiveDictationRules.dictationOutcome(live, fileResult)
        val text = outcome.text.orEmpty()
        val ok = outcome.result == DictationOutcomeResult.Text && text.isNotBlank()
        // Watch time is relative to its construction; shift to feed start, then drop the leading silence.
        val firstPartialMs = watch.firstPartialMs.takeIf { it >= 0 }?.let { it - (feedStart - watchStart) - item.leadMs }
        val err = if (ok) {
            null
        } else {
            "result=${outcome.result.rawValue} live=${live.ended.rawValue}${live.failureKind?.let { "/$it" }.orEmpty()} liveRaw=$liveResult"
        }
        return Round(item, ok, firstPartialMs, text, err)
    }

    /** Same folding as the controller: recognizer codes by table, network, timeout as busy, the rest other. */
    private fun reportableKind(failure: DictationFailure): SystemFailureKind {
        val kind = when (failure) {
            is DictationFailure.Recognizer -> SystemFailure.kindOf(SystemFailureInput.Code(failure.code))
            DictationFailure.Network -> SystemFailureKind.Network
            DictationFailure.Timeout -> SystemFailureKind.Busy
            else -> SystemFailureKind.Other
        }
        return if (kind.isReportable) kind else SystemFailureKind.Other
    }

    private fun isZh(lang: String) = lang.startsWith("zh") || lang.startsWith("cmn")

    private fun p50(values: List<Long>): Long? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        return sorted[(sorted.size - 1) / 2]
    }

    /** Pooled error rate: total edit distance over total reference units; null when no round in this language. */
    private fun errorRate(rounds: List<Round>, units: (String) -> List<String>): Double? {
        if (rounds.isEmpty()) return null
        var edits = 0
        var total = 0
        for (round in rounds) {
            val reference = units(round.item.text)
            edits += editDistance(reference, units(round.finalText))
            total += reference.size
        }
        return if (total == 0) null else edits.toDouble() / total
    }

    private fun isDropped(codePoint: Int): Boolean {
        val type = Character.getType(codePoint)
        return Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint) || type in PUNCTUATION_TYPES
    }

    /** Chinese: drop punctuation and whitespace, one unit per character; digits are kept as written. */
    private fun zhUnits(text: String): List<String> =
        text.codePoints().toArray().filterNot(::isDropped).map { String(Character.toChars(it)) }

    /** English: lowercase, punctuation to space, one unit per word; digits are kept as written. */
    private fun enUnits(text: String): List<String> =
        text.lowercase().codePoints().toArray()
            .joinToString("") { if (isDropped(it)) " " else String(Character.toChars(it)) }
            .split(' ').filter { it.isNotEmpty() }

    private fun editDistance(a: List<String>, b: List<String>): Int {
        var previous = IntArray(b.size + 1) { it }
        for (i in 1..a.size) {
            val current = IntArray(b.size + 1)
            current[0] = i
            for (j in 1..b.size) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                current[j] = minOf(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.size]
    }

    private companion object {
        const val TAG = "VoiceS5"
        const val SLOT = "probe:s5"
        const val DEFAULT_ROUNDS = 50
        const val DEFAULT_LEAD_MS = 300L
        const val TRAILING_SILENCE_MS = 1_500L
        const val LATENCY_ROUNDS = 10
        val PUNCTUATION_TYPES = setOf(
            Character.CONNECTOR_PUNCTUATION.toInt(),
            Character.DASH_PUNCTUATION.toInt(),
            Character.START_PUNCTUATION.toInt(),
            Character.END_PUNCTUATION.toInt(),
            Character.INITIAL_QUOTE_PUNCTUATION.toInt(),
            Character.FINAL_QUOTE_PUNCTUATION.toInt(),
            Character.OTHER_PUNCTUATION.toInt(),
        )
    }
}
