package ai.oriveo.community.core.voice.live

import android.content.Context
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Conversation recognition quality and sentence splitting (R1 baseline, record only, no assertions): on device [VoiceS5Rig] (production conversation path, system recognition, system TTS playback),
 * args -e bed quiet|fan|tv (default quiet) plays the corpus noise loop as background bed; -e mic real|silent (default real, silent see [VoiceS5Rig.mic]); runs the 20 corpus lines per language in conversation order (first 10 lines include a 1 s pause).
 * Per line: overlay injection -> play the preset reply (amend cancels the previous generation and regenerates; expected reply count = number of send events) -> inject the next line as soon as back to listening (target within 200 ms of playback end; actual gap recorded in gapMs).
 * Per line records send / amend count and text (more than one = split sentence, compare after concatenation), missed utterance (no send within 10 s after speech end, or SayAgain this round),
 * CER (strip punctuation, convert Arabic digits to Chinese reading) / WER (lowercase, strip punctuation), decision latency = last send / amend of this round minus speech end (only rounds not split), also records amendCount.
 * Speech end = time the last injected sample is read minus the trailing silence length of the corpus.
 * Result: getExternalFilesDir("s5-results")/conversation-quality-<bed>.json, logcat TAG VoiceS5 prints one summary line per language plus one session info line.
 */
@RunWith(AndroidJUnit4::class)
class VoiceS5ConversationQualityTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private class Item(val utterance: VoiceS5Rig.Utterance, val pause: Boolean, val tailMs: Long)

    @Test
    fun recognitionQuality() {
        val bed = InstrumentationRegistry.getArguments().getString("bed") ?: "quiet"
        require(bed in BEDS) { "bed must be one of $BEDS, got $bed" }
        val mic = InstrumentationRegistry.getArguments().getString("mic") ?: VoiceS5Rig.MIC_REAL
        require(mic in VoiceS5Rig.MICS) { "mic must be one of ${VoiceS5Rig.MICS}, got $mic" }
        val root = context.getExternalFilesDir("s5")!!
        val manifest = JSONObject(File(root, "manifest.json").readText())
        val sampleRate = manifest.optInt("sampleRate", 16_000)
        val items = corpus(root, manifest, sampleRate)
        val noise = if (bed == "quiet") null else noiseSamples(root, manifest, bed)

        val rig = VoiceS5Rig(context, mic)
        val rounds = mutableListOf<JSONObject>()
        // rig.close() also records an Ended by itself; only count the timeline before teardown
        var eventsBeforeClose = 0
        try {
            rig.start(items.first().utterance.lang)
            noise?.let { rig.setNoise(bed, it) }
            // Before the first line, let the noise floor and guard settle; then inject each line as soon as back to listening.
            Thread.sleep(SETTLE_MS)
            var previousReplyEnd: Long? = null
            for ((i, item) in items.withIndex()) {
                val index = i + 1
                // After the session ends mid-run (e.g. Ended(IDLE)), injections all miss; stop spinning.
                if (!rig.active()) break
                val u = item.utterance
                rig.switchLanguage(u.lang)
                val listening = rig.awaitStatus(LISTEN_TIMEOUT_MS) { it in LISTENING_LIKE }
                val injectAt = rig.now()
                rig.inject(index, u)
                val injectEvent = rig.timeline.events.lastOrNull { it.optString("type") == "inject" && it.optInt("turn") == index }
                val endT = injectEvent?.takeIf { !it.isNull("endT") }?.optLong("endT")
                // endT is the time relative to the rig start; -rel(0) = rig start elapsedRealtime, converted back to absolute time.
                val speechEndAt = endT?.let { -rig.rel(0) + it - item.tailMs } ?: (rig.now() - item.tailMs)
                awaitHeard(rig, index, speechEndAt + MISS_WINDOW_MS)
                val settled = awaitSettled(rig, index)
                rounds += round(rig, index, item, speechEndAt, listening, settled, previousReplyEnd?.let { injectAt - it })
                previousReplyEnd = rig.spansOf(index).maxOfOrNull { it.endAt.get() }?.takeIf { it >= 0 }
            }
            rig.setNoise(null, null)
        } finally {
            eventsBeforeClose = rig.timeline.events.size
            rig.close()
        }

        val events = rig.timeline.events
        val session = events.firstOrNull { it.optString("type") == "session" }
        val noiseOff = events.lastOrNull { it.optString("type") == "noiseOff" }
        val summaries = items.map { it.utterance.lang }.distinct().map { lang -> summarize(bed, lang, rounds.filter { it.getString("lang") == lang }) }
        val sessionLine = "conversation-quality bed=$bed session route=${session?.optString("route")} aec=${session?.opt("aec")} mic=${session?.opt("mic")} " +
            "volume=${session?.opt("voiceCallVolume")}/${session?.opt("voiceCallMax")} " +
            "noiseMixedSec=${noiseOff?.optLong("mixedSamples")?.div(sampleRate) ?: 0} " +
            "device=${Build.MANUFACTURER} ${Build.MODEL} sdk=${Build.VERSION.SDK_INT}"
        val out = JSONObject()
            .put("bed", bed)
            .put("mic", mic)
            .put("summary", JSONArray().apply { summaries.forEach { put(it.first) }; put(sessionLine) })
            .put("languages", JSONObject().apply { summaries.forEach { put(it.second.getString("lang"), it.second) } })
            .put("rounds", JSONArray().apply { rounds.forEach { put(it) } })
            .put("spans", JSONArray().apply {
                rig.timeline.spans.forEach {
                    put(JSONObject().put("turn", it.turn).put("kind", it.kind).put("text", it.text).put("startT", rig.rel(it.startAt)).put("endT", rig.rel(it.endAt.get())))
                }
            })
            .put("timeline", rig.timeline.toJson())
        val dir = context.getExternalFilesDir("s5-results")!!.apply { mkdirs() }
        File(dir, "conversation-quality-$bed.json").writeText(out.toString(2))
        summaries.forEach { VoiceS5Rig.log(it.first) }
        VoiceS5Rig.log(sessionLine)

        // Metrics are record-only, no assertions; only assert the session ran to completion: not ended midway, every round fully injected.
        val ended = events.take(eventsBeforeClose).firstOrNull { it.optString("type") == "event" && it.optString("name").startsWith("Ended") }
        val injectComplete = rounds.count { r ->
            events.lastOrNull { it.optString("type") == "inject" && it.optInt("turn") == r.getInt("turn") }?.optBoolean("complete") == true
        }
        assertTrue("conversation ended mid-run (${ended?.optString("name")}@turn${ended?.optInt("turn")}): $sessionLine", ended == null)
        assertEquals("not every round ran: $sessionLine", items.size, rounds.size)
        assertEquals("not every round was injected to completion: $sessionLine", items.size, injectComplete)
    }

    /** Wait until this round shows send / amend or a SayAgain prompt, at the latest by [deadline] (speech end + 10 s). */
    private fun awaitHeard(rig: VoiceS5Rig, index: Int, deadline: Long) {
        while (rig.now() < deadline) {
            if (rig.sendsOf(index).isNotEmpty() || sayAgain(rig, index) > 0) return
            Thread.sleep(POLL_MS)
        }
    }

    /** Wait until every send in this round has its reply playback started (amend cancels the previous generation and regenerates, no extra reply), all playback ended and back to listening; returns false on timeout. */
    private fun awaitSettled(rig: VoiceS5Rig, index: Int): Boolean {
        val deadline = rig.now() + PLAY_TIMEOUT_MS
        while (rig.now() < deadline) {
            val replies = rig.spansOf(index).count { it.kind == "reply" }
            if (replies >= rig.sendsOf(index).count { it.kind == "send" } && !rig.speaking() && rig.status() in LISTENING_LIKE) return true
            Thread.sleep(POLL_MS)
        }
        return false
    }

    private fun sayAgain(rig: VoiceS5Rig, index: Int): Int = rig.timeline.events.count {
        it.optString("type") == "prompt" && it.optString("which") == "SayAgain" && it.optInt("turn") == index
    }

    private fun round(
        rig: VoiceS5Rig,
        index: Int,
        item: Item,
        speechEndAt: Long,
        listening: Boolean,
        settled: Boolean,
        gapMs: Long?,
    ): JSONObject {
        val u = item.utterance
        val sends = rig.sendsOf(index)
        val firstSend = sends.firstOrNull { it.kind == "send" }
        val sayAgain = sayAgain(rig, index)
        val inWindow = firstSend != null && firstSend.at <= speechEndAt + MISS_WINDOW_MS
        val missed = !inWindow || sayAgain > 0
        val hypothesis = sends.joinToString(" ") { it.text }
        // amend is a follow-up to the same message, not a split: only count kind == "send" for split counting
        val sendCount = sends.count { it.kind == "send" }
        val amendCount = sends.count { it.kind == "amend" }
        // Decision latency uses the last send / amend of this round (after amend is the final submission); split rounds are not counted
        val lastSend = sends.lastOrNull()?.takeIf { sendCount == 1 }
        val zh = u.lang.startsWith("zh")
        val ref = if (zh) zhChars(u.text) else enWords(u.text)
        val hyp = if (zh) zhChars(hypothesis) else enWords(hypothesis)
        val edits = editDistance(ref, hyp)
        return JSONObject()
            .put("turn", index)
            .put("id", u.id)
            .put("lang", u.lang)
            .put("pause", item.pause)
            .put("text", u.text)
            .put("hypothesis", hypothesis)
            .put("sendCount", sendCount)
            .put("amendCount", amendCount)
            .put("split", sendCount > 1)
            .put("sends", JSONArray().apply { sends.forEach { put(JSONObject().put("kind", it.kind).put("text", it.text).put("t", rig.rel(it.at))) } })
            .put("sayAgain", sayAgain)
            .put("missed", missed)
            .put("refUnits", ref.size)
            .put("edits", edits)
            .put("errorRate", if (ref.isEmpty()) JSONObject.NULL else edits.toDouble() / ref.size)
            .put("speechEndT", rig.rel(speechEndAt))
            .put("tailMs", item.tailMs)
            .put("latencyMs", lastSend?.let { it.at - speechEndAt } ?: JSONObject.NULL)
            .put("gapMs", gapMs ?: JSONObject.NULL)
            .put("listeningBefore", listening)
            .put("settled", settled)
    }

    /** Per-language summary: missed, CER/WER (heard = non-missed lines, all = all lines, missed lines count as empty recognition), split count for pause lines, latency p50 / p95. */
    private fun summarize(bed: String, lang: String, rounds: List<JSONObject>): Pair<String, JSONObject> {
        val metric = if (lang.startsWith("zh")) "cer" else "wer"
        fun rate(list: List<JSONObject>): Double? {
            val units = list.sumOf { it.getInt("refUnits") }
            return if (units == 0) null else list.sumOf { it.getInt("edits") }.toDouble() / units
        }
        val heard = rounds.filter { !it.getBoolean("missed") }
        val allRate = rate(rounds.map { r ->
            if (r.getBoolean("missed")) JSONObject().put("refUnits", r.getInt("refUnits")).put("edits", r.getInt("refUnits")) else r
        })
        val heardRate = rate(heard)
        val latencies = rounds.mapNotNull { r -> r.opt("latencyMs").takeIf { it is Number }?.let { (it as Number).toLong() } }.sorted()
        val pauseRounds = rounds.filter { it.getBoolean("pause") }
        val pauseSplit = pauseRounds.count { it.getBoolean("split") }
        val splitAll = rounds.count { it.getBoolean("split") }
        val missed = rounds.count { it.getBoolean("missed") }
        val sayAgain = rounds.sumOf { it.getInt("sayAgain") }
        val gaps = rounds.mapNotNull { r -> r.opt("gapMs").takeIf { it is Number }?.let { (it as Number).toLong() } }
        val p50 = percentile(latencies, 0.50)
        val p95 = percentile(latencies, 0.95)
        val line = "conversation-quality bed=$bed lang=$lang rounds=${rounds.size} missed=$missed sayAgain=$sayAgain " +
            "${metric}Heard=${fmt(heardRate)} ${metric}All=${fmt(allRate)} pauseSplit=$pauseSplit/${pauseRounds.size} splitAll=$splitAll " +
            "latencyP50=${p50 ?: "n/a"} latencyP95=${p95 ?: "n/a"} latencyN=${latencies.size} " +
            "gapOver200=${gaps.count { it > GAP_TARGET_MS }}/${gaps.size}"
        val obj = JSONObject()
            .put("lang", lang)
            .put("rounds", rounds.size)
            .put("missed", missed)
            .put("sayAgain", sayAgain)
            .put("metric", metric)
            .put("rateHeard", heardRate ?: JSONObject.NULL)
            .put("rateAll", allRate ?: JSONObject.NULL)
            .put("pauseRounds", pauseRounds.size)
            .put("pauseSplit", pauseSplit)
            .put("splitAll", splitAll)
            .put("latencyP50Ms", p50 ?: JSONObject.NULL)
            .put("latencyP95Ms", p95 ?: JSONObject.NULL)
            .put("latencyN", latencies.size)
            .put("gapOver200", gaps.count { it > GAP_TARGET_MS })
            .put("summary", line)
        return line to obj
    }

    private fun fmt(value: Double?): String = value?.let { String.format(Locale.US, "%.3f", it) } ?: "n/a"

    /** Nearest-rank percentile. */
    private fun percentile(sorted: List<Long>, p: Double): Long? {
        if (sorted.isEmpty()) return null
        val rank = ceil(p * sorted.size).toInt().coerceIn(1, sorted.size)
        return sorted[rank - 1]
    }

    private fun corpus(root: File, manifest: JSONObject, sampleRate: Int): List<Item> {
        val items = manifest.getJSONArray("conversation")
        return (0 until items.length()).map { items.getJSONObject(it) }.map {
            val samples = VoiceLive.readWav(File(root, it.getString("file")))
            Item(
                utterance = VoiceS5Rig.Utterance(
                    id = it.getString("id"),
                    lang = it.getString("lang"),
                    text = it.getString("text"),
                    reply = it.getString("reply"),
                    samples = samples,
                ),
                pause = it.optBoolean("pause", false),
                tailMs = tailMs(samples, sampleRate),
            )
        }
    }

    private fun noiseSamples(root: File, manifest: JSONObject, id: String): ShortArray {
        val items = manifest.getJSONArray("noise")
        val item = (0 until items.length()).map { items.getJSONObject(it) }.firstOrNull { it.getString("id") == id }
        requireNotNull(item) { "corpus noise has no $id" }
        return VoiceLive.readWav(File(root, item.getString("file")))
    }

    /** Trailing silence length of corpus: count of samples after the last sample with amplitude >= max(peak / 20, 300). */
    private fun tailMs(samples: ShortArray, sampleRate: Int): Long {
        val peak = samples.maxOfOrNull { abs(it.toInt()) } ?: 0
        val threshold = maxOf(peak / 20, VOICED_FLOOR)
        val last = samples.indexOfLast { abs(it.toInt()) >= threshold }
        if (last < 0) return 0
        return (samples.size - 1 - last).toLong() * 1_000L / sampleRate
    }

    private companion object {
        val BEDS = setOf("quiet", "fan", "tv")
        /** Listening-type state word: after a not-heard / check-language prompt the phase stays listening; the state word stays on the prompt until the next utterance starts. */
        val LISTENING_LIKE = setOf(
            ConversationStatusKey.LISTENING,
            ConversationStatusKey.SAY_AGAIN,
            ConversationStatusKey.CHECK_LANGUAGE,
        )
        const val SETTLE_MS = 1_000L
        const val MISS_WINDOW_MS = 10_000L
        const val LISTEN_TIMEOUT_MS = 30_000L
        const val PLAY_TIMEOUT_MS = 60_000L
        const val POLL_MS = 20L
        const val GAP_TARGET_MS = 200L
        const val VOICED_FLOOR = 300
        private const val DIGITS = "\u96F6\u4E00\u4E8C\u4E09\u56DB\u4E94\u516D\u4E03\u516B\u4E5D"

        /** CER unit: convert Arabic digits to Chinese reading, then strip punctuation and whitespace, per character. */
        fun zhChars(text: String): List<String> {
            val spoken = Regex("""\d+(\.\d+)?""").replace(text) { m ->
                val parts = m.value.split(".")
                val whole = parts[0]
                val head = if (whole.length > 12 || (whole.length > 1 && whole.startsWith("0"))) {
                    whole.map { DIGITS[it - '0'] }.joinToString("")
                } else {
                    zhInteger(whole.toLong())
                }
                if (parts.size > 1) head + "\u70B9" + parts[1].map { DIGITS[it - '0'] }.joinToString("") else head
            }
            return spoken.lowercase(Locale.ROOT).filter { it.isLetterOrDigit() }.map { it.toString() }
        }

        /** WER unit: lowercase, strip punctuation, then split on whitespace. */
        fun enWords(text: String): List<String> =
            text.lowercase(Locale.ROOT).replace(Regex("""[^\p{L}\p{N}\s]"""), "").split(Regex("""\s+""")).filter { it.isNotEmpty() }

        fun zhInteger(n: Long): String {
            if (n == 0L) return "\u96F6"
            val yi = (n / 100_000_000L).toInt()
            val wan = ((n / 10_000L) % 10_000L).toInt()
            val rest = (n % 10_000L).toInt()
            val sb = StringBuilder()
            var gap = false
            if (yi > 0) sb.append(under10k(yi)).append("\u4EBF")
            if (wan > 0) {
                if (sb.isNotEmpty() && wan < 1_000) sb.append("\u96F6")
                sb.append(under10k(wan)).append("\u4E07")
            } else if (sb.isNotEmpty()) {
                gap = true
            }
            if (rest > 0) {
                if (sb.isNotEmpty() && (rest < 1_000 || gap)) sb.append("\u96F6")
                sb.append(under10k(rest))
            }
            val s = sb.toString()
            return if (s.startsWith("\u4E00\u5341")) s.drop(1) else s
        }

        private fun under10k(n: Int): String {
            val sb = StringBuilder()
            var zero = false
            for ((unit, name) in listOf(1_000 to "\u5343", 100 to "\u767E", 10 to "\u5341", 1 to "")) {
                val d = n / unit % 10
                if (d == 0) {
                    if (sb.isNotEmpty()) zero = true
                } else {
                    if (zero) sb.append("\u96F6")
                    zero = false
                    sb.append(DIGITS[d]).append(name)
                }
            }
            return sb.toString()
        }

        fun editDistance(a: List<String>, b: List<String>): Int {
            var prev = IntArray(b.size + 1) { it }
            for (i in 1..a.size) {
                val cur = IntArray(b.size + 1)
                cur[0] = i
                for (j in 1..b.size) {
                    val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                    cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                }
                prev = cur
            }
            return prev[b.size]
        }
    }
}
