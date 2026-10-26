package ai.oriveo.community.core.context

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.notice.ContextPriceLineConfirmStore
import ai.oriveo.community.feature.chat.ContextCapConfirmPresentation
import ai.oriveo.community.feature.chat.ContextCapPricing
import ai.oriveo.community.feature.chat.ContextConfirmAttempt
import ai.oriveo.community.feature.chat.ContextConfirmDecision
import ai.oriveo.community.feature.chat.ContextConfirmInput
import ai.oriveo.community.feature.chat.confirm
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/** One send at the gate point: plan estimate after compaction plus this request's window. */
data class ContextCapConfirmRequest(
    val conversationId: String,
    /** Assistant placeholder of this send; identifies the pending confirmation. */
    val messageId: String,
    val attempt: ContextConfirmAttempt,
    /** Runtime model id of this request. */
    val model: String,
    /** Display name for the dialog text. */
    val modelName: String,
    val providerKind: ProviderKind,
    /** P-hat = plan.budget.estimatedInput at the gate point. */
    val estimatedInput: Int,
    val B: Int?,
    val limitedBy: ContextBudgetLimit?,
    /** Price line T of this window; null for managed / Free / Relay. */
    val priceLineTokens: Int?,
)

/** A send waiting for the user's answer; the chat screen shows the dialog for it. */
data class PendingContextCapConfirmation(
    val conversationId: String,
    val messageId: String,
    val modelName: String,
    val input: ContextConfirmInput,
    val decision: ContextConfirmDecision,
) {
    val id: String = "$conversationId:$messageId"
}

sealed interface ContextCapConfirmChoice {
    /** Send as is; [dontAsk] is the "don't ask again" checkbox (only shown for the price line). */
    data class Send(val dontAsk: Boolean = false) : ContextCapConfirmChoice

    data object Cancel : ContextCapConfirmChoice
}

/**
 * Pre-send confirmation gate: decides, suspends the send until the user answers, and records a confirm
 * in the local state. No timeout: cancelling the waiting coroutine = cancel.
 */
class ContextCapConfirmCoordinator(
    private val store: ContextPriceLineConfirmStore,
    private val reminderEnabled: suspend () -> Boolean,
) {
    private data class Entry(
        val pending: PendingContextCapConfirmation,
        val result: CompletableDeferred<ContextCapConfirmChoice>,
    )

    /** Keyed by conversation: at most one pending confirmation per conversation (gate contract rule 4). */
    private val entries = ConcurrentHashMap<String, Entry>()
    private val _pending = MutableStateFlow<List<PendingContextCapConfirmation>>(emptyList())
    val pending: StateFlow<List<PendingContextCapConfirmation>> = _pending.asStateFlow()

    /** True = send; false = the user cancelled (the caller rolls the send back). */
    suspend fun confirm(request: ContextCapConfirmRequest): Boolean {
        if (request.attempt != ContextConfirmAttempt.SEND && request.attempt != ContextConfirmAttempt.EDIT) return true
        val state = withContext(Dispatchers.IO) { store.state(request.conversationId) }
        val input = ContextConfirmInput(
            attempt = request.attempt,
            model = request.model,
            reminderEnabled = reminderEnabled(),
            state = state,
            pricing = request.priceLineTokens?.let { pricing(request.providerKind, request.model) },
            estimatedInput = request.estimatedInput,
            B = request.B,
            limitedBy = request.limitedBy,
            priceLineTokens = request.priceLineTokens,
        )
        val decision = ContextCapConfirmPresentation.decide(input)
        if (!decision.asks) return true
        val pending = PendingContextCapConfirmation(
            conversationId = request.conversationId,
            messageId = request.messageId,
            modelName = request.modelName,
            input = input,
            decision = decision,
        )
        val choice = awaitChoice(pending)
        if (choice !is ContextCapConfirmChoice.Send) return false
        withContext(Dispatchers.IO + NonCancellable) {
            store.confirm(request.conversationId, decision, choice.dontAsk)
        }
        return true
    }

    private suspend fun awaitChoice(pending: PendingContextCapConfirmation): ContextCapConfirmChoice {
        val entry = Entry(pending, CompletableDeferred())
        // A newer send in the same conversation replaces the older one; the older one is cancelled (rolled back).
        entries.put(pending.conversationId, entry)?.result?.complete(ContextCapConfirmChoice.Cancel)
        publish()
        return try {
            entry.result.await()
        } finally {
            entries.remove(pending.conversationId, entry)
            publish()
        }
    }

    fun resolve(confirmationId: String, choice: ContextCapConfirmChoice) {
        val entry = entries.values.firstOrNull { it.pending.id == confirmationId } ?: return
        if (!entries.remove(entry.pending.conversationId, entry)) return
        publish()
        entry.result.complete(choice)
    }

    fun cancelConversation(conversationId: String) {
        cancelWhere { it.conversationId == conversationId }
    }

    fun cancelAll() {
        cancelWhere { true }
    }

    private fun cancelWhere(predicate: (PendingContextCapConfirmation) -> Boolean) {
        entries.entries.toList().forEach { (conversationId, entry) ->
            if (predicate(entry.pending) && entries.remove(conversationId, entry)) {
                entry.result.complete(ContextCapConfirmChoice.Cancel)
            }
        }
        publish()
    }

    private fun publish() {
        _pending.value = entries.values.map { it.pending }.sortedBy { it.id }
    }

    /** Catalog base and long-context prices per million tokens (same source as the cap panel). */
    private fun pricing(kind: ProviderKind, modelId: String): ContextCapPricing? {
        val resolved = MetadataClient.resolveCatalogModel(modelId, kind) ?: return null
        val long = resolved.longContext ?: return null
        return ContextCapPricing(
            basePrompt = resolved.promptPerToken?.let { it * PER_MILLION },
            baseCompletion = resolved.completionPerToken?.let { it * PER_MILLION },
            longPrompt = long.promptPerMToken,
            longCompletion = long.completionPerMToken,
        )
    }

    private companion object {
        const val PER_MILLION = 1_000_000.0
    }
}
