package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.relayAnthropicThinkingFields
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.transport.parseJsonObjectOrNull

/**
 * Predicts, while thinking is on, which parameter rows in the advanced settings will not be sent; the prediction and the outbound path share one source.
 *
 * The thinking body comes from the same writer as the send path (official connections read the capability recipe, relays read the same thinking decision as the builder),
 * and the drop decision is the very function the outbound guard in [GenerationParameterResolver] uses. This class never decides whether thinking is on
 * and never copies the tier ladder.
 */
internal object GenerationParameterThinkingPreview {
    fun dropped(
        provider: Provider,
        modelID: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
        relayProfile: GenerationProfileRef? = null,
        relayProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
    ): List<GenerationParameterResolver.DroppedParameter> = when {
        provider.kind == ProviderKind.Anthropic -> officialAnthropic(modelID, reasoningMode, requestOptions)
        // The criterion reads only the connection's protocol field, never the model name: the same model on the Chat Completions protocol gets no preview.
        provider.kind == ProviderKind.Relay && provider.relayRequested?.transport == RelayTransport.AnthropicMessages ->
            relayAnthropic(modelID, reasoningMode, requestOptions, relayProfile, relayProjection)
        // Other protocols have no such interplay.
        else -> emptyList()
    }

    private fun officialAnthropic(
        modelID: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
    ): List<GenerationParameterResolver.DroppedParameter> {
        // A preview is not a send: no execution fact is recorded.
        val runtime = applyCapabilityRuntimeRecipes(
            bodyJson = "{}",
            providerKind = ProviderKind.Anthropic,
            modelID = modelID,
            finalTransport = TransportKind.AnthropicMessages.wireValue,
            webRequested = false,
            reasoningMode = reasoningMode,
            requestOptions = requestOptions.copy(capabilityExecutionCollector = null),
        )
        val body = parseJsonObjectOrNull(runtime.body) ?: return emptyList()
        val profile = MetadataClient.resolveCatalogModel(modelID, ProviderKind.Anthropic)?.profiles?.generation
        return GenerationParameterResolver.previewAnthropicThinkingDrops(body, requestOptions.generationParameters, profile)
    }

    private fun relayAnthropic(
        modelID: String,
        reasoningMode: ReasoningMode,
        requestOptions: ChatRequestOptions,
        profile: GenerationProfileRef?,
        projection: CapabilityEvidenceProductionAdapter.Projection?,
    ): List<GenerationParameterResolver.DroppedParameter> {
        // No stored tier, or automatic: the builder sends no thinking, so there is nothing to preview.
        val fields = relayAnthropicThinkingFields(modelID, reasoningMode, requestOptions, projection) ?: return emptyList()
        val body = parseJsonObjectOrNull("{$fields}") ?: return emptyList()
        return GenerationParameterResolver.previewAnthropicThinkingDrops(
            body,
            requestOptions.generationParameters,
            profile ?: requestOptions.activeModel?.generationProfile,
        )
    }
}
