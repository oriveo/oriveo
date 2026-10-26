package ai.oriveo.community.feature.chat.voice

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * With a screen reader on, the voice bar's status word is announced once per change and nothing else;
 * while the reader talks the controller ignores capture ([onSpeaking] true … false).
 *
 * Android has no "announcement finished" callback (announceForAccessibility is fire-and-forget), so the end is
 * estimated as characters × 80 ms + 500 ms; a newer announcement restarts the estimate.
 */
class StatusAnnouncer(
    private val scope: CoroutineScope,
    private val screenReaderOn: () -> Boolean,
    private val speak: (String) -> Unit,
    private val onSpeaking: (Boolean) -> Unit,
) {
    private var last: String? = null
    private var timer: Job? = null

    fun announce(text: String) {
        if (text == last) return
        last = text
        if (!screenReaderOn()) return
        speak(text)
        timer?.cancel()
        onSpeaking(true)
        timer = scope.launch {
            delay(estimateMillis(text))
            timer = null
            onSpeaking(false)
        }
    }

    /** The conversation ended: drop the pending estimate and let capture go. */
    fun reset() {
        last = null
        val running = timer ?: return
        timer = null
        running.cancel()
        onSpeaking(false)
    }

    companion object {
        fun estimateMillis(text: String): Long = text.length * 80L + 500L
    }
}
