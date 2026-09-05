package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind

/**
 * The single catalog-model builder.
 *
 * Builds an AIModel from the published catalog metadata, falling back to the runtime values when
 * that metadata is unavailable. Every provider adapter shares this, so no adapter has to carry
 * its own hard-coded rules.
 */
object CatalogModelBuilder {

    fun buildCatalogModel(
        providerKind: ProviderKind,
        runtimeModelId: String,
        fallbackName: String,
        fallbackContextLength: Int? = null,
        fallbackSummary: String? = null,
        createdAt: Double? = null,
    ): AIModel {
        val metadata = MetadataClient.resolveCatalogModel(runtimeModelId, providerKind)
        val capabilities = metadata?.capabilities?.takeIf { it.isNotEmpty() }
            ?: listOf(ModelCapability.Text)
        val pricing = pricePresentation(metadata)
        val contextLength = metadata?.contextLength ?: fallbackContextLength

        return AIModel(
            id = runtimeModelId,
            canonicalModelId = metadata?.canonicalModelId,
            name = metadata?.displayName ?: fallbackName,
            capabilities = capabilities,
            reasoningModeAvailable = metadata?.profiles?.reasoning != null,
            isAvailable = true,
            isDefault = metadata?.isDefault ?: false,
            isRecommended = metadata?.uiHints?.recommended ?: false,
            priceTier = pricing.priceTier,
            summary = fallbackSummary ?: compactContextText(contextLength),
            contextLength = contextLength,
            maxOutputTokens = metadata?.maxOutputTokens,
            groupKey = metadata?.uiHints?.groupKey,
            groupName = metadata?.uiHints?.groupName,
            sortRank = metadata?.uiHints?.rank,
            badgeOrder = metadata?.uiHints?.badgeOrder,
            createdAt = createdAt,
            promptPrice = pricing.promptPrice,
            completionPrice = pricing.completionPrice,
            billingSku = metadata?.billingSku,
            pricingUnit = metadata?.pricingUnit ?: "per_token",
            sourceSummary = metadata?.sourceSummary,
            costPerUnit = metadata?.costPerUnit,
            costInputBatches = metadata?.costInputBatches,
            costOutputBatches = metadata?.costOutputBatches,
            costInputPriority = metadata?.costInputPriority,
            costOutputPriority = metadata?.costOutputPriority,
            cacheReadInputPerMToken = metadata?.cacheReadInputPerMToken,
            cacheCreationInputPerMToken = metadata?.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken = metadata?.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken = metadata?.cacheWrite1hPerMToken,
            supportsPdfInput = metadata?.supportsPdfInput == true,
            supportsServiceTier = metadata?.supportsServiceTier == true,
            reasoningProfile = metadata?.profiles?.reasoning,
            webSearchProfile = metadata?.profiles?.webSearch,
            imageGenProfile = metadata?.profiles?.imageGen,
            generationProfile = metadata?.profiles?.generation,
            // Deliberately left null when the catalog does not list this model: that means
            // "cannot tell", which is not the same as "not supported".
            toolCall = metadata?.toolCall,
        )
    }

    /**
     * Refreshes a stored model's capabilities, pricing and related fields from the latest
     * catalog metadata. Called at startup so persisted models keep up with the published
     * catalog.
     */
    fun enrichStoredModel(
        model: AIModel,
        providerKind: ProviderKind,
    ): AIModel {
        val metadata = MetadataClient.resolveCatalogModel(model.id, providerKind) ?: return model

        val capabilities = metadata.capabilities.takeIf { it.isNotEmpty() } ?: model.capabilities
        val pricing = pricePresentation(metadata)

        return model.copy(
            canonicalModelId = metadata.canonicalModelId ?: model.canonicalModelId,
            name = metadata.displayName ?: model.name,
            capabilities = capabilities,
            reasoningModeAvailable = metadata.profiles?.reasoning != null,
            isRecommended = metadata.uiHints?.recommended == true,
            priceTier = pricing.priceTier,
            summary = model.summary ?: compactContextText(metadata.contextLength ?: model.contextLength),
            groupKey = metadata.uiHints?.groupKey,
            groupName = metadata.uiHints?.groupName,
            sortRank = metadata.uiHints?.rank,
            badgeOrder = metadata.uiHints?.badgeOrder,
            promptPrice = pricing.promptPrice,
            completionPrice = pricing.completionPrice,
            billingSku = metadata.billingSku,
            pricingUnit = metadata.pricingUnit,
            sourceSummary = metadata.sourceSummary,
            costPerUnit = metadata.costPerUnit,
            costInputBatches = metadata.costInputBatches,
            costOutputBatches = metadata.costOutputBatches,
            costInputPriority = metadata.costInputPriority,
            costOutputPriority = metadata.costOutputPriority,
            cacheReadInputPerMToken = metadata.cacheReadInputPerMToken,
            cacheCreationInputPerMToken = metadata.cacheCreationInputPerMToken,
            cacheWrite5mPerMToken = metadata.cacheWrite5mPerMToken,
            cacheWrite1hPerMToken = metadata.cacheWrite1hPerMToken,
            supportsPdfInput = metadata.supportsPdfInput,
            supportsServiceTier = metadata.supportsServiceTier,
            contextLength = metadata.contextLength ?: model.contextLength,
            maxOutputTokens = metadata.maxOutputTokens ?: model.maxOutputTokens,
            reasoningProfile = metadata.profiles?.reasoning,
            webSearchProfile = metadata.profiles?.webSearch,
            imageGenProfile = metadata.profiles?.imageGen,
            // When the catalog does have an entry, a null here is an authoritative withdrawal;
            // the old profile must not be left behind in the local snapshot.
            generationProfile = metadata.profiles?.generation,
            // On a v2 catalog hit an explicit null is an authoritative unknown and has to clear
            // the previous verdict. Only a missing version or v1 keeps the historical fallback,
            // so behaviour does not change abruptly while the catalog is mid-upgrade.
            toolCall = if (metadata.capabilityContractVersion >= 2) {
                metadata.toolCall
            } else {
                metadata.toolCall ?: model.toolCall
            },
        )
    }

    fun pricePresentation(
        metadata: MetadataClient.ResolvedModelMetadata?,
    ): PricingPresentation {
        if (metadata == null) {
            return PricingPresentation()
        }

        return when (metadata.pricingStatus) {
            "priced" -> {
                if (metadata.pricingUnit != "per_token") {
                    PricingPresentation(priceTier = "Non-standard billing")
                } else {
                    PricingPresentation(
                        priceTier = ModelPricingFormatter.formatPerMillion(
                            metadata.promptPerToken,
                            metadata.completionPerToken,
                        ),
                        promptPrice = metadata.promptPerToken,
                        completionPrice = metadata.completionPerToken,
                    )
                }
            }
            "free" -> PricingPresentation(
                priceTier = "Free",
                promptPrice = 0.0,
                completionPrice = 0.0,
            )
            else -> PricingPresentation(priceTier = "Price unknown")
        }
    }

    data class PricingPresentation(
        val priceTier: String = "",
        val promptPrice: Double? = null,
        val completionPrice: Double? = null,
    )

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
