package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import ai.oriveo.community.core.provider.ResolvedProviderCatalog

data class ProviderCatalogGroup(
    val id: String,
    val title: String,
    val models: List<AIModel>,
)

data class VendorGroup(
    val id: String,
    val groupKey: String?,
    val groupName: String?,
    val models: List<AIModel>,
)

fun buildProviderCatalogGroups(
    provider: Provider,
    resolvedCatalog: ResolvedProviderCatalog? = null,
    searchQuery: String,
): List<ProviderCatalogGroup> {
    val enabledIds = provider.models.map { it.id }.toSet()
    val normalizedQuery = searchQuery.trim().lowercase()
    val catalog = resolvedCatalog ?: ProviderCatalogResolver.resolve(provider)
    val dedupedCatalog = ModelSelectionUtils.deduplicateByCanonical(catalog.catalog.map { it.model })
    // Resolve each model's group identity once up front. Doing it inside groupBy computed the same
    // model's identity twice and allocated a throwaway ProviderCatalogGroup per call, so the whole
    // pass re-ran on every keystroke of the search field.
    val identityById = HashMap<String, ProviderCatalogGroup>(dedupedCatalog.size).apply {
        for (model in dedupedCatalog) {
            put(model.id, resolveCatalogGroupIdentity(model, provider))
        }
    }
    fun groupIdOf(model: AIModel): String = identityById[model.id]?.id ?: provider.kind.rawValue
    fun groupTitleOf(model: AIModel): String = identityById[model.id]?.title ?: provider.displayName

    val groupScoresById = dedupedCatalog
        .groupBy(::groupIdOf)
        .mapValues { (_, models) -> catalogGroupScore(models) }
    // Deduplicate again at the presentation layer as a safety net against duplicates left behind by
    // older persisted data.
    return dedupedCatalog
        .filterNot { model -> model.id in enabledIds }
        .groupBy(::groupIdOf)
        .map { (groupId, models) ->
            val title = models.firstOrNull()?.let(::groupTitleOf) ?: provider.displayName
            val filteredModels = if (normalizedQuery.isEmpty()) {
                models
            } else {
                filterModelsWithinGroup(
                    models = models,
                    normalizedQuery = normalizedQuery,
                    title = title,
                    groupId = groupId,
                )
            }
            ProviderCatalogGroup(
                id = groupId,
                title = title,
                models = filteredModels.sortedWith { lhs, rhs -> compareCatalogModels(lhs, rhs) },
            )
        }
        .filter { it.models.isNotEmpty() }
        .sortedWith { lhs, rhs -> compareCatalogGroups(lhs, rhs, groupScoresById) }
}

fun sortedProvidersForModelPicker(providers: List<Provider>): List<Provider> {
    // Scored from the models the user has already enabled, so this never has to call
    // ProviderCatalogResolver.resolve().
    val scores = providers.associate { it.id to pickerProviderScore(it) }
    return providers.sortedWith { lhs, rhs ->
        val scoreDiff = (scores[rhs.id] ?: 0) - (scores[lhs.id] ?: 0)
        if (scoreDiff != 0) scoreDiff
        else lhs.displayName.compareTo(rhs.displayName, ignoreCase = true)
    }
}

fun sortedEnabledModels(provider: Provider): List<AIModel> {
    return provider.models.sortedWith { lhs, rhs ->
        when {
            lhs.isDefault != rhs.isDefault -> if (lhs.isDefault) -1 else 1
            lhs.isAvailable != rhs.isAvailable -> if (lhs.isAvailable) -1 else 1
            (lhs.sortRank ?: 0) != (rhs.sortRank ?: 0) -> (rhs.sortRank ?: 0) - (lhs.sortRank ?: 0)
            enabledModelPriorityScore(lhs) != enabledModelPriorityScore(rhs) ->
                enabledModelPriorityScore(rhs) - enabledModelPriorityScore(lhs)
            (lhs.createdAt ?: 0.0) != (rhs.createdAt ?: 0.0) ->
                (rhs.createdAt ?: 0.0).compareTo(lhs.createdAt ?: 0.0)
            else -> lhs.name.compareTo(rhs.name, ignoreCase = true)
        }
    }
}

fun groupModelsByVendor(
    provider: Provider,
    models: List<AIModel>,
): List<VendorGroup> {
    val explicitGroups = models
        .mapNotNull { model ->
            explicitVendorGroupIdentity(model)?.let { identity -> identity to model }
        }
        .groupBy { (identity, _) -> identity.id }

    if (explicitGroups.isEmpty()) {
        return listOf(
            VendorGroup(
                id = provider.id,
                groupKey = null,
                groupName = null,
                models = models,
            ),
        )
    }

    val mappedGroups = explicitGroups
        .map { (groupId, entries) ->
            val identity = entries.first().first
            VendorGroup(
                id = groupId,
                groupKey = identity.id,
                groupName = identity.title,
                models = entries.map { it.second },
            )
        }

    val groups = mappedGroups
        .sortedWith { lhs, rhs ->
            val scoreDiff = catalogGroupScore(rhs.models) - catalogGroupScore(lhs.models)
            if (scoreDiff != 0) scoreDiff
            else lhs.groupName.orEmpty().compareTo(rhs.groupName.orEmpty(), ignoreCase = true)
        }
        .toMutableList()

    val ungroupedModels = models.filter { explicitVendorGroupIdentity(it) == null }
    if (ungroupedModels.isNotEmpty()) {
        groups += VendorGroup(
            id = "${provider.id}-ungrouped",
            groupKey = null,
            groupName = null,
            models = ungroupedModels,
        )
    }

    return groups
}

/**
 * Provider detail grouping preserves the catalog's own order exactly: models arrive in
 * group/model sort order, and applying client-side popularity scoring here would keep a catalog
 * reordering from taking effect until the next app release.
 */
fun detailEnabledModelGroups(provider: Provider): List<VendorGroup> {
    val groups = mutableListOf<VendorGroup>()
    val groupIndexes = mutableMapOf<String, Int>()

    provider.models.forEach { model ->
        val identity = explicitVendorGroupIdentity(model)
        val groupId = identity?.id ?: "${provider.id}-ungrouped"
        val existingIndex = groupIndexes[groupId]
        if (existingIndex == null) {
            groupIndexes[groupId] = groups.size
            groups += VendorGroup(
                id = groupId,
                groupKey = identity?.id,
                groupName = identity?.title,
                models = listOf(model),
            )
        } else {
            val existing = groups[existingIndex]
            groups[existingIndex] = existing.copy(models = existing.models + model)
        }
    }

    return groups
}

fun comparePickerModels(lhs: AIModel, rhs: AIModel): Int {
    return when {
        lhs.isDefault != rhs.isDefault -> if (lhs.isDefault) -1 else 1
        lhs.isAvailable != rhs.isAvailable -> if (lhs.isAvailable) -1 else 1
        lhs.groupName.orEmpty() != rhs.groupName.orEmpty() ->
            lhs.groupName.orEmpty().compareTo(rhs.groupName.orEmpty(), ignoreCase = true)

        else -> lhs.name.compareTo(rhs.name, ignoreCase = true)
    }
}

fun shouldAutoExpandCatalogGroups(searchQuery: String): Boolean =
    searchQuery.trim().isNotEmpty()

/**
 * Orders the vendor groups on the provider detail screen.
 *
 * Ordering consumes only the `uiHints.rank` published in the model catalog (surfaced as
 * `model.sortRank`). It deliberately does not weight one vendor over another by provider kind, and
 * does not fall back to parsing the model slug: adjusting the published rank is enough to change the
 * order, with no app release required.
 */
private fun compareCatalogGroups(
    lhs: ProviderCatalogGroup,
    rhs: ProviderCatalogGroup,
    groupScoresById: Map<String, Int>,
): Int {
    val lhsScore = groupScoresById[lhs.id] ?: catalogGroupScore(lhs)
    val rhsScore = groupScoresById[rhs.id] ?: catalogGroupScore(rhs)
    val scoreDiff = rhsScore - lhsScore
    if (scoreDiff != 0) {
        return scoreDiff
    }

    return lhs.title.compareTo(rhs.title, ignoreCase = true)
}

private fun compareCatalogModels(lhs: AIModel, rhs: AIModel): Int {
    // Ordered by sortRank descending for every provider; the comparison strategy never switches on
    // `providerKind`.
    if (lhs.isAvailable != rhs.isAvailable) {
        return if (lhs.isAvailable) -1 else 1
    }

    // Prefer the rank published in the model catalog (`uiHints.rank`).
    val rankDiff = (rhs.sortRank ?: 0) - (lhs.sortRank ?: 0)
    if (rankDiff != 0) return rankDiff

    val priorityDiff = catalogPriorityScore(rhs) - catalogPriorityScore(lhs)
    if (priorityDiff != 0) {
        return priorityDiff
    }

    val createdAtDiff = (rhs.createdAt ?: 0.0).compareTo(lhs.createdAt ?: 0.0)
    if (createdAtDiff != 0) {
        return createdAtDiff
    }

    // Final tie-breaker: ascending ASCII order of the canonical model id, so the listing is stable.
    val lhsId = lhs.canonicalModelId ?: lhs.id
    val rhsId = rhs.canonicalModelId ?: rhs.id
    return lhsId.compareTo(rhsId)
}

private fun catalogGroupScore(group: ProviderCatalogGroup): Int {
    return catalogGroupScore(group.models)
}

private fun catalogGroupScore(models: List<AIModel>): Int {
    val rankedScores = models
        .map(::catalogPriorityScore)
        .sortedDescending()
    val first = rankedScores.getOrElse(0) { 0 }
    val second = rankedScores.getOrElse(1) { 0 }
    val third = rankedScores.getOrElse(2) { 0 }

    return first * 10_000 + second * 100 + third
}

/** Lightweight provider score for the model picker, based only on enabled models so it avoids resolve(). */
private fun pickerProviderScore(provider: Provider): Int {
    val models = provider.models
    val bestScore = models.maxOfOrNull(::catalogPriorityScore) ?: 0
    var score = bestScore
    if (preferredEnabledModel(provider)?.isAvailable == true) {
        score += 80
    }
    return score + minOf(models.size, 24)
}

private fun preferredEnabledModel(provider: Provider): AIModel? =
    provider.models.firstOrNull { it.isDefault } ?: provider.models.firstOrNull()

private fun catalogPriorityScore(model: AIModel): Int {
    model.sortRank?.let { rank ->
        return rank
    }

    var score = 0

    if (model.isAvailable) {
        score += 180
    }
    if (model.capabilities.contains(ModelCapability.File)) {
        score += 12
    }
    if ((model.promptPrice == 0.0) || (model.completionPrice == 0.0)) {
        score += 4
    }

    return score + recencyScore(model.createdAt)
}

private fun enabledModelPriorityScore(model: AIModel): Int {
    var score = 0

    if (model.isAvailable) score += 180
    if (model.capabilities.contains(ModelCapability.File)) score += 8
    val identifier = model.id.lowercase()
    if (
        identifier.contains("claude") ||
        identifier.contains("gpt") ||
        identifier.contains("gemini") ||
        identifier.contains("deepseek") ||
        identifier.contains("sonar")
    ) {
        score += 34
    }
    if (
        identifier.contains("sonnet") ||
        identifier.contains("opus") ||
        identifier.contains("flash") ||
        identifier.contains("pro") ||
        identifier.contains("turbo") ||
        identifier.contains("o1") ||
        identifier.contains("o3")
    ) {
        score += 12
    }
    if (
        identifier.contains("preview") ||
        identifier.contains("beta") ||
        identifier.contains("alpha") ||
        identifier.contains(":free")
    ) {
        score -= 18
    }

    return score + recencyScore(model.createdAt)
}

private fun recencyScore(createdAtEpoch: Double?): Int {
    if (createdAtEpoch == null || createdAtEpoch <= 0) return 0

    val now = System.currentTimeMillis() / 1000.0
    val ageSeconds = kotlin.math.max(0.0, now - createdAtEpoch)
    val day = 24 * 60 * 60.0

    return when {
        ageSeconds < 30 * day -> 24
        ageSeconds < 90 * day -> 16
        ageSeconds < 180 * day -> 8
        ageSeconds < 365 * day -> 3
        else -> 0
    }
}

/**
 * Resolves one model's group identity, driven strictly by the fields published in the model catalog.
 *
 * It does not branch on `provider.kind` to parse an OpenRouter or SiliconFlow slug. When the catalog
 * publishes no `groupKey`/`groupName`, this degrades to a provider-level identity built from
 * `providerKind.rawValue` and `provider.displayName`.
 */
private fun resolveCatalogGroupIdentity(
    model: AIModel,
    provider: Provider,
): ProviderCatalogGroup = ProviderCatalogGroup(
    id = model.groupKey ?: provider.kind.rawValue,
    title = model.groupName ?: provider.displayName,
    models = emptyList(),
)

private data class ExplicitVendorIdentity(
    val id: String,
    val title: String,
)

private fun explicitVendorGroupIdentity(model: AIModel): ExplicitVendorIdentity? {
    val groupKey = model.groupKey?.trim().takeUnless { it.isNullOrEmpty() } ?: return null
    val groupName = model.groupName?.trim().takeUnless { it.isNullOrEmpty() } ?: return null
    return ExplicitVendorIdentity(groupKey, groupName)
}

private fun filterModelsWithinGroup(
    models: List<AIModel>,
    normalizedQuery: String,
    title: String,
    groupId: String,
): List<AIModel> {
    val groupMatches = title.lowercase().contains(normalizedQuery) ||
        groupId.lowercase().contains(normalizedQuery)

    if (groupMatches) {
        return models
    }

    return models.filter { model ->
        model.name.lowercase().contains(normalizedQuery) ||
            model.id.lowercase().contains(normalizedQuery) ||
            (model.summary?.lowercase()?.contains(normalizedQuery) == true)
    }
}
