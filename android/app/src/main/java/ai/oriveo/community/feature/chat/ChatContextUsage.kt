package ai.oriveo.community.feature.chat

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/**
 * Context usage summary of the current conversation for the ring in the input area; recomputed when the conversation switches, messages change, the conversation cap changes or a checkpoint changes.
 * Always null for a draft conversation and when not wired (unit tests, [deps] or its ledger is null). Extracted from ChatViewModel.
 */
internal fun chatContextUsage(
    deps: ChatCompactionDeps?,
    conversation: StateFlow<ConversationRenderState>,
    scope: CoroutineScope,
): StateFlow<ContextUsageSummary?> {
    val ledger = deps?.ledger ?: return MutableStateFlow(null)
    val conversationId = conversation.map { it.conversation?.id }.distinctUntilChanged()
    return ContextUsageSource(
        ledger = ledger,
        store = deps.store,
        accountId = deps.accountId,
        loadConversation = { id -> deps.conversationRepository.getWithMessages(id) },
        rhoHi = deps.chatRepository::currentRhoHi,
        // Compute B now from the conversation's current cap and window (same source as sending); when not wired or the conversation / connection cannot be resolved, keep the manifest's B.
        currentB = { id ->
            val current = conversation.value.conversation?.takeIf { it.id == id }
            current?.let { deps.contextWindowB?.invoke(it) }
        },
    ).flow(
        conversationId = conversationId,
        messagesChanged = conversation
            .map { state -> state.conversation?.messages?.map { it.id to it.state } }
            .distinctUntilChanged(),
        // Recompute the denominator right after the cap changes.
        capChanged = combine(
            conversation.map { it.conversation?.contextCap }.distinctUntilChanged(),
            deps.contextDefaultCap?.distinctUntilChanged() ?: flowOf(Unit),
        ) { cap, global -> cap to global },
    )
        // When switching to a new conversation while the new result is still computing, do not show the previous conversation's result.
        .combine(conversationId) { result, id -> result?.forConversation(id) }
        .stateIn(scope, SharingStarted.WhileSubscribed(5000), null)
}
