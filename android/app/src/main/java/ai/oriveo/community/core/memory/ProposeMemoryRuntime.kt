package ai.oriveo.community.core.memory

import ai.oriveo.community.core.context.MemoryPropose
import ai.oriveo.community.core.context.MemoryProposeMode
import ai.oriveo.community.core.context.MemoryProposeModeInput
import ai.oriveo.community.core.context.MemoryProposePurpose
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterProfileFingerprint
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterLifecycleRules
import ai.oriveo.community.core.provider.ToolCallTransportResolver
import ai.oriveo.community.core.provider.transport.TransportKind
import java.util.concurrent.ConcurrentHashMap

/**
 * Process-wide state of propose_memory (memory-propose.v3 rules 1, 6): the in-process degraded set
 * ("connection id\nmodel id") and the per-send mode decision. The degraded set lives only in memory and
 * resets with the process.
 */
object ProposeMemoryRuntime {
    private val degraded: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** Rule 6: a first leg carrying tools was deterministically rejected; later sends on this pair fall back. */
    fun markDegraded(connectionId: String, modelId: String) {
        degraded += MemoryPropose.degradedKey(connectionId, modelId)
    }

    fun isDegraded(connectionId: String, modelId: String): Boolean =
        MemoryPropose.degradedKey(connectionId, modelId) in degraded

    /**
     * Client tools can ride this send: the MCP tool predicate holds and the send is not Moonshot's built-in
     * web search loop (that loop owns the tool list).
     */
    @Suppress("LongParameterList")
    fun connectionSupportsTools(
        runner: McpChatToolRunner,
        provider: Provider,
        model: AIModel,
        memoryVerdict: Boolean?,
        localIdentity: CapabilityEvidenceIdentity?,
        moonshotBuiltinSearch: Boolean,
    ): Boolean = !moonshotBuiltinSearch && runner.connectionSupportsTools(provider, model, memoryVerdict, localIdentity)

    /** Same predicate without a runner instance (the MCP predicate holds no instance state). */
    fun connectionSupportsTools(
        provider: Provider,
        model: AIModel,
        memoryVerdict: Boolean?,
        localIdentity: CapabilityEvidenceIdentity?,
        moonshotBuiltinSearch: Boolean,
    ): Boolean = !moonshotBuiltinSearch && McpChatToolRunner.supportsTools(provider, model, memoryVerdict, localIdentity)

    /**
     * Gemini generateContent (official or Relay) with web search on: the API does not take the search tool and
     * function tools in one request, so propose_memory cannot ride this send.
     */
    fun geminiWebSearch(provider: Provider, model: AIModel?, webSearchEnabled: Boolean): Boolean =
        webSearchEnabled &&
            ToolCallTransportResolver.declaredTransport(provider, model) == TransportKind.GeminiGenerate.wireValue

    /**
     * This send goes out with json_schema — the value the send path resolves from [store] under the profile
     * that declares its wire, dormant values filtered with the same activeParameterIds as the final dispatch.
     * Structured output conflicts with tools (generation parameter conflictsWith), so both memory tools fall back.
     */
    fun structuredOutputActive(
        store: GenerationParameterSettingsStore?,
        provider: Provider,
        model: AIModel?,
        modelId: String,
        conversationId: String,
    ): Boolean {
        if (store == null || model == null) return false
        val profile = GenerationParameterAvailability.profile(provider, model) ?: return false
        val activeIds = GenerationParameterLifecycleRules.declaredParameterIdsForFinalDispatch(profile)
        if (JSON_SCHEMA !in activeIds) return false
        val overrides = store.resolve(
            transient = null,
            providerID = provider.id,
            modelID = modelId,
            conversationID = conversationId,
            profileFingerprint = GenerationParameterProfileFingerprint.make(provider, model),
            activeParameterIds = activeIds,
        )
        return overrides?.values?.get(JSON_SCHEMA)?.state == GenerationOverrideState.Value
    }

    @Suppress("LongParameterList")
    fun mode(
        purpose: MemoryProposePurpose,
        freshSend: Boolean,
        memoryEnabled: Boolean,
        autoSuggest: Boolean,
        connectionSupportsTools: Boolean,
        connectionId: String,
        modelId: String,
        geminiWebSearch: Boolean = false,
        structuredOutput: Boolean = false,
    ): MemoryProposeMode = MemoryPropose.mode(
        MemoryProposeModeInput(
            purpose = purpose,
            freshSend = freshSend,
            memoryEnabled = memoryEnabled,
            autoSuggest = autoSuggest,
            connectionSupportsTools = connectionSupportsTools && !geminiWebSearch && !structuredOutput,
            degraded = isDegraded(connectionId, modelId),
        ),
    )

    internal fun clearForTest() = degraded.clear()

    private const val JSON_SCHEMA = "json_schema"
}
