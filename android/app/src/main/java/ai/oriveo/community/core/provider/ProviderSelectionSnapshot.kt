package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

/**
 * Lightweight selection snapshot: it only reads the enabled, current and default models and
 * never falls back to the full catalog.
 */
object ProviderSelectionSnapshot {
    data class PersistedSelection(
        val model: AIModel?,
        val storedModelId: String,
    )

    fun enabledModels(provider: Provider?): List<AIModel> = provider?.models ?: emptyList()

    fun defaultModel(
        provider: Provider?,
        metadata: MetadataClient = MetadataClient.instance,
    ): AIModel? {
        val enabled = enabledModels(provider)
        if (enabled.isEmpty()) return null

        enabled.firstOrNull { it.isDefault }?.let { return it }

        if (provider != null && provider.kind != ProviderKind.Relay) {
            val metadataDefaultId = metadata.defaultModelId(provider.kind)
            if (!metadataDefaultId.isNullOrBlank()) {
                ModelSelectionUtils.matchingModel(enabled, metadataDefaultId)?.let { return it }
            }
        }

        return enabled.firstOrNull()
    }

    fun selectedModel(
        provider: Provider?,
        modelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): AIModel? {
        val targetId = modelId?.trim().orEmpty()
        if (provider == null || targetId.isEmpty()) return null

        val enabled = enabledModels(provider)
        if (enabled.isEmpty()) return null

        ModelSelectionUtils.matchingModel(enabled, targetId)?.let { return it }

        if (provider.kind != ProviderKind.Relay) {
            val resolved = metadata.resolveCatalogModel(targetId, provider.kind)
            val canonical = resolved?.canonicalModelId
            if (!canonical.isNullOrBlank()) {
                ModelSelectionUtils.matchingModel(enabled, canonical)?.let { return it }
                return metadataBackedHistoricalModel(
                    provider = provider,
                    resolved = resolved,
                    fallbackModelId = targetId,
                )
            }
        }

        return null
    }

    fun currentModel(
        provider: Provider?,
        storedModelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): AIModel? = selectedModel(provider, storedModelId, metadata) ?: defaultModel(provider, metadata)

    fun runtimeModelId(
        provider: Provider?,
        storedModelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): String? = selectedModel(provider, storedModelId, metadata)?.id ?: storedModelId?.trim()?.takeIf { it.isNotEmpty() }

    fun persistedSelection(
        provider: Provider?,
        requestedModelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): PersistedSelection? {
        val targetId = requestedModelId?.trim().orEmpty()
        if (targetId.isEmpty()) return null

        val model = selectedModel(provider, targetId, metadata)
        val storedModelId = model?.let(ModelSelectionUtils::preferredStoredModelIdentifier)
            ?: ModelSelectionUtils.resolvedId(targetId)

        return PersistedSelection(
            model = model,
            storedModelId = storedModelId,
        )
    }

    private fun metadataBackedHistoricalModel(
        provider: Provider,
        resolved: MetadataClient.ResolvedModelMetadata?,
        fallbackModelId: String,
    ): AIModel? {
        val metadataModel = resolved ?: return null
        val pricing = CatalogModelBuilder.pricePresentation(metadataModel)
        return AIModel(
            id = metadataModel.canonicalModelId,
            name = metadataModel.displayName ?: metadataModel.canonicalModelId,
            capabilities = metadataModel.capabilities.ifEmpty { listOf(ai.oriveo.community.core.model.ModelCapability.Text) },
            reasoningModeAvailable = metadataModel.profiles.reasoning != null,
            isAvailable = true,
            isDefault = metadataModel.isDefault,
            priceTier = pricing.priceTier,
            summary = compactContextText(metadataModel.contextLength),
            contextLength = metadataModel.contextLength,
            groupKey = metadataModel.uiHints?.groupKey,
            groupName = metadataModel.uiHints?.groupName,
            promptPrice = pricing.promptPrice,
            completionPrice = pricing.completionPrice,
            canonicalModelId = metadataModel.canonicalModelId,
            isRecommended = metadataModel.uiHints?.recommended ?: false,
            sortRank = metadataModel.uiHints?.rank,
            badgeOrder = metadataModel.uiHints?.badgeOrder,
            reasoningProfile = metadataModel.profiles.reasoning,
            webSearchProfile = metadataModel.profiles.webSearch,
            imageGenProfile = metadataModel.profiles.imageGen,
            toolCall = metadataModel.toolCall,
        )
    }

    private fun compactContextText(contextLength: Int?): String? {
        val value = contextLength ?: return null
        if (value <= 0) return null
        return when {
            value >= 1_000_000 -> "${value / 1_000_000}M"
            value >= 1_000 -> "${value / 1_000}K"
            else -> value.toString()
        }
    }
}
