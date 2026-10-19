package ai.oriveo.community.core.memory

import ai.oriveo.community.core.context.ContextRecallEntry
import ai.oriveo.community.core.context.MemoryRecallHit
import ai.oriveo.community.core.context.MemoryRecallIndex
import ai.oriveo.community.core.context.MemorySearch
import ai.oriveo.community.core.context.MemoryProposePurpose
import ai.oriveo.community.core.context.MemorySearchContext
import ai.oriveo.community.core.context.MemorySearchMode
import ai.oriveo.community.core.context.MemorySearchModeInput
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.time.Instant

/**
 * search_memory state of one chat send in tool mode (memory-search.v1 rules 4, 6; legRules 2-5): the L3 index the
 * send's [D] recall used, the per-turn call count, and the hits found so far. Nothing here is persisted.
 */
class MemorySearchTurn(
    private val index: MemoryRecallIndex,
    private val conversationId: String,
    private val folderId: String?,
    private val now: Instant,
    private val connectionId: String,
    private val modelId: String,
) {
    private val lock = Any()
    private var calls = 0
    private val returned = ArrayList<MemoryRecallHit>()
    private val searched = ArrayList<MemoryRecallHit>()

    /**
     * Runs one call and answers its tool_result text. [recallIds] are the ids this turn's [D] recall placed;
     * [recallMax] / [rhoHi] are the request's recall cap and estimate factor.
     */
    fun run(argumentsJson: String, recallIds: List<String>, recallMax: Int?, rhoHi: Double): String = synchronized(lock) {
        val exclude = recallIds + returned.map { it.id }
        val outcome = MemorySearch.search(
            index,
            argumentsJson,
            MemorySearchContext(conversationId, folderId, now, exclude),
            priorInTurn = calls,
        )
        calls++
        outcome.hits.forEach { hit -> if (searched.none { it.id == hit.id }) searched += hit }
        returned += MemorySearch.returnedHits(outcome, recallMax, rhoHi)
        MemorySearch.toolResult(outcome, recallMax, rhoHi)
    }

    /** Ids placed in a tool_result so far, in call order (they join the plan's memoryIds, rule 6). */
    val returnedIds: List<String> get() = synchronized(lock) { returned.map { it.id } }

    /** Every hit found so far as [D] recall entries, in call order (legRules 3: appended after the automatic ones). */
    val searchedEntries: List<ContextRecallEntry> get() = synchronized(lock) {
        searched.map { ContextRecallEntry(it.id, it.text, it.date) }
    }

    /** legRules 5: a first leg carrying the tool was deterministically rejected; both host tools fall back. */
    fun onToolsRejected() = ProposeMemoryRuntime.markDegraded(connectionId, modelId)

    companion object {
        /**
         * memory-search.v1 rule 5 for one send: a turn when it carries search_memory (purpose chat, memory on, client
         * tools can ride the send — the propose_memory predicate —, the pair not degraded, at least one recallable L3
         * item in [index]); null otherwise. Fresh sends, retries and regenerations alike; continue never.
         */
        @Suppress("LongParameterList")
        fun forSend(
            purpose: MemoryProposePurpose,
            useMemory: Boolean,
            provider: Provider,
            model: AIModel?,
            modelId: String,
            memoryVerdict: Boolean?,
            localIdentity: CapabilityEvidenceIdentity?,
            webSearchEnabled: Boolean,
            index: MemoryRecallIndex?,
            conversationId: String,
            folderId: String?,
            now: Instant,
            /** D-296: json_schema goes out on this send ([ProposeMemoryRuntime.structuredOutputActive]); falls back. */
            structuredOutput: Boolean = false,
        ): MemorySearchTurn? {
            val supportsTools = model != null &&
                ProposeMemoryRuntime.connectionSupportsTools(
                    provider = provider,
                    model = model,
                    memoryVerdict = memoryVerdict,
                    localIdentity = localIdentity,
                    moonshotBuiltinSearch = provider.kind == ProviderKind.Moonshot && webSearchEnabled,
                ) && !ProposeMemoryRuntime.geminiWebSearch(provider, model, webSearchEnabled) && !structuredOutput
            val mode = MemorySearch.mode(
                MemorySearchModeInput(
                    purpose = purpose,
                    memoryEnabled = useMemory,
                    connectionSupportsTools = supportsTools,
                    degraded = ProposeMemoryRuntime.isDegraded(provider.id, modelId),
                    recallableItems = index?.let { MemorySearch.recallableItems(it, conversationId, folderId, now) } ?: 0,
                ),
            )
            if (mode != MemorySearchMode.TOOL || index == null) return null
            return MemorySearchTurn(index, conversationId, folderId, now, provider.id, modelId)
        }
    }
}
