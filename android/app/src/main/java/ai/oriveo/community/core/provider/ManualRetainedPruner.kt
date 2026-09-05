package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

/**
 * Prunes manually retained models - models the user has enabled locally that the published
 * catalog does not list.
 *
 * - flag off (the default): the provider is returned unchanged, keeping locally enabled models
 *   the catalog does not know about
 * - flag on: entries the catalog does not list are dropped from `provider.models`, and if the
 *   default model was among them the selection falls back to the catalog's `defaultModelId` or
 *   to the first remaining model
 *
 * Applies to the official providers. Relay is exempt - its directory is the user's own, so it is
 * returned untouched.
 *
 * Called after `ProviderRepository.resyncProvider()` finishes.
 */
object ManualRetainedPruner {

    /**
     * The built-in pruning switch.
     *
     * - `false`: keep the manually retained path while the catalog is still filling out (default)
     * - `true`: prune once the catalog is considered complete
     *
     * Flipping this constant to `true` and shipping is all it takes; clients prune on their next
     * resync.
     */
    const val MANUAL_RETAINED_PRUNING_ENABLED: Boolean = false

    /**
     * Test-only override of the built-in flag, so register / resync / refresh can be exercised
     * with pruning both on and off.
     *
     * Production code never writes this; null falls back to `MANUAL_RETAINED_PRUNING_ENABLED`.
     */
    @JvmStatic
    @Volatile
    var flagOverrideForTesting: Boolean? = null

    @JvmStatic
    fun isPruningEnabled(): Boolean = flagOverrideForTesting ?: MANUAL_RETAINED_PRUNING_ENABLED

    /**
     * Decides what to prune from the contract version and the switch.
     *
     * If the catalog contract has entered safe degradation (`isContractVersionDegraded`) the
     * directory must not be extended even with the flag off. This function still keeps the
     * user's enabled models, which the resolver then shows in its manually retained section;
     * nothing is pruned here, so a contract anomaly can never quietly delete the user's data.
     *
     * @param provider the provider being pruned
     * @param isPruningEnabled whether pruning is active; callers may override the built-in
     *   constant, which the tests do
     * @param metadata the MetadataClient to read, defaulting to the global instance
     */
    fun prune(
        provider: Provider,
        isPruningEnabled: Boolean = isPruningEnabled(),
        metadata: MetadataClient = MetadataClient.instance,
    ): Provider {
        // Relay does not go through this path: its directory belongs to the user.
        if (provider.kind == ProviderKind.Relay) {
            return provider
        }
        if (!isPruningEnabled) return provider

        val resolved = ProviderCatalogResolver.resolve(provider, metadata)
        val metadataBackedIds = resolved.catalog
            .filter { !it.isManual }
            .map { it.model.id }
            .toSet()

        // With no catalog data, prune nothing and keep the existing behaviour, so going offline
        // never deletes anything.
        if (metadataBackedIds.isEmpty()) return provider

        val prunedModels = provider.models.filter { model -> model.id in metadataBackedIds }
        if (prunedModels.size == provider.models.size) return provider

        // Pruned models are reported with a single println rather than any reporting pipeline.
        // println rather than android.util.Log so unit tests do not have to mock Log.
        val removedModels = provider.models.filter { it.id !in metadataBackedIds }
        if (removedModels.isNotEmpty()) {
            println(
                "[ManualRetainedPruner] pruned ${removedModels.size} ids from ${provider.kind.rawValue}: " +
                    removedModels.joinToString(",") { it.id },
            )
        }

        val metadataDefault = metadata.defaultModelId(provider.kind)
        val preferredDefaultId = prunedModels.firstOrNull { it.isDefault }?.id
            ?: metadataDefault?.takeIf { def -> prunedModels.any { it.id == def } }
            ?: prunedModels.firstOrNull()?.id

        return ModelSelectionUtils.synchronizeDefaultSelection(
            provider = provider.copy(models = prunedModels),
            preferredModelId = preferredDefaultId,
        )
    }
}
