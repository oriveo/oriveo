package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.util.TreeMap
import java.util.TreeSet

/**
 * Model selection and matching helpers: picking a sensible default, deciding whether
 * two model records point at the same remote model, and deduplicating.
 */
object ModelSelectionUtils {
    private val dateSuffixRegex = Regex("""(?:-\d{8}|-\d{4}-\d{2}-\d{2})$""")

    /** Strips the "manual-" prefix to get the resolved model id. */
    fun resolvedId(modelId: String): String {
        val trimmed = modelId.trim()
        return if (trimmed.startsWith("manual-")) trimmed.removePrefix("manual-") else trimmed
    }

    fun preferredStoredModelIdentifier(model: AIModel): String {
        val canonical = model.canonicalModelId?.trim().orEmpty()
        if (canonical.isNotEmpty()) return canonical
        return resolvedId(model.id)
    }

    fun preferredStoredModelIdentifier(models: List<AIModel>, targetId: String): String {
        return matchingModel(models, targetId)
            ?.let(::preferredStoredModelIdentifier)
            ?: resolvedId(targetId)
    }

    fun runtimeModelIdentifier(models: List<AIModel>, targetId: String): String {
        return matchingModel(models, targetId)?.id ?: targetId.trim()
    }

    /**
     * Fuzzy model lookup: try an exact id match first, then the resolved id, then the
     * other identifiers a model carries.
     */
    fun matchingModel(models: List<AIModel>, targetId: String): AIModel? {
        val trimmedTarget = targetId.trim()
        if (trimmedTarget.isEmpty()) return null

        val lookupCandidates = lookupCandidates(trimmedTarget)

        lookupCandidates.forEach { candidate ->
            models.firstOrNull { model ->
                model.id.equals(candidate, ignoreCase = true)
            }?.let { return it }
        }

        return models.find { model ->
            modelIdentifiers(model).any { identifier ->
                lookupCandidates.any { candidate ->
                    identifier.equals(candidate, ignoreCase = true)
                }
            }
        }
    }

    /**
     * Catalog match index: the batch form of [matchingModel] and of "does this model
     * [modelsShareSameRemoteModel] with anything in the catalog".
     *
     * Scanning the whole catalog once per model is O(N x catalog), and [modelIdentifiers]
     * runs two to four regexes plus a handful of string allocations per model. A relay
     * catalog comes from the user's own server and can hold thousands of entries, and
     * "add all" writes the whole catalog into provider.models, so at 1500 x 1500 a single
     * [ProviderCatalogResolver.resolve] takes hundreds of milliseconds, and it runs twice
     * on every Provider write. Building the index once turns each query into a lookup per
     * candidate.
     *
     * Equivalence: comparisons use `String.CASE_INSENSITIVE_ORDER`, the same folding as
     * `equals(ignoreCase = true)` (a plain `lowercase()` diverges on non-ASCII ids, and a
     * relay catalog cannot be assumed to be ASCII). "First match in catalog order" is
     * preserved by recording the index of each identifier's first occurrence.
     */
    class CatalogMatchIndex internal constructor(private val models: List<AIModel>) {
        // First pass of matchingModel: the untrimmed model.id against each candidate, first in catalog order.
        private val firstByExactId = TreeMap<String, AIModel>(String.CASE_INSENSITIVE_ORDER)
        // Second pass: catalog index of the first model whose identifiers contain a candidate.
        private val firstIndexByIdentifier = TreeMap<String, Int>(String.CASE_INSENSITIVE_ORDER)
        private val names = TreeSet(String.CASE_INSENSITIVE_ORDER)

        init {
            models.forEachIndexed { index, model ->
                firstByExactId.putIfAbsent(model.id, model)
                modelIdentifiers(model).forEach { identifier ->
                    firstIndexByIdentifier.putIfAbsent(identifier, index)
                }
                names.add(model.name)
            }
        }

        /** Returns exactly what `matchingModel(models, targetId)` returns. */
        fun match(targetId: String): AIModel? {
            val trimmedTarget = targetId.trim()
            if (trimmedTarget.isEmpty()) return null
            val candidates = lookupCandidates(trimmedTarget)
            candidates.forEach { candidate ->
                firstByExactId[candidate]?.let { return it }
            }
            val firstIndex = candidates.mapNotNull { firstIndexByIdentifier[it] }.minOrNull() ?: return null
            return models[firstIndex]
        }

        /** Returns exactly what `models.any { modelsShareSameRemoteModel(model, it, providerKind) }` returns. */
        fun sharesRemoteModelWithAny(model: AIModel, providerKind: ProviderKind): Boolean {
            if (modelIdentifiers(model).any { it in firstIndexByIdentifier }) return true
            if (providerKind == ProviderKind.OpenRouter || providerKind == ProviderKind.SiliconFlow) {
                return false
            }
            return model.name.isNotBlank() && model.name in names
        }
    }

    fun catalogMatchIndex(models: List<AIModel>): CatalogMatchIndex = CatalogMatchIndex(models)

    /** Decides whether two model records stand for the same remote model. */
    fun modelsShareSameRemoteModel(
        a: AIModel,
        b: AIModel,
        providerKind: ProviderKind,
    ): Boolean {
        if (
            modelIdentifiers(a).any { left ->
                modelIdentifiers(b).any { right ->
                    left.equals(right, ignoreCase = true)
                }
            }
        ) {
            return true
        }

        if (providerKind == ProviderKind.OpenRouter || providerKind == ProviderKind.SiliconFlow) {
            return false
        }

        return a.name.equals(b.name, ignoreCase = true) && a.name.isNotBlank()
    }

    /**
     * Merges manually added models into a freshly synced list.
     *
     * Anything the user added by hand is kept, which means an id starting with
     * "manual-" or an id absent from the synced list, minus any entry the sync already
     * covers.
     */
    fun mergeManualModels(
        existingModels: List<AIModel>,
        syncedModels: List<AIModel>,
        providerKind: ProviderKind,
    ): List<AIModel> {
        // Manual models: the "manual-" prefix, or simply absent from the synced list.
        val syncedIds = syncedModels.map { it.id }.toSet()
        val manualModels = existingModels.filter { model ->
            model.id.startsWith("manual-") || model.id !in syncedIds
        }

        // Drop the manual entries the synced list already covers.
        val uniqueManuals = manualModels.filter { manual ->
            syncedModels.none { synced -> modelsShareSameRemoteModel(manual, synced, providerKind) }
        }

        // Manual models go in front.
        return uniqueManuals + syncedModels
    }

    /**
     * True replace semantics for a relay catalog refresh.
     *
     * [mergeManualModels] treats any stale catalog entry missing from the new listing as
     * if the user had typed it in, which leaves the UI permanently unable to say that a
     * model is gone from the endpoint. Relay models carry an explicit [AIModel.isManual]
     * flag, so keep only the genuinely hand-entered ones and let the freshly fetched
     * catalog decide everything else.
     */
    fun replaceRelayCatalog(
        existingModels: List<AIModel>,
        syncedModels: List<AIModel>,
        providerKind: ProviderKind,
    ): List<AIModel> {
        val manualModels = existingModels.filter { it.isManual }
        val uniqueManuals = manualModels.filter { manual ->
            syncedModels.none { synced -> modelsShareSameRemoteModel(manual, synced, providerKind) }
        }
        return uniqueManuals + syncedModels
    }

    /**
     * A refreshed catalog only enriches; it never deletes a relay model the user has
     * enabled.
     *
     * Models present in the new catalog take its metadata; models absent from it keep
     * the old object and stay sendable. Whether a model is missing is derived by the
     * consumer from the catalog ids confirmed in that same pass, so it never pollutes
     * isAvailable.
     */
    fun retainRelayEnabledModels(
        existingEnabledModels: List<AIModel>,
        catalogModels: List<AIModel>,
        providerKind: ProviderKind,
    ): List<AIModel> {
        if (existingEnabledModels.isEmpty()) return initialEnabledModels(catalogModels)

        val retained = existingEnabledModels.map { existing ->
            matchingModel(catalogModels, existing.id) ?: existing
        }.distinctBy { resolvedId(it.id) }
        val preferredDefaultId = existingEnabledModels.firstOrNull { it.isDefault }?.id
            ?: retained.firstOrNull()?.id
        return markDefaultModel(retained, preferredDefaultId)
    }

    fun initialEnabledModels(catalogModels: List<AIModel>): List<AIModel> {
        if (catalogModels.isEmpty()) return emptyList()

        val availableModels = catalogModels.filter { it.isAvailable }
        val candidatePool = availableModels.ifEmpty { catalogModels }
        // The default comes from the catalog's isDefault flag; there is no local scoring.
        val initialModel = candidatePool.firstOrNull { it.isDefault }
            ?: catalogModels.firstOrNull { it.isDefault }
            ?: candidatePool.firstOrNull()
            ?: catalogModels.first()

        return markDefaultModel(
            models = listOf(initialModel),
            preferredModelId = initialModel.id,
        )
    }

    fun makeEnabledModels(
        existingEnabledModels: List<AIModel>,
        catalogModels: List<AIModel>,
        providerKind: ProviderKind,
    ): List<AIModel> {
        if (catalogModels.isEmpty()) return existingEnabledModels

        val resolvedExistingModels = existingEnabledModels
            .mapNotNull { existingModel ->
                matchingModel(catalogModels, existingModel.id)
            }
            .distinctBy { resolvedId(it.id) }

        val selectedModels = if (resolvedExistingModels.isEmpty()) {
            initialEnabledModels(catalogModels)
        } else {
            resolvedExistingModels
        }

        val preferredDefaultId = existingEnabledModels.firstOrNull { it.isDefault }?.id
            ?: selectedModels.firstOrNull { it.isDefault }?.id
            ?: catalogModels.firstOrNull { it.isDefault }?.id

        return markDefaultModel(
            models = selectedModels,
            preferredModelId = preferredDefaultId,
        )
    }

    fun allEnabledModels(
        catalogModels: List<AIModel>,
        preferredDefaultId: String?,
    ): List<AIModel> {
        if (catalogModels.isEmpty()) return emptyList()

        return markDefaultModel(
            models = catalogModels,
            preferredModelId = preferredDefaultId ?: catalogModels.firstOrNull { it.isDefault }?.id,
        )
    }

    fun filteredRecommendedModels(
        recommendations: List<AIModel>,
        enabledModels: List<AIModel>,
        providerKind: ProviderKind,
    ): List<AIModel> {
        return recommendations.filter { recommendation ->
            enabledModels.none { enabledModel ->
                modelsShareSameRemoteModel(enabledModel, recommendation, providerKind)
            }
        }
    }

    fun enableModel(
        provider: Provider,
        model: AIModel,
    ): Provider {
        if (provider.models.any { modelsShareSameRemoteModel(it, model, provider.kind) }) {
            return provider
        }

        val updatedModels = provider.models + model.copy(isDefault = provider.models.isEmpty())

        return synchronizeDefaultSelection(
            provider = provider.copy(models = updatedModels),
            preferredModelId = provider.defaultModel?.id ?: model.id,
        )
    }

    fun synchronizeDefaultSelection(
        provider: Provider,
        preferredModelId: String?,
    ): Provider {
        val resolvedDefaultId = preferredModelId
            ?: provider.models.firstOrNull { it.isDefault }?.id
            ?: provider.catalogModels.firstOrNull { it.isDefault }?.id

        return provider.copy(
            models = markDefaultModel(provider.models, resolvedDefaultId),
            catalogModels = markDefaultFlag(provider.catalogModels, resolvedDefaultId),
        )
    }

    fun markDefaultModel(
        models: List<AIModel>,
        preferredModelId: String?,
    ): List<AIModel> {
        if (models.isEmpty()) return emptyList()

        val resolvedDefaultId = preferredModelId?.let { preferredId ->
            matchingModel(models, preferredId)?.id
        } ?: models.firstOrNull { it.isDefault }?.id
            ?: models.first().id

        return models.map { model ->
            model.copy(
                isDefault = model.id == resolvedDefaultId,
            )
        }
    }

    fun markDefaultFlag(
        models: List<AIModel>,
        preferredModelId: String?,
    ): List<AIModel> {
        val resolvedDefaultId = preferredModelId?.let { preferredId ->
            matchingModel(models, preferredId)?.id
        }
        return models.map { model ->
            model.copy(
                isDefault = resolvedDefaultId != null && model.id == resolvedDefaultId,
            )
        }
    }

    // ---- canonical deduplication ----

    /** Canonical key for a model, matching how the catalog derives its canonical model id. */
    fun canonicalKey(model: AIModel): String =
        model.canonicalModelId?.trim()?.takeIf { it.isNotEmpty() }
            ?: model.id.replace(dateSuffixRegex, "")

    /**
     * Deduplicates by canonical key, preferring the entry without a date suffix.
     *
     * The trailing `distinctBy { it.id }` is defence, not duplicated work: the grouping
     * key is the canonical key, so two records with the SAME id but different
     * canonicalModelId land under two keys and both survive. The result is handed
     * straight to a LazyColumn/LazyRow with `key = it.id`, and a duplicate key there is
     * a crash, not a cosmetic glitch.
     */
    fun deduplicateByCanonical(models: List<AIModel>): List<AIModel> {
        val seen = mutableMapOf<String, Int>()
        val result = mutableListOf<AIModel>()
        for (model in models) {
            val key = canonicalKey(model)
            val idx = seen[key]
            if (idx != null) {
                if (model.id == key) result[idx] = model
            } else {
                seen[key] = result.size
                result.add(model)
            }
        }
        return result.distinctBy { it.id }
    }

    private fun modelIdentifiers(model: AIModel): List<String> {
        val candidates = listOf(
            model.id.trim(),
            resolvedId(model.id),
            stripSnapshotDateSuffix(model.id),
            model.canonicalModelId?.trim().orEmpty(),
            model.canonicalModelId?.let(::stripSnapshotDateSuffix).orEmpty(),
            preferredStoredModelIdentifier(model),
        )

        return candidates
            .filter { it.isNotEmpty() }
            .distinctBy { it.lowercase() }
    }

    private fun lookupCandidates(modelId: String): List<String> {
        val trimmed = modelId.trim()
        val resolved = resolvedId(trimmed)
        val strippedTrimmed = stripSnapshotDateSuffix(trimmed)
        val strippedResolved = stripSnapshotDateSuffix(resolved)

        return listOf(trimmed, resolved, strippedTrimmed, strippedResolved)
            .filter { it.isNotEmpty() }
            .distinctBy { it.lowercase() }
    }

    private fun stripSnapshotDateSuffix(modelId: String): String =
        modelId.trim().replace(dateSuffixRegex, "")
}
