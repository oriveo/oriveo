package ai.oriveo.community.ui.component.streaming

/**
 * Timing table for block-level commit rendering. All feel tuning for the streaming
 * reveal happens here and nowhere else - change one value at a time, otherwise you
 * cannot tell which knob caused the difference on a real device.
 *
 * Durations are milliseconds; all lengths are UTF-16 code units, the same unit as
 * Kotlin's String indices, so they can be compared against source offsets directly.
 * The delays are consumed by the reveal state machine according to the kind of
 * boundary that was just crossed.
 */
internal data class BlockCommitCadence(
    /**
     * Target size of one word chunk. ASCII scans back to a word boundary, so the
     * chunk actually ends at the next space; CJK has no word boundaries and is cut
     * straight at the character count.
     */
    val wordChunkLenAscii: Int = 12,
    val wordChunkLenCjk: Int = 6,

    /** Gap between consecutive word chunks. */
    val chunkDelayMs: Long = 100,
    /** Pause after a whole line has settled. */
    val lineEndDelayMs: Long = 140,
    /** Pause after a blank line, i.e. a paragraph boundary. */
    val paragraphDelayMs: Long = 180,
    /** Gap between committed table rows. */
    val tableRowDelayMs: Long = 100,

    /** Fade-in duration of a committed block (ease-out cubic). */
    val fadeDurationMs: Long = 250,

    /**
     * Staggered in-line fade, which is what produces the "sweeping in from the left"
     * feel: a committed run longer than the threshold is split into segments and the
     * segments start their fade at offset times instead of all at once.
     */
    val fadeStaggerThresholdUtf16: Int = 16,
    val fadeStaggerSegmentUtf16: Int = 12,
    val fadeStaggerStepMs: Long = 45,
    /**
     * Cap on the accumulated stagger within a single block. A very long line has many
     * segments, so the per-segment step is amortised under this ceiling; without it the
     * tail segments would not start fading until seconds after the head.
     */
    val fadeStaggerMaxDelayMs: Long = 300,

    /**
     * Mid-range catch-up: once the un-rendered backlog exceeds the threshold, the
     * inter-block delay is multiplied by this scale so the reveal closes the gap.
     * The 20k snap is still the extreme fallback beyond this.
     */
    val catchupBacklogUtf16: Int = 400,
    val catchupDelayScale: Double = 0.5,

    /**
     * Largest span of source text (UTF-16) we will hold back waiting for an unclosed
     * inline span to close. Past this the text is committed literally instead.
     * Committed content is never rewritten, and line-scoped parsing guarantees that
     * once a run has been committed literally it stays literal, so this cannot flicker.
     */
    val maxInlineHoldUtf16: Int = 120,

    /**
     * Largest span we will hold back waiting for an ASCII word to finish at the end of
     * a line. A very long line with no spaces (a URL, base64) has no word boundary at
     * all, so past this limit the reveal degrades to fixed [wordChunkLenAscii] chunks
     * rather than letting the whole line stall until it terminates.
     */
    val maxWordHoldUtf16: Int = 48,

    /**
     * Once the backlog exceeds this, a single step may commit up to [multiLineMax]
     * complete lines so the reveal absorbs the pile-up quickly.
     */
    val multiLineBacklog: Int = 1_500,
    val multiLineMax: Int = 3,
) {
    companion object {
        val Default = BlockCommitCadence()
    }
}
