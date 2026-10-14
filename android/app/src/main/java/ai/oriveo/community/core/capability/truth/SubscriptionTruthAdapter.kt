package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.openai.codexReasoningEffort

/**
 * Capability truth source for the subscription link (Codex / Grok subscriptions): the per-model declarations from upstream `/models` are attached via the production mapping to the
 * provider catalog snapshot; the tier is written to the Server model facts on cold start.
 *
 * Subscription models are not in the official metadata and never have a recipe; querying through the official adapter used to yield an all-unknown result.
 * Here the upstream declaration is copied as is, a missing one means unsupported, and the model id is never guessed. Pure function: no network, no credentials, no storage reads
 * (model facts come from the synced cache that [MetadataClient] has already persisted).
 */
internal object SubscriptionTruthAdapter : CapabilityTruthAdapter {
    const val SOURCE = "upstream_declaration"
    private const val FACTS_SOURCE = "model_facts"
    private const val GRADE = "declared"
    private const val SCOPE = "provider_model_transport"
    private const val REASONING_PREFIX = "reasoning_level/"

    override fun candidates(input: CapabilityTruthAdapter.Input): List<CapabilityEvidenceFacade.Candidate> {
        val provider = input.provider
        val model = input.model
        val key = input.key
        val identity = input.queryIdentity
        if (ProviderForm.of(provider) != ProviderForm.Subscription || identity == null) return emptyList()
        // tool_call is not owned by the catalog snapshot: the snapshot only counts as a first-hand declaration when it carries a toolCall boolean, otherwise it falls back to
        // model facts, and with none of those no candidate is produced; byte-for-byte identical to before the official adapter was split out, unaffected by catalog state.
        if (key == "tool_call") return toolCallCandidates(provider, model, identity, input.metadataClient)
        if (!owns(key)) return emptyList()
        // State 1: when the snapshot was not fetched, say nothing and let the projection fail closed as missing_evidence;
        // do not fall back to `provider.models`, which is a stale in-session object, not a snapshot.
        if (provider.catalogModels.isEmpty()) return emptyList()
        val catalogModel = provider.catalogModels.firstOrNull { it.id == model.id }
        val transport = input.finalTransport
            ?: CapabilityControlResolution.subscriptionFinalTransport(provider, model)
            ?: return emptyList()
        val candidateIdentity = CapabilityEvidenceFacade.CandidateIdentity(
            providerKind = provider.kind.rawValue,
            modelId = model.id,
            effectiveTransport = transport,
        )
        if (catalogModel == null) {
            // State 2: snapshot present, model absent. This is not "upstream says unsupported"; a dedicated source lets the facade resolve it to no outbound.
            return listOf(
                CapabilityEvidenceFacade.Candidate(
                    key = key,
                    support = "unknown",
                    source = CapabilityEvidenceFacade.CATALOG_ABSENT,
                    grade = "none",
                    scope = SCOPE,
                    identity = candidateIdentity,
                ),
            )
        }
        val mode = reasoningMode(key)
        val (supported, source) = when {
            key == "vision_input" -> (ModelCapability.Image in catalogModel.capabilities) to SOURCE
            key == "web_search" -> (ModelCapability.Web in catalogModel.capabilities) to SOURCE
            else -> {
                // Tiers are filtered by the same function as the outbound path (`codexReasoningEffort`): every tier shown in the UI
                // must map to a value upstream really accepts in the request. When the first-hand declaration is empty, the dictionary fallback source is model_facts.
                val levels = CapabilityControlResolution.subscriptionDeclaredReasoningLevels(provider.kind, catalogModel)
                val passes = codexReasoningEffort(mode?.rawValue, levels) != null
                passes to if (catalogModel.upstreamReasoningLevels.isNotEmpty()) SOURCE else FACTS_SOURCE
            }
        }
        return listOf(
            CapabilityEvidenceFacade.Candidate(
                key = key,
                support = if (supported) "supported" else "unsupported",
                source = source,
                grade = GRADE,
                scope = SCOPE,
                identity = candidateIdentity,
            ),
        )
    }

    /** tool_call fallback moved over unchanged from the official adapter: first-hand declaration first, then model facts, and no candidate if neither exists. */
    private fun toolCallCandidates(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceFacade.QueryIdentity,
        metadataClient: MetadataClient,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val firstParty = model.toolCall
        val modelFact = if (firstParty == null) metadataClient.modelFacts(provider.kind, model.id)?.toolCall else null
        val support = firstParty ?: modelFact ?: return emptyList()
        return listOf(
            CapabilityEvidenceFacade.Candidate(
                key = "tool_call",
                support = if (support) "supported" else "unsupported",
                source = if (firstParty != null) SOURCE else FACTS_SOURCE,
                grade = if (firstParty != null) GRADE else "external_declared",
                scope = SCOPE,
                identity = CapabilityEvidenceFacade.CandidateIdentity(
                    providerKind = provider.kind.rawValue,
                    modelId = MetadataClient.normalizeModelFactsID(model.id),
                    effectiveTransport = identity.effectiveTransport,
                    metadataRevision = identity.metadataRevision,
                ),
            ),
        )
    }

    private fun owns(key: String): Boolean =
        key == "vision_input" || key == "web_search" || reasoningMode(key) != null

    private fun reasoningMode(key: String): ReasoningMode? {
        if (!key.startsWith(REASONING_PREFIX)) return null
        val raw = key.removePrefix(REASONING_PREFIX)
        return ReasoningMode.entries.firstOrNull { it != ReasoningMode.Automatic && it.rawValue == raw }
    }
}
