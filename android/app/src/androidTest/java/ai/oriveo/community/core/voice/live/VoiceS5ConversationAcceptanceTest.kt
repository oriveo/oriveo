package ai.oriveo.community.core.voice.live

import android.content.Context
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.voice.conversation.ConversationDisplayState
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Conversation playback echo: on a real device, [VoiceS5Rig] (production conversation path: real capture, system recognition, system TTS playback, production reducer)
 * runs the conversation corpus lines with pause=false (20 lines). Per line: wait for listening -> overlay injection -> play the preset reply -> no injection for 4 s after playback ends.
 * send / amend events during playback and within 4 s after it count as self-triggered; assert 0.
 * Corpus: getExternalFilesDir("s5")/manifest.json; result: getExternalFilesDir("s5-results")/conversation-echo.json,
 * logcat TAG VoiceS5 prints a summary line.
 *
 * Noise-only run: only the fan / tv loop noise from the corpus noise entries (durationSec) plays, no speech injected, output routed to the speaker;
 * send / amend count as false triggers, assert 0; SayAgain / CheckLanguage are only recorded (limit <= 1).
 * Result: getExternalFilesDir("s5-results")/conversation-noise.json (merged by noise id), logcat TAG VoiceS5 prints a summary line.
 *
 * Short answer / repeat: for each shortAnswers corpus entry, first inject one conversation line in the same language, reply = that entry's reply (played out loud),
 * inject the short answer within [SHORT_INJECT_WITHIN_MS] after the reply ends; no send / amend within [SHORT_WINDOW_MS] after injection start counts as a miss, assert <= 1.
 * Result: getExternalFilesDir("s5-results")/conversation-short.json, logcat TAG VoiceS5 prints a summary line.
 */
@RunWith(AndroidJUnit4::class)
class VoiceS5ConversationAcceptanceTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun speakerEcho20() {
        val utterances = corpus()
        assertEquals("corpus conversation pause=false", ROUNDS, utterances.size)
        val rig = VoiceS5Rig(context)
        val rounds = JSONArray()
        // rig.close() also records an Ended by itself; only count the timeline before teardown
        var eventsBeforeClose = 0
        try {
            rig.start(utterances.first().lang)
            for ((i, u) in utterances.withIndex()) {
                val index = i + 1
                // After the session ends mid-run (e.g. Ended(IDLE)), injections all miss; stop spinning.
                if (!rig.active()) break
                rig.switchLanguage(u.lang)
                // After a SAY_AGAIN / CHECK_LANGUAGE prompt, statusKey stays there until the next utterance starts, but it is still listening.
                val listening = rig.awaitStatus(LISTEN_TIMEOUT_MS) { it in LISTENING_LIKE }
                // Let the noise floor and guard settle after listening before speaking.
                Thread.sleep(SETTLE_MS)
                rig.inject(index, u)
                // Status may still be SAY_AGAIN from the previous round: go by whether this round started playback or showed the not-heard prompt, not the current status field.
                val replied = awaitAnswered(rig, index)
                val back = awaitListening(rig)
                quietWindow(rig, index)
                val sends = rig.sendsOf(index)
                val spans = rig.spansOf(index)
                val injected = rig.timeline.events.lastOrNull { it.optString("type") == "inject" && it.optInt("turn") == index }
                rounds.put(
                    JSONObject()
                        .put("turn", index)
                        .put("id", u.id)
                        .put("lang", u.lang)
                        .put("text", u.text)
                        .put("reply", u.reply)
                        .put("listeningBefore", listening)
                        .put("injectComplete", injected?.optBoolean("complete") == true)
                        .put("speaking", replied)
                        .put("listeningAfter", back)
                        .put("sayAgain", turnPrompts(rig, index, "SayAgain"))
                        .put("checkLanguage", turnPrompts(rig, index, "CheckLanguage"))
                        .put("sends", JSONArray().apply { sends.forEach { put(JSONObject().put("kind", it.kind).put("text", it.text).put("t", rig.rel(it.at))) } })
                        .put("replyPlayed", spans.any { it.kind == "reply" }),
                )
            }
        } finally {
            eventsBeforeClose = rig.timeline.events.size
            rig.close()
        }

        val selfTriggers = selfTriggers(rig)
        val events = rig.timeline.events
        fun prompts(which: String) = events.count { it.optString("type") == "prompt" && it.optString("which") == which }
        val replied = (1..ROUNDS).count { t -> rig.spansOf(t).any { it.kind == "reply" } }
        val noSend = (1..ROUNDS).count { t -> rig.sendsOf(t).isEmpty() }
        val session = events.firstOrNull { it.optString("type") == "session" }
        val ended = events.take(eventsBeforeClose).firstOrNull { it.optString("type") == "event" && it.optString("name").startsWith("Ended") }
        val list = (0 until rounds.length()).map { rounds.getJSONObject(it) }
        val injectedComplete = list.count { it.getBoolean("injectComplete") }
        val sayAgainTurns = list.filter { it.getInt("sayAgain") > 0 }.map { it.getInt("turn") }
        val summary = "conversation-echo rounds=$ROUNDS ran=${list.size} injectComplete=$injectedComplete replied=$replied noSend=$noSend selfTriggers=${selfTriggers.size} " +
            "selfTriggerTurns=${selfTriggers.map { it.turn }} sayAgain=${prompts("SayAgain")} sayAgainTurns=$sayAgainTurns checkLanguage=${prompts("CheckLanguage")} " +
            "echoHint=${prompts("EchoHint")} nudgeOrb=${events.count { it.optString("type") == "nudgeOrb" }} " +
            "ended=${ended?.let { "${it.optString("name")}@turn${it.optInt("turn")}" }} " +
            "route=${session?.optString("route")} aec=${session?.opt("aec")} " +
            "volume=${session?.opt("voiceCallVolume")}/${session?.opt("voiceCallMax")} " +
            "device=${Build.MANUFACTURER} ${Build.MODEL} sdk=${Build.VERSION.SDK_INT}"
        val out = JSONObject()
            .put("summary", summary)
            .put("selfTriggers", JSONArray().apply { selfTriggers.forEach { put(JSONObject().put("turn", it.turn).put("kind", it.kind).put("text", it.text).put("t", rig.rel(it.at))) } })
            .put("rounds", rounds)
            .put("spans", JSONArray().apply {
                rig.timeline.spans.forEach {
                    put(JSONObject().put("turn", it.turn).put("kind", it.kind).put("text", it.text).put("startT", rig.rel(it.startAt)).put("endT", rig.rel(it.endAt.get())))
                }
            })
            .put("timeline", rig.timeline.toJson())
        val dir = context.getExternalFilesDir("s5-results")!!.apply { mkdirs() }
        File(dir, "conversation-echo.json").writeText(out.toString(2))
        VoiceS5Rig.log(summary)

        assertTrue("conversation was not routed to the speaker: $summary", session?.optString("route") == "SPEAKER")
        assertTrue("voice call volume was not at max: $summary", session != null && session.optInt("voiceCallVolume") == session.optInt("voiceCallMax"))
        assertTrue("conversation ended mid-run (${ended?.optString("name")}): $summary", ended == null)
        assertEquals("not every round was injected to completion: $summary", ROUNDS, injectedComplete)
        assertTrue("no reply was played, nothing measured: $summary", replied > 0)
        assertEquals("speaker self-triggers: $summary", 0, selfTriggers.size)
    }

    @Test
    fun shortAnswers20() {
        val shorts = shortAnswers()
        assertEquals("corpus shortAnswers", ROUNDS, shorts.size)
        val leads = corpus()
        val rig = VoiceS5Rig(context)
        val rounds = JSONArray()
        // rig.close() also records an Ended by itself; only count the timeline before teardown
        var eventsBeforeClose = 0
        val falseOnsets = JSONArray()
        try {
            rig.start(shorts.first().lang)
            for ((i, s) in shorts.withIndex()) {
                val index = i + 1
                // After the session ends mid-run (e.g. Ended(IDLE)), injections all miss; stop spinning.
                if (!rig.active()) break
                val shortTurn = SHORT_TURN_BASE + index
                rig.switchLanguage(s.lang)
                val lead = leads.filter { it.lang == s.lang }.let { same -> same.getOrNull(i % maxOf(same.size, 1)) }
                requireNotNull(lead) { "corpus conversation has no ${s.lang} sentence for ${s.id}" }
                // A reply triggered by the previous short answer may be paused by its own echo (segment not ended, state back to listening); wait for it to finish before starting this round.
                val listening = awaitIdle(rig)
                Thread.sleep(SETTLE_MS)
                settleBeforeInject(rig, index, falseOnsets)
                // Lead-in sentence samples + this entry's preset reply: the AI plays what the short answer should follow.
                rig.inject(index, VoiceS5Rig.Utterance(lead.id, lead.lang, lead.text, s.reply, lead.samples))
                val ends = awaitReplyEnd(rig, index)
                val replyEnd = ends?.first
                val lastEnd = ends?.second
                var injectStartT: Long? = null
                var injectEndT: Long? = null
                if (replyEnd != null) {
                    // The reply after the recognized short answer takes the lead-in's reply, only to get the pipeline back to listening.
                    rig.inject(shortTurn, VoiceS5Rig.Utterance(s.id, s.lang, s.text, lead.reply, s.samples))
                    val injected = rig.timeline.events.lastOrNull { it.optString("type") == "inject" && it.optInt("turn") == shortTurn }
                    injectStartT = injected?.optLong("startT", -1)?.takeIf { it >= 0 }
                    injectEndT = injected?.optLong("endT", -1)?.takeIf { it >= 0 }
                    val windowFrom = injectStartT ?: rig.rel(rig.now())
                    val wait = windowFrom + SHORT_WINDOW_MS - rig.rel(rig.now())
                    if (wait > 0) Thread.sleep(wait)
                    awaitIdle(rig)
                }
                val windowStart = injectStartT
                val shortSends = rig.sendsOf(shortTurn).filter { windowStart != null && rig.rel(it.at) <= windowStart + SHORT_WINDOW_MS }
                val shortEvents = rig.timeline.events.filter { it.optInt("turn") == shortTurn }
                rounds.put(
                    JSONObject()
                        .put("turn", index)
                        .put("id", s.id)
                        .put("lang", s.lang)
                        .put("text", s.text)
                        .put("reply", s.reply)
                        .put("leadId", lead.id)
                        .put("listeningBefore", listening)
                        .put("leadSends", JSONArray().apply { rig.sendsOf(index).forEach { put(JSONObject().put("kind", it.kind).put("text", it.text).put("t", rig.rel(it.at))) } })
                        .put("replyEndT", replyEnd?.let(rig::rel) ?: JSONObject.NULL)
                        .put("injectStartT", injectStartT ?: JSONObject.NULL)
                        .put("injectEndT", injectEndT ?: JSONObject.NULL)
                        .put("lastPlaybackEndT", lastEnd?.let(rig::rel) ?: JSONObject.NULL)
                        .put("injectDelayMs", if (lastEnd != null && injectStartT != null) injectStartT - rig.rel(lastEnd) else JSONObject.NULL)
                        .put("measured", replyEnd != null && injectStartT != null)
                        .put("sends", JSONArray().apply { shortSends.forEach { put(JSONObject().put("kind", it.kind).put("text", it.text).put("t", rig.rel(it.at))) } })
                        .put("recognized", shortSends.firstOrNull()?.text ?: JSONObject.NULL)
                        .put("dropped", replyEnd != null && injectStartT != null && shortSends.isEmpty())
                        .put("nudgeOrb", shortEvents.count { it.optString("type") == "nudgeOrb" })
                        .put("echoHint", shortEvents.count { it.optString("type") == "prompt" && it.optString("which") == "EchoHint" })
                        .put("events", JSONArray().apply { shortEvents.forEach { put(it) } }),
                )
            }
        } finally {
            eventsBeforeClose = rig.timeline.events.size
            rig.close()
        }

        val list = (0 until rounds.length()).map { rounds.getJSONObject(it) }
        val measured = list.count { it.getBoolean("measured") }
        val dropped = list.filter { it.getBoolean("dropped") }
        val late = list.count { it.opt("injectDelayMs") is Number && it.getLong("injectDelayMs") > SHORT_INJECT_WITHIN_MS }
        val events = rig.timeline.events
        val session = events.firstOrNull { it.optString("type") == "session" }
        val ended = events.take(eventsBeforeClose).firstOrNull { it.optString("type") == "event" && it.optString("name").startsWith("Ended") }
        val onsetGaps = (0 until falseOnsets.length()).map { falseOnsets.getJSONObject(it).opt("sinceLastPlaybackMs") }
        val summary = "conversation-short rounds=$ROUNDS measured=$measured dropped=${dropped.size} droppedIds=${dropped.map { it.getString("id") }} " +
            "droppedNudgeOrb=${dropped.count { it.getInt("nudgeOrb") > 0 }} lateInject=$late " +
            "maxInjectDelayMs=${list.mapNotNull { (it.opt("injectDelayMs") as? Number)?.toLong() }.maxOrNull()} " +
            "nudgeOrb=${events.count { it.optString("type") == "nudgeOrb" }} " +
            "ended=${ended?.let { "${it.optString("name")}@turn${it.optInt("turn")}" }} " +
            "preInjectFalseOnsets=${falseOnsets.length()} falseOnsetSincePlaybackMs=$onsetGaps " +
            "route=${session?.optString("route")} aec=${session?.opt("aec")} " +
            "volume=${session?.opt("voiceCallVolume")}/${session?.opt("voiceCallMax")} " +
            "device=${Build.MANUFACTURER} ${Build.MODEL} sdk=${Build.VERSION.SDK_INT}"
        val out = JSONObject()
            .put("summary", summary)
            .put("rounds", rounds)
            .put("preInjectFalseOnsets", falseOnsets)
            .put("spans", JSONArray().apply {
                rig.timeline.spans.forEach {
                    put(JSONObject().put("turn", it.turn).put("kind", it.kind).put("text", it.text).put("startT", rig.rel(it.startAt)).put("endT", rig.rel(it.endAt.get())))
                }
            })
            .put("timeline", rig.timeline.toJson())
        val dir = context.getExternalFilesDir("s5-results")!!.apply { mkdirs() }
        File(dir, "conversation-short.json").writeText(out.toString(2))
        VoiceS5Rig.log(summary)

        assertTrue("conversation was not routed to the speaker: $summary", session?.optString("route") == "SPEAKER")
        assertTrue("conversation ended mid-run (${ended?.optString("name")}): $summary", ended == null)
        assertEquals("not every short answer was measured: $summary", ROUNDS, measured)
        assertEquals("short answers injected later than ${SHORT_INJECT_WITHIN_MS}ms after reply end: $summary", 0, late)
        assertTrue("short answers dropped: $summary", dropped.size <= SHORT_MAX_DROPPED)
    }

    /**
     * Wait for the last playback of reply line [index] to end (if the reply was interrupted and replayed, wait for the replay; the prompt line right after it also waits to finish),
     * returns (reply last ended, last playback end of this round) timestamps (elapsedRealtime); null if it never started or timed out.
     * "Inject within 200 ms of playback end" is measured from the last playback end of this round (including the prompt line).
     */
    private fun awaitReplyEnd(rig: VoiceS5Rig, index: Int): Pair<Long, Long>? {
        val deadline = rig.now() + REPLY_TIMEOUT_MS + PLAY_TIMEOUT_MS
        while (rig.now() < deadline) {
            val spans = rig.spansOf(index)
            val replies = spans.filter { it.kind == "reply" }
            if (replies.isNotEmpty() && !rig.speaking()) return replies.maxOf { it.endAt.get() } to spans.maxOf { it.endAt.get() }
            Thread.sleep(REPLY_POLL_MS)
        }
        return null
    }

    /** Wait until no segment is playing (including paused, not-yet-ended ones) and the state is listening; returns false on timeout. */
    private fun awaitIdle(rig: VoiceS5Rig, timeoutMs: Long = PLAY_TIMEOUT_MS): Boolean {
        val deadline = rig.now() + timeoutMs
        while (rig.now() < deadline) {
            if (idle(rig)) return true
            Thread.sleep(REPLY_POLL_MS)
        }
        return false
    }

    /** No segment playing; state word and display state are both listening-type (including still listening after a not-heard / check-language prompt; no VAD-started sentence unfinished). */
    private fun idle(rig: VoiceS5Rig): Boolean =
        !rig.speaking() && rig.status() in LISTENING_LIKE && rig.display() in LISTENING_LIKE_DISPLAY

    /**
     * If a false onset happened before lead-in injection (state / display not listening, or a segment playing), wait for it to settle (<= [FALSE_ONSET_SETTLE_MS]) before injecting;
     * record start/end times and ms since last playback end each time (timeline preInjectFalseOnset). After settling, stay stable for [SETTLE_MS], at most [FALSE_ONSET_ROUNDS] times.
     */
    private fun settleBeforeInject(rig: VoiceS5Rig, index: Int, out: JSONArray) {
        repeat(FALSE_ONSET_ROUNDS) {
            if (idle(rig)) return
            val events = rig.timeline.events.toList()
            val listening = ConversationDisplayState.LISTENING.rawValue
            val lastListening = events.lastOrNull { it.optString("type") == "display" && it.optString("state") == listening }?.optLong("t")
            val start = events.firstOrNull {
                it.optString("type") == "display" && it.optString("state") != listening && (lastListening == null || it.optLong("t") >= lastListening)
            }?.optLong("t") ?: rig.rel(rig.now())
            val lastPlayback = rig.timeline.spans.mapNotNull { span -> span.endAt.get().takeIf { it >= 0 } }.maxOrNull()?.let(rig::rel)
            val settled = awaitIdle(rig, FALSE_ONSET_SETTLE_MS)
            val end = rig.rel(rig.now())
            val since = lastPlayback?.let { start - it }
            rig.timeline.add("preInjectFalseOnset", "startT" to start, "endT" to end, "sinceLastPlaybackMs" to since, "settled" to settled)
            out.put(
                JSONObject().put("turn", index).put("startT", start).put("endT", end)
                    .put("sinceLastPlaybackMs", since ?: JSONObject.NULL).put("settled", settled),
            )
            Thread.sleep(SETTLE_MS)
        }
    }

    private fun shortAnswers(): List<VoiceS5Rig.Utterance> {
        val root = context.getExternalFilesDir("s5")!!
        val manifest = JSONObject(File(root, "manifest.json").readText())
        val items = requireNotNull(manifest.optJSONArray("shortAnswers")) { "corpus manifest has no shortAnswers" }
        return (0 until items.length()).map { items.getJSONObject(it) }.map {
            VoiceS5Rig.Utterance(
                id = it.getString("id"),
                lang = it.getString("lang"),
                text = it.getString("text"),
                reply = it.getString("reply"),
                samples = VoiceLive.readWav(File(root, it.getString("file"))),
            )
        }
    }

    @Test
    fun noiseIdleFan() = noiseIdle("fan")

    @Test
    fun noiseIdleTv() = noiseIdle("tv")

    private fun noiseIdle(id: String) {
        val root = context.getExternalFilesDir("s5")!!
        val manifest = JSONObject(File(root, "manifest.json").readText())
        val items = manifest.getJSONArray("noise")
        val item = (0 until items.length()).map { items.getJSONObject(it) }.firstOrNull { it.getString("id") == id }
        requireNotNull(item) { "corpus noise has no $id" }
        val samples = VoiceLive.readWav(File(root, item.getString("file")))
        val durationMs = item.getLong("durationSec") * 1_000L
        val rig = VoiceS5Rig(context)
        var mixed = 0L
        try {
            rig.start(NOISE_LANGUAGE)
            rig.setNoise(id, samples)
            Thread.sleep(durationMs)
            mixed = rig.noiseMixedSamples()
            rig.setNoise(null, null)
        } finally {
            rig.close()
        }

        val events = rig.timeline.events
        fun prompts(which: String) = events.count { it.optString("type") == "prompt" && it.optString("which") == which }
        val sends = rig.timeline.sends.toList()
        val sendCount = sends.count { it.kind == "send" }
        val amendCount = sends.count { it.kind == "amend" }
        val session = events.firstOrNull { it.optString("type") == "session" }
        val sampleRate = manifest.optInt("sampleRate", 16_000)
        val summary = "conversation-noise id=$id durationSec=${durationMs / 1_000} mixedSec=${mixed / sampleRate} " +
            "send=$sendCount amend=$amendCount sayAgain=${prompts("SayAgain")} checkLanguage=${prompts("CheckLanguage")} " +
            "didNotCatch=${prompts("DidNotCatch")} echoHint=${prompts("EchoHint")} " +
            "nudgeOrb=${events.count { it.optString("type") == "nudgeOrb" }} replies=${rig.timeline.spans.count { it.kind == "reply" }} " +
            "route=${session?.optString("route")} aec=${session?.opt("aec")} " +
            "volume=${session?.opt("voiceCallVolume")}/${session?.opt("voiceCallMax")} " +
            "device=${Build.MANUFACTURER} ${Build.MODEL} sdk=${Build.VERSION.SDK_INT}"
        val result = JSONObject()
            .put("summary", summary)
            .put("sends", JSONArray().apply { sends.forEach { put(JSONObject().put("kind", it.kind).put("text", it.text).put("t", rig.rel(it.at))) } })
            .put("spans", JSONArray().apply {
                rig.timeline.spans.forEach {
                    put(JSONObject().put("kind", it.kind).put("text", it.text).put("startT", rig.rel(it.startAt)).put("endT", rig.rel(it.endAt.get())))
                }
            })
            .put("timeline", rig.timeline.toJson())
        val dir = context.getExternalFilesDir("s5-results")!!.apply { mkdirs() }
        val file = File(dir, "conversation-noise.json")
        // fan / tv run as two separate instrument runs; same file, merged by id.
        val out = runCatching { JSONObject(file.readText()) }.getOrNull() ?: JSONObject()
        out.put(id, result)
        file.writeText(out.toString(2))
        VoiceS5Rig.log(summary)

        assertTrue("conversation was not routed to the speaker: $summary", session?.optString("route") == "SPEAKER")
        assertTrue("noise bed was not mixed for the whole run: $summary", mixed >= (durationMs - NOISE_SLACK_MS) * sampleRate / 1_000)
        assertEquals("noise false sends: $summary", 0, sendCount)
        assertEquals("noise false amends: $summary", 0, amendCount)
    }

    /** No injection within [QUIET_MS] after this round's last playback end; if playback starts again in that window (self-triggered), wait for it and recalc the window, at most [QUIET_ROUNDS] times. */
    private fun quietWindow(rig: VoiceS5Rig, index: Int) {
        repeat(QUIET_ROUNDS) {
            val lastEnd = rig.spansOf(index).maxOfOrNull { it.endAt.get() } ?: rig.now()
            val wait = lastEnd + QUIET_MS - rig.now()
            if (wait > 0) Thread.sleep(wait)
            if (!rig.speaking() && rig.status() in LISTENING_LIKE) {
                val after = rig.spansOf(index).maxOfOrNull { it.endAt.get() } ?: lastEnd
                if (after <= lastEnd) return
            } else {
                awaitListening(rig)
            }
        }
    }

    /** Wait for this round's reply playback to start, or for the not-heard / check-language prompt (within [REPLY_TIMEOUT_MS]); returns false on timeout. */
    private fun awaitAnswered(rig: VoiceS5Rig, index: Int): Boolean {
        val deadline = rig.now() + REPLY_TIMEOUT_MS
        while (rig.now() < deadline) {
            if (rig.spansOf(index).isNotEmpty() || turnPrompts(rig, index, "SayAgain") + turnPrompts(rig, index, "CheckLanguage") > 0) return true
            Thread.sleep(REPLY_POLL_MS)
        }
        return false
    }

    /** Wait until no segment is playing and the state word is listening-type (within [PLAY_TIMEOUT_MS]); returns false on timeout. */
    private fun awaitListening(rig: VoiceS5Rig): Boolean {
        val deadline = rig.now() + PLAY_TIMEOUT_MS
        while (rig.now() < deadline) {
            if (!rig.speaking() && rig.status() in LISTENING_LIKE) return true
            Thread.sleep(REPLY_POLL_MS)
        }
        return false
    }

    private fun turnPrompts(rig: VoiceS5Rig, index: Int, which: String): Int = rig.timeline.events.count {
        it.optString("type") == "prompt" && it.optString("which") == which && it.optInt("turn") == index
    }

    /** A send / amend that lands during any TTS playback or within [QUIET_MS] after it ends. */
    private fun selfTriggers(rig: VoiceS5Rig): List<VoiceS5Rig.Send> {
        val spans = rig.timeline.spans.toList()
        return rig.timeline.sends.filter { send ->
            spans.any { span ->
                val end = span.endAt.get().takeIf { it >= 0 } ?: Long.MAX_VALUE
                send.at >= span.startAt && send.at <= end + QUIET_MS
            }
        }
    }

    private fun corpus(): List<VoiceS5Rig.Utterance> {
        val root = context.getExternalFilesDir("s5")!!
        val manifest = JSONObject(File(root, "manifest.json").readText())
        val items = manifest.getJSONArray("conversation")
        return (0 until items.length()).map { items.getJSONObject(it) }
            .filter { !it.optBoolean("pause", false) }
            .map {
                VoiceS5Rig.Utterance(
                    id = it.getString("id"),
                    lang = it.getString("lang"),
                    text = it.getString("text"),
                    reply = it.getString("reply"),
                    samples = VoiceLive.readWav(File(root, it.getString("file"))),
                )
            }
    }

    private companion object {
        const val ROUNDS = 20
        const val QUIET_MS = 4_000L
        const val QUIET_ROUNDS = 3
        const val SETTLE_MS = 1_000L
        const val LISTEN_TIMEOUT_MS = 30_000L
        const val REPLY_TIMEOUT_MS = 30_000L
        const val PLAY_TIMEOUT_MS = 60_000L
        const val NOISE_LANGUAGE = "zh-CN"
        const val NOISE_SLACK_MS = 2_000L
        const val SHORT_TURN_BASE = 100
        const val SHORT_WINDOW_MS = 8_000L
        const val SHORT_INJECT_WITHIN_MS = 200L
        const val SHORT_MAX_DROPPED = 1
        const val REPLY_POLL_MS = 5L
        const val FALSE_ONSET_SETTLE_MS = 10_000L
        const val FALSE_ONSET_ROUNDS = 3
        /** Listening-type state word: after a not-heard / check-language prompt the phase stays listening; the state word stays on the prompt until the next utterance starts. */
        val LISTENING_LIKE = setOf(
            ConversationStatusKey.LISTENING,
            ConversationStatusKey.SAY_AGAIN,
            ConversationStatusKey.CHECK_LANGUAGE,
        )
        val LISTENING_LIKE_DISPLAY = setOf(
            ConversationDisplayState.LISTENING,
            ConversationDisplayState.SAY_AGAIN,
            ConversationDisplayState.CHECK_LANGUAGE,
        )
    }
}
