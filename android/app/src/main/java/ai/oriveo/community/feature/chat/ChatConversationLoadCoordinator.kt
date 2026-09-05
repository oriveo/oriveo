package ai.oriveo.community.feature.chat

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.model.Conversation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Owns the "the conversation is taking too long to load" watchdog for one chat screen.
 *
 * It is split out of [ChatViewModel] so that the skeleton, timeout and retry rules live in one
 * place with a single decision function, [resolveChatLoadState], rather than being spread across
 * the ViewModel as ad hoc flags.
 */
internal class ChatConversationLoadCoordinator(
    private val viewModelScope: CoroutineScope,
    private val requestedConversationId: String?,
    private val currentConversation: () -> Conversation?,
    private val hasMissingInitialConversation: () -> Boolean,
) {

    /**
     * Whether the watchdog has fired.
     *
     * Deliberately a boolean rather than an elapsed timestamp: elapsed time would be a continuously
     * changing value and would recompose the screen on every millisecond it is read. The timeout
     * only ever needs to be expressed to [resolveChatLoadState] as "expired or not".
     */
    private var watchdogExpired: Boolean by mutableStateOf(false)

    /** The single value that decides what the screen renders and whether the composer is usable. */
    val chatLoadState: ChatLoadState
        get() = resolveState(elapsedSinceEnterMs = if (watchdogExpired) CHAT_LOAD_STALLED_TIMEOUT_MS else 0L)

    private var watchdogJob: Job? = null

    private fun resolveState(elapsedSinceEnterMs: Long): ChatLoadState = resolveChatLoadState(
        requestedConversationId = requestedConversationId,
        conversation = currentConversation(),
        hasMissingInitialConversation = hasMissingInitialConversation(),
        elapsedSinceEnterMs = elapsedSinceEnterMs,
    )

    /** Arms the watchdog for the requested conversation. A brand new chat needs no watchdog. */
    fun start() {
        requestedConversationId ?: return
        armWatchdog()
    }

    /** Retry from the stalled card: clear the expiry and start the wait over. */
    fun retry() {
        watchdogExpired = false
        start()
    }

    /** Called when the ViewModel is cleared. */
    fun stop() {
        watchdogJob?.cancel()
        watchdogJob = null
    }

    private fun armWatchdog() {
        watchdogJob?.cancel()
        watchdogExpired = false
        watchdogJob = viewModelScope.launch {
            delay(CHAT_LOAD_STALLED_TIMEOUT_MS)
            // Only an unresolved bootstrap counts as stalled. Re-resolve without the timeout first
            // so a screen that has since reached content or an empty state is left alone.
            if (resolveState(elapsedSinceEnterMs = 0L) == ChatLoadState.Bootstrapping) {
                watchdogExpired = true
            }
        }
    }
}
