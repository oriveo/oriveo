package ai.oriveo.community.core.search

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Result of "one-tap enable" (external search one_tap_enable): after the onboarding page test passes and the service is persisted, the conversation id and catalog service id are recorded,
 * and taken when the chat input returns to the foreground ([consume]): turn **this conversation's** web switch on and send pick_service for the newly connected service.
 * Failure / cancel records nothing and changes nothing. In memory only; the chat page is in the back stack and not in composition, so it stays until taken.
 */
object WebSearchOneTapResults {
    data class Enabled(val conversationId: String, val catalogServiceId: String)

    private val pending = MutableStateFlow<Enabled?>(null)

    val enabledConversation: StateFlow<Enabled?> = pending.asStateFlow()

    fun enabled(conversationId: String, catalogServiceId: String) {
        pending.value = Enabled(conversationId, catalogServiceId)
    }

    /** If this is the result for this conversation, take it and return it. */
    fun consume(conversationId: String): Enabled? {
        val current = pending.value?.takeIf { it.conversationId == conversationId } ?: return null
        return current.takeIf { pending.compareAndSet(it, null) }
    }
}
