package ai.oriveo.community.core.voice

/** Live text: final = finalized segments joined with join, volatile = the current partial with surrounding whitespace trimmed, text = both joined with needsSpace. */
data class LivePartial(val final: String, val volatile: String, val text: String)

/** Result of writing live text into the input field: region (including inserted spaces, which are removed on dismiss to restore the original text) and volatile are both UTF-16 half-open ranges [start, end). */
data class LiveInsertion(
    val text: String,
    val cursor: Int,
    val regionStart: Int,
    val regionEnd: Int,
    val volatileStart: Int,
    val volatileEnd: Int,
)

/** How the live session ended. */
enum class LiveEnded(val rawValue: String) {
    Ok("ok"),
    Failed("failed"),
    Timeout("timeout"),
}

/** Terminal state of the live session; failureKind is set only for Failed and must be one of the five kinds; droppedAudio = audio chunks were dropped during the session (text may be missing in the middle). */
data class LiveSessionResult(
    val finals: List<String>,
    val partial: String = "",
    val ended: LiveEnded,
    val failureKind: SystemFailureKind? = null,
    val hasRecording: Boolean,
    val droppedAudio: Boolean = false,
)

/** Final result of recognizing the recorded file (after busy auto-retry); no_transcript from the recognizer is given as empty text. */
sealed interface LiveFileResult {
    data class Text(val text: String) : LiveFileResult
    data class Failed(val failureKind: SystemFailureKind) : LiveFileResult
}

enum class DictationOutcomeResult(val rawValue: String) {
    Text("text"),
    NoTranscript("no_transcript"),
    Failed("failed"),
}

enum class DictationOutcomeSource(val rawValue: String) {
    Live("live"),
    File("file"),
    LivePartial("live_partial"),
}

/** result = text carries source and text; failed carries failureKind. */
data class DictationOutcome(
    val fileAttempted: Boolean,
    val result: DictationOutcomeResult,
    val source: DictationOutcomeSource? = null,
    val text: String? = null,
    val failureKind: SystemFailureKind? = null,
)

/**
 * Pure rules for system-engine live dictation, one-to-one with rules.liveDictation in dictation.v1.json (reference implementation: scripts/lib/voice-cloud.mjs).
 * Text is processed by code point; write offsets are UTF-16.
 */
object LiveDictationRules {
    const val MAX_TEXT_LENGTH = 50_000

    fun livePartial(finals: List<String>, partial: String): LivePartial {
        val final = DictationRules.join(finals)
        val volatile = DictationRules.trim(partial)
        return LivePartial(final, volatile, concat(final, volatile))
    }

    /**
     * Always recomputed from the original text and selection at the start of dictation, placed the same way as [DictationRules.insert];
     * when over maxLength (UTF-16), whole code points are trimmed from the end of the live text: volatile first, then final; trim at the end.
     * The result equals removing one code point at a time and re-trimming until it fits, but is computed in one pass: remaining budget = limit - original length - spaces to insert,
     * cut once at the budget; if the trailing space makes the length exceed 1, remove one more code point.
     */
    fun liveInsert(
        text: String,
        selectionStart: Int,
        selectionEnd: Int,
        finals: List<String>,
        partial: String,
        maxLength: Int = MAX_TEXT_LENGTH,
    ): LiveInsertion {
        val live = livePartial(finals, partial)
        val offset = maxOf(selectionStart, selectionEnd).coerceIn(0, text.length)
        val before = if (offset > 0) Character.codePointBefore(text, offset) else null
        val after = if (offset < text.length) text.codePointAt(offset) else null
        fun leading(first: String): Int = if (DictationRules.needsSpace(before, first.codePointAt(0))) 1 else 0
        fun trailing(last: String): Int =
            if (DictationRules.needsSpace(Character.codePointBefore(last, last.length), after)) 1 else 0

        var fin = live.final
        var vol = live.volatile
        if (vol.isNotEmpty()) {
            val middle = if (fin.isEmpty()) 0 else concat(fin, vol).length - fin.length - vol.length
            val budget = maxLength - text.length - leading(fin.ifEmpty { vol }) - fin.length - middle
            vol = fitToBudget(vol, budget, ::trailing)
        }
        if (vol.isEmpty() && fin.isNotEmpty()) {
            fin = fitToBudget(fin, maxLength - text.length - leading(fin), ::trailing)
        }
        val inserted = DictationRules.insert(text, selectionStart, selectionEnd, concat(fin, vol))
        return LiveInsertion(
            text = inserted.text,
            cursor = inserted.cursor,
            regionStart = offset,
            regionEnd = offset + (inserted.text.length - text.length),
            volatileStart = inserted.cursor - vol.length,
            volatileEnd = inserted.cursor,
        )
    }

    /**
     * Take the longest prefix of [segment] (already trimmed) that fits [budget] together with the trailing space: cut at whole code points, then trim;
     * if the trailing space makes it exceed by exactly 1, remove one more code point (it always fits then). If nothing fits, return an empty string.
     */
    private fun fitToBudget(segment: String, budget: Int, trailing: (String) -> Int): String {
        if (budget <= 0) return ""
        var fitted = segment
        if (segment.length > budget) {
            var cut = budget
            if (Character.isLowSurrogate(segment[cut]) && Character.isHighSurrogate(segment[cut - 1])) cut--
            fitted = DictationRules.trim(segment.substring(0, cut))
        }
        if (fitted.isEmpty() || fitted.length + trailing(fitted) <= budget) return fitted
        return DictationRules.trim(dropLastCodePoint(fitted))
    }

    /**
     * Live ends normally with a non-empty final and there is no "dropped audio plus recording" case: use it directly, without recognizing the file. Otherwise use the file result when a recording exists; if the file is empty or failed,
     * the live text already on screen (final + the last unfinalized part) is kept as live_partial; otherwise no_transcript / failed. With no recording, live is the terminal result, and timeout maps to busy.
     */
    fun dictationOutcome(live: LiveSessionResult, file: LiveFileResult?): DictationOutcome {
        if (live.ended == LiveEnded.Failed) {
            require(live.failureKind?.isReportable == true) { "bad live.failureKind ${live.failureKind}" }
        }
        if (file is LiveFileResult.Failed) {
            require(file.failureKind.isReportable) { "bad file.failureKind ${file.failureKind}" }
        }
        val finalText = DictationRules.join(live.finals)
        // Dropped audio chunks mean text may be missing in the middle and is untrustworthy: if a recording exists, send the same segment to file recognition.
        if (live.ended == LiveEnded.Ok && finalText.isNotEmpty() && !(live.droppedAudio && live.hasRecording)) {
            return DictationOutcome(false, DictationOutcomeResult.Text, DictationOutcomeSource.Live, finalText)
        }
        val shown = livePartial(live.finals, live.partial).text
        if (!live.hasRecording) {
            if (shown.isNotEmpty()) {
                return DictationOutcome(false, DictationOutcomeResult.Text, DictationOutcomeSource.LivePartial, shown)
            }
            if (live.ended == LiveEnded.Ok) return DictationOutcome(false, DictationOutcomeResult.NoTranscript)
            val kind = if (live.ended == LiveEnded.Timeout) SystemFailureKind.Busy else live.failureKind
            return DictationOutcome(false, DictationOutcomeResult.Failed, failureKind = kind)
        }
        requireNotNull(file) { "file result required when live text is empty or live session did not end ok" }
        if (file is LiveFileResult.Text) {
            val text = DictationRules.trim(file.text)
            if (text.isNotEmpty()) {
                return DictationOutcome(true, DictationOutcomeResult.Text, DictationOutcomeSource.File, text)
            }
        }
        if (shown.isNotEmpty()) {
            return DictationOutcome(true, DictationOutcomeResult.Text, DictationOutcomeSource.LivePartial, shown)
        }
        if (file is LiveFileResult.Failed) {
            return DictationOutcome(true, DictationOutcomeResult.Failed, failureKind = file.failureKind)
        }
        return DictationOutcome(true, DictationOutcomeResult.NoTranscript)
    }

    /** When both parts are non-empty and needsSpace, insert one U+0020. */
    private fun concat(final: String, volatile: String): String {
        if (final.isEmpty() || volatile.isEmpty()) return final + volatile
        val left = Character.codePointBefore(final, final.length)
        val right = volatile.codePointAt(0)
        return if (DictationRules.needsSpace(left, right)) "$final $volatile" else final + volatile
    }

    private fun dropLastCodePoint(text: String): String =
        if (text.isEmpty()) text else text.substring(0, text.offsetByCodePoints(text.length, -1))
}
