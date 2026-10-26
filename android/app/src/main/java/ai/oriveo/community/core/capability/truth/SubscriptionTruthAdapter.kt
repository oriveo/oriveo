package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
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

    /** Whether thinking is shown: the first-hand declared tiers are non-empty, or the model facts say reasoning; false if both are missing. */
    override fun thinking(input: CapabilityTruthAdapter.FactInput): Boolean {
        val declared = input.provider.catalogModels.firstOrNull { it.id == input.model.id } ?: input.model
        return declared.upstreamReasoningLevels.isNotEmpty() ||
            modelFacts(input.metadataClient, input.provider.kind, input.model)?.reasoning == true
    }

    override fun candidates(input: CapabilityTruthAdapter.Input): List<CapabilityEvidenceFacade.Candidate> {
        val provider = input.provider
        val model = input.model
        val key = input.key
        val identity = input.queryIdentity
        if (ProviderForm.of(provider) != ProviderForm.Subscription || identity == null) return emptyList()
        // tool_call is not owned by the catalog snapshot: the subscription /models does not ship tool fields, and model.toolCall is a server catalog bit,
        // not first-hand; only model facts count, and with none of those no candidate is produced (same rule as toolCallVerdict), unaffected by catalog state.
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
            // Vision input uses the same verdict as the input projection (first-hand > model facts > unknown); the legacy Image capability bit is not read.
            key == CapabilityEvidenceFacade.VISION_INPUT -> {
                val verdict = inputVerdict(provider, model, key, wireFamily = null, input.metadataClient)
                val inputSource = if (catalogModel.upstreamInputModalities != null) SOURCE else FACTS_SOURCE
                return listOf(
                    CapabilityEvidenceFacade.Candidate(
                        key = key,
                        support = CapabilityControlResolution.evidenceSupport(verdict.state),
                        source = inputSource,
                        grade = GRADE,
                        scope = SCOPE,
                        identity = candidateIdentity,
                    ),
                )
            }
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

    /** Subscription tool_call trusts only model facts (the first-hand layer is always empty; the catalog bit is not first-hand); no candidate if there are none. */
    private fun toolCallCandidates(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceFacade.QueryIdentity,
        metadataClient: MetadataClient,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val support = modelFacts(metadataClient, provider.kind, model)?.toolCall ?: return emptyList()
        return listOf(
            CapabilityEvidenceFacade.Candidate(
                key = "tool_call",
                support = if (support) "supported" else "unsupported",
                source = FACTS_SOURCE,
                grade = "external_declared",
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

    /**
     * Verdict for the three subscription input keys:
     * first-hand declaration ([AIModel.upstreamInputModalities]) > modelFacts input modalities (read only when first-hand is null) > unknown / catalog_silent.
     * A first-hand list that lacks the medium means unavailable / model_capability_absent; a modelFacts list that lacks it means unknown (third-party facts are not hard evidence).
     * Never reads the provider-level attachment envelope or the legacy capability bits.
     */
    internal fun inputVerdict(
        key: String,
        firstHand: List<String>?,
        modelFacts: List<String>?,
        wireFamily: String?,
    ): CapabilityEvidenceFacade.InputCapabilityVerdict {
        val media = INPUT_MEDIA[key] ?: throw IllegalArgumentException("not an input capability key: $key")
        fun List<String>.declares() = any { it.trim().lowercase() in media }
        return when {
            firstHand != null -> if (firstHand.declares()) {
                CapabilityEvidenceFacade.InputCapabilityVerdict(CapabilityControlResolution.STATE_AUTO_AVAILABLE, wireFamily = wireFamily)
            } else {
                CapabilityEvidenceFacade.InputCapabilityVerdict("unavailable", "model_capability_absent", wireFamily)
            }
            modelFacts != null -> if (modelFacts.declares()) {
                CapabilityEvidenceFacade.InputCapabilityVerdict(CapabilityControlResolution.STATE_AUTO_AVAILABLE, wireFamily = wireFamily)
            } else {
                CapabilityEvidenceFacade.InputCapabilityVerdict("unknown", wireFamily = wireFamily)
            }
            else -> CapabilityEvidenceFacade.InputCapabilityVerdict("unknown", "catalog_silent", wireFamily)
        }
    }

    /** Production lookup: first-hand reads this model from the subscription catalog snapshot (falling back to the current model); modelFacts reads the persisted models.dev input modalities. */
    internal fun inputVerdict(
        provider: Provider,
        model: AIModel,
        key: String,
        wireFamily: String?,
        metadataClient: MetadataClient,
    ): CapabilityEvidenceFacade.InputCapabilityVerdict {
        val declared = provider.catalogModels.firstOrNull { it.id == model.id } ?: model
        val firstHand = declared.upstreamInputModalities
        val facts = if (firstHand == null) modelFacts(metadataClient, provider.kind, model)?.modalities?.input else null
        return inputVerdict(key, firstHand, facts, wireFamily)
    }

    /**
     * modelFacts of a subscription model: look up by model.id first, then by canonical id (when the subscription slug differs from the canonical one,
     * facts are registered only under the canonical id), the same rule as the Web subscription-truth-adapter.
     */
    internal fun modelFacts(
        metadataClient: MetadataClient,
        providerKind: ProviderKind,
        model: AIModel,
    ): MetadataClient.ModelFacts? =
        metadataClient.modelFacts(providerKind, model.id)
            ?: model.canonicalModelId?.takeIf { it.isNotBlank() }?.let { metadataClient.modelFacts(providerKind, it) }

    /** Declared medium names per input key (the same vocabulary as Codex `input_modalities` / models.dev `modalities.input`). */
    private val INPUT_MEDIA: Map<String, Set<String>> = mapOf(
        CapabilityEvidenceFacade.VISION_INPUT to setOf("image"),
        CapabilityEvidenceFacade.FILE_INPUT to setOf("file", "pdf"),
        CapabilityEvidenceFacade.VIDEO_INPUT to setOf("video"),
    )

    private fun owns(key: String): Boolean =
        key == CapabilityEvidenceFacade.VISION_INPUT || key == "web_search" || reasoningMode(key) != null

    private fun reasoningMode(key: String): ReasoningMode? {
        if (!key.startsWith(REASONING_PREFIX)) return null
        val raw = key.removePrefix(REASONING_PREFIX)
        return ReasoningMode.entries.firstOrNull { it != ReasoningMode.Automatic && it.rawValue == raw }
    }
}
