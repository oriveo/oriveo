package ai.oriveo.community.feature.providers.detail

import androidx.annotation.StringRes
import androidx.compose.runtime.Immutable
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import ai.oriveo.community.core.provider.ResolvedProviderCatalog
import ai.oriveo.community.core.provider.relay.RelayCatalogGrouping
import ai.oriveo.community.core.provider.relay.RelayKeyBinding

/**
 * `models` is written once at construction and only read afterwards, and `AIModel` is itself
 * @Immutable, so both classes really are immutable to Compose. Without the annotation the
 * `List<AIModel>` field makes the whole class unstable, and `CatalogGroupHeader` can never skip
 * recomposition. Declaring `kotlin.collections.List` stable in `compose-stability.txt` instead
 * would be false: `MutableList` implements it too.
 */
@Immutable
data class ProviderCatalogGroup(
    val id: String,
    val title: String,
    val models: List<AIModel>,
    /** When non-null the UI shows this localized text instead of [title] (the relay "Other" group). */
    @StringRes val titleRes: Int? = null,
)

@Immutable
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
    /** Relay only (local connections included): the family function, in production the cached Server family and then the heuristic. */
    relayFamily: (String) -> String? = RelayKeyBinding::cachedFamily,
): List<ProviderCatalogGroup> {
    val enabledIds = provider.models.map { it.id }.toSet()
    // "Enabled" must mean the same thing as in enableModel (modelsShareSameRemoteModel: aliases,
    // snapshot date suffixes, canonical ids, same display name). Filtering by exact id alone leaves
    // rows in the catalog that enableModel then treats as already present, so tapping "+" does
    // nothing and the row never goes away.
    val enabledIndex = ModelSelectionUtils.catalogMatchIndex(provider.models, provider.kind)
    val normalizedQuery = searchQuery.trim().lowercase()
    val catalog = resolvedCatalog ?: ProviderCatalogResolver.resolve(provider)
    val dedupedCatalog = ModelSelectionUtils.deduplicate(catalog.catalog.map { it.model }, provider.kind)
    if (provider.kind == ProviderKind.Relay) {
        return relayCatalogGroups(provider, dedupedCatalog, enabledIds, enabledIndex, normalizedQuery, relayFamily)
    }
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

    // Compute scores before sorting: scoring goes through the capability facade (governedFileBadge), so doing it
    // inside the comparator would call it n log n times, and recencyScore reads the current time, so a score that
    // changes mid-sort would break the comparator's transitivity.
    val priorityById = HashMap<String, Int>(dedupedCatalog.size).apply {
        for (model in dedupedCatalog) put(model.id, catalogPriorityScore(provider, model))
    }
    fun priorityOf(model: AIModel): Int = priorityById[model.id] ?: catalogPriorityScore(provider, model)

    val groupScoresById = dedupedCatalog
        .groupBy(::groupIdOf)
        .mapValues { (_, models) -> rankedGroupScore(models.map(::priorityOf)) }
    // Deduplicate again at the presentation layer as a safety net against duplicates left behind by
    // older persisted data.
    return dedupedCatalog
        .filterNot { model -> model.id in enabledIds || enabledIndex.sharesRemoteModelWithAny(model, provider.kind) }
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
                models = filteredModels.sortedWith { lhs, rhs -> compareCatalogModels(lhs, rhs, priorityOf(lhs), priorityOf(rhs)) },
            )
        }
        .filter { it.models.isNotEmpty() }
        .sortedWith { lhs, rhs -> compareCatalogGroups(lhs, rhs, provider, groupScoresById) }
}

/**
 * Relay (local connections included) catalog grouping: one grouping by family, groups ordered by first appearance in the catalog with "Other" last, catalog order within a group;
 * the groupKey stamped onto catalog rows at fetch time no longer takes part. Step 2 of adding goes through the same path via [ai.oriveo.community.feature.providers.relay.relaySetupCatalogGroups].
 */
private fun relayCatalogGroups(
    provider: Provider,
    dedupedCatalog: List<AIModel>,
    enabledIds: Set<String>,
    enabledIndex: ModelSelectionUtils.CatalogMatchIndex,
    normalizedQuery: String,
    family: (String) -> String?,
): List<ProviderCatalogGroup> {
    val remaining = dedupedCatalog.filterNot { model ->
        model.id in enabledIds || enabledIndex.sharesRemoteModelWithAny(model, provider.kind)
    }
    return RelayCatalogGrouping.groups(remaining, AIModel::id, family).mapNotNull { group ->
        val title = group.label.orEmpty()
        val models = if (normalizedQuery.isEmpty()) {
            group.items
        } else {
            filterModelsWithinGroup(group.items, normalizedQuery, title, group.id)
        }
        models.takeIf { it.isNotEmpty() }?.let {
            ProviderCatalogGroup(
                id = group.id,
                title = title,
                models = it,
                titleRes = if (group.label == null) R.string.relay_catalog_group_other else null,
            )
        }
    }
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
    // A relay's enabled rows keep their stored (enabled) order and are not re-ranked by model-name scoring.
    if (provider.kind == ProviderKind.Relay) return provider.models

    // Score every model once before sorting (decorate-sort-undecorate). Two reasons, and speed
    // is only one of them:
    //   1. enabledModelPriorityScore does an id.lowercase() plus ten contains() calls. Inside the
    //      comparator it ran twice per comparison, n log n times, on the main thread (this is
    //      remembered by ProviderDetailScreen), and "add all" can push n to several hundred.
    //   2. Its recencyScore reads System.currentTimeMillis(), so a score could change in the
    //      middle of a sort. A comparator that stops being transitive makes TimSort throw
    //      "Comparison method violates its general contract!". Freezing the scores closes that window.
    val scored = provider.models.map { model -> model to enabledModelPriorityScore(provider, model) }
    return scored.sortedWith { lhs, rhs ->
        val left = lhs.first
        val right = rhs.first
        when {
            left.isDefault != right.isDefault -> if (left.isDefault) -1 else 1
            left.isAvailable != right.isAvailable -> if (left.isAvailable) -1 else 1
            (left.sortRank ?: 0) != (right.sortRank ?: 0) -> (right.sortRank ?: 0) - (left.sortRank ?: 0)
            lhs.second != rhs.second -> rhs.second - lhs.second
            (left.createdAt ?: 0.0) != (right.createdAt ?: 0.0) ->
                (right.createdAt ?: 0.0).compareTo(left.createdAt ?: 0.0)
            else -> left.name.compareTo(right.name, ignoreCase = true)
        }
    }.map { it.first }
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

    // Group scores are computed once before sorting, for the same reason as in compareCatalogModels.
    val groups = mappedGroups
        .map { group -> group to catalogGroupScore(provider, group.models) }
        .sortedWith { (lhs, lhsScore), (rhs, rhsScore) ->
            val scoreDiff = rhsScore - lhsScore
            if (scoreDiff != 0) scoreDiff
            else lhs.groupName.orEmpty().compareTo(rhs.groupName.orEmpty(), ignoreCase = true)
        }
        .map { it.first }
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

/** [ignoreDefault]: pass true for relay models, where the legacy isDefault no longer moves a model to the front. */
fun comparePickerModels(lhs: AIModel, rhs: AIModel, ignoreDefault: Boolean = false): Int {
    return when {
        !ignoreDefault && lhs.isDefault != rhs.isDefault -> if (lhs.isDefault) -1 else 1
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
    provider: Provider,
    groupScoresById: Map<String, Int>,
): Int {
    val lhsScore = groupScoresById[lhs.id] ?: catalogGroupScore(provider, lhs)
    val rhsScore = groupScoresById[rhs.id] ?: catalogGroupScore(provider, rhs)
    val scoreDiff = rhsScore - lhsScore
    if (scoreDiff != 0) {
        return scoreDiff
    }

    return lhs.title.compareTo(rhs.title, ignoreCase = true)
}

private fun compareCatalogModels(lhs: AIModel, rhs: AIModel, lhsPriority: Int, rhsPriority: Int): Int {
    // Ordered by sortRank descending for every provider; the comparison strategy never switches on
    // `providerKind`.
    if (lhs.isAvailable != rhs.isAvailable) {
        return if (lhs.isAvailable) -1 else 1
    }

    // Prefer the rank published in the model catalog (`uiHints.rank`).
    val rankDiff = (rhs.sortRank ?: 0) - (lhs.sortRank ?: 0)
    if (rankDiff != 0) return rankDiff

    val priorityDiff = rhsPriority - lhsPriority
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

private fun catalogGroupScore(provider: Provider, group: ProviderCatalogGroup): Int {
    return catalogGroupScore(provider, group.models)
}

private fun catalogGroupScore(provider: Provider, models: List<AIModel>): Int =
    rankedGroupScore(models.map { catalogPriorityScore(provider, it) })

private fun rankedGroupScore(scores: List<Int>): Int {
    val rankedScores = scores.sortedDescending()
    val first = rankedScores.getOrElse(0) { 0 }
    val second = rankedScores.getOrElse(1) { 0 }
    val third = rankedScores.getOrElse(2) { 0 }

    return first * 10_000 + second * 100 + third
}

/** Lightweight provider score for the model picker, based only on enabled models so it avoids resolve(). */
private fun pickerProviderScore(provider: Provider): Int {
    val models = provider.models
    val bestScore = models.maxOfOrNull { catalogPriorityScore(provider, it) } ?: 0
    var score = bestScore
    if (preferredEnabledModel(provider)?.isAvailable == true) {
        score += 80
    }
    return score + minOf(models.size, 24)
}

private fun preferredEnabledModel(provider: Provider): AIModel? =
    if (provider.kind == ProviderKind.Relay) {
        provider.models.firstOrNull()
    } else {
        provider.models.firstOrNull { it.isDefault } ?: provider.models.firstOrNull()
    }

private fun catalogPriorityScore(provider: Provider, model: AIModel): Int {
    model.sortRank?.let { rank ->
        return rank
    }

    var score = 0

    if (model.isAvailable) {
        score += 180
    }
    if (governedFileBadge(provider, model)) {
        score += 12
    }
    if ((model.promptPrice == 0.0) || (model.completionPrice == 0.0)) {
        score += 4
    }

    return score + recencyScore(model.createdAt)
}

/**
 * The "file" bonus only counts when the file_input projection is shown (same rule as iOS
 * permitsDisplay(.file) and the Web input projection), never the raw capability array. Only this one
 * key is projected, so a model's whole badge set (web search / thinking controls) is not resolved.
 */
private fun governedFileBadge(provider: Provider, model: AIModel): Boolean =
    CapabilityEvidenceProductionAdapter.governedInputVisible(provider, model, CapabilityEvidenceFacade.FILE_INPUT)

// internal so the equivalence test can use the production scoring function as its reference
// instead of a copy that would only prove the copy agrees with itself.
internal fun enabledModelPriorityScore(provider: Provider, model: AIModel): Int {
    var score = 0

    if (model.isAvailable) score += 180
    if (governedFileBadge(provider, model)) score += 8
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
