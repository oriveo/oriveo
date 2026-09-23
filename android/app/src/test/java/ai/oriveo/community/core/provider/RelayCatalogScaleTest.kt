package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * At relay catalog scale, the catalog resolution that runs before every write must not grow
 * with "enabled x catalog".
 *
 * A relay catalog comes from the user's own server (thousands of entries are normal), and
 * "add all" writes the whole catalog into `provider.models`. Scanning the whole catalog for
 * each enabled model, with a regex per pair, made a single [prepareProviderForUpsert] take
 * 650-1250ms at 1500 x 1500 on a desktop JVM, and it runs on every Provider write.
 *
 * Equivalence is checked against the **production** pairwise functions
 * [ModelSelectionUtils.matchingModel] / [ModelSelectionUtils.modelsShareSameRemoteModel],
 * not a copy of them inside the test.
 */
class RelayCatalogScaleTest {

    @Before
    fun setUp() {
        // Give relay enrichment real official catalogs to hit, so the production cross-provider match runs.
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o", "gpt-4o-mini" to "gpt-4o-mini", "gpt-4.1" to "gpt-4.1"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o", displayName = "GPT-4o"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o-mini", canonicalModelId = "gpt-4o-mini"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1", canonicalModelId = "gpt-4.1"),
                ),
            ),
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Anthropic,
                defaultModelId = "claude-sonnet-4-5",
                resolveMap = mapOf("claude-sonnet-4-5" to "claude-sonnet-4-5"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "claude-sonnet-4-5", canonicalModelId = "claude-sonnet-4-5"),
                ),
            ),
        )
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `catalog match index agrees with the production pairwise matcher`() {
        val catalog = trickyCatalog()
        val index = ModelSelectionUtils.catalogMatchIndex(catalog)
        val queries = catalog.map { it.id } + listOf(
            "GPT-4O", " gpt-4o ", "manual-gpt-4o", "gpt-4o-2024-08-06", "claude-3-5-sonnet-20241022",
            "claude-3-5-sonnet", "Qwen/QWEN2.5-72B-INSTRUCT", "not-in-catalog", "", "   ", "manual-",
        )
        queries.forEach { query ->
            assertSame(
                "match($query) must return the same catalog object as matchingModel",
                ModelSelectionUtils.matchingModel(catalog, query),
                index.match(query),
            )
        }

        val probes = catalog + listOf(
            model("Mystery Model", name = "GPT-4o"),
            model("relay-only-model", name = "   "),
            model("manual-deepseek-chat"),
            model("gpt-4.1-2025-04-14"),
            model("x", canonicalModelId = "claude-3-5-sonnet-20241022"),
        )
        listOf(ProviderKind.Relay, ProviderKind.OpenRouter, ProviderKind.SiliconFlow, ProviderKind.OpenAI).forEach { kind ->
            probes.forEach { probe ->
                assertEquals(
                    "sharesRemoteModelWithAny(${probe.id}, $kind)",
                    catalog.any { ModelSelectionUtils.modelsShareSameRemoteModel(probe, it, kind) },
                    index.sharesRemoteModelWithAny(probe, kind),
                )
            }
        }
    }

    @Test
    fun `resolve keeps the enabled and manual sets of the pairwise implementation`() {
        val catalog = relayCatalog(400)
        val manual = listOf(
            model("my-private-finetune", isManual = true),
            model("manual-gpt-4o", isManual = true),
            model("GPT-4O-2024-08-06"),
        )
        val provider = relayProvider(catalog = catalog, models = catalog.take(250) + manual)

        val resolved = ProviderCatalogResolver.resolve(provider)

        // resolve enriches the catalog itself in production, so the reference must use the same enriched catalog.
        val enrichedCatalog = RelayOfficialCatalogResolver.enrichCatalog(provider, MetadataClient.relayRuntimeConfig())
        val expectedEnabledIds = provider.models
            .mapNotNull { ModelSelectionUtils.matchingModel(enrichedCatalog, it.id)?.id }
            .toSet()
        val expectedManualIds = provider.models
            .filter { enabled ->
                enrichedCatalog.none { ModelSelectionUtils.modelsShareSameRemoteModel(enabled, it, provider.kind) }
            }
            .map { it.id }

        assertEquals(expectedEnabledIds, resolved.catalog.filter { it.isEnabled && !it.isManual }.map { it.model.id }.toSet())
        assertEquals(expectedManualIds, resolved.catalog.filter { it.isManual }.map { it.model.id })
        assertTrue("precondition: the reference must contain manual models", expectedManualIds.isNotEmpty())
        assertTrue("precondition: the reference must contain enabled matches", expectedEnabledIds.size >= 250)
    }

    /**
     * Measures the production write entry point [prepareProviderForUpsert] (enrichment + catalog
     * resolution) with a 1500 model relay catalog and all 1500 enabled (the shape "add all"
     * produces): median of 5 runs after 2 warmups.
     *
     * The pairwise implementation took 650-1250ms on the same input; the 150ms budget leaves
     * ample headroom on slower machines.
     */
    @Test
    fun `finalizing a 1500 model relay with everything enabled stays far below a frame budget multiple`() {
        val catalog = relayCatalog(1_500)
        val provider = relayProvider(catalog = catalog, models = catalog)

        val medianMs = medianMillis(warmups = 2, runs = 5) { prepareProviderForUpsert(provider) }
        println("RelayCatalogScaleTest prepareProviderForUpsert catalog=1500 enabled=1500 median=${"%.1f".format(medianMs)}ms")

        val prepared = prepareProviderForUpsert(provider)
        assertEquals(1_500, prepared.cachedAvailableModelCount)
        assertTrue(
            "prepareProviderForUpsert(1500 x 1500) median ${"%.1f".format(medianMs)}ms exceeds the 150ms budget",
            medianMs < 150.0,
        )
    }

    private fun medianMillis(warmups: Int, runs: Int, block: () -> Unit): Double {
        repeat(warmups) { block() }
        val samples = (1..runs).map {
            val start = System.nanoTime()
            block()
            (System.nanoTime() - start) / 1_000_000.0
        }.sorted()
        return samples[samples.size / 2]
    }

    private fun relayProvider(catalog: List<AIModel>, models: List<AIModel>): Provider = Provider(
        id = "5f0c7c52-5a8e-4a0e-9d7e-3b1f0a9c2e11",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        models = models.mapIndexed { index, model -> model.copy(isDefault = index == 0) },
        catalogModels = catalog,
        baseUrlText = "https://relay.example.com/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
    )

    private fun model(
        id: String,
        name: String = id,
        canonicalModelId: String? = null,
        isManual: Boolean = false,
    ) = AIModel(
        id = id,
        name = name,
        capabilities = listOf(ModelCapability.Text),
        canonicalModelId = canonicalModelId,
        isManual = isManual,
    )

    /** Covers every branch of matchingModel: case, surrounding whitespace, the manual- prefix, snapshot date suffixes, canonical ids, duplicates. */
    private fun trickyCatalog(): List<AIModel> = listOf(
        model("gpt-4o"),
        model("GPT-4o", name = "GPT-4o duplicate by case"),
        model(" gpt-4o-mini "),
        model("gpt-4o-2024-08-06"),
        model("manual-deepseek-chat"),
        model("claude-3-5-sonnet-20241022"),
        model("claude-sonnet-4-5", canonicalModelId = "claude-sonnet-4-5-20250929"),
        model("Qwen/Qwen2.5-72B-Instruct"),
        model("gemini-2.5-pro", name = "Gemini 2.5 Pro"),
        model("gemini-2.5-pro-2025-06-17", name = "gemini 2.5 pro"),
        model("relay-alias", canonicalModelId = "gpt-4.1"),
        model("blank-name", name = ""),
    )

    /** The shape of a real relay catalog: official ids, snapshot dates, vendor prefixes, channel tags and case variants mixed together. */
    private fun relayCatalog(size: Int): List<AIModel> {
        val bases = listOf(
            "gpt-4o", "gpt-4o-mini", "gpt-4.1", "o3", "o4-mini", "claude-sonnet-4-5", "claude-3-5-haiku",
            "gemini-2.5-pro", "gemini-2.5-flash", "deepseek-chat", "deepseek-reasoner", "qwen-max",
            "glm-4.6", "kimi-k2", "MiniMax-M2", "grok-4",
        )
        val vendors = listOf("openai", "anthropic", "google", "deepseek-ai", "Qwen", "zai-org", "moonshotai", "x-ai")
        val ids = LinkedHashSet<String>()
        var i = 0
        while (ids.size < size) {
            val base = bases[i % bases.size]
            val vendor = vendors[i % vendors.size]
            ids += when (i % 6) {
                0 -> if (i < bases.size) base else "$base-${i / bases.size}"
                1 -> "$base-2025${(i % 12 + 1).toString().padStart(2, '0')}${(i % 28 + 1).toString().padStart(2, '0')}"
                2 -> "$vendor/$base-$i"
                3 -> "[channel$i]$base"
                4 -> "${base.uppercase()}-THINKING-$i"
                else -> "$base:free-$i"
            }
            i++
        }
        return ids.map { model(it) }
    }
}
