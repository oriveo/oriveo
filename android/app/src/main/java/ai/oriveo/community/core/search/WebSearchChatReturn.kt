package ai.oriveo.community.core.search

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Going from the model options panel to the web search settings (one-tap enable / web card "Add search service" / last row of the "Search method" page) and coming back (external search):
 * - when leaving the panel, [leave] records the conversation and the services already present;
 * - when leaving that settings page, [finish] settles immediately: an extra service is the one connected successfully from this panel, no extra service means it was not completed.
 *   After settling the record is discarded, so a service added directly in settings later is not selected by mistake;
 * - when the chat input returns to the foreground, [consume] takes the settlement: reopen the model options panel, and if there is a new service send pick_service (when [Finished.arms]).
 * In memory only, one-shot.
 */
object WebSearchChatReturn {
    data class Pending(
        val conversationId: String,
        val oneTap: Boolean,
        /** oneTapArms: whether external can be recorded as on after success (not recorded when the panel cannot persist). */
        val arms: Boolean,
        val serviceIdsBefore: Set<String>,
    )

    data class Finished(val conversationId: String, val arms: Boolean, val addedServiceId: String?)

    private val state = MutableStateFlow<Any?>(null)

    /** For observation: the input box takes the settlement from here when it appears. */
    val changes: StateFlow<Any?> = state.asStateFlow()

    fun leave(value: Pending) {
        state.value = value
    }

    /** Leaving the settings page opened from the panel: settle the unfinished record against [currentServiceIds] (storage order); with no record (added directly in settings) do nothing. */
    @Synchronized
    fun finish(currentServiceIds: List<String>) {
        val pending = state.value as? Pending ?: return
        val added = currentServiceIds.lastOrNull { it !in pending.serviceIdsBefore }
        state.value = Finished(pending.conversationId, pending.arms, added)
    }

    /** If this is the settlement for this conversation, take it and return it; if not yet settled (still in settings) return null. */
    @Synchronized
    fun consume(conversationId: String): Finished? {
        val finished = state.value as? Finished ?: return null
        if (finished.conversationId != conversationId) return null
        state.value = null
        return finished
    }
}
