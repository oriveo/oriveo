package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the three main-thread hot paths of the provider detail catalog. It only locks that the
 * results did not change, not how they are computed.
 *
 * The three original forms and their cost:
 *   1. Every "enabled models" row ran `matchingModel(wholeRelayCatalog, model.id)` during
 *      composition, an O(catalog) scan that, on a miss, also runs two regexes per catalog model.
 *      A relay catalog comes from the user's own server and can hold thousands of entries.
 *   2. `sortedEnabledModels` computed `enabledModelPriorityScore` (an `id.lowercase()` plus ten
 *      `contains`) inside the comparator, twice per comparison across n log n comparisons, on
 *      the main thread.
 *   3. `detailEnabledModelGroups` copied the whole list with `existing.models + model` for every
 *      model, which is O(n^2).
 *
 * All three equivalence checks use the production functions themselves as the reference
 * (`ModelSelectionUtils.matchingModel`, `enabledModelPriorityScore`, `explicitVendorGroupIdentity`)
 * rather than a copy of the scoring or grouping rules in the test; a copy would only prove that
 * the copy agrees with itself.
 *
 * Inputs come out of `ProviderCatalogResolver.resolve()` (a relay reads its local `catalogModels`,
 * the only source of a relay catalog), not from hand-built bare `AIModel` lists.
 */
class ProviderDetailCatalogHotPathTest {

    // ---- 1. relay catalog membership index == matchingModel ----

    @Test
    fun `catalog membership index answers exactly what matchingModel answered`() {
        val provider = relayProviderWithProductionCatalog()
        val catalog = ProviderCatalogResolver.resolve(provider).catalog.map { it.model }
        assertTrue("the resolver must actually produce a catalog, or this test checks nothing", catalog.size >= 8)

        val index = ModelSelectionUtils.catalogMembershipIndex(catalog)

        // In the catalog, enabled, case variants, dated suffixes, the manual- prefix, and ids that
        // do not exist at all.
        val probes = catalog.map { it.id } +
            catalog.map { it.id.uppercase() } +
            catalog.map { "manual-${it.id}" } +
            provider.models.map { it.id } +
            listOf("", "   ", "nope/not-in-catalog", "anthropic/claude-sonnet-20260101")

        probes.forEach { probe ->
            assertEquals(
                "the index and matchingModel must agree on `$probe`",
                ModelSelectionUtils.matchingModel(catalog, probe) != null,
                ModelSelectionUtils.catalogIndexContains(index, probe),
            )
        }
    }

    @Test
    fun `empty confirmed catalog still reports every model as missing`() {
        // An empty catalog (RelayCatalogUiState.Empty) passes an empty index, not null: "confirmed
        // and empty" is not "unconfirmed", and only the latter must suppress the missing badge.
        val index = ModelSelectionUtils.catalogMembershipIndex(emptyList())
        assertFalse(ModelSelectionUtils.catalogIndexContains(index, "anthropic/claude-sonnet"))
    }

    // ---- 2. sortedEnabledModels with frozen scores matches item by item ----

    @Test
    fun `sorted enabled models match the pre-freeze comparator item by item`() {
        val provider = relayProviderWithProductionCatalog().let { relay ->
            // The whole catalog as enabled models: what "add all" produces, and exactly where the
            // quadratic grouping and the in-comparator scoring show up.
            relay.copy(models = ProviderCatalogResolver.resolve(relay).catalog.map { it.model })
        }

        // Reference: the comparator as it was before scores were frozen, scoring on every
        // comparison with the production scoring function.
        val reference = provider.models.sortedWith { lhs, rhs ->
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

        assertEquals(
            "freezing the scores changes only the cost; the order must match item by item",
            reference.map { it.id },
            sortedEnabledModels(provider).map { it.id },
        )
    }

    // ---- 3. detailEnabledModelGroups without the quadratic copy matches item by item ----

    @Test
    fun `detail enabled groups match the quadratic reference accumulation`() {
        val base = relayProviderWithProductionCatalog()
        val provider = base.copy(models = ProviderCatalogResolver.resolve(base).catalog.map { it.model })

        // Reference: the accumulation as it was, copying the whole list with `existing.models + model`.
        val reference = mutableListOf<VendorGroup>()
        val referenceIndexes = mutableMapOf<String, Int>()
        provider.models.forEach { model ->
            val identity = explicitVendorGroupIdentity(model)
            val groupId = identity?.id ?: "${provider.id}-ungrouped"
            val existingIndex = referenceIndexes[groupId]
            if (existingIndex == null) {
                referenceIndexes[groupId] = reference.size
                reference += VendorGroup(groupId, identity?.id, identity?.title, listOf(model))
            } else {
                val existing = reference[existingIndex]
                reference[existingIndex] = existing.copy(models = existing.models + model)
            }
        }

        val actual = detailEnabledModelGroups(provider)
        assertEquals(
            "group order and identity must match item by item",
            reference.map { it.id to it.groupName },
            actual.map { it.id to it.groupName },
        )
        assertEquals(
            "model order within each group must match item by item",
            reference.map { group -> group.models.map { it.id } },
            actual.map { group -> group.models.map { it.id } },
        )
        assertTrue("there must be at least one real group, or this test degrades into a no-op", actual.size >= 2)
    }

    // ---- 4. Source contract: the whole-catalog scan must not move back into the rows ----

    /** A `matchingModel(` call inside the rows would put the O(catalog) scan back into every row's composition. */
    @Test
    fun `enabled model rows look membership up by index instead of scanning the catalog`() {
        val enabledModels = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailEnabledModels.kt",
        ).readText().withoutComments()
        val detailScreen = File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailScreen.kt",
        ).readText().withoutComments()

        assertFalse(
            "scanning the whole catalog again for every row is what drops frames on large relay catalogs",
            enabledModels.contains("ModelSelectionUtils.matchingModel("),
        )
        assertTrue(
            "rows may only look the index up",
            enabledModels.contains("ModelSelectionUtils.catalogIndexContains("),
        )
        assertTrue(
            "the index must be built once in remember, not rebuilt on every composition",
            detailScreen.contains("remember(relayCatalogState, currentProvider.catalogModels)"),
        )
    }
}

private fun String.withoutComments(): String =
    lineSequence()
        .filterNot {
            val trimmed = it.trimStart()
            trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
        }
        .joinToString("\n")

/**
 * A relay catalog is the one on the user's own server, read through `catalogModels` (the only
 * source of a relay catalog) and expanded by the production `ProviderCatalogResolver.resolve()`;
 * it does not borrow any assumption from the built-in providers' catalogs. The ids deliberately
 * mix letter case, dated suffixes and bare ungrouped models to cover every candidate path of
 * `matchingModel`.
 */
private fun relayProviderWithProductionCatalog(): Provider {
    val catalog = listOf(
        relayModel("anthropic/claude-sonnet-4", "Claude Sonnet 4", "anthropic", "Anthropic", 200),
        relayModel("anthropic/claude-haiku-20260514", "Claude Haiku", "anthropic", "Anthropic", 150),
        relayModel("openai/GPT-4.1", "GPT-4.1", "openai", "OpenAI", 190),
        relayModel("openai/gpt-4.1-mini", "GPT-4.1 mini", "openai", "OpenAI", null),
        relayModel("google/gemini-2.5-pro", "Gemini 2.5 Pro", "google", "Google", 180),
        relayModel("google/gemini-2.5-flash", "Gemini 2.5 Flash", "google", "Google", null),
        relayModel("deepseek-chat", "DeepSeek Chat", null, null, null),
        relayModel("qwen/qwen3-max-preview", "Qwen3 Max Preview", "qwen", "Qwen", null),
        relayModel("local-llama-3.1-8b", "Llama 3.1 8B", null, null, null),
    )
    return Provider(
        id = "relay-hot-path",
        kind = ProviderKind.Relay,
        baseUrlText = "https://relay.example.test/v1",
        catalogModels = catalog,
        models = listOf(catalog[0].copy(isDefault = true), catalog[4]),
    )
}

private fun relayModel(
    id: String,
    name: String,
    groupKey: String?,
    groupName: String?,
    sortRank: Int?,
) = AIModel(
    id = id,
    name = name,
    reasoningModeAvailable = false,
    isAvailable = true,
    groupKey = groupKey,
    groupName = groupName,
    sortRank = sortRank,
)
