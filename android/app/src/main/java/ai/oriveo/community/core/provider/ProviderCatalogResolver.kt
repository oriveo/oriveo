package ai.oriveo.community.core.provider

import androidx.annotation.VisibleForTesting
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.transport.TransportKind
import java.util.concurrent.atomic.AtomicInteger

/** Resolved state of a single model. */
data class ResolvedModel(
    val model: AIModel,
    val isEnabled: Boolean,
    val isManual: Boolean,
)

/** A provider's resolved model catalog: the published catalog combined with the user's own state. */
data class ResolvedProviderCatalog(
    val catalog: List<ResolvedModel>,
    val enabledModels: List<ResolvedModel>,
    val recommendedModels: List<ResolvedModel>,
    val defaultModel: ResolvedModel?,
    val availableModelCount: Int,
    val hasManualModels: Boolean,
)

/**
 * Full preprocessing that every path writing a Provider to the database must go
 * through. It does two things:
 *   1. `applyRelayEnrichment`, folding catalog prices and capabilities into
 *      catalogModels and models
 *   2. caches the model count as `cachedAvailableModelCount`
 *
 * Callers are every dao.upsert site: the provider repository, backup restore, the
 * login coordinator, the benchmark seed receiver and so on.
 */
fun prepareProviderForUpsert(
    provider: Provider,
    metadata: MetadataClient = MetadataClient.instance,
): Provider {
    val enriched = RelayOfficialCatalogResolver.applyRelayEnrichmentIfNeeded(provider, metadata)
    val resolved = ProviderCatalogResolver.resolve(enriched)
    return enriched.copy(cachedAvailableModelCount = resolved.availableModelCount)
}

/**
 * Resolves a provider's model catalog. Pure function, no side effects.
 *
 * The published catalog held by MetadataClient is the source of truth; it is combined
 * with the provider's locally enabled models to produce a ResolvedProviderCatalog.
 * Relay is the exception and uses the locally stored catalogModels instead.
 */
object ProviderCatalogResolver {
    private val debugResolveCounter = AtomicInteger(0)

    /** Test-only: drops the process-level state this object accumulates so one test class cannot leak into the next. */
    @VisibleForTesting
    fun resetForTest() {
        debugResolveCounter.set(0)
    }

    @get:JvmStatic
    @set:JvmStatic
    var debugResolveCallCount: Int
        get() = debugResolveCounter.get()
        set(value) {
            debugResolveCounter.set(value.coerceAtLeast(0))
        }

    /**
     * Resolves the complete model catalog for a provider.
     *
     * 1. Relay uses `provider.catalogModels`, which the user defined themselves
     * 2. every other provider takes its model list from MetadataClient, falling back to
     *    local data when the catalog is unavailable
     * 3. enabled state comes from `provider.models`
     * 4. manual models are the ones in `provider.models` that match no catalog entry
     * 5. recommendations are isRecommended && !isEnabled, sorted by sortRank descending
     * 6. the default model is the user's own choice, else the catalog's defaultModelId,
     *    else the first enabled model
     */
    fun resolve(provider: Provider, metadata: MetadataClient = MetadataClient.instance): ResolvedProviderCatalog {
        debugResolveCounter.incrementAndGet()
        val catalogModels = buildCatalogModels(provider, metadata)
        val enabledIds = buildEnabledIdSet(provider, catalogModels, metadata)
        val manualModels = buildManualModels(provider, catalogModels, provider.kind)

        // Assemble the full catalog.
        val catalog = catalogModels.map { model ->
            ResolvedModel(
                model = model,
                isEnabled = model.id in enabledIds,
                isManual = false,
            )
        } + manualModels.map { model ->
            ResolvedModel(
                model = model,
                isEnabled = true,
                isManual = true,
            )
        }

        val enabledModels = catalog.filter { it.isEnabled }

        // Recommendations: flagged as recommended, not yet enabled, highest sortRank first.
        val recommendedModels = catalog.filter { resolved ->
            resolved.model.isRecommended && !resolved.isEnabled
        }.sortedByDescending { it.model.sortRank ?: 0 }

        // Default model resolution chain.
        val defaultModel = resolveDefaultModel(
            provider = provider,
            enabledModels = enabledModels,
            catalog = catalog,
            metadata = metadata,
        )

        return ResolvedProviderCatalog(
            catalog = catalog,
            enabledModels = enabledModels,
            recommendedModels = recommendedModels,
            defaultModel = defaultModel,
            availableModelCount = catalog.count { it.model.isAvailable },
            hasManualModels = manualModels.isNotEmpty(),
        )
    }

    // ---- internals ----

    /**
     * Produces the catalog model list.
     *
     * - Relay is the exception and keeps using the local `provider.catalogModels`, which
     *   is the only legitimate way a user-defined catalog enters the app.
     * - For every other provider the published catalog is the single source of truth:
     *   - when the catalog declares a contract version this build cannot honour
     *     (`isContractVersionDegraded`), expanding the catalog is forbidden even though
     *     the catalog did load, and an empty list is returned. Models the user had
     *     already enabled survive because `buildManualModels` keeps rendering them as
     *     manual-retained entries.
     *   - when the catalog is loaded and the contract is supported, the catalog is built
     *     from its canonical ids
     *   - when the catalog is unavailable, either on a cold first launch with no cache or
     *     after a failed load, falling back to `provider.catalogModels` is NOT allowed;
     *     during that window `buildManualModels` alone carries the user's enabled models
     */
    private fun buildCatalogModels(provider: Provider, metadata: MetadataClient): List<AIModel> {
        if (provider.kind == ProviderKind.Relay) {
            // Relay: enrich the local catalogModels with catalog data where the ids match,
            // merging display metadata and capabilities and intersecting the transports.
            val runtimeConfig = metadata.relayRuntimeConfig()
            return RelayOfficialCatalogResolver.enrichCatalog(provider, runtimeConfig, metadata)
        }

        // Subscription instances: the catalog truth is the subscription link itself,
        // which fetches live and writes the result into catalogModels, not the published
        // catalog. Measured against the real thing, the two sets do not overlap at all: the
        // subscription only accepts grok-4.6 and grok-4.5, while the published catalog
        // lists grok-4.3, grok-code-fast-1 and friends. Without this branch the model
        // library would show a subscription user a whole page of models, every one of
        // which fails the moment it is selected, with an error nobody can interpret.
        // When the fetch fails catalogModels is empty and we honestly return an empty
        // catalog; lastError is what tells the user to resync.
        if (provider.authMode == ProviderAuthMode.Subscription) {
            return provider.catalogModels
        }

        // Safe degradation: a catalog contract version too far ahead of this build stops
        // the catalog from being expanded at all.
        if (metadata.isContractVersionDegraded) {
            return emptyList()
        }

        val metadataIds = metadata.providerModelIds(provider.kind)
        if (metadataIds.isEmpty()) {
            // Catalog unavailable: return an empty list. Models the user already enabled
            // stay visible as manual-retained entries via buildManualModels, and the UI
            // distinguishes the resulting states.
            return emptyList()
        }

        // A model whose transport kind this build does not know how to speak is hidden
        // from the picker rather than offered and then failing at request time.
        return metadataIds.mapNotNull { modelId ->
            val resolved = metadata.resolveCatalogModel(modelId, provider.kind)
            val rawTransport = resolved?.transport
            if (!rawTransport.isNullOrBlank() && TransportKind.fromWireValue(rawTransport) == null) {
                return@mapNotNull null
            }
            CatalogModelBuilder.buildCatalogModel(
                providerKind = provider.kind,
                runtimeModelId = modelId,
                fallbackName = modelId,
            )
        }
    }

    /**
     * Builds the set of enabled model ids, matching on model.id, on canonicalModelId and
     * on the aliases the catalog publishes.
     */
    private fun buildEnabledIdSet(
        provider: Provider,
        catalogModels: List<AIModel>,
        metadata: MetadataClient,
    ): Set<String> {
        val enabledIds = mutableSetOf<String>()
        for (enabledModel in provider.models) {
            // Direct match against the catalog.
            val matched = ModelSelectionUtils.matchingModel(catalogModels, enabledModel.id)
            if (matched != null) {
                enabledIds.add(matched.id)
                continue
            }
            // Otherwise try to match through a catalog alias.
            if (provider.kind != ProviderKind.Relay) {
                val resolved = metadata.resolveCatalogModel(enabledModel.id, provider.kind)
                if (resolved != null) {
                    val catalogMatch = catalogModels.firstOrNull { it.id == resolved.canonicalModelId }
                        ?: ModelSelectionUtils.matchingModel(catalogModels, resolved.canonicalModelId)
                    if (catalogMatch != null) {
                        enabledIds.add(catalogMatch.id)
                        continue
                    }
                }
            }
        }
        return enabledIds
    }

    /**
     * Finds the manual models: entries in provider.models that match no catalog entry.
     */
    private fun buildManualModels(
        provider: Provider,
        catalogModels: List<AIModel>,
        providerKind: ProviderKind,
    ): List<AIModel> {
        return provider.models.filter { enabledModel ->
            catalogModels.none { catalogModel ->
                ModelSelectionUtils.modelsShareSameRemoteModel(enabledModel, catalogModel, providerKind)
            }
        }
    }

    /**
     * Default model resolution chain:
     * 1. the default the user already picked
     * 2. the defaultModelId the catalog names
     * 3. the first enabled model
     */
    private fun resolveDefaultModel(
        provider: Provider,
        enabledModels: List<ResolvedModel>,
        catalog: List<ResolvedModel>,
        metadata: MetadataClient,
    ): ResolvedModel? {
        // 1. The user's existing default, looked up among enabled models only.
        val userDefault = provider.defaultModel
        if (userDefault != null) {
            enabledModels.firstOrNull { it.model.id == userDefault.id }?.let { return it }
        }

        // 2. The catalog's defaultModelId, again only among enabled models.
        if (provider.kind != ProviderKind.Relay) {
            val metadataDefaultId = metadata.defaultModelId(provider.kind)
            if (metadataDefaultId != null) {
                enabledModels.firstOrNull { it.model.id == metadataDefaultId }?.let { return it }
            }
        }

        // 3. Fall back to the first enabled model.
        return enabledModels.firstOrNull()
    }
}
