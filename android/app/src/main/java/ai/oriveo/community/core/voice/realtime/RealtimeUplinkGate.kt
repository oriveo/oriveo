package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.VadEvent
import ai.oriveo.community.core.voice.conversation.VoiceConversationConstants
import ai.oriveo.community.core.voice.conversation.VoiceConversationVad

enum class UplinkGateOpenReason(val rawValue: String) { SPEECH("speech"), GUARD_END("guardEnd") }

/** Decision for one stepped frame. */
sealed interface UplinkGateStep {
    /** Send this frame now. */
    data object Send : UplinkGateStep

    /** Hold this frame back. */
    data object Hold : UplinkGateStep

    /**
     * The gate opens at this frame: send the held frames [flushFromFrame, this frame] in order, then pass through.
     * Held frames before [flushFromFrame] are dropped (no silence is substituted).
     */
    data class Open(val reason: UplinkGateOpenReason, val flushFromFrame: Long) : UplinkGateStep
}

/**
 * Speaker uplink gate for the realtime model, contract realtime-conversation.v1 uplinkGateCases
 * (reference scripts/lib/realtime-conversation.mjs uplinkGate). Streaming and pure: the host steps every 20 ms frame's dBFS
 * and calls [playbackStarted] / [playbackEnded] before stepping the frame where they happen.
 *
 * On the speaker route frames from playback start until postPlaybackGuardMs after playback end are held; the gate opens
 * when the local voice check confirms speech (flushing its preroll) or when the guard window ends (flushing vadPrerollMs).
 */
class RealtimeUplinkGate {
    // The same cascade VAD is fed every frame (also while unarmed) so its noise floor stays current.
    private var vad = VoiceConversationVad()

    // Fixed by the first stepped frame: true = it carried a speech probability, the whole session is model mode.
    private var model: Boolean? = null
    private var frame = 0L
    private var route = ConversationRoute.SPEAKER
    private var playbackStart: Long? = null
    private var playbackEnd: Long? = null
    private var armed = false
    private var bargeIn = true

    // Echo reference history (F2c): clamped near-end dB and downlink reference dB of the last ECHO_RING frames, indexed by
    // frame % ECHO_RING. Preallocated so the per-frame check never allocates.
    private val nearRing = DoubleArray(ECHO_RING)
    private val farRing = DoubleArray(ECHO_RING)
    private val diffScratch = DoubleArray(ECHO_WINDOW)

    // Onset backtrack history (E-434): raw dB and the probability actually fed to the VAD (after the echo decision;
    // NaN = no model probability) of the last ONSET_RING frames, indexed by frame % ONSET_RING.
    private val onsetDb = DoubleArray(ONSET_RING)
    private val onsetProb = DoubleArray(ONSET_RING)

    // The echo reference is in effect once any frame of the session carried a reference level.
    private var echoRef = false

    /** Playback starts at the next stepped frame; a new cycle replaces the previous one (even an opened one). */
    fun playbackStarted(route: ConversationRoute) {
        this.route = route
        playbackStart = frame
        playbackEnd = null
        // Same as runVad resetFrame: drop the utterance in progress, keep the noise floor.
        vad.reset()
        armed = route == ConversationRoute.SPEAKER
    }

    /**
     * The output route changed during the current cycle (E-602): arming is re-decided for the new route at once; the
     * VAD state and the cycle start / end are kept.
     */
    fun routeChanged(route: ConversationRoute) {
        this.route = route
        armed = route == ConversationRoute.SPEAKER
    }

    /** Playback really ended at the next stepped frame; only the first call of a cycle counts. */
    fun playbackEnded() {
        if (playbackStart != null && playbackEnd == null) playbackEnd = frame
    }

    /** false (after disableBargeIn): speech during playback no longer opens the gate; the guard window still does. */
    fun setBargeIn(on: Boolean) {
        bargeIn = on
    }

    /**
     * Steps one 20 ms frame. [prob] = the frame's speech probability; the first stepped frame decides the mode for
     * the whole session (with a probability = model mode, without = energy mode, which ignores later probabilities).
     * A model-mode frame without a probability means inference failed: the rest of the session runs on a fresh energy
     * VAD and never returns to the model.
     * [ref] = dBFS of the downlink PCM block at the playback head when this frame was captured (null = not playing /
     * digital silence). In model mode, a frame inside [playback start, guard end) whose near-end level follows the
     * reference is treated as echo and fed to the VAD with probability 0 (its dB still feeds the noise floor).
     */
    fun step(db: Double, prob: Double? = null, ref: Double? = null): UplinkGateStep {
        val i = frame++
        val pb = playbackStart
        val pe = playbackEnd
        val slot = (i % ECHO_RING).toInt()
        nearRing[slot] = clampEcho(db)
        farRing[slot] = clampEcho(ref)
        if (ref != null) echoRef = true
        val modelMode = model ?: (prob != null).also { model = it }
        if (modelMode && prob == null) {
            model = false
            vad = VoiceConversationVad()
        }
        val guardEnd = pe?.let { it + GUARD_FRAMES }
        var modelProb = prob.takeIf { model == true }
        if (modelProb != null && modelProb > 0 && pb != null && i >= pb && (guardEnd == null || i < guardEnd) &&
            isEcho(i)
        ) {
            modelProb = 0.0
        }
        val onsetSlot = (i % ONSET_RING).toInt()
        onsetDb[onsetSlot] = db
        onsetProb[onsetSlot] = modelProb ?: Double.NaN
        val speech = localSpeechStart(i, db, modelProb, pb, pe)
        if (!armed || pb == null) return UplinkGateStep.Send
        if (guardEnd != null && i >= guardEnd) {
            armed = false
            return UplinkGateStep.Open(UplinkGateOpenReason.GUARD_END, maxOf(pb, i - PREROLL_FRAMES))
        }
        if (speech != null && speech.frame >= pb && (guardEnd == null || speech.frame < guardEnd) &&
            (bargeIn || (pe != null && speech.frame >= pe))
        ) {
            armed = false
            var from = maxOf(pb, speech.prerollFrame)
            if (echoRef) from = backtrackOnset(i, pb, speech.frame, from)
            return UplinkGateStep.Open(UplinkGateOpenReason.SPEECH, from)
        }
        return UplinkGateStep.Hold
    }

    /**
     * The only local voice decision of the gate: the cascade VAD with the same thresholds as runVad, in model mode
     * when [prob] is given.
     */
    private fun localSpeechStart(index: Long, db: Double, prob: Double?, pb: Long?, pe: Long?): VadEvent.SpeechStart? =
        vad.step(index, db, route, pb, pe, prob) as? VadEvent.SpeechStart

    /**
     * Onset backtrack (E-434, reference uplinkGate `if (echoRef)`): with the echo reference in effect, frames the echo
     * decision let through during playback are trusted as speech. Within VAD_MODEL_ONSET_BACKTRACK_MS before the onset
     * run [onset] (not earlier than the barge-in grace end), find the earliest run of ≥ VAD_MODEL_ONSET_MIN_RUN_FRAMES
     * frames with probability ≥ VAD_MODEL_START_PROB and dB ≥ VAD_ABSOLUTE_MIN_DB; the flush start moves to its first
     * frame − preroll (never before [pb]), so a first syllable shorter than the barge-in minimum is not swallowed.
     */
    private fun backtrackOnset(i: Long, pb: Long, onset: Long, from: Long): Long {
        // Frames older than the history are gone; the ring covers the backtrack window plus a long onset run.
        val lo = maxOf(pb + GRACE_FRAMES, onset - BACKTRACK_FRAMES, i - ONSET_RING + 1)
        var run = 0
        var j = lo
        while (j < onset) {
            val slot = (j % ONSET_RING).toInt()
            val p = onsetProb[slot]
            run = if (!p.isNaN() && p >= VoiceConversationConstants.VAD_MODEL_START_PROB &&
                onsetDb[slot] >= VoiceConversationConstants.VAD_ABSOLUTE_MIN_DB
            ) {
                run + 1
            } else {
                0
            }
            if (run >= VoiceConversationConstants.VAD_MODEL_ONSET_MIN_RUN_FRAMES) {
                return maxOf(pb, minOf(from, j - run + 1 - PREROLL_FRAMES))
            }
            j++
        }
        return from
    }

    /**
     * Echo reference decision for frame [i] (reference echoRefIsEcho): pick the delay d in 0..ECHO_MAX_DELAY frames with
     * the highest Pearson correlation between the ECHO_DELAY_WINDOW near-end frames ending at i and the reference frames
     * ending at i − d (ties keep the smaller d; zero variance skips d; windows must lie within seen frames). That best
     * long-window correlation must itself be ≥ ECHO_REF_MIN_DELAY_CORRELATION. On that delay the ECHO_WINDOW short window must correlate ≥ ECHO_REF_MIN_CORRELATION and the near-end frame must not exceed the
     * aligned reference + gain + ECHO_REF_BARGE_IN_MARGIN_DB, gain = lower median of (near − ref) where ref is above floor.
     * Anything undecidable is not echo.
     */
    private fun isEcho(i: Long): Boolean {
        val nearFrom = i - ECHO_DELAY_WINDOW + 1
        if (nearFrom < 0) return false
        var bestD = -1
        var bestRho = 0.0
        var d = 0
        while (d <= ECHO_MAX_DELAY && nearFrom - d >= 0) {
            val rho = pearson(nearFrom, nearFrom - d, ECHO_DELAY_WINDOW)
            if (!rho.isNaN() && (bestD < 0 || rho > bestRho)) {
                bestD = d
                bestRho = rho
            }
            d++
        }
        if (bestD < 0 || bestRho < ECHO_REF_MIN_DELAY_CORRELATION) return false
        val shortFrom = i - ECHO_WINDOW + 1
        val rho = pearson(shortFrom, shortFrom - bestD, ECHO_WINDOW)
        if (rho.isNaN() || rho < ECHO_REF_MIN_CORRELATION) return false
        var m = 0
        for (k in 0 until ECHO_WINDOW) {
            val f = farAt(shortFrom - bestD + k)
            if (f > ECHO_REF_FLOOR_DB) diffScratch[m++] = nearAt(shortFrom + k) - f
        }
        if (m == 0) return false
        java.util.Arrays.sort(diffScratch, 0, m)
        val gain = diffScratch[(m - 1) / 2]
        return nearAt(i) <= farAt(i - bestD) + gain + ECHO_REF_BARGE_IN_MARGIN_DB
    }

    /** Pearson correlation of near[nearFrom, +n) and far[farFrom, +n); NaN when either window has zero variance. */
    private fun pearson(nearFrom: Long, farFrom: Long, n: Int): Double {
        var ma = 0.0
        var mb = 0.0
        for (k in 0 until n) {
            ma += nearAt(nearFrom + k)
            mb += farAt(farFrom + k)
        }
        ma /= n
        mb /= n
        var sab = 0.0
        var saa = 0.0
        var sbb = 0.0
        for (k in 0 until n) {
            val a = nearAt(nearFrom + k) - ma
            val b = farAt(farFrom + k) - mb
            sab += a * b
            saa += a * a
            sbb += b * b
        }
        if (saa == 0.0 || sbb == 0.0) return Double.NaN
        return sab / Math.sqrt(saa * sbb)
    }

    private fun nearAt(index: Long): Double = nearRing[(index % ECHO_RING).toInt()]

    private fun farAt(index: Long): Double = farRing[(index % ECHO_RING).toInt()]

    internal companion object {
        // Echo reference constants, contract realtime-conversation.v1 constants echoRef*.
        internal const val ECHO_REF_WINDOW_MS = 300
        internal const val ECHO_REF_DELAY_WINDOW_MS = 1000
        internal const val ECHO_REF_MAX_DELAY_MS = 500
        internal const val ECHO_REF_MIN_CORRELATION = 0.6
        internal const val ECHO_REF_MIN_DELAY_CORRELATION = 0.7
        internal const val ECHO_REF_BARGE_IN_MARGIN_DB = 6.0
        internal const val ECHO_REF_FLOOR_DB = -80.0
        private val ECHO_WINDOW = (ECHO_REF_WINDOW_MS / VoiceConversationConstants.FRAME_MS).toInt()
        private val ECHO_DELAY_WINDOW = (ECHO_REF_DELAY_WINDOW_MS / VoiceConversationConstants.FRAME_MS).toInt()
        private val ECHO_MAX_DELAY = (ECHO_REF_MAX_DELAY_MS / VoiceConversationConstants.FRAME_MS).toInt()

        // Near window plus the largest delay: every frame isEcho can look at.
        private val ECHO_RING = ECHO_DELAY_WINDOW + ECHO_MAX_DELAY

        /** Clamp to [ECHO_REF_FLOOR_DB, 0]; null / NaN = floor. */
        private fun clampEcho(v: Double?): Double = when {
            v == null || !(v >= ECHO_REF_FLOOR_DB) -> ECHO_REF_FLOOR_DB
            v > 0 -> 0.0
            else -> v
        }

        private val GUARD_FRAMES = (VoiceConversationConstants.POST_PLAYBACK_GUARD_MS / VoiceConversationConstants.FRAME_MS).toLong()
        private val PREROLL_FRAMES = VoiceConversationConstants.PREROLL_FRAMES.toLong()
        private val GRACE_FRAMES = (VoiceConversationConstants.BARGE_IN_GRACE_MS / VoiceConversationConstants.FRAME_MS).toLong()
        private val BACKTRACK_FRAMES =
            (VoiceConversationConstants.VAD_MODEL_ONSET_BACKTRACK_MS / VoiceConversationConstants.FRAME_MS).toLong()

        // Backtrack window plus room for the onset run before the gate opens (5 s of frames in total).
        private const val ONSET_RING = 256
    }
}
