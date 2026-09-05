package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

/**
 * Lightweight read path for display names: it resolves a provider name, a model
 * name and the canonical model id, and nothing else.
 *
 * Deliberately narrow: it never returns a full catalog, never triggers
 * [ProviderCatalogResolver], and knows nothing about recommendations, grouping or
 * enabled state.
 */
class ModelDisplayLookup(
    providers: List<Provider>,
    private val metadata: MetadataClient = MetadataClient.instance,
) {
    private val providersById = providers.associateBy { it.id }

    fun providerDisplayName(providerId: String?): String? =
        providerId?.let { providersById[it]?.displayName }

    fun modelDisplayName(
        providerId: String?,
        modelId: String?,
        fallback: String?,
    ): String? {
        val provider = providerId?.let { providersById[it] } ?: return fallback
        val targetId = modelId?.trim().orEmpty()
        if (targetId.isEmpty()) return fallback

        if (provider.kind == ProviderKind.Relay) {
            localModel(provider, targetId)?.name?.let { return it }
        } else {
            val metadataResolved = metadata.resolveCatalogModel(targetId, provider.kind)
            metadataResolved?.displayName?.takeIf { it.isNotBlank() }?.let { return it }
            metadataResolved?.canonicalModelId?.let { canonicalId ->
                localModel(provider, canonicalId)?.name?.let { return it }
                metadata.resolveCatalogModel(canonicalId, provider.kind)
                    ?.displayName
                    ?.takeIf { it.isNotBlank() }
                    ?.let { return it }
            }
            localModel(provider, targetId)?.name?.let { return it }
        }

        return fallback
    }

    fun canonicalModelId(
        providerId: String?,
        modelId: String?,
    ): String? {
        val provider = providerId?.let { providersById[it] } ?: return null
        val targetId = modelId?.trim().orEmpty()
        if (targetId.isEmpty()) return null

        localModel(provider, targetId)?.canonicalModelId?.takeIf { it.isNotBlank() }?.let { return it }
        localModel(provider, targetId)?.id?.let { return it }

        if (provider.kind != ProviderKind.Relay) {
            metadata.resolveCatalogModel(targetId, provider.kind)?.canonicalModelId?.let { return it }
        }

        return null
    }

    private fun localModel(provider: Provider, targetId: String): AIModel? {
        val localCandidates = if (provider.catalogModels.isNotEmpty()) {
            (provider.models + provider.catalogModels).distinctBy { it.id }
        } else {
            provider.models
        }
        return ModelSelectionUtils.matchingModel(localCandidates, targetId)
    }
}
