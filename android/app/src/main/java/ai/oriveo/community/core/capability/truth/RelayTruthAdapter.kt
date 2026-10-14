package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade

/**
 * Capability truth source for Relay: the user's local declarations on this connection.
 *
 * The criteria are moved over unchanged from `CapabilityEvidenceProductionAdapter`; override values come first. Runtime rejection observations are not here:
 * they are an overlay of the outbound policy and need the cache, so the caller appends them and the adapter stays a pure function.
 */
internal object RelayTruthAdapter : CapabilityTruthAdapter {
    override fun candidates(input: CapabilityTruthAdapter.Input): List<CapabilityEvidenceFacade.Candidate> =
        relayCandidates(input.provider, input.model, input.queryIdentity, input.key)

    private fun relayCandidates(
        provider: Provider,
        model: AIModel,
        queryIdentity: CapabilityEvidenceFacade.QueryIdentity?,
        key: String,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val query = queryIdentity ?: return relayUnscopedDeclaration(provider, model, key)
        val identity = CapabilityEvidenceFacade.CandidateIdentity(
            partitionId = query.partitionId,
            connectionInstanceId = query.connectionInstanceId,
            connectionGeneration = query.connectionGeneration,
            credentialEpoch = query.credentialEpoch,
            providerKind = query.providerKind,
            modelId = query.canonicalModelId ?: query.modelId,
            effectiveTransport = query.effectiveTransport,
            endpointFingerprint = query.endpointFingerprint,
            metadataRevision = query.metadataRevision,
            generationRevision = query.generationRevision,
        )
        if (key.startsWith("generation_parameter/")) {
            val id = key.substringAfter('/')
            val parameter = model.generationProfile?.parameters?.firstOrNull { it.id == id } ?: return emptyList()
            return listOfNotNull(
                CapabilityEvidenceFacade.normalizeGenerationParameter(
                    raw = parameter,
                    identity = identity,
                    source = "relay_declaration",
                ),
            )
        }
        return relayDeclaration(provider, model, key)?.let { support ->
            listOf(
                CapabilityEvidenceFacade.Candidate(
                    key = key,
                    support = candidateSupport(support),
                    source = "relay_declaration",
                    grade = candidateGrade(support),
                    scope = "connection_model_transport",
                    identity = identity,
                ),
            )
        }.orEmpty()
    }

    /** When scope is missing only the UI declaration is kept, and the facade will not authorize because the identity is incomplete. */
    private fun relayUnscopedDeclaration(
        provider: Provider,
        model: AIModel,
        key: String,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val support = relayDeclaration(provider, model, key) ?: return emptyList()
        return listOf(
            CapabilityEvidenceFacade.Candidate(
                key = key,
                support = candidateSupport(support),
                source = "relay_declaration",
                grade = candidateGrade(support),
                scope = "connection_model_transport",
                identity = CapabilityEvidenceFacade.CandidateIdentity(
                    providerKind = ProviderKind.Relay.rawValue,
                    modelId = model.canonicalModelId ?: model.id,
                    effectiveTransport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model).value,
                ),
            ),
        )
    }

    /** A user declaration can only be accepted (unverified) or unsupported; only local engine declarations and web probe searched yield supported. */
    private fun candidateSupport(declaration: String): String = when (declaration) {
        "supported", "unsupported" -> declaration
        else -> "unknown"
    }

    private fun candidateGrade(declaration: String): String =
        if (declaration == "accepted") "accepted_unverified" else "declared"

    /**
     * The local engine's declaration for this model: effective only when the connection has an engineProfile; keys whose declaration is null
     * fall through to the existing Relay rules below.
     */
    private fun engineDeclaration(provider: Provider, model: AIModel, key: String): String? {
        if (provider.relayRequested?.engineProfile.isNullOrBlank()) return null
        val declared = when (key) {
            "vision_input" -> model.engineDeclaration?.image
            "tool_call" -> model.engineDeclaration?.toolCall
            else -> null
        } ?: return null
        return if (declared) "supported" else "unsupported"
    }

    private fun relayDeclaration(provider: Provider, model: AIModel, key: String): String? =
        overrideDeclaration(model, key) ?: engineDeclaration(provider, model, key) ?: userDeclaration(provider, model, key)

    /**
     * Override values on the Model > Advanced page (`user` / `tested`) are the highest source for Relay vision / tools, overriding engine declarations and the other candidates.
     * A `tested` true means a passed real test; a `user` true is only the user's claim, unverified like a user declaration.
     */
    private fun overrideDeclaration(model: AIModel, key: String): String? {
        val overrides = model.relayCapabilityOverrides ?: return null
        val overrideKey = when (key) {
            "vision_input" -> "image"
            "tool_call" -> "toolCall"
            else -> return null
        }
        val value = (if (overrideKey == "image") overrides.image else overrides.toolCall) ?: return null
        return when {
            !value -> "unsupported"
            overrides.sourceOf(overrideKey) == RelayCapabilityOverrides.SOURCE_TESTED -> "supported"
            else -> "accepted"
        }
    }

    private fun userDeclaration(provider: Provider, model: AIModel, key: String): String? = when {
        key == "tool_call" -> when (model.toolCall) {
            false -> "unsupported"
            true -> "accepted"
            null -> null
        }
        key == "web_search" -> webSearchDeclaration(provider, model)
        key == "vision_input" && ModelCapability.Image in model.capabilities -> "accepted"
        key.startsWith("reasoning_level/") && model.reasoningModeAvailable &&
            !model.reasoningProfile.isNullOrBlank() -> "accepted"
        else -> null
    }

    /**
     * Relay web truth: when the first-send protocol has a connection-level segment (including read-time mapping of legacy fields), judge by the model x protocol
     * local probe record under the current segment: searched -> supported, rejected -> unsupported, silent / untested / stale hash -> unknown; no segment -> unknown.
     * Protocol and record lookup share one resolution with the model options panel relayWeb ([ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve]).
     */
    private fun webSearchDeclaration(provider: Provider, model: AIModel): String? {
        val transport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model).value
        val fragment = ai.oriveo.community.core.provider.relay.RelayWebFragmentStore.shared.effective(provider)[transport]
            ?: return null
        return when (
            ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.shared
                .currentResult(provider.id, model.id, transport, fragment)
        ) {
            ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Searched -> "supported"
            ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Rejected -> "unsupported"
            else -> null
        }
    }
}
