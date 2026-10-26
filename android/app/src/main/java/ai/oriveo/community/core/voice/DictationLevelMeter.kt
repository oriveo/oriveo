package ai.oriveo.community.core.voice

import ai.oriveo.community.BuildConfig
import kotlin.math.log10
import kotlin.math.sqrt
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
  * Live dictation level: each PCM16 chunk's RMS is converted to dBFS, mapped linearly from −60…0 dB to 0…1 and clamped; at most the latest [CAPACITY] values are kept for the waveform.
  * Chunks arriving less than [MIN_INTERVAL_MILLIS] after the last publish are dropped (≤ 15 per second).
  * [onPcm] is called on the capture thread, [start] / [reset] on the main thread; publishing goes through StateFlow.value without switching threads.
  * Chunks arriving before [start] or after [reset] are ignored, so a late chunk before capture stops cannot refill an already cleared list.
 */
class DictationLevelMeter(private val clock: () -> Long) : PcmSink {
    private val lock = Any()
    private val recent = ArrayDeque<Float>(CAPACITY)
    private var lastPublishAt: Long? = null
    private var active = false

    private val _levels = MutableStateFlow<List<Float>>(emptyList())

    /** Recent levels (oldest first), each 0…1; an empty list when not recording. */
    val levels: StateFlow<List<Float>> = _levels.asStateFlow()

    /** Starts receiving: clears old values, then accepts subsequent chunks. */
    fun start() {
        synchronized(lock) {
            clearLocked()
            active = true
        }
    }

    /** Stops receiving and clears. */
    fun reset() {
        synchronized(lock) {
            active = false
            clearLocked()
        }
    }

    /** Preview sample (DEBUG only): publishes a static set of levels (the last [CAPACITY]) without receiving PCM. */
    fun showForShots(levels: List<Float>) {
        if (!BuildConfig.DEBUG) return
        synchronized(lock) {
            clearLocked()
            active = false
            recent.addAll(levels.takeLast(CAPACITY))
            _levels.value = recent.toList()
        }
    }

    override fun onPcm(samples: ShortArray, count: Int) = publish { level(samples, count) }

    /** Recognizer self-recording: the level reported by the recognizer's onRmsChanged is mapped to 0…1 on the recognizer scale [RECOGNIZER_FLOOR_DB]…[RECOGNIZER_CEIL_DB], throttled like PCM. */
    fun onRecognizerRmsDb(rmsdB: Float) = publish { recognizerLevel(rmsdB) }

    private inline fun publish(level: () -> Float) {
        synchronized(lock) {
            if (!active) return
            val now = clock()
            val last = lastPublishAt
            if (last != null && now - last < MIN_INTERVAL_MILLIS) return
            lastPublishAt = now
            recent.addLast(level())
            while (recent.size > CAPACITY) recent.removeFirst()
            _levels.value = recent.toList()
        }
    }

    private fun clearLocked() {
        recent.clear()
        lastPublishAt = null
        _levels.value = emptyList()
    }

    companion object {
        /** Maximum number of levels kept. */
        const val CAPACITY = 24

        /** Minimum interval between two publishes (≤ 15 per second). */
        const val MIN_INTERVAL_MILLIS = 66L

        /** Lower dBFS bound mapped to 0. */
        const val FLOOR_DBFS = -60.0

        /** Level of one PCM16 chunk: RMS converted to dBFS, [FLOOR_DBFS]…0 mapped linearly to 0…1 and clamped; an empty chunk or digital silence is 0. */
        fun level(samples: ShortArray, count: Int): Float {
            val n = count.coerceAtMost(samples.size)
            if (n <= 0) return 0f
            var sum = 0.0
            for (i in 0 until n) {
                val s = samples[i] / 32768.0
                sum += s * s
            }
            val rms = sqrt(sum / n)
            if (rms <= 0.0) return 0f
            return levelOf(20.0 * log10(rms))
        }

        /** Recognizer level lower bound mapped to 0 (dB, recognizer scale, not dBFS). */
        const val RECOGNIZER_FLOOR_DB = -2f

        /** Recognizer level upper bound mapped to 1 (dB). */
        const val RECOGNIZER_CEIL_DB = 10f

        /** Level from the recognizer's onRmsChanged: [RECOGNIZER_FLOOR_DB]…[RECOGNIZER_CEIL_DB] mapped linearly to 0…1, clamped outside both ends. */
        fun recognizerLevel(rmsdB: Float): Float =
            ((rmsdB - RECOGNIZER_FLOOR_DB) / (RECOGNIZER_CEIL_DB - RECOGNIZER_FLOOR_DB)).coerceIn(0f, 1f)

        /** [FLOOR_DBFS]…0 dB mapped linearly to 0…1 and clamped. */
        private fun levelOf(dbfs: Double): Float = ((dbfs - FLOOR_DBFS) / -FLOOR_DBFS).coerceIn(0.0, 1.0).toFloat()
    }
}
