package ai.oriveo.community.core.voice.conversation

import java.text.Normalizer

/**
 * Voice conversation turn contract voice-conversation.v1 (shared/voice-contracts/voice-conversation.v1.json).
 * Pure functions: no IO, no clock; time only enters through the event atMs. Reference implementation scripts/lib/voice-conversation.mjs; operation order maps line by line to it.
 */
object VoiceConversationConstants {
    const val FRAME_MS = 20
    const val VAD_START_MS = 120
    const val VAD_END_SILENCE_MS = 600
    const val VAD_MIN_UTTERANCE_MS = 250
    const val VAD_MAX_UTTERANCE_MS = 60_000
    const val VAD_PREROLL_MS = 300
    const val VAD_START_OVER_FLOOR_DB = 12.0
    const val VAD_CONTINUE_OVER_FLOOR_DB = 6.0
    const val VAD_ABSOLUTE_MIN_DB = -55.0
    const val VAD_CONTINUE_ABS_MIN_DB = -60.0
    const val FLOOR_INIT_DB = -50.0
    const val FLOOR_ALPHA = 0.05
    const val FLOOR_MIN_DB = -75.0
    const val FLOOR_MAX_DB = -30.0
    // VAD model mode: when frames carry speech probability, onset / sustain uses probability plus an energy gate relative to the noise floor; the floor is the minimum of a 100 ms sliding mean over the last 3 s
    const val VAD_MODEL_START_PROB = 0.5
    const val VAD_MODEL_CONTINUE_PROB = 0.35
    const val VAD_MODEL_GATE_OVER_FLOOR_DB = 6.0
    const val VAD_MODEL_CONTINUE_OVER_FLOOR_DB = 3.0
    const val VAD_MODEL_BG_PERCENTILE = 70
    const val VAD_MODEL_START_OVER_BG_DB = 4.0
    const val VAD_MODEL_CONTINUE_OVER_BG_DB = 2.0
    /** Continuation reference: within FLOOR_WINDOW_MS after a sentence, when the pause segment floor is not higher than the previous sentence's bgAtStart plus this value, the onset gate and new sentence bgAtStart take min(bg, previous bgAtStart). */
    const val VAD_MODEL_FOLLOW_UP_FLOOR_OVER_BG_DB = 3.0
    const val VAD_MODEL_ONSET_BACKTRACK_MS = 1000
    const val VAD_MODEL_ONSET_MIN_RUN_FRAMES = 2
    const val FLOOR_WINDOW_MS = 3000
    const val FLOOR_SMOOTH_MS = 100
    const val FRAME_MIN_DB = -120.0
    const val FRAME_MAX_DB = 0.0
    const val BARGE_IN_GRACE_MS = 1000
    const val BARGE_IN_MIN_SPEECH_MS = 300
    const val POST_PLAYBACK_GUARD_MS = 800
    // Onset gate inside the echo window: measured echo ≤ 2 frames; 300 ms would swallow single-syllable short answers such as "dui" or "No"
    const val POST_PLAYBACK_GUARD_MIN_SPEECH_MS = 160
    const val ECHO_OVERLAP_RATIO = 0.6
    const val ECHO_WINDOW_MS = 3_000L
    const val ECHO_MIN_WEIGHT = 12
    const val ECHO_HAN_UNIT_WEIGHT = 3
    const val ECHO_OTHER_UNIT_WEIGHT = 4
    const val FALSE_BARGE_INS_PER_CONVERSATION = 2
    const val CONVERSATIONS_TO_REMEMBER = 2
    const val IDLE_TIMEOUT_MS = 120_000L
    const val THINKING_EARCON_MS = 1_500L

    /** Reply audio gate: reply speech plays no earlier than 1600 ms after the sentence's silence start; speech started before the gate joins the same utterance. */
    const val REPLY_AUDIO_GATE_MS = 1_600L
    const val PARTIAL_STALL_MS = 1_500L
    const val ENDPOINT_MAX_SILENCE_MS = 1_600L
    const val ENDPOINT_PARTIAL_SETTLE_MS = 500L
    val CONTINUATION_PUNCTUATION = listOf(",", "，", "\u3001", ";", "；")
    val CONTINUATION_WORDS = listOf(
        "\u7136\u540E", "\u4F46\u662F", "\u56E0\u4E3A", "\u6240\u4EE5", "\u800C\u4E14", "\u6216\u8005", "\u8FD8\u6709", "\u5C31\u662F", "\u90A3\u4E2A", "\u5982\u679C", "\u548C", "\u8DDF",
        "and", "but", "so", "because", "or", "then", "if", "the", "a", "an", "to", "of", "with", "um", "uh",
    )
    const val SAY_AGAIN_MIN_VOICED_MS = 600
    const val CHECK_LANGUAGE_MIN_VOICED_MS = 1000
    const val CHECK_LANGUAGE_AFTER_MISSES = 2
    const val LISTEN_TO_THINK_TAP_GUARD_MS = 600L
    const val STOP_TO_VOICE_GUARD_MS = 500L
    const val STT_RETRIES = 1

    const val PREROLL_FRAMES = VAD_PREROLL_MS / FRAME_MS
}

// ───────────── A. VAD ─────────────

enum class ConversationRoute(val rawValue: String) {
    SPEAKER("speaker"),
    HEADPHONES("headphones"),
    BLUETOOTH("bluetooth"),
    ;

    companion object {
        /** Unknown values map to the speaker. */
        fun from(raw: String?): ConversationRoute = entries.firstOrNull { it.rawValue == raw } ?: SPEAKER
    }
}

/** Reason a sentence ended; [FORCED] is a host-forced end (tap ball / stall), already in the forced_end_* fixtures. */
enum class VadEndReason(val rawValue: String) { SILENCE("silence"), MAX_LENGTH("maxLength"), FORCED("forced") }

sealed interface VadEvent {
    val frame: Long

    data class SpeechStart(override val frame: Long, val prerollFrame: Long) : VadEvent
    data class SpeechEnd(override val frame: Long, val voicedMs: Int, val reason: VadEndReason) : VadEvent
    data class Discarded(override val frame: Long) : VadEvent
}

/** Streaming VAD: the host feeds it frame by frame; [runVad] is its fold over a whole sequence. */
class VoiceConversationVad {
    private var floor = VoiceConversationConstants.FLOOR_INIT_DB
    /** Whether the first frame carries speech probability: if so the whole segment uses model mode, never mixed; null = no frame fed yet. */
    private var model: Boolean? = null
    private val modelFloor = ModelFloor()
    private var bg = VoiceConversationConstants.FLOOR_INIT_DB
    /** Background level of the frame where the onset was established; the sustain gate during speech uses it as reference. */
    private var bgAtStart = VoiceConversationConstants.FLOOR_INIT_DB
    /** Continuation reference: bgAtStart of the last retained sentence (speechEnd) and its closing frame; cleared by reset. */
    private var lastBgAtStart: Double? = null
    private var lastCloseFrame: Long? = null
    private var speaking = false
    private var startFrame = -1L
    private var run = 0
    private var runStart = -1L
    private var silence = 0
    private var voicedMs = 0
    /** Model mode: first frames of short interrupted bursts that happened while not speaking (ascending); on onset the pre-roll is traced back to the earliest segment within the window. */
    private val onsetRuns = ArrayDeque<Long>()
    /** Whether the current short burst's first frame is within the playback candidate window of the loudspeaker (most likely echo; not recorded). */
    private var runInCandidate = false

    /** Whether we are inside an established stretch of speech. */
    val isSpeaking: Boolean get() = speaking

    /** Current noise floor (dBFS, clamped to FLOOR_MIN_DB…FLOOR_MAX_DB): conversation level is mapped relative to it. */
    val floorDb: Double get() = floor

    /**
     * Feed frame [index]. [playbackStartFrame] is the frame where loudspeaker playback started (null = not playing); [playbackEndedFrame] is the frame where playback really ended
     * (null = none). Only when [route] is the loudspeaker does it enter the interrupt candidates and echo window. [prob] is that frame's speech probability (null = energy rule);
     * a first frame carrying prob means the whole segment is in model mode.
     */
    fun step(
        index: Long,
        rawDb: Double,
        route: ConversationRoute,
        playbackStartFrame: Long?,
        playbackEndedFrame: Long? = null,
        prob: Double? = null,
    ): VadEvent? {
        val k = VoiceConversationConstants
        val model = this.model ?: (prob != null).also { this.model = it }
        val p = prob ?: 0.0
        val pb = playbackStartFrame
        val pe = playbackEndedFrame
        val speaker = route == ConversationRoute.SPEAKER
        val db = clampFrameDb(rawDb)
        val inCandidate = speaker && pb != null && index >= pb && (pe == null || index < pe)
        if (inCandidate && index < pb!! + GRACE_FRAMES) {
            run = 0 // Grace frame: does not update the noise floor and does not count speech / silence, but voids the interrupt-unconfirmed speech run
            return null
        }
        if (model) {
            floor = modelFloor.floor() // Only look at frames before this one
            bg = modelFloor.bg()
            modelFloor.push(db)
        }
        if (!speaking) {
            // Continuation after a pause: bg raised by the previous sentence does not block the second half; if the pause segment is not quiet (e.g. TV on), proceed as before
            val lastBg = lastBgAtStart
            val lastClose = lastCloseFrame
            val followUp = model && lastBg != null && lastClose != null &&
                index - lastClose <= FOLLOW_UP_FRAMES && floor <= lastBg + k.VAD_MODEL_FOLLOW_UP_FLOOR_OVER_BG_DB
            val startBg = if (followUp) minOf(bg, lastBg!!) else bg
            val voiced = if (model) {
                p >= k.VAD_MODEL_START_PROB && db >= maxOf(
                    k.VAD_ABSOLUTE_MIN_DB,
                    floor + k.VAD_MODEL_GATE_OVER_FLOOR_DB,
                    startBg + k.VAD_MODEL_START_OVER_BG_DB,
                )
            } else {
                db >= floor + k.VAD_START_OVER_FLOOR_DB && db >= k.VAD_ABSOLUTE_MIN_DB
            }
            if (voiced) {
                if (run == 0) {
                    runStart = index
                    runInCandidate = inCandidate
                }
                run++
                val inGuard = speaker && pe != null && runStart >= pe && runStart < pe + GUARD_FRAMES
                val need = when {
                    inCandidate -> k.BARGE_IN_MIN_SPEECH_MS
                    inGuard -> k.POST_PLAYBACK_GUARD_MIN_SPEECH_MS
                    else -> k.VAD_START_MS
                } / k.FRAME_MS
                if (run >= need) {
                    speaking = true
                    startFrame = runStart
                    bgAtStart = startBg // Onset gate bg of the frame where onset was established (for continuation, min(bg, previous bgAtStart))
                    voicedMs = run * k.FRAME_MS
                    silence = 0
                    run = 0
                    val lowest = if (pe != null && runStart >= pe) pe else 0L
                    val early = onsetRuns.firstOrNull { index - it <= BACKTRACK_FRAMES }
                    val onset = if (early != null) minOf(runStart, early) else runStart
                    onsetRuns.clear()
                    // need ≤ 15 frames, far below MAX_FRAMES, so this onset frame cannot also hit the length cap; therefore only speechStart is emitted
                    return VadEvent.SpeechStart(runStart, maxOf(lowest, onset - k.PREROLL_FRAMES))
                }
            } else {
                if (model && run >= k.VAD_MODEL_ONSET_MIN_RUN_FRAMES && !runInCandidate) {
                    onsetRuns.addLast(runStart)
                    // Keep only the window; long-term noise floor does not accumulate
                    while (index - onsetRuns.first() > BACKTRACK_FRAMES) onsetRuns.removeFirst()
                }
                run = 0
                if (!model) floor = updateFloor(floor, db)
            }
            return null
        }
        val held = if (model) {
            p >= k.VAD_MODEL_CONTINUE_PROB &&
                modelFloor.smoothed() >= maxOf(
                    floor + k.VAD_MODEL_CONTINUE_OVER_FLOOR_DB,
                    bgAtStart + k.VAD_MODEL_CONTINUE_OVER_BG_DB,
                )
        } else {
            db >= maxOf(floor + k.VAD_CONTINUE_OVER_FLOOR_DB, k.VAD_CONTINUE_ABS_MIN_DB)
        }
        if (held) {
            voicedMs += k.FRAME_MS
            silence = 0
        } else {
            silence++
            if (!model) floor = updateFloor(floor, db)
            if (silence >= END_FRAMES) return close(index, VadEndReason.SILENCE)
        }
        if (index - startFrame + 1 >= MAX_FRAMES) return close(index, VadEndReason.MAX_LENGTH)
        return null
    }

    private fun close(index: Long, reason: VadEndReason): VadEvent {
        val event = if (voicedMs >= VoiceConversationConstants.VAD_MIN_UTTERANCE_MS) {
            lastBgAtStart = bgAtStart
            lastCloseFrame = index
            VadEvent.SpeechEnd(index, voicedMs, reason)
        } else {
            VadEvent.Discarded(index)
        }
        speaking = false
        silence = 0
        voicedMs = 0
        return event
    }

    /**
     * Host force-ends the current speech (tap ball / stall), closing the sentence before processing frame [index]: same shortest-sentence rule as silence closing;
     * speech shorter than VAD_MIN_UTTERANCE_MS emits [VadEvent.Discarded]; speech runs are always cleared; null when not speaking.
     */
    fun forceEnd(index: Long): VadEvent? {
        run = 0
        onsetRuns.clear()
        if (!speaking) return null
        return close(index, VadEndReason.FORCED)
    }

    /** resetVad: the sentence in progress and the unconfirmed speech run are discarded without emitting events; the noise floor is kept. */
    fun reset() {
        speaking = false
        run = 0
        onsetRuns.clear()
        silence = 0
        voicedMs = 0
        // Keep continuation reference: playback-start reset only drops the sentence in progress and the speech run, otherwise the bg raised by the user's last sentence within the last 3 s would block interjection
    }

    /**
     * Model-mode noise floor: minimum of the FLOOR_SMOOTH_MS sliding mean within the last FLOOR_WINDOW_MS; FLOOR_INIT_DB when there are no frames at all. Speech frames are included too.
     * Background level bg = the element at index floor((n−1)·VAD_MODEL_BG_PERCENTILE/100) of the same buffer sorted ascending; FLOOR_INIT_DB when empty;
     * smoothed = the smoothed value after the last push.
     */
    private class ModelFloor {
        private val dbs = ArrayDeque<Double>()
        private val smooth = ArrayDeque<Double>()

        fun floor(): Double = smooth.minOrNull() ?: VoiceConversationConstants.FLOOR_INIT_DB

        fun bg(): Double {
            if (smooth.isEmpty()) return VoiceConversationConstants.FLOOR_INIT_DB
            val sorted = smooth.sorted()
            return sorted[(sorted.size - 1) * VoiceConversationConstants.VAD_MODEL_BG_PERCENTILE / 100]
        }

        fun smoothed(): Double = smooth.last()

        fun push(db: Double) {
            dbs.addLast(db)
            if (dbs.size > SMOOTH_FRAMES) dbs.removeFirst()
            var sum = 0.0
            for (v in dbs) sum += v
            smooth.addLast(sum / dbs.size)
            if (smooth.size > WINDOW_FRAMES) smooth.removeFirst()
        }
    }

    private companion object {
        val SMOOTH_FRAMES = VoiceConversationConstants.FLOOR_SMOOTH_MS / VoiceConversationConstants.FRAME_MS
        val WINDOW_FRAMES = VoiceConversationConstants.FLOOR_WINDOW_MS / VoiceConversationConstants.FRAME_MS
        val GRACE_FRAMES = VoiceConversationConstants.BARGE_IN_GRACE_MS / VoiceConversationConstants.FRAME_MS
        val BACKTRACK_FRAMES = VoiceConversationConstants.VAD_MODEL_ONSET_BACKTRACK_MS / VoiceConversationConstants.FRAME_MS
        val FOLLOW_UP_FRAMES = VoiceConversationConstants.FLOOR_WINDOW_MS / VoiceConversationConstants.FRAME_MS
        val GUARD_FRAMES = VoiceConversationConstants.POST_PLAYBACK_GUARD_MS / VoiceConversationConstants.FRAME_MS
        val END_FRAMES = VoiceConversationConstants.VAD_END_SILENCE_MS / VoiceConversationConstants.FRAME_MS
        val MAX_FRAMES = VoiceConversationConstants.VAD_MAX_UTTERANCE_MS / VoiceConversationConstants.FRAME_MS

        fun clampFrameDb(db: Double): Double {
            if (!(db >= VoiceConversationConstants.FRAME_MIN_DB)) return VoiceConversationConstants.FRAME_MIN_DB
            return if (db > VoiceConversationConstants.FRAME_MAX_DB) VoiceConversationConstants.FRAME_MAX_DB else db
        }

        fun updateFloor(floor: Double, db: Double): Double {
            val f = floor + VoiceConversationConstants.FLOOR_ALPHA * (db - floor)
            return when {
                f < VoiceConversationConstants.FLOOR_MIN_DB -> VoiceConversationConstants.FLOOR_MIN_DB
                f > VoiceConversationConstants.FLOOR_MAX_DB -> VoiceConversationConstants.FLOOR_MAX_DB
                else -> f
            }
        }
    }
}

/**
 * [resetFrame]: the host ran resetVad on this frame (the sentence in progress is discarded before processing this frame; the noise floor is kept).
 * [probs]: per-frame speech probability (same length as [frames]; null = energy rule).
 */
fun runVad(
    frames: List<Double>,
    route: ConversationRoute = ConversationRoute.SPEAKER,
    playbackStartFrame: Long? = null,
    playbackEndedFrame: Long? = null,
    resetFrame: Long? = null,
    probs: List<Double?>? = null,
    forceEndFrame: Long? = null,
): List<VadEvent> {
    val vad = VoiceConversationVad()
    val events = mutableListOf<VadEvent>()
    frames.forEachIndexed { index, db ->
        val i = index.toLong()
        if (i == resetFrame) vad.reset()
        if (i == forceEndFrame) vad.forceEnd(i)?.let(events::add)
        vad.step(i, db, route, playbackStartFrame, playbackEndedFrame, probs?.get(index))?.let(events::add)
    }
    return events
}

// ───────────── B. Self-echo detection ─────────────

data class EchoVerdict(val echo: Boolean, val overlap: Double?)

/** Ranges where each code point is its own unit (Han / kana / Hangul / Thai), listed explicitly rather than relying on the platform Unicode Script table. */
private val SINGLE_UNIT_RANGES = arrayOf(
    0x0e00..0x0e7f, 0x1100..0x11ff, 0x2e80..0x2fdf, 0x3005..0x3005, 0x3007..0x3007, 0x3021..0x3029, 0x3038..0x303b,
    0x3040..0x30ff, 0x3130..0x318f, 0x31f0..0x31ff, 0x3400..0x4dbf, 0x4e00..0x9fff, 0xa960..0xa97f,
    0xac00..0xd7ff, 0xf900..0xfaff, 0xff66..0xff9f, 0xffa0..0xffdc, 0x1b000..0x1b16f, 0x20000..0x3ffff,
)

/** Full Unicode White_Space set, listed explicitly rather than using platform trim. */
private val WHITE_SPACE = setOf(
    0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
    0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
)

private fun isSeparator(cp: Int): Boolean {
    if (cp in 0xFE00..0xFE0F || cp in 0xE0100..0xE01EF) return true
    return when (Character.getType(cp).toByte()) {
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
        Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
        Character.OTHER_PUNCTUATION,
        Character.MATH_SYMBOL, Character.CURRENCY_SYMBOL, Character.MODIFIER_SYMBOL, Character.OTHER_SYMBOL,
        Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR,
        Character.CONTROL, Character.FORMAT,
        -> true
        else -> false
    }
}

private fun isSingleUnit(cp: Int): Boolean = SINGLE_UNIT_RANGES.any { cp in it }

private fun String.cps(): IntArray = codePoints().toArray()

private fun cpString(cp: Int): String = String(Character.toChars(cp))

private fun trimEndWhiteSpace(str: String): String {
    val cps = str.cps()
    var n = cps.size
    while (n > 0 && cps[n - 1] in WHITE_SPACE) n--
    return String(cps, 0, n)
}

private fun trimStartWhiteSpace(str: String): String {
    val cps = str.cps()
    var i = 0
    while (i < cps.size && cps[i] in WHITE_SPACE) i++
    return String(cps, i, cps.size - i)
}

private val ZH_DIGITS = mapOf(
    '\u96F6'.code to 0, '\u3007'.code to 0, '\u4E00'.code to 1, '\u4E8C'.code to 2, '\u4E24'.code to 2, '\u4E09'.code to 3,
    '\u56DB'.code to 4, '\u4E94'.code to 5, '\u516D'.code to 6, '\u4E03'.code to 7, '\u516B'.code to 8, '\u4E5D'.code to 9,
)
private val ZH_SMALL = mapOf('\u5341'.code to 10.0, '\u767E'.code to 100.0, '\u5343'.code to 1000.0)
private val ZH_BIG = mapOf('\u4E07'.code to 10000.0, '\u4EBF'.code to 100000000.0)

private fun isZhNumeral(cp: Int): Boolean = cp in ZH_DIGITS || cp in ZH_SMALL || cp in ZH_BIG

/** 2^53 - 1: same bound as the reference implementation's Number.MAX_SAFE_INTEGER; arithmetic uses double so it matches step by step. */
private const val MAX_SAFE_INTEGER = 9007199254740991.0

/** A run of consecutive Chinese numeral characters → Arabic numeral string; runs with no numeral characters (zero to nine) are returned as is. */
fun zhNumberRun(run: String): String {
    val chars = run.cps()
    if (chars.none { it in ZH_DIGITS }) return run
    if (chars.none { it in ZH_SMALL || it in ZH_BIG }) return chars.joinToString("") { ZH_DIGITS.getValue(it).toString() }
    var total = 0.0
    var section = 0.0
    var num = 0.0
    var hasNum = false
    fun big(v: Double) = v > MAX_SAFE_INTEGER
    for (c in chars) {
        val digit = ZH_DIGITS[c]
        val small = ZH_SMALL[c]
        if (digit != null) {
            num = digit.toDouble()
            hasNum = true
        } else if (small != null) {
            section += (if (hasNum) num else 1.0) * small
            num = 0.0
            hasNum = false
        } else if (c == '\u4E07'.code) {
            total += (section + num) * ZH_BIG.getValue(c)
            section = 0.0
            num = 0.0
            hasNum = false
        } else {
            total = (total + section + num) * ZH_BIG.getValue(c)
            section = 0.0
            num = 0.0
            hasNum = false
        }
        if (big(total) || big(section)) return run
    }
    val value = total + section + num
    return if (big(value)) run else value.toLong().toString()
}

/** Echo comparison units: NFKC → lowercase, walked by code point; Chinese numeral runs are first converted to Arabic digits, separators split and discard, digits and Han / kana / Hangul each form one unit. */
fun echoUnits(text: String): List<String> {
    val units = mutableListOf<String>()
    val buf = StringBuilder()
    fun flush() {
        if (buf.isNotEmpty()) units += buf.toString()
        buf.setLength(0)
    }
    val chars = Normalizer.normalize(text, Normalizer.Form.NFKC).lowercase().cps()
    var i = 0
    while (i < chars.size) {
        val cp = chars[i]
        if (isZhNumeral(cp)) {
            var j = i
            while (j < chars.size && isZhNumeral(chars[j])) j++
            flush()
            zhNumberRun(String(chars, i, j - i)).cps().forEach { units += cpString(it) }
            i = j
            continue
        }
        when {
            isSeparator(cp) -> flush()
            cp in '0'.code..'9'.code || isSingleUnit(cp) -> {
                flush()
                units += cpString(cp)
            }
            else -> buf.appendCodePoint(cp)
        }
        i++
    }
    flush()
    return units
}

private fun isHanUnit(u: String): Boolean = isSingleUnit(u.codePointAt(0))

/** [pool]: AI sentences and prompts already played this turn (in playback order); when not compared (empty or too short) overlap is null. */
fun isEcho(transcript: String, pool: List<String>): EchoVerdict {
    val k = VoiceConversationConstants
    val t = echoUnits(transcript)
    val weight = t.sumOf { if (isHanUnit(it)) k.ECHO_HAN_UNIT_WEIGHT else k.ECHO_OTHER_UNIT_WEIGHT }
    if (t.isEmpty() || weight < k.ECHO_MIN_WEIGHT) return EchoVerdict(echo = false, overlap = null)
    val p = pool.flatMap(::echoUnits)
    // Longest common contiguous units (rolling one-row DP)
    var best = 0
    var prev = IntArray(p.size + 1)
    for (i in 1..t.size) {
        val cur = IntArray(p.size + 1)
        for (j in 1..p.size) {
            if (t[i - 1] == p[j - 1]) {
                cur[j] = prev[j - 1] + 1
                if (cur[j] > best) best = cur[j]
            }
        }
        prev = cur
    }
    val ratio = best.toDouble() / t.size
    return EchoVerdict(ratio >= k.ECHO_OVERLAP_RATIO, Math.floor(ratio * 10000 + 0.5) / 10000)
}

/** Caption ends with a comma-like punctuation or a conjunction: sentence break is deferred to endpointMaxSilenceMs. */
fun endsWithContinuation(text: String): Boolean {
    val raw = trimEndWhiteSpace(text)
    if (raw.isEmpty()) return false
    val last = raw.cps().last()
    if (cpString(last) in VoiceConversationConstants.CONTINUATION_PUNCTUATION) return true
    if (isSeparator(last)) return false // Closing punctuation such as a full stop or question mark: the speaker is done
    val units = echoUnits(raw)
    return VoiceConversationConstants.CONTINUATION_WORDS.any { w ->
        val wu = echoUnits(w)
        wu.size <= units.size && wu.indices.all { k -> units[units.size - wu.size + k] == wu[k] }
    }
}

/** Interjection while thinking: the host attaches the new speech to the end of the previous user message (same bubble). */
fun joinAmend(previous: String, text: String): String {
    val a = trimEndWhiteSpace(previous)
    val b = trimStartWhiteSpace(text)
    if (b.isEmpty()) return a
    if (a.isEmpty()) return b
    val last = a.cps().last()
    val first = b.codePointAt(0)
    return if (isSingleUnit(last) || isSingleUnit(first)) a + b else "$a $b"
}

// ───────────── C. State machine ─────────────

enum class ConversationPhase { IDLE, LISTENING, THINKING, SPEAKING, ENDED }

enum class ReplyStatus { NONE, STREAMING, COMPLETED }

/** Hint after dictation fails. */
enum class ConversationNotice { SAY_AGAIN, CHECK_LANGUAGE }

data class ConversationState(
    val phase: ConversationPhase = ConversationPhase.IDLE,
    val route: ConversationRoute = ConversationRoute.SPEAKER,
    val deviceRemembersNoSpeakerBargeIn: Boolean = false,
    val speakerBargeIn: Boolean = true,
    val userSpeaking: Boolean = false,
    val utteranceStartMs: Long? = null,
    val partialText: String = "",
    val partialChangedAtMs: Long? = null,
    val stallFired: Boolean = false,
    val holdUtteranceId: String? = null,
    val holdVoicedMs: Int? = null,
    val holdSilenceStartMs: Long? = null,
    val holdSinceMs: Long? = null,
    val continuedUtteranceId: String? = null,
    val continuedVoicedMs: Int? = null,
    /** This sentence was ended by a host forceEndUtterance (: no reply audio gate is set). */
    val forcedByTap: Boolean = false,
    val muted: Boolean = false,
    val awaitingApproval: Boolean = false,
    val error: Boolean = false,
    val interrupted: Boolean = false,
    val screenReaderSpeaking: Boolean = false,
    val messagePlaying: Boolean = false,
    val promptPlaying: Boolean = false,
    val falseBargeIns: Int = 0,
    val playbackStopped: Boolean = false,
    val playbackEndedAtMs: Long? = null,
    /** Echo pool: AI sentences and prompts already started playing this turn. */
    val spoken: List<String> = emptyList(),
    val sttAttempts: Int = 0,
    val awaitedUtteranceId: String? = null,
    /** VAD events arriving while thinking and waiting for transcription; replayed in order after the transcript settles. */
    val pendingVad: List<ConversationEvent> = emptyList(),
    val utteranceVoicedMs: Int? = null,
    val utteranceCompared: Boolean = false,
    val heardPending: Boolean = false,
    val amend: Boolean = false,
    val bargeIn: Boolean = false,
    val reply: ReplyStatus = ReplyStatus.NONE,
    val drained: Boolean = false,
    val thinkingSinceMs: Long? = null,
    val thinkingEarconPlayed: Boolean = false,
    /** Reply audio gate time; null when ended by a tap on the ball. */
    val gateAt: Long? = null,
    /** Reply sentences arriving before the gate, in arrival order. */
    val gateQueue: List<String> = emptyList(),
    /** replyCompleted that arrived before the gate. */
    val gateCompleted: Boolean = false,
    val lastActivityMs: Long? = null,
    val emptyStreak: Int = 0,
    val languageHintShown: Boolean = false,
    val notice: ConversationNotice? = null,
)

fun initialConversationState(): ConversationState = ConversationState()

enum class EndReason(val rawValue: String) { USER("user"), SYSTEM("system"), IDLE("idle"), ERROR("error") }

enum class VoicePromptKind(val rawValue: String) {
    DID_NOT_CATCH("didNotCatch"),
    APPROVAL_NEEDED("approvalNeeded"),
    SAY_AGAIN("sayAgain"),
    CHECK_LANGUAGE("checkLanguage"),
    ECHO_HINT("echoHint"),
}

enum class EarconKind(val rawValue: String) { START("start"), HEARD("heard"), THINKING("thinking"), END("end") }

enum class HapticKind(val rawValue: String) { LIGHT("light") }

enum class ResumeFrom(val rawValue: String) { PAUSE_POINT("pausePoint"), SENTENCE_START("sentenceStart") }

sealed interface ConversationEvent {
    val atMs: Long

    data class Start(
        override val atMs: Long,
        val route: ConversationRoute,
        val deviceRemembersNoSpeakerBargeIn: Boolean,
    ) : ConversationEvent
    data class VadSpeechStart(override val atMs: Long) : ConversationEvent

    /** [voicedMs]: speech duration of this segment (default 0). */
    data class VadSpeechEnd(override val atMs: Long, val utteranceId: String, val voicedMs: Int = 0) : ConversationEvent
    data class VadDiscarded(override val atMs: Long) : ConversationEvent
    data class BargeInDetected(override val atMs: Long) : ConversationEvent
    data class SttPartial(override val atMs: Long, val text: String) : ConversationEvent
    data class SttResult(override val atMs: Long, val utteranceId: String, val text: String) : ConversationEvent
    data class SttFailed(override val atMs: Long, val utteranceId: String) : ConversationEvent
    data class ReplySentence(override val atMs: Long, val text: String) : ConversationEvent
    data class SentenceStarted(override val atMs: Long, val text: String) : ConversationEvent
    data class ReplyCompleted(override val atMs: Long) : ConversationEvent
    data class PlaybackDrained(override val atMs: Long) : ConversationEvent
    data class ReplyFailed(override val atMs: Long, val code: String) : ConversationEvent
    data class ApprovalPending(override val atMs: Long) : ConversationEvent
    data class ApprovalResolved(override val atMs: Long) : ConversationEvent
    data class TapOrb(override val atMs: Long) : ConversationEvent
    data class ToggleMute(override val atMs: Long) : ConversationEvent
    /** One-shot timer at [nextDeadlineMs]; not activity, so it doesn't refresh lastActivityMs. */
    data class Deadline(override val atMs: Long) : ConversationEvent
    data class InterruptionBegan(override val atMs: Long) : ConversationEvent
    data class InterruptionEnded(override val atMs: Long) : ConversationEvent
    data class ScreenReaderSpeaking(override val atMs: Long, val speaking: Boolean) : ConversationEvent
    data class RouteChanged(override val atMs: Long, val route: ConversationRoute) : ConversationEvent
    data class PlayMessage(override val atMs: Long, val messageId: String) : ConversationEvent
    data class MessagePlaybackEnded(override val atMs: Long) : ConversationEvent

    /** Host: a speakPrompt started playing ([text] is the text actually spoken; it enters the echo pool). */
    data class PromptStarted(override val atMs: Long, val text: String) : ConversationEvent
    data class PromptEnded(override val atMs: Long) : ConversationEvent

    /** [reason] only takes user / system (anything else is treated as system). */
    data class End(override val atMs: Long, val reason: EndReason) : ConversationEvent
}

sealed interface ConversationEffect {
    data object StartCapture : ConversationEffect
    data class Transcribe(val utteranceId: String) : ConversationEffect
    data class SendMessage(val text: String) : ConversationEffect

    /** Replace the previous user message with joinAmend(it, [text]) and regenerate; empty string = regenerate as is. */
    data class AmendLastMessage(val text: String) : ConversationEffect
    data object CancelGeneration : ConversationEffect
    data class EnqueueSpeech(val text: String) : ConversationEffect
    data object PausePlayback : ConversationEffect
    data class ResumePlayback(val from: ResumeFrom) : ConversationEffect
    data object StopPlayback : ConversationEffect
    data class SpeakPrompt(val prompt: VoicePromptKind) : ConversationEffect
    data class Earcon(val kind: EarconKind) : ConversationEffect
    data class Haptic(val kind: HapticKind) : ConversationEffect
    data object NudgeOrb : ConversationEffect
    data class EndConversation(val reason: EndReason, val code: String? = null) : ConversationEffect
    data object RememberFalseBargeInConversation : ConversationEffect
    data object ForceEndUtterance : ConversationEffect

    /** The just-resumed speech belongs to the sentence [utteranceId]: the host keeps the recognition session / audio, and the next vadSpeechEnd reuses the same id. */
    data class ContinueUtterance(val utteranceId: String) : ConversationEffect

    /** Reset VAD (noise floor kept); when [playbackEndedAtMs] is non-null the echo window opens from that moment. */
    data class ResetVad(val playbackEndedAtMs: Long?) : ConversationEffect
    data class SetCaptureMuted(val muted: Boolean) : ConversationEffect
    data object PauseCapture : ConversationEffect
    data object ResumeCapture : ConversationEffect
    data class PlayMessage(val messageId: String) : ConversationEffect
    data object TranscribeToDraft : ConversationEffect
}

data class Reduction(val state: ConversationState, val effects: List<ConversationEffect>)

private typealias Fx = MutableList<ConversationEffect>

private val LIGHT_HAPTIC = ConversationEffect.Haptic(HapticKind.LIGHT)

private fun ConversationState.computeSpeakerBargeIn(): Boolean =
    route != ConversationRoute.SPEAKER ||
        !(deviceRemembersNoSpeakerBargeIn || falseBargeIns >= VoiceConversationConstants.FALSE_BARGE_INS_PER_CONVERSATION)

private fun ConversationState.holding(): Boolean = holdUtteranceId != null

private fun ConversationState.clearUtterance(): ConversationState = copy(
    userSpeaking = false,
    utteranceStartMs = null,
    partialText = "",
    partialChangedAtMs = null,
    stallFired = false,
    holdUtteranceId = null,
    holdVoicedMs = null,
    holdSilenceStartMs = null,
    holdSinceMs = null,
    continuedUtteranceId = null,
    continuedVoicedMs = null,
    forcedByTap = false,
)

private fun ConversationState.resetTurn(): ConversationState = clearUtterance().copy(
    playbackStopped = false,
    sttAttempts = 0,
    awaitedUtteranceId = null,
    pendingVad = emptyList(),
    utteranceVoicedMs = null,
    utteranceCompared = false,
    heardPending = false,
    amend = false,
    bargeIn = false,
    reply = ReplyStatus.NONE,
    drained = false,
    thinkingSinceMs = null,
    thinkingEarconPlayed = false,
    gateQueue = emptyList(),
    gateCompleted = false,
)

private fun ConversationState.guardOrigin(t: Long): Long? =
    playbackEndedAtMs?.takeIf { t - it < VoiceConversationConstants.POST_PLAYBACK_GUARD_MS }

private fun ConversationState.toListening(t: Long, fx: Fx): ConversationState {
    fx += ConversationEffect.ResetVad(guardOrigin(t))
    return resetTurn().copy(phase = ConversationPhase.LISTENING, lastActivityMs = t, gateAt = null)
}

private fun ConversationState.toThinking(t: Long): ConversationState =
    resetTurn().copy(phase = ConversationPhase.THINKING, thinkingSinceMs = t)

private fun ConversationState.maybeFinish(t: Long, fx: Fx): ConversationState =
    if (phase == ConversationPhase.SPEAKING && reply == ReplyStatus.COMPLETED && (drained || playbackStopped) && !bargeIn) {
        toListening(t, fx)
    } else {
        this
    }

private fun ConversationState.stopPlayback(t: Long, fx: Fx): ConversationState {
    fx += ConversationEffect.StopPlayback
    return copy(playbackStopped = true, playbackEndedAtMs = t)
}

/** Cases where this sentence can become a turn (send after transcription / interrupt / supplement). */
private fun ConversationState.canFinalize(): Boolean =
    phase == ConversationPhase.LISTENING || (phase == ConversationPhase.THINKING && amend) ||
        (phase == ConversationPhase.SPEAKING && bargeIn)

/** : only compare sentences played through the loudspeaker that started while playing or within echoWindowMs after playback ended. */
private fun ConversationState.inEchoWindow(): Boolean {
    if (route != ConversationRoute.SPEAKER) return false
    if (phase == ConversationPhase.SPEAKING) return true
    val start = utteranceStartMs ?: return false
    val ended = playbackEndedAtMs ?: return false
    return start - ended <= VoiceConversationConstants.ECHO_WINDOW_MS
}

private fun ConversationState.holdUntil(): Long {
    val cap = holdSilenceStartMs!! + VoiceConversationConstants.ENDPOINT_MAX_SILENCE_MS
    if (endsWithContinuation(partialText)) return cap
    return minOf(cap, maxOf(holdSinceMs!!, (partialChangedAtMs ?: 0L) + VoiceConversationConstants.ENDPOINT_PARTIAL_SETTLE_MS))
}

private fun ConversationState.regenerate(t: Long, fx: Fx, text: String): ConversationState {
    fx += ConversationEffect.AmendLastMessage(text)
    return toThinking(t).copy(reply = ReplyStatus.STREAMING, spoken = emptyList())
}

/** User voice interrupted by an external force (mute, incoming call, screen reader, playing a message, prompt): the sentence is discarded; an interjection discarded while thinking regenerates as is. */
private fun ConversationState.abandonUtterance(t: Long, fx: Fx): ConversationState {
    val wasAmending = amend && userSpeaking
    // Queued openings are discarded as well
    val s = clearUtterance().copy(pendingVad = emptyList())
    return when {
        wasAmending -> s.regenerate(t, fx, "")
        s.phase == ConversationPhase.SPEAKING && s.bargeIn && s.awaitedUtteranceId == null -> s.dropBargeIn(t, fx)
        else -> s
    }
}

/** Interrupt candidate discarded: resume playing from where it was interrupted (not restored during a call; the call end stops playback), then run the closing check. */
private fun ConversationState.dropBargeIn(t: Long, fx: Fx): ConversationState {
    val s = copy(bargeIn = false)
    if (!s.playbackStopped && !s.interrupted) fx += ConversationEffect.ResumePlayback(ResumeFrom.PAUSE_POINT)
    return s.maybeFinish(t, fx)
}

/** silenceStartMs: the sentence's silence start; a tap-ball end passes null and sets no gate. */
private fun ConversationState.finalize(
    utteranceId: String,
    voicedMs: Int?,
    t: Long,
    fx: Fx,
    silenceStartMs: Long?,
): ConversationState {
    val compared = inEchoWindow()
    val s = when (phase) {
        ConversationPhase.LISTENING -> toThinking(t)
        // Supplement judgement for that sentence: the thinking timer restarts from the moment of this judgement
        ConversationPhase.THINKING -> clearUtterance().copy(thinkingSinceMs = t)
        else -> clearUtterance()
    }
    if (!compared) {
        fx += ConversationEffect.Earcon(EarconKind.HEARD)
        fx += LIGHT_HAPTIC
    }
    fx += ConversationEffect.Transcribe(utteranceId)
    return s.copy(
        gateAt = silenceStartMs?.let { it + VoiceConversationConstants.REPLY_AUDIO_GATE_MS },
        awaitedUtteranceId = utteranceId,
        sttAttempts = 1,
        utteranceVoicedMs = voicedMs ?: 0,
        utteranceCompared = compared,
        heardPending = compared,
    )
}

private fun ConversationState.gateWaiting(t: Long): Boolean =
    phase == ConversationPhase.THINKING && gateAt != null && t < gateAt

/** Replies queued before the gate are re-emitted in arrival order and enter speaking; replyCompleted that arrived before the gate is sent afterward. */
private fun ConversationState.flushGate(t: Long, fx: Fx): ConversationState {
    if (phase != ConversationPhase.THINKING || gateQueue.isEmpty()) return this
    var s = copy(phase = ConversationPhase.SPEAKING)
    if (!s.playbackStopped) {
        s = s.copy(drained = false)
        for (text in gateQueue) fx += ConversationEffect.EnqueueSpeech(text)
    }
    s = s.copy(gateQueue = emptyList(), gateAt = null)
    if (s.gateCompleted) s = s.copy(gateCompleted = false, reply = ReplyStatus.COMPLETED).maybeFinish(t, fx)
    return s
}

private fun ConversationState.heard(fx: Fx): ConversationState {
    if (heardPending) {
        fx += ConversationEffect.Earcon(EarconKind.HEARD)
        fx += LIGHT_HAPTIC
    }
    return copy(heardPending = false)
}

private fun ConversationState.countEcho(fx: Fx): ConversationState {
    fx += ConversationEffect.NudgeOrb
    if (route != ConversationRoute.SPEAKER) return this
    var s = copy(falseBargeIns = falseBargeIns + 1)
    if (s.falseBargeIns == VoiceConversationConstants.FALSE_BARGE_INS_PER_CONVERSATION) {
        s = s.copy(speakerBargeIn = s.computeSpeakerBargeIn())
        fx += ConversationEffect.RememberFalseBargeInConversation
        fx += ConversationEffect.SpeakPrompt(VoicePromptKind.ECHO_HINT)
    }
    return s
}

private fun ConversationState.sent(): ConversationState = copy(emptyStreak = 0, notice = null, spoken = emptyList())

private fun ConversationState.miss(t: Long, fx: Fx): ConversationState {
    val k = VoiceConversationConstants
    val voiced = utteranceVoicedMs ?: 0
    var s = toListening(t, fx)
    if (voiced >= k.CHECK_LANGUAGE_MIN_VOICED_MS) s = s.copy(emptyStreak = s.emptyStreak + 1)
    if (voiced < k.SAY_AGAIN_MIN_VOICED_MS) return s
    s = if (s.emptyStreak >= k.CHECK_LANGUAGE_AFTER_MISSES && !s.languageHintShown) {
        s.copy(languageHintShown = true, notice = ConversationNotice.CHECK_LANGUAGE)
    } else {
        s.copy(notice = ConversationNotice.SAY_AGAIN)
    }
    fx += ConversationEffect.SpeakPrompt(
        if (s.notice == ConversationNotice.CHECK_LANGUAGE) VoicePromptKind.CHECK_LANGUAGE else VoicePromptKind.SAY_AGAIN,
    )
    fx += LIGHT_HAPTIC
    return s
}

private fun ConversationState.idleQuiet(): Boolean =
    !muted && !userSpeaking && !awaitingApproval && !interrupted && !screenReaderSpeaking && !messagePlaying

private fun ConversationState.thinkingEarconPending(): Boolean =
    !thinkingEarconPlayed && !awaitingApproval && !interrupted && !userSpeaking

private fun ConversationState.stallPending(): Boolean =
    userSpeaking && !holding() && canFinalize() && partialText != "" && !stallFired

/**
 * When the host should dispatch the next [ConversationEvent.Deadline]; null = no timer armed.
 * The host re-arms one one-shot timer after every reduce instead of polling.
 */
fun nextDeadlineMs(state: ConversationState): Long? = when {
    state.holding() ->
        if (state.holdSilenceStartMs == null || state.holdSinceMs == null) null else state.holdUntil()
    state.stallPending() -> state.partialChangedAtMs?.let { it + VoiceConversationConstants.PARTIAL_STALL_MS }
    state.phase == ConversationPhase.LISTENING && state.idleQuiet() ->
        state.lastActivityMs?.let { it + VoiceConversationConstants.IDLE_TIMEOUT_MS }
    state.phase == ConversationPhase.THINKING -> listOfNotNull(
        state.gateAt.takeIf { state.gateQueue.isNotEmpty() },
        state.thinkingSinceMs?.takeIf { state.thinkingEarconPending() }?.let { it + VoiceConversationConstants.THINKING_EARCON_MS },
    ).minOrNull()
    else -> null
}

private fun ConversationState.toggledMute(t: Long, fx: Fx): ConversationState {
    val s = copy(muted = !muted)
    fx += ConversationEffect.SetCaptureMuted(s.muted)
    return if (s.muted) s.abandonUtterance(t, fx) else s
}

/** Interjection while thinking: VAD is only accepted once the reply has been sent and it is not waiting for transcription; speech already underway at the moment of opening does not count. */
private fun ConversationState.thinkingAcceptsVad(): Boolean =
    awaitedUtteranceId == null && (reply == ReplyStatus.STREAMING || userSpeaking)

/** Opening while thinking and waiting for transcription is not lost: onset / close / discard are queued as-is and replayed after the transcript settles; a discard that immediately follows an onset cancels out. */
private fun ConversationState.queuesVad(event: ConversationEvent): Boolean =
    phase == ConversationPhase.THINKING && awaitedUtteranceId != null &&
        (event is ConversationEvent.VadSpeechStart || event is ConversationEvent.VadSpeechEnd ||
            event is ConversationEvent.VadDiscarded)

/** Turn state machine: does not change inputs; returns the new state and the effects to run in order. */
fun reduce(state: ConversationState, event: ConversationEvent): Reduction {
    val unchanged = Reduction(state, emptyList())
    if (state.phase == ConversationPhase.ENDED) return unchanged
    if (state.phase == ConversationPhase.IDLE && event !is ConversationEvent.Start) return unchanged
    val t = event.atMs
    var s = if (event is ConversationEvent.Deadline) state else state.copy(lastActivityMs = t)
    // Discarded events do not change other state but still record activity time (except deadline)
    val dropped = Reduction(s, emptyList())
    val fx = mutableListOf<ConversationEffect>()
    var replay: List<ConversationEvent>? = null
    // Position of the hint for a final transcription failure: after replay, do not play it if the user is already speaking
    var didNotCatchAt: Int? = null
    // Position of the empty-result sayAgain / checkLanguage hint: after replay, drop it if the user is speaking or waiting for the next sentence
    var missPromptAt: Int? = null

    val isVad = event is ConversationEvent.VadSpeechStart || event is ConversationEvent.VadSpeechEnd ||
        event is ConversationEvent.VadDiscarded || event is ConversationEvent.BargeInDetected
    if (isVad) {
        if (s.muted || s.interrupted || s.screenReaderSpeaking || s.messagePlaying || s.promptPlaying) return dropped
        if (s.queuesVad(event)) {
            val tail = s.pendingVad.lastOrNull()
            val queue = if (event is ConversationEvent.VadDiscarded && tail is ConversationEvent.VadSpeechStart) {
                s.pendingVad.dropLast(1)
            } else {
                s.pendingVad + event
            }
            return Reduction(s.copy(pendingVad = queue), emptyList())
        }
        if (s.phase == ConversationPhase.THINKING && !s.thinkingAcceptsVad()) return dropped
        // When switching to a route where interrupts are not allowed, a sentence already begun must still be able to close, otherwise userSpeaking never comes down
        if (s.phase == ConversationPhase.SPEAKING &&
            ((!s.speakerBargeIn && !s.userSpeaking) || s.awaitedUtteranceId != null)
        ) {
            return dropped
        }
    }

    when (event) {
        is ConversationEvent.Start -> {
            if (s.phase == ConversationPhase.IDLE) {
                s = s.copy(route = event.route, deviceRemembersNoSpeakerBargeIn = event.deviceRemembersNoSpeakerBargeIn)
                s = s.copy(speakerBargeIn = s.computeSpeakerBargeIn(), phase = ConversationPhase.LISTENING)
                fx += ConversationEffect.StartCapture
                fx += ConversationEffect.Earcon(EarconKind.START)
                fx += LIGHT_HAPTIC
            }
        }
        is ConversationEvent.VadSpeechStart -> when {
            s.holding() -> {
                val id = s.holdUtteranceId!!
                fx += ConversationEffect.ContinueUtterance(id)
                s = s.copy(
                    continuedUtteranceId = id,
                    continuedVoicedMs = s.holdVoicedMs ?: 0,
                    // Continuation restarts the subtitle stall timer; it must not be force-broken immediately
                    partialChangedAtMs = if (s.partialText != "") t else s.partialChangedAtMs,
                    holdUtteranceId = null,
                    holdVoicedMs = null,
                    holdSilenceStartMs = null,
                    holdSinceMs = null,
                    stallFired = false,
                    forcedByTap = false,
                )
            }
            s.userSpeaking -> Unit
            else -> {
                s = s.copy(userSpeaking = true, utteranceStartMs = t, notice = null)
                if (s.phase == ConversationPhase.THINKING) {
                    s = s.copy(
                        amend = true,
                        reply = ReplyStatus.NONE,
                        gateAt = null,
                        gateQueue = emptyList(),
                        gateCompleted = false,
                    )
                    fx += ConversationEffect.CancelGeneration
                }
            }
        }
        is ConversationEvent.VadSpeechEnd -> {
            if (!s.userSpeaking || s.holding()) return dropped
            if (!s.canFinalize()) {
                s = s.clearUtterance()
            } else {
                // Continuation sentence: speech is summed across segments
                s = s.copy(
                    holdUtteranceId = event.utteranceId,
                    holdVoicedMs = (s.continuedVoicedMs ?: 0) + event.voicedMs,
                    holdSilenceStartMs = t - VoiceConversationConstants.VAD_END_SILENCE_MS,
                    holdSinceMs = t,
                )
                if (s.partialText == "" || s.holdUntil() <= t) {
                    s = s.finalize(event.utteranceId, s.holdVoicedMs, t, fx, s.holdSilenceStartMs.takeUnless { s.forcedByTap })
                }
            }
        }
        is ConversationEvent.VadDiscarded -> {
            if (!s.userSpeaking || s.holding()) return dropped
            // Continuation segment was too short and dropped: the previous sentence remains valid and is committed as one sentence with its original id
            val continued = s.continuedUtteranceId
            s = if (continued != null && s.canFinalize()) {
                val silenceStart = if (s.forcedByTap) null else t - VoiceConversationConstants.VAD_END_SILENCE_MS
                s.finalize(continued, s.continuedVoicedMs, t, fx, silenceStart)
            } else {
                s.abandonUtterance(t, fx)
            }
        }
        is ConversationEvent.BargeInDetected -> {
            if (s.phase == ConversationPhase.SPEAKING && !s.bargeIn && s.userSpeaking && s.speakerBargeIn) {
                s = s.copy(bargeIn = true)
                if (!s.playbackStopped) fx += ConversationEffect.PausePlayback
            }
        }
        is ConversationEvent.SttPartial -> {
            if (!s.userSpeaking) return dropped
            if (event.text != s.partialText) {
                s = s.copy(partialText = event.text, partialChangedAtMs = t, stallFired = false)
            }
        }
        is ConversationEvent.SttResult -> {
            if (s.awaitedUtteranceId == null || event.utteranceId != s.awaitedUtteranceId) return dropped
            replay = s.pendingVad
            s = s.copy(awaitedUtteranceId = null, pendingVad = emptyList())
            val text = event.text
            val empty = echoUnits(text).isEmpty()
            val echo = !empty && s.utteranceCompared && isEcho(text, s.spoken).echo
            when {
                s.bargeIn -> if (empty || echo) {
                    s = s.copy(bargeIn = false, heardPending = false)
                    if (!s.playbackStopped) fx += ConversationEffect.ResumePlayback(ResumeFrom.SENTENCE_START)
                    s = s.countEcho(fx).maybeFinish(t, fx)
                } else {
                    s = s.heard(fx)
                    fx += ConversationEffect.CancelGeneration
                    fx += ConversationEffect.SendMessage(text)
                    s = s.toThinking(t).copy(reply = ReplyStatus.STREAMING).sent()
                }
                s.amend -> if (empty || echo) {
                    if (echo) fx += ConversationEffect.NudgeOrb
                    s = s.regenerate(t, fx, "")
                } else {
                    s = s.heard(fx).regenerate(t, fx, text).sent()
                }
                empty -> {
                    val before = fx.size
                    s = s.miss(t, fx)
                    if (fx.size - 2 >= before && fx[fx.size - 2] is ConversationEffect.SpeakPrompt) missPromptAt = fx.size - 2
                }
                echo -> s = s.countEcho(fx).toListening(t, fx)
                else -> {
                    s = s.heard(fx)
                    fx += ConversationEffect.SendMessage(text)
                    s = s.copy(reply = ReplyStatus.STREAMING).sent()
                }
            }
        }
        is ConversationEvent.SttFailed -> {
            if (s.awaitedUtteranceId == null || event.utteranceId != s.awaitedUtteranceId) return dropped
            replay = s.pendingVad
            s = s.copy(pendingVad = emptyList())
            when {
                s.sttAttempts <= VoiceConversationConstants.STT_RETRIES -> {
                    s = s.copy(sttAttempts = s.sttAttempts + 1)
                    fx += ConversationEffect.Transcribe(event.utteranceId)
                }
                s.amend -> s = s.regenerate(t, fx, "")
                else -> {
                    if (s.bargeIn) fx += ConversationEffect.CancelGeneration
                    didNotCatchAt = fx.size
                    s = s.toListening(t, fx)
                }
            }
        }
        is ConversationEvent.ReplySentence -> {
            if (s.reply != ReplyStatus.STREAMING ||
                (s.phase != ConversationPhase.THINKING && s.phase != ConversationPhase.SPEAKING)
            ) {
                return dropped
            }
            if (s.gateWaiting(t)) {
                s = s.copy(gateQueue = s.gateQueue + event.text)
            } else {
                s = s.flushGate(t, fx).copy(phase = ConversationPhase.SPEAKING)
                if (!s.playbackStopped) {
                    s = s.copy(drained = false)
                    fx += ConversationEffect.EnqueueSpeech(event.text)
                }
            }
        }
        is ConversationEvent.SentenceStarted -> {
            if (s.phase != ConversationPhase.SPEAKING) return dropped
            s = s.copy(spoken = s.spoken + event.text)
        }
        is ConversationEvent.ReplyCompleted -> {
            if (s.reply != ReplyStatus.STREAMING) return dropped
            if (s.gateQueue.isNotEmpty() && s.gateWaiting(t)) {
                s = s.copy(gateCompleted = true)
            } else {
                s = s.flushGate(t, fx).copy(reply = ReplyStatus.COMPLETED)
                s = if (s.phase == ConversationPhase.THINKING) s.toListening(t, fx) else s.maybeFinish(t, fx)
            }
        }
        is ConversationEvent.PlaybackDrained -> {
            if (s.phase != ConversationPhase.SPEAKING) return dropped
            s = s.copy(drained = true, playbackEndedAtMs = t).maybeFinish(t, fx)
        }
        is ConversationEvent.ReplyFailed -> {
            if (s.reply != ReplyStatus.STREAMING) return dropped
            s = s.copy(error = true, phase = ConversationPhase.ENDED)
            fx += ConversationEffect.EndConversation(EndReason.ERROR, event.code)
        }
        is ConversationEvent.ApprovalPending -> {
            if (!s.awaitingApproval) {
                s = s.copy(awaitingApproval = true)
                fx += ConversationEffect.SpeakPrompt(VoicePromptKind.APPROVAL_NEEDED)
            }
        }
        is ConversationEvent.ApprovalResolved -> s = s.copy(awaitingApproval = false)
        is ConversationEvent.TapOrb -> when {
            s.awaitingApproval -> Unit
            s.muted && s.phase == ConversationPhase.LISTENING -> s = s.toggledMute(t, fx)
            s.holding() -> s = s.finalize(s.holdUtteranceId!!, s.holdVoicedMs, t, fx, null)
            s.phase == ConversationPhase.LISTENING || (s.phase == ConversationPhase.THINKING && s.userSpeaking) ->
                if (s.userSpeaking) {
                    s = s.copy(forcedByTap = true)
                    fx += ConversationEffect.ForceEndUtterance
                }
            s.phase == ConversationPhase.THINKING -> {
                if (t - (s.thinkingSinceMs ?: 0L) >= VoiceConversationConstants.LISTEN_TO_THINK_TAP_GUARD_MS) {
                    fx += ConversationEffect.CancelGeneration
                    s = s.toListening(t, fx)
                }
            }
            s.phase == ConversationPhase.SPEAKING && !s.playbackStopped -> s = s.stopPlayback(t, fx).maybeFinish(t, fx)
        }
        is ConversationEvent.ToggleMute -> s = s.toggledMute(t, fx)
        is ConversationEvent.Deadline -> when {
            s.holding() -> if (t >= s.holdUntil()) {
                s = s.finalize(s.holdUtteranceId!!, s.holdVoicedMs, t, fx, s.holdSilenceStartMs.takeUnless { s.forcedByTap })
            }
            s.stallPending() -> {
                if (t >= (s.partialChangedAtMs ?: 0L) + VoiceConversationConstants.PARTIAL_STALL_MS) {
                    s = s.copy(stallFired = true)
                    fx += ConversationEffect.ForceEndUtterance
                }
            }
            s.phase == ConversationPhase.LISTENING -> {
                if (s.idleQuiet() && t - (s.lastActivityMs ?: 0L) >= VoiceConversationConstants.IDLE_TIMEOUT_MS) {
                    s = s.copy(phase = ConversationPhase.ENDED)
                    fx += ConversationEffect.Earcon(EarconKind.END)
                    fx += LIGHT_HAPTIC
                    fx += ConversationEffect.EndConversation(EndReason.IDLE)
                }
            }
            s.phase == ConversationPhase.THINKING -> {
                if (s.gateQueue.isNotEmpty() && t >= s.gateAt!!) {
                    s = s.flushGate(t, fx)
                } else if (s.thinkingEarconPending() &&
                    t - (s.thinkingSinceMs ?: 0L) >= VoiceConversationConstants.THINKING_EARCON_MS
                ) {
                    s = s.copy(thinkingEarconPlayed = true)
                    fx += ConversationEffect.Earcon(EarconKind.THINKING)
                }
            }
        }
        is ConversationEvent.InterruptionBegan -> {
            if (!s.interrupted) {
                s = s.copy(interrupted = true)
                if (s.phase == ConversationPhase.SPEAKING && !s.playbackStopped) fx += ConversationEffect.PausePlayback
                fx += ConversationEffect.PauseCapture
                s = s.abandonUtterance(t, fx)
            }
        }
        is ConversationEvent.InterruptionEnded -> {
            if (s.interrupted) {
                s = s.copy(interrupted = false)
                if (s.phase == ConversationPhase.SPEAKING && !s.playbackStopped) s = s.stopPlayback(t, fx)
                fx += ConversationEffect.ResumeCapture
                s = s.maybeFinish(t, fx)
            }
        }
        is ConversationEvent.ScreenReaderSpeaking -> {
            s = s.copy(screenReaderSpeaking = event.speaking)
            if (s.screenReaderSpeaking) s = s.abandonUtterance(t, fx)
        }
        is ConversationEvent.RouteChanged -> {
            val prev = s.route
            s = s.copy(route = event.route)
            s = s.copy(speakerBargeIn = s.computeSpeakerBargeIn())
            if (prev != ConversationRoute.SPEAKER && s.route == ConversationRoute.SPEAKER &&
                s.phase == ConversationPhase.SPEAKING && !s.playbackStopped
            ) {
                s = s.stopPlayback(t, fx).maybeFinish(t, fx)
            }
        }
        is ConversationEvent.PlayMessage -> {
            if (s.phase != ConversationPhase.LISTENING || s.messagePlaying || s.interrupted) return dropped
            s = s.copy(messagePlaying = true).clearUtterance()
            fx += ConversationEffect.PauseCapture
            fx += ConversationEffect.PlayMessage(event.messageId)
        }
        is ConversationEvent.MessagePlaybackEnded -> {
            if (s.messagePlaying) {
                s = s.copy(messagePlaying = false, playbackEndedAtMs = t)
                fx += ConversationEffect.ResumeCapture
                if (s.phase == ConversationPhase.LISTENING) fx += ConversationEffect.ResetVad(t)
            }
        }
        is ConversationEvent.PromptStarted -> {
            if (!s.promptPlaying) {
                s = s.copy(promptPlaying = true, spoken = s.spoken + event.text).abandonUtterance(t, fx)
            }
        }
        is ConversationEvent.PromptEnded -> {
            if (s.promptPlaying) {
                s = s.copy(promptPlaying = false, playbackEndedAtMs = t)
                if (s.phase == ConversationPhase.LISTENING) fx += ConversationEffect.ResetVad(t)
            }
        }
        is ConversationEvent.End -> {
            val reason = if (event.reason == EndReason.USER) EndReason.USER else EndReason.SYSTEM
            if (reason == EndReason.USER && s.userSpeaking) fx += ConversationEffect.TranscribeToDraft
            fx += ConversationEffect.Earcon(EarconKind.END)
            fx += LIGHT_HAPTIC
            fx += ConversationEffect.EndConversation(reason)
            s = s.copy(phase = ConversationPhase.ENDED, pendingVad = emptyList())
        }
    }
    var out = if (!replay.isNullOrEmpty()) replayVad(s, fx, replay, t) else Reduction(s, fx)
    val promptAt = missPromptAt
    if (promptAt != null && (out.state.userSpeaking || out.state.awaitedUtteranceId != null)) {
        // Host playing a prompt voids the next sentence being recorded / just closed; if it was not actually played it counts as not prompted, and a later miss in this session can still prompt
        val effects = out.effects.toMutableList()
        val dropped = effects[promptAt] as ConversationEffect.SpeakPrompt
        effects.subList(promptAt, promptAt + 2).clear()
        val state = out.state.copy(
            notice = null,
            languageHintShown = if (dropped.prompt == VoicePromptKind.CHECK_LANGUAGE) false else out.state.languageHintShown,
        )
        out = Reduction(state, effects)
    }
    val notCaughtAt = didNotCatchAt ?: return out
    if (out.state.userSpeaking) return out
    val effects = out.effects.toMutableList()
    effects.addAll(notCaughtAt, listOf(ConversationEffect.SpeakPrompt(VoicePromptKind.DID_NOT_CATCH), LIGHT_HAPTIC))
    return Reduction(out.state, effects)
}

/**
 * After the transcript settles, replay the queued VAD: if still waiting for transcription (retry), keep it as is; otherwise run reduce on the new state one by one, effects chained after.
 * Replayed events carry the original atMs; activity time does not roll back, and still records this event's moment.
 */
private fun replayVad(s: ConversationState, fx: List<ConversationEffect>, replay: List<ConversationEvent>, t: Long): Reduction {
    if (s.phase == ConversationPhase.THINKING && s.awaitedUtteranceId != null) {
        return Reduction(s.copy(pendingVad = replay), fx)
    }
    var state = s
    val effects = fx.toMutableList()
    for (e in replay) {
        val r = reduce(state, e)
        state = r.state
        effects += r.effects
    }
    return Reduction(state.copy(lastActivityMs = t), effects)
}

/** Display state, read-only for the UI; null for idle / ended (except on error). */
enum class ConversationDisplayState(val rawValue: String) {
    LISTENING("listening"),
    USER_SPEAKING("userSpeaking"),
    THINKING("thinking"),
    SPEAKING("speaking"),
    MUTED("muted"),
    AWAITING_APPROVAL("awaitingApproval"),
    SAY_AGAIN("sayAgain"),
    CHECK_LANGUAGE("checkLanguage"),
    ERROR("error"),
}

/** Status-line key: caption while the user is speaking with subtitles; "Speaking · tap to interrupt" when the loudspeaker must not be interrupted. */
enum class ConversationStatusKey(val rawValue: String) {
    LISTENING("listening"),
    CAPTION("caption"),
    THINKING("thinking"),
    SPEAKING("speaking"),
    SPEAKING_TAP_TO_INTERRUPT("speakingTapToInterrupt"),
    MUTED("muted"),
    AWAITING_APPROVAL("awaitingApproval"),
    SAY_AGAIN("sayAgain"),
    CHECK_LANGUAGE("checkLanguage"),
    ERROR("error"),
}

fun displayState(state: ConversationState): ConversationDisplayState? = when {
    state.error -> ConversationDisplayState.ERROR
    state.phase == ConversationPhase.IDLE || state.phase == ConversationPhase.ENDED -> null
    state.awaitingApproval -> ConversationDisplayState.AWAITING_APPROVAL
    state.muted && state.phase == ConversationPhase.LISTENING -> ConversationDisplayState.MUTED
    state.userSpeaking && state.canFinalize() -> ConversationDisplayState.USER_SPEAKING
    state.phase == ConversationPhase.LISTENING && state.notice == ConversationNotice.SAY_AGAIN ->
        ConversationDisplayState.SAY_AGAIN
    state.phase == ConversationPhase.LISTENING && state.notice == ConversationNotice.CHECK_LANGUAGE ->
        ConversationDisplayState.CHECK_LANGUAGE
    state.phase == ConversationPhase.LISTENING -> ConversationDisplayState.LISTENING
    state.phase == ConversationPhase.THINKING -> ConversationDisplayState.THINKING
    else -> ConversationDisplayState.SPEAKING
}

fun statusKey(state: ConversationState): ConversationStatusKey? = when (displayState(state)) {
    null -> null
    ConversationDisplayState.LISTENING -> ConversationStatusKey.LISTENING
    ConversationDisplayState.USER_SPEAKING ->
        if (state.partialText != "") ConversationStatusKey.CAPTION else ConversationStatusKey.LISTENING
    ConversationDisplayState.THINKING -> ConversationStatusKey.THINKING
    ConversationDisplayState.SPEAKING ->
        if (state.route == ConversationRoute.SPEAKER && !state.speakerBargeIn) {
            ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT
        } else {
            ConversationStatusKey.SPEAKING
        }
    ConversationDisplayState.MUTED -> ConversationStatusKey.MUTED
    ConversationDisplayState.AWAITING_APPROVAL -> ConversationStatusKey.AWAITING_APPROVAL
    ConversationDisplayState.SAY_AGAIN -> ConversationStatusKey.SAY_AGAIN
    ConversationDisplayState.CHECK_LANGUAGE -> ConversationStatusKey.CHECK_LANGUAGE
    ConversationDisplayState.ERROR -> ConversationStatusKey.ERROR
}

/** Realtime subtitle at the status-line position: non-empty only when statusKey is caption. */
fun caption(state: ConversationState): String? =
    if (statusKey(state) == ConversationStatusKey.CAPTION) state.partialText else null
