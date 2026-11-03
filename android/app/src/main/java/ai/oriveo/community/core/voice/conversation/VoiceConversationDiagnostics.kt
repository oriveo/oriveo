package ai.oriveo.community.core.voice.conversation

/**
 * Per-turn diagnostics of the conversation host: observation only, no behavior change. All callbacks are invoked synchronously on the host thread (main thread); implementations must not lock, do IO, or block;
 * Frame index is the capture frame index (each frame is [VoiceConversationConstants.FRAME_MS] ms); time is in milliseconds on the host clock.
 * Default is [NoOp]; test-rig implementations write the events into the timeline.
 */
interface VoiceConversationDiagnostics {
    /**
     * VAD mode for this session, reported once before capture starts: [mode] is model / energy; [reason] is the energy-mode cause
     * (none = no model configured, timeout = model load timed out, otherwise the exception class name); null in model mode.
     */
    fun vadMode(mode: String, reason: String?) {}

    /**
     * Sampled every [LEVEL_SAMPLE_FRAMES] frames: this frame's level, the noise floor at that time, whether VAD is in speech, this frame's speech probability (null in energy mode),
     * VAD mode, and the latest model inference time (microseconds, null in energy mode).
     */
    fun level(frame: Long, db: Double, floorDb: Double, voiced: Boolean, prob: Float?, mode: String, inferenceUs: Long?) {}

    /** VAD start: speech start frame, pre-roll start frame, noise floor, speech probability at the decision frame (null in energy mode), VAD mode. */
    fun vadStart(frame: Long, prerollFrame: Long, floorDb: Double, prob: Float?, mode: String) {}

    /** VAD stop: end frame, noise floor, accumulated speech milliseconds, end reason (silence / maxLength / forced), speech probability at the decision frame, VAD mode. */
    fun vadEnd(frame: Long, floorDb: Double, voicedMs: Int, reason: String, prob: Float?, mode: String) {}

    /** VAD drop (speech shorter than the minimum utterance length): end frame, noise floor. */
    fun vadDiscarded(frame: Long, floorDb: Double) {}

    /**
     * Realtime recognition session opened: [recognizer] is ON_DEVICE / DEFAULT (null if unavailable), [component] is the recognition service component package (null if unavailable),
     * [languageTag] is the recognition language.
     */
    fun liveStart(utteranceId: String, recognizer: String?, component: String?, languageTag: String?) {}

    /** Realtime session opened (including pre-roll replay): time taken to open the session. */
    fun liveOpened(utteranceId: String, elapsedMs: Long) {}

    /** Realtime session failed to open: duration and failure code (null_session / attach_failed / exception class name). */
    fun liveOpenFailed(utteranceId: String, elapsedMs: Long, code: String) {}

    /** Each realtime text output arrives: time, character count of finalized segments, character count of the unfinalized partial. */
    fun transcript(utteranceId: String, atMs: Long, finalChars: Int, partialChars: Int) {}

    /** One finalized utterance: text source live / file / none, recognizer error code for file recognition (null if none), text character count (0 on failure). */
    fun transcribed(utteranceId: String, source: String, recognizerCode: Int?, chars: Int) {}

    /** Deadline timer reset: deadline time (null = cleared) and reason (holdUntil / cap / other / none). */
    fun deadline(atMs: Long?, reason: String) {}

    /**
     * Capture reader thread read count (every 500 ms, final total reported again before the thread exits on its own): total reads, reads returning 0 samples, reads returning an error code.
     * Stopped but no [captureStopped] means the reader thread is stuck inside read.
     */
    fun captureStats(atMs: Long, reads: Long, zeroReads: Long, errorReads: Long) {}

    /** Capture reader thread stops delivering PCM on its own: reason read_error / sink_error / silenced (not reported when the session is closed intentionally). */
    fun captureStopped(atMs: Long, reason: String) {}

    /** Software capture gate toggled (mute key / pause capture): paused and muted state after the toggle, and whether capture is still live. */
    fun sinkGate(atMs: Long, paused: Boolean, muted: Boolean, live: Boolean) {}

    /** Frame consumer coroutine exited with a non-cancellation exception: exception class name (reported only, still rethrown). */
    fun consumerFailed(atMs: Long, error: String) {}

    /** Frame consumer coroutine exited (reported for normal exit, cancellation, or exception). */
    fun consumerExit(atMs: Long) {}

    /** Frame consumer backlog: enqueued minus consumed exceeds 75 frames (1.5 s), then the session ends as a capture failure; reported once per session. */
    fun consumerLag(atMs: Long, enqueued: Long, consumed: Long) {}

    /**
     * Frame stall: capture is running (not paused / muted / interrupted) but no new frame has been enqueued for over 1.5 s, then the session ends as a capture failure:
     * last enqueue time and cumulative enqueued frame count.
     */
    fun captureStalled(atMs: Long, lastFrameAtMs: Long, frames: Long) {}

    object NoOp : VoiceConversationDiagnostics

    companion object {
        /** Level sampled once every 500 ms. */
        const val LEVEL_SAMPLE_FRAMES = 500 / VoiceConversationConstants.FRAME_MS
    }
}
