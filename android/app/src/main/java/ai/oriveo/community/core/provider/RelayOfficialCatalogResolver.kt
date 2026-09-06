package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

/**
 * Enriches a relay's locally discovered models from the published model catalog.
 *
 * The rules:
 *   - every entry in `provider.catalogModels` is looked up across the known providers
 *     (`resolveCatalogModelAcrossProvidersWithProvider`)
 *   - on a hit, merge displayName / canonicalModelId / capabilities / profiles / uiHints
 *   - the resulting capabilities are the intersection of the catalog's capabilities with
 *     `relayRuntimeConfig.transportEnvelopes[transport]`, because a relay can only really do what
 *     both the model and the transport it is reached through support
 *   - a profile is kept only when the final capability set still contains the matching feature
 *   - on a miss the local model is left exactly as it is; catalog capabilities are never invented
 */
object RelayOfficialCatalogResolver {

    fun enrich(
        localModel: AIModel,
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
        metadata: MetadataClient = MetadataClient.instance,
    ): AIModel {
        // `model.isManual` is the single source of truth, but data written by older clients may
        // still encode the manual marker as a `relay-manual-` id prefix, so both are accepted.
        // A manual model takes the `enrichManualOfficialPricing` path, which merges pricing only
        // and leaves the user-entered fields alone, so the catalog cannot overwrite what the user
        // typed in by hand.
        val isRelayManualModel = localModel.isManual ||
            localModel.id.trim().startsWith("relay-manual-")
        val priority = RelayRuntimeSupport.transportProviderKind(provider)
        val match = metadata.resolveCatalogModelAcrossProvidersWithProvider(
            modelID = resolvedRelayModelId(localModel.id),
            transportPriority = priority,
        ) ?: return localModel

        if (isRelayManualModel) {
            return enrichManualOfficialPricing(localModel, match)
        }

        val envelope = RelayRuntimeSupport.envelopeKey(provider)?.let { key ->
            runtimeConfig.transportEnvelopes[key]
        }
        val officialCaps = match.metadata.capabilities.ifEmpty { listOf(ModelCapability.Text) }
        val autoCaps = intersectCapabilities(officialCaps, envelope)
        val mergedCaps = mergeCapabilities(autoCaps, localModel.capabilities)
        val safeCaps = if (mergedCaps.isEmpty()) listOf(ModelCapability.Text) else mergedCaps

        val reasoningProfile = if (ModelCapability.Reasoning in safeCaps) {
            match.metadata.profiles.reasoning
        } else null
        val webSearchProfile = if (ModelCapability.Web in safeCaps) {
            match.metadata.profiles.webSearch
        } else null
        val imageGenProfile = if (ModelCapability.ImageGen in safeCaps) {
            match.metadata.profiles.imageGen
        } else null

        val pricing = CatalogModelBuilder.pricePresentation(match.metadata)

        val uiHints = match.metadata.uiHints
        return localModel.copy(
            name = match.metadata.displayName ?: localModel.name,
            capabilities = safeCaps,
            reasoningModeAvailable = ModelCapability.Reasoning in safeCaps && reasoningProfile != null,
            canonicalModelId = match.canonicalModelId,
            isRecommended = uiHints?.recommended == true || localModel.isRecommended,
            sortRank = uiHints?.rank ?: localModel.sortRank,
            groupKey = uiHints?.groupKey ?: localModel.groupKey,
            groupName = uiHints?.groupName ?: localModel.groupName,
            badgeOrder = uiHints?.badgeOrder?.filter { it in safeCaps && it != ModelCapability.Text }
                ?: localModel.badgeOrder,
            priceTier = pricing.priceTier.ifEmpty { localModel.priceTier },
            promptPrice = pricing.promptPrice ?: localModel.promptPrice,
            completionPrice = pricing.completionPrice ?: localModel.completionPrice,
            contextLength = match.metadata.contextLength ?: localModel.contextLength,
            reasoningProfile = reasoningProfile,
            webSearchProfile = webSearchProfile,
            imageGenProfile = imageGenProfile,
            // Once the catalog has matched, we do not fall back to the relay's previously stored
            // profile: a null here means the catalog has withdrawn that capability.
            generationProfile = match.metadata.profiles.generation,
        )
    }

    private fun resolvedRelayModelId(modelId: String): String {
        val trimmed = modelId.trim()
        return if (trimmed.startsWith("relay-manual-")) {
            trimmed.removePrefix("relay-manual-")
        } else {
            trimmed
        }
    }

    private fun enrichManualOfficialPricing(
        localModel: AIModel,
        match: MetadataClient.RelayCatalogMatchResult,
    ): AIModel {
        val pricing = CatalogModelBuilder.pricePresentation(match.metadata)
        return localModel.copy(
            canonicalModelId = match.canonicalModelId,
            priceTier = pricing.priceTier.ifEmpty { localModel.priceTier },
            promptPrice = pricing.promptPrice ?: localModel.promptPrice,
            completionPrice = pricing.completionPrice ?: localModel.completionPrice,
            billingSku = match.metadata.billingSku ?: localModel.billingSku,
            pricingUnit = match.metadata.pricingUnit,
            sourceSummary = match.metadata.sourceSummary ?: localModel.sourceSummary,
            costPerUnit = match.metadata.costPerUnit ?: localModel.costPerUnit,
            costInputBatches = match.metadata.costInputBatches ?: localModel.costInputBatches,
            costOutputBatches = match.metadata.costOutputBatches ?: localModel.costOutputBatches,
            costInputPriority = match.metadata.costInputPriority ?: localModel.costInputPriority,
            costOutputPriority = match.metadata.costOutputPriority ?: localModel.costOutputPriority,
            cacheReadInputPerMToken = match.metadata.cacheReadInputPerMToken ?: localModel.cacheReadInputPerMToken,
            cacheCreationInputPerMToken = match.metadata.cacheCreationInputPerMToken ?: localModel.cacheCreationInputPerMToken,
        )
    }

    fun enrichCatalog(
        provider: Provider,
        runtimeConfig: MetadataClient.RelayRuntimeConfig,
        metadata: MetadataClient = MetadataClient.instance,
    ): List<AIModel> {
        return provider.catalogModels.map { localModel ->
            enrich(localModel, provider, runtimeConfig, metadata)
        }
    }

    /**
     * Whole-provider enrichment: enriches both `catalogModels` and `models`.
     * Every path that writes a provider to the database (ProviderRepository, SyncManager,
     * BackupService and so on) must go through this function, otherwise half the stored models
     * end up enriched and half do not.
     */
    fun applyRelayEnrichmentIfNeeded(
        provider: Provider,
        metadata: MetadataClient = MetadataClient.instance,
    ): Provider {
        if (provider.kind != ProviderKind.Relay) return provider
        val runtimeConfig = metadata.relayRuntimeConfig()
        return provider.copy(
            catalogModels = provider.catalogModels.map { enrich(it, provider, runtimeConfig, metadata) },
            models = provider.models.map { enrich(it, provider, runtimeConfig, metadata) },
        )
    }

    // ── Capability Intersection ──

    private fun intersectCapabilities(
        capabilities: List<ModelCapability>,
        envelope: MetadataClient.RelayTransportEnvelope?,
    ): List<ModelCapability> {
        if (envelope == null) return capabilities
        return capabilities.filter { envelopeAllows(envelope, it) }
    }

    private fun mergeCapabilities(
        base: List<ModelCapability>,
        add: List<ModelCapability>,
    ): List<ModelCapability> {
        val seen = linkedSetOf<ModelCapability>()
        seen.addAll(base)
        seen.addAll(add)
        return seen.toList()
    }

    private fun envelopeAllows(
        envelope: MetadataClient.RelayTransportEnvelope,
        capability: ModelCapability,
    ): Boolean = when (capability) {
        ModelCapability.Image -> envelope.image
        ModelCapability.Video -> false
        ModelCapability.File -> envelope.nativeFile || envelope.textFileInline
        ModelCapability.Web -> envelope.webSearch
        ModelCapability.ImageGen -> envelope.imageGeneration
        ModelCapability.Reasoning -> envelope.reasoning
        ModelCapability.ToolCall -> false
        ModelCapability.Text -> true
        ModelCapability.NativePdf -> envelope.nativeFile   // native_pdf = subset of nativeFile
        ModelCapability.Unknown -> false
    }
}
