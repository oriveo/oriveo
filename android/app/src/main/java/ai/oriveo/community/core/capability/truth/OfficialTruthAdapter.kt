package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Capability truth source for official providers: the metadata published by the Server (typed candidates first, then legacy fields);
 * when the model is not in the catalog, only `tool_call` falls back to the model's own declaration and model facts.
 *
 * Web exception: without typed candidates only the Server recipe verdict (`capabilityControls.web.state`) is trusted,
 * and the legacy capabilities / webSearch profile are not read (the contract `rules.official.web_search`).
 */
internal object OfficialTruthAdapter : CapabilityTruthAdapter {
    /** Whether thinking is shown: the catalog entry capabilities include reasoning; when the catalog lacks this model, read reasoning from the model facts, and false if that is missing too. */
    override fun thinking(input: CapabilityTruthAdapter.FactInput): Boolean {
        val entry = input.metadataClient.currentCapabilityEvidenceModel(input.model.id, input.provider.kind)
        if (entry != null) return ModelCapability.Reasoning in entry.metadata.capabilities
        return input.metadataClient.modelFacts(input.provider.kind, input.model.id)?.reasoning == true
    }

    override fun candidates(input: CapabilityTruthAdapter.Input): List<CapabilityEvidenceFacade.Candidate> {
        val provider = input.provider
        val persistedModel = input.model
        val current = input.current
        val queryIdentity = input.queryIdentity
        val key = input.key
        val finalTransport = input.finalTransport
        val metadataClient = input.metadataClient
        if (current == null) {
            // For API Key models outside the catalog (hand-entered / delisted), only tool_call falls back to the model's own declaration and model facts;
            // the same fallback for the subscription form lives in [SubscriptionTruthAdapter]; this one serves the official form only.
            if (key != "tool_call" || queryIdentity == null) return emptyList()
            val firstParty = persistedModel.toolCall
            val modelFact = if (firstParty == null) {
                metadataClient.modelFacts(provider.kind, persistedModel.id)?.toolCall
            } else {
                null
            }
            val support = firstParty ?: modelFact ?: return emptyList()
            return listOf(
                CapabilityEvidenceFacade.Candidate(
                    key = key,
                    support = if (support) "supported" else "unsupported",
                    source = if (firstParty != null) "server_profile" else "model_facts",
                    grade = if (firstParty != null) "declared" else "external_declared",
                    scope = "provider_model_transport",
                    identity = CapabilityEvidenceFacade.CandidateIdentity(
                        providerKind = provider.kind.rawValue,
                        modelId = MetadataClient.normalizeModelFactsID(persistedModel.id),
                        effectiveTransport = queryIdentity.effectiveTransport,
                        metadataRevision = queryIdentity.metadataRevision,
                    ),
                ),
            )
        }
        val safe = current.metadata.capabilityEvidenceCandidates.orEmpty()
            .filter { it.key == key }
            .map(::facadeCandidate)
        if (current.metadata.capabilityEvidenceViewMalformed == true && isGovernedCapabilityKey(key)) {
            return emptyList()
        }
        // Three-state namespace for tool_call: presence is authoritative, and an empty list or only expired candidates both mean unknown, so the top-level `toolCall` is not revived.
        // When the view is absent (null), only an older server with a missing or v1 capability contract version may fall back to legacy; a server at >= 2 omits the view key
        // for models without evidence, which means unknown (the same threshold as iOS authoritativeCapabilityContractVersion).
        if (key == "tool_call" &&
            (current.metadata.capabilityEvidenceCandidates != null || current.metadata.capabilityContractVersion >= 2)
        ) {
            return safe
        }
        if (safe.isNotEmpty() || current.metadata.capabilityEvidenceOwnedKeys?.contains(key) == true) return safe
        return officialLegacyCandidates(provider, current, persistedModel, key, finalTransport)
    }

    private fun officialLegacyCandidates(
        provider: Provider,
        current: MetadataClient.CurrentCapabilityEvidenceModel,
        persistedModel: AIModel,
        key: String,
        finalTransport: String?,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val model = current.metadata
        val transport = model.transport ?: finalTransport ?: return emptyList()
        val identity = CapabilityEvidenceFacade.CandidateIdentity(
            providerKind = provider.kind.rawValue,
            modelId = model.canonicalModelId,
            effectiveTransport = transport,
            metadataRevision = current.metadataRevision,
            generationRevision = current.generationRevision,
        )
        if (key.startsWith("generation_parameter/")) {
            val id = key.substringAfter('/')
            // `supportsTemperature: false` in the catalog is an explicit negative conclusion from the Server and must enter the facade as
            // an `unsupported` candidate. What the ruling relaxed is "we have no evidence",
            // not "the Server said unsupported"; if it were not a candidate, a temperature explicitly set by the user would be sent out anyway.
            if (id == "temperature" && model.supportsTemperature == false) {
                return listOf(
                    CapabilityEvidenceFacade.Candidate(
                        key = key,
                        support = "unsupported",
                        source = "server_profile",
                        grade = "declared",
                        scope = "provider_model_transport",
                        identity = identity,
                    ),
                )
            }
            val parameter = model.profiles.generation?.parameters?.firstOrNull { it.id == id } ?: return emptyList()
            return listOfNotNull(
                CapabilityEvidenceFacade.normalizeGenerationParameter(
                    raw = parameter,
                    identity = identity,
                    scope = "provider_model_transport",
                ),
            )
        }
        if (key == "web_search") {
            // Whether web can be used is decided by the recipe verdict: a web mention in capabilities or an attached webSearch profile
            // does not mean this transport has an executable web recipe.
            val state = ((model.capabilityControls?.get("web") as? JsonObject)?.get("state") as? JsonPrimitive)
                ?.contentOrNull
            // When the verdict reaches no conclusion (custom-only reachable, unknown, not delivered), no candidate is produced and "unknown" gets no source.
            val support = CapabilityControlResolution.evidenceSupport(state)
            if (support == "unknown") return emptyList()
            return listOf(
                CapabilityEvidenceFacade.Candidate(
                    key = key,
                    support = support,
                    source = "server_profile",
                    grade = "declared",
                    scope = "provider_model_transport",
                    identity = identity,
                ),
            )
        }
        val support = when {
            key == "tool_call" -> when (model.toolCall) {
                true -> "supported"
                false -> "unsupported"
                null -> "unknown"
            }
            // Vision input trusts only the Server recipe verdict: a missing key is unknown, and Image in capabilities is no longer consulted.
            key == CapabilityEvidenceFacade.VISION_INPUT -> CapabilityControlResolution.evidenceSupport(
                ((model.capabilityControls?.get(CapabilityEvidenceFacade.VISION_INPUT) as? JsonObject)?.get("state") as? JsonPrimitive)
                    ?.contentOrNull,
            )
            key.startsWith("reasoning_level/") -> if (
                key.substringAfter('/') in current.declaredReasoningLevels
            ) "supported" else "unknown"
            else -> return emptyList()
        }
        return listOf(
            CapabilityEvidenceFacade.Candidate(
                key = key,
                support = support,
                source = "legacy_metadata",
                grade = "legacy_unverified",
                scope = "provider_model_transport",
                identity = identity,
            ),
        )
    }

    /** When the whole public namespace is malformed, no capability key may be revived from legacy metadata. */
    private fun isGovernedCapabilityKey(key: String): Boolean =
        key in setOf("tool_call", "web_search", CapabilityEvidenceFacade.VISION_INPUT) ||
            key.startsWith("generation_parameter/") ||
            key.startsWith("reasoning_level/")

    private fun facadeCandidate(raw: MetadataClient.CapabilityEvidenceCandidateView) =
        CapabilityEvidenceFacade.Candidate(
            key = raw.key,
            support = raw.support,
            source = raw.source,
            grade = raw.grade,
            scope = raw.scope,
            identity = CapabilityEvidenceFacade.CandidateIdentity(
                providerKind = raw.providerKind,
                modelId = raw.modelId,
                effectiveTransport = raw.transport,
                metadataRevision = raw.metadataRevision,
                generationRevision = raw.generationRevision,
            ),
            observedAt = raw.observedAt,
            expiresAt = raw.expiresAt,
        )
}
