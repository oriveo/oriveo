package ai.oriveo.community.core.provider

import androidx.compose.runtime.Stable
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapLatest

/**
 * Lightweight read path for display names: it resolves a provider name, a model
 * name and the canonical model id, and nothing else.
 *
 * Deliberately narrow: it never returns a full catalog, never triggers
 * [ProviderCatalogResolver], and knows nothing about recommendations, grouping or
 * enabled state.
 *
 * Every conversation row on Home and every message in a chat asks it once, and a relay
 * catalog comes from the user's own server (a public catalog can hold 22,000 models). So
 * each provider's local model index is built once per instance and every row after that is
 * a lookup instead of a scan. Screens get instances from [modelDisplayLookups], which builds
 * one per providers emission in the background and [prewarm]s it, so composition only reads a
 * finished one; the indexes go away with the instance and never answer from an old catalog.
 *
 * The indexes are internal memoization that changes no observable result, so the class is
 * still stable for Compose.
 */
@Stable
class ModelDisplayLookup private constructor(
    providers: List<Provider>,
    private val metadata: MetadataClient,
    /** False only for [Pending]: the screen has no lookup built from any emission yet, and callers must not show its fallback as a display name. */
    val isReady: Boolean,
) {
    constructor(
        providers: List<Provider>,
        metadata: MetadataClient = MetadataClient.instance,
    ) : this(providers, metadata, isReady = true)

    private val providersById = providers.associateBy { it.id }
    private val localIndexes = HashMap<String, ModelSelectionUtils.CatalogMatchIndex>()
    private val enabledIndexes = HashMap<String, ModelSelectionUtils.CatalogMatchIndex>()

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

    /**
     * Returns exactly what `ProviderSelectionSnapshot.selectedModel(provider, modelId, metadata)` returns, looking
     * enabled models up in this instance's index. After "add all" the enabled models are the whole relay catalog,
     * and comparing them one by one for every row grows with the catalog. When [provider] is not the object this
     * instance indexed (the caller holds another emission), it falls back to the one-by-one comparison.
     */
    fun selectedModel(
        provider: Provider,
        modelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): AIModel? {
        if (providersById[provider.id] !== provider) {
            return ProviderSelectionSnapshot.selectedModel(provider, modelId, metadata)
        }
        return ProviderSelectionSnapshot.selectedModel(provider, modelId, metadata) { _, targetId ->
            enabledIndex(provider).match(targetId)
        }
    }

    /** Builds every provider's local and enabled indexes (fuzzy layer included) now. Call it off the main thread; queries after that are table lookups. */
    fun prewarm() {
        providersById.values.forEach { provider ->
            localIndex(provider).prewarm()
            enabledIndex(provider).prewarm()
        }
    }

    /** Returns exactly what `matchingModel(localCandidates, targetId)` returns, with the same candidates in the same order. */
    private fun localModel(provider: Provider, targetId: String): AIModel? =
        localIndex(provider).match(targetId)

    private fun localIndex(provider: Provider): ModelSelectionUtils.CatalogMatchIndex = synchronized(localIndexes) {
        localIndexes.getOrPut(provider.id) {
            val localCandidates = if (provider.catalogModels.isNotEmpty()) {
                (provider.models + provider.catalogModels).distinctBy { it.id }
            } else {
                provider.models
            }
            ModelSelectionUtils.catalogMatchIndex(localCandidates)
        }
    }

    private fun enabledIndex(provider: Provider): ModelSelectionUtils.CatalogMatchIndex = synchronized(enabledIndexes) {
        enabledIndexes.getOrPut(provider.id) {
            ModelSelectionUtils.catalogMatchIndex(ProviderSelectionSnapshot.enabledModels(provider))
        }
    }

    companion object {
        /** Placeholder until a lookup has been built from any emission. */
        val Pending: ModelDisplayLookup by lazy { ModelDisplayLookup(emptyList(), MetadataClient.instance, isReady = false) }
    }
}

/**
 * Builds a [ModelDisplayLookup] for each providers emission on [dispatcher] and calls [ModelDisplayLookup.prewarm], so
 * Home, folders and chat only read a finished lookup during composition. Indexing a 22k relay catalog takes tens of
 * milliseconds of CPU, which the first row used to pay on the main thread after `remember(providers)`. A new emission
 * discards an unfinished older build.
 */
@OptIn(ExperimentalCoroutinesApi::class)
fun Flow<List<Provider>>.modelDisplayLookups(
    dispatcher: CoroutineDispatcher = Dispatchers.Default,
): Flow<ModelDisplayLookup> = mapLatest { providers ->
    ModelDisplayLookup(providers).also { it.prewarm() }
}.flowOn(dispatcher)
