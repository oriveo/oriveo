package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ResolvedModel
import ai.oriveo.community.core.provider.ResolvedProviderCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderCatalogGroupingTest {

    @Test
    fun `catalog grouping is metadata-driven and identical across aggregator kinds`() {
        val models = listOf(
            makeModel(
                "anthropic/claude-sonnet",
                name = "Claude Sonnet",
                groupKey = "anthropic",
                groupName = "Anthropic",
                sortRank = 200,
            ),
            makeModel(
                "openai/gpt-4.1",
                name = "GPT-4.1",
                groupKey = "openai",
                groupName = "OpenAI",
                sortRank = 190,
            ),
        )
        val openRouter = makeProvider(catalogModels = models).copy(kind = ProviderKind.OpenRouter)
        val siliconFlow = makeProvider(catalogModels = models).copy(kind = ProviderKind.SiliconFlow)

        val openRouterGroups = buildProviderCatalogGroups(
            openRouter, resolvedCatalog = resolvedCatalogFor(openRouter), searchQuery = "",
        )
        val siliconFlowGroups = buildProviderCatalogGroups(
            siliconFlow, resolvedCatalog = resolvedCatalogFor(siliconFlow), searchQuery = "",
        )

        // Both id lists must match, ordered by the sortRank published in the model catalog and
        // independent of provider.kind.
        assertEquals(
            "grouping order must not branch on provider.kind",
            openRouterGroups.map { it.id },
            siliconFlowGroups.map { it.id },
        )
    }


    @Test
    fun `buildProviderCatalogGroups groups openrouter catalog by vendor with fixed weight order`() {
        val provider = makeProvider(
            catalogModels = listOf(
                makeModel(
                    "qwen/qwen-max",
                    name = "Qwen Max",
                    groupKey = "qwen",
                    groupName = "Qwen",
                    sortRank = 80,
                    createdAt = 100.0,
                ),
                makeModel(
                    "anthropic/claude-3.7-sonnet",
                    name = "Claude 3.7 Sonnet",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    reasoningModeAvailable = true,
                    isRecommended = true,
                    sortRank = 180,
                    createdAt = 300.0,
                ),
                makeModel(
                    "anthropic/claude-3.5-haiku",
                    name = "Claude 3.5 Haiku",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    sortRank = 120,
                    createdAt = 200.0,
                ),
            ),
        )

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "")

        assertEquals(2, groups.size)
        assertEquals("anthropic", groups.first().id)
        assertEquals(listOf("Claude 3.7 Sonnet", "Claude 3.5 Haiku"), groups.first().models.map { it.name })
    }

    @Test
    fun `enabled default supplier no longer pushes its own catalog group to the top`() {
        val provider = makeProvider(
            models = listOf(
                makeModel(
                    "openai/gpt-4.1",
                    name = "GPT-4.1",
                    groupKey = "openai",
                    groupName = "OpenAI",
                    sortRank = 110,
                ).copy(isDefault = true),
            ),
            catalogModels = listOf(
                makeModel(
                    "openai/gpt-4.1-mini",
                    name = "GPT-4.1 mini",
                    groupKey = "openai",
                    groupName = "OpenAI",
                    sortRank = 112,
                ),
                makeModel(
                    "anthropic/claude-3.7-sonnet",
                    name = "Claude 3.7 Sonnet",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    sortRank = 180,
                ),
            ),
        )

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "")

        assertEquals(listOf("anthropic", "openai"), groups.map { it.id })
    }

    @Test
    fun `buildProviderCatalogGroups excludes enabled models`() {
        val provider = makeProvider(
            models = listOf(makeModel("openai/gpt-4.1")),
            catalogModels = listOf(
                makeModel("openai/gpt-4.1"),
                makeModel("anthropic/claude-3.7-sonnet", groupKey = "anthropic", groupName = "Anthropic"),
            ),
        )

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "")

        assertEquals(1, groups.size)
        assertEquals(listOf("anthropic/claude-3.7-sonnet"), groups.first().models.map { it.id })
    }

    @Test
    fun `search query narrows groups and auto expands`() {
        val provider = makeProvider(
            catalogModels = listOf(
                makeModel("openai/gpt-4.1", name = "GPT-4.1", groupKey = "openai", groupName = "OpenAI"),
                makeModel("anthropic/claude-3.7-sonnet", name = "Claude 3.7 Sonnet", groupKey = "anthropic", groupName = "Anthropic"),
            ),
        )

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "claude")

        assertEquals(1, groups.size)
        assertEquals("Anthropic", groups.first().title)
        assertTrue(shouldAutoExpandCatalogGroups("claude"))
        assertFalse(shouldAutoExpandCatalogGroups(""))
    }

    @Test
    fun `supplier query keeps the whole supplier group`() {
        val provider = makeProvider(
            catalogModels = listOf(
                makeModel(
                    "anthropic/claude-3.7-sonnet",
                    name = "Claude 3.7 Sonnet",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    sortRank = 180,
                    createdAt = 300.0,
                ),
                makeModel(
                    "anthropic/claude-3.5-haiku",
                    name = "Claude 3.5 Haiku",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    sortRank = 120,
                    createdAt = 200.0,
                ),
            ),
        )

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "anthropic")

        assertEquals(1, groups.size)
        assertEquals(
            listOf("Claude 3.7 Sonnet", "Claude 3.5 Haiku"),
            groups.first().models.map { it.name },
        )
    }

    @Test
    fun `models inside a supplier are sorted by metadata sortRank desc regardless of kind`() {
        // Model ordering looks only at sortRank; it never branches on createdAt or provider.kind.
        val provider = makeProvider(
            catalogModels = listOf(
                makeModel(
                    "anthropic/claude-sonnet",
                    name = "Claude Sonnet",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    sortRank = 220,
                    createdAt = 100.0,
                ),
                makeModel(
                    "anthropic/claude-haiku",
                    name = "Claude Haiku",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    isRecommended = true,
                    sortRank = 120,
                    createdAt = 200.0,
                ),
            ),
            kind = ProviderKind.OpenRouter,
        )

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "")

        assertEquals(listOf("Claude Sonnet", "Claude Haiku"), groups.first().models.map { it.name })
    }

    @Test
    fun `unweighted openrouter vendors are sorted by metadata sortRank before title`() {
        val provider = makeProvider(
            models = listOf(
                makeModel(
                    "nvidia/llama-3.1-nemotron-ultra",
                    name = "Nemotron Ultra",
                    groupKey = "nvidia",
                    groupName = "NVIDIA",
                    sortRank = 240,
                ),
            ),
            catalogModels = listOf(
                makeModel(
                    "nvidia/llama-3.1-nemotron-ultra",
                    name = "Nemotron Ultra",
                    groupKey = "nvidia",
                    groupName = "NVIDIA",
                    sortRank = 240,
                ),
                makeModel(
                    "nvidia/llama-3.1-nemotron-super",
                    name = "Nemotron Super",
                    groupKey = "nvidia",
                    groupName = "NVIDIA",
                    sortRank = 90,
                ),
                makeModel(
                    "bytedance-seed/seed-1.6",
                    name = "Seed 1.6",
                    groupKey = "bytedance-seed",
                    groupName = "ByteDance Seed",
                    sortRank = 180,
                ),
            ),
            kind = ProviderKind.OpenRouter,
        )

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "")

        assertEquals(listOf("nvidia", "bytedance-seed"), groups.map { it.id })
        assertEquals(listOf("Nemotron Super"), groups.first().models.map { it.name })
    }

    @Test
    fun `openrouter vendors sorted by metadata sortRank then alphabetically`() {
        // Ordering must be driven by the sortRank published in the model catalog (uiHints.rank)
        // rather than a vendor weight table baked into the client.
        val provider = makeProvider(
            catalogModels = listOf(
                makeModel("qwen/qwen-max", name = "Qwen Max", groupKey = "qwen", groupName = "Qwen", sortRank = 40),
                makeModel("google/gemini-2.5-pro", name = "Gemini 2.5 Pro", groupKey = "google", groupName = "Google", sortRank = 50),
                makeModel("x-ai/grok-3", name = "Grok 3", groupKey = "x-ai", groupName = "xAI", sortRank = 10),
                makeModel("openai/gpt-4.1", name = "GPT-4.1", groupKey = "openai", groupName = "OpenAI", sortRank = 70),
                makeModel("anthropic/claude-sonnet", name = "Claude Sonnet", groupKey = "anthropic", groupName = "Anthropic", sortRank = 80),
                makeModel("deepseek/deepseek-r1", name = "DeepSeek R1", groupKey = "deepseek", groupName = "DeepSeek", sortRank = 20),
            ),
            kind = ProviderKind.OpenRouter,
        )

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "")

        // Descending rank: anthropic(80) -> openai(70) -> google(50) -> qwen(40) -> deepseek(20) -> x-ai(10)
        assertEquals(
            listOf("anthropic", "openai", "google", "qwen", "deepseek", "x-ai"),
            groups.map { it.id },
        )
    }

    @Test
    fun `siliconflow vendors sorted by metadata sortRank then alphabetically`() {
        val provider = makeProvider(
            catalogModels = listOf(
                makeModel("stepfun-ai/step-3", name = "Step 3", groupKey = "stepfun-ai", groupName = "StepFun", sortRank = 20),
                makeModel("qwen/Qwen3-32B", name = "Qwen3 32B", groupKey = "qwen", groupName = "Qwen", sortRank = 60),
                makeModel("deepseek-ai/DeepSeek-V3.1", name = "DeepSeek V3.1", groupKey = "deepseek-ai", groupName = "DeepSeek", sortRank = 70),
                makeModel("zai-org/GLM-4.5V", name = "GLM 4.5V", groupKey = "zai-org", groupName = "Z.ai / GLM", sortRank = 40),
                makeModel("moonshotai/Kimi-K2", name = "Kimi K2", groupKey = "moonshotai", groupName = "Moonshot AI", sortRank = 10),
            ),
        ).copy(kind = ProviderKind.SiliconFlow)

        val groups = buildProviderCatalogGroups(provider, resolvedCatalog = resolvedCatalogFor(provider), searchQuery = "")

        assertEquals(
            listOf("deepseek-ai", "qwen", "zai-org", "stepfun-ai", "moonshotai"),
            groups.map { it.id },
        )
    }

    @Test
    fun `single explicit vendor group remains visible when mixed with ungrouped models`() {
        val provider = makeProvider(
            models = listOf(
                makeModel(
                    "vendor-a/model-1",
                    name = "Vendor A One",
                    groupKey = "vendor-a",
                    groupName = "Vendor A",
                    sortRank = 220,
                ).copy(isDefault = true),
                makeModel(
                    "orphan/model",
                    name = "Orphan",
                ),
            ),
        ).copy(kind = ProviderKind.OpenRouter)

        val groups = groupModelsByVendor(provider, provider.models)

        assertEquals(listOf("Vendor A", null), groups.map { it.groupName })
        assertEquals(listOf("vendor-a/model-1"), groups.first().models.map { it.id })
        assertEquals(listOf("orphan/model"), groups.last().models.map { it.id })
    }

    @Test
    fun `detail enabled groups preserve enabled model order`() {
        val provider = makeProvider(
            models = listOf(
                makeModel("zeta/model-2", groupKey = "zeta", groupName = "Zeta", sortRank = 1),
                makeModel("zeta/model-1", groupKey = "zeta", groupName = "Zeta", sortRank = 999),
                makeModel("alpha/model", groupKey = "alpha", groupName = "Alpha", sortRank = 500),
            ),
        ).copy(kind = ProviderKind.OpenAI)

        val groups = detailEnabledModelGroups(provider)

        assertEquals(listOf("zeta", "alpha"), groups.map { it.id })
        assertEquals(listOf("zeta/model-2", "zeta/model-1"), groups.first().models.map { it.id })
    }

    /** BYOK providers are sorted by sortRank descending; a higher published rank comes first. */
    @Test
    fun `sortedEnabledModels still scores BYOK provider models`() {
        val provider = makeProvider(
            models = listOf(
                makeModel("low-rank", name = "Low", sortRank = 110),
                makeModel("high-rank", name = "High", sortRank = 180),
            ),
        ).copy(kind = ProviderKind.OpenRouter)

        assertEquals(listOf("high-rank", "low-rank"), sortedEnabledModels(provider).map { it.id })
    }

    @Test
    fun `sortedProvidersForModelPicker prioritizes stronger providers`() {
        val openAI = makeProvider(
            models = listOf(makeModel("gpt-4.1", name = "GPT-4.1", sortRank = 110)),
            catalogModels = listOf(makeModel("gpt-4.1", name = "GPT-4.1", sortRank = 110)),
        ).copy(kind = ProviderKind.OpenAI)
        val anthropic = makeProvider(
            models = listOf(makeModel("claude-3.7-sonnet", name = "Claude 3.7 Sonnet", sortRank = 165)),
            catalogModels = listOf(makeModel("claude-3.7-sonnet", name = "Claude 3.7 Sonnet", sortRank = 165)),
        ).copy(kind = ProviderKind.Anthropic)

        val sorted = sortedProvidersForModelPicker(listOf(openAI, anthropic))

        assertEquals(ProviderKind.Anthropic, sorted.first().kind)
        assertEquals(ProviderKind.OpenAI, sorted.last().kind)
    }

    // Normalising vendor keys such as thudm/zai-org is handled by the published catalog through its
    // `vendorKey`/`groupKey` fields rather than by parsing slugs in the client.

    // ProviderCatalogResolver does not feed catalogModels back for catalog-backed providers, so this
    // helper builds a Relay provider (whose catalog is client-side) and some tests copy it to
    // OpenRouter. The grouping logic under test is the same either way.
    private fun makeProvider(
        models: List<AIModel> = emptyList(),
        catalogModels: List<AIModel> = emptyList(),
        kind: ProviderKind = ProviderKind.Relay,
    ) = Provider(
        id = "test-provider",
        kind = kind,
        models = models,
        catalogModels = catalogModels,
    )

    private fun makeModel(
        id: String,
        name: String = id,
        groupKey: String? = null,
        groupName: String? = null,
        reasoningModeAvailable: Boolean = false,
        isRecommended: Boolean = false,
        sortRank: Int? = null,
        createdAt: Double? = null,
    ) = AIModel(
        id = id,
        name = name,
        reasoningModeAvailable = reasoningModeAvailable,
        isAvailable = true,
        isRecommended = isRecommended,
        groupKey = groupKey,
        groupName = groupName,
        sortRank = sortRank,
        createdAt = createdAt,
    )

    /**
     * Builds an explicit ResolvedProviderCatalog to inject into buildProviderCatalogGroups, bypassing
     * the catalog lookup ProviderCatalogResolver would otherwise perform.
     */
    private fun resolvedCatalogFor(provider: Provider): ResolvedProviderCatalog {
        val enabledIds = provider.models.map { it.id }.toSet()
        val catalog = provider.catalogModels.map { model ->
            ResolvedModel(model = model, isEnabled = model.id in enabledIds, isManual = false)
        }
        return ResolvedProviderCatalog(
            catalog = catalog,
            enabledModels = catalog.filter { it.isEnabled },
            recommendedModels = catalog.filter { it.model.isRecommended && !it.isEnabled },
            defaultModel = catalog.firstOrNull { it.model.isDefault } ?: catalog.firstOrNull(),
            availableModelCount = catalog.size,
            hasManualModels = false,
        )
    }
}
