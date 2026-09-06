package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ManualRetainedResolverTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `case 1 metadata hit and locally enabled shows in official catalog`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val provider = officialProvider(
            models = listOf(model("gpt-4o", isDefault = true)),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertTrue(resolved.enabledModels.any { it.model.id == "gpt-4o" })
        assertFalse(resolved.hasManualModels)
    }

    @Test
    fun `case 2 metadata hit and locally enabled flag on stays same`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val provider = officialProvider(models = listOf(model("gpt-4o", isDefault = true)))

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertTrue(resolved.enabledModels.any { it.model.id == "gpt-4o" })
        assertFalse(resolved.hasManualModels)
    }

    @Test
    fun `case 3 metadata hit but not enabled shows in official catalog as disabled`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf(
                    "gpt-4o" to "gpt-4o",
                    "gpt-4o-mini" to "gpt-4o-mini",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o-mini", canonicalModelId = "gpt-4o-mini"),
                ),
            ),
        )
        val provider = officialProvider(models = listOf(model("gpt-4o", isDefault = true)))

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertEquals(2, resolved.catalog.size)

        assertEquals(1, resolved.enabledModels.size)
        assertEquals("gpt-4o", resolved.enabledModels.first().model.id)

        val miniEntry = resolved.catalog.firstOrNull { it.model.id == "gpt-4o-mini" }
        assertNotNull(miniEntry)
        assertFalse(miniEntry!!.isEnabled)
        assertFalse(miniEntry.isManual)
    }

    @Test
    fun `case 4 metadata miss but locally enabled with flag off keeps as manual`() {

        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val provider = officialProvider(
            models = listOf(
                model("gpt-4o", isDefault = true),
                model("legacy-model"),
            ),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertTrue(resolved.hasManualModels)
        val manual = resolved.catalog.firstOrNull { it.isManual }
        assertNotNull(manual)
        assertEquals("legacy-model", manual!!.model.id)
        assertTrue(manual.isEnabled)
    }

    @Test
    fun `case 5 metadata miss locally enabled flag on prunes via utility`() {

        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val provider = officialProvider(
            models = listOf(
                model("gpt-4o", isDefault = true),
                model("legacy-model"),
            ),
        )

        val pruned = ManualRetainedPruner.prune(
            provider = provider,
            isPruningEnabled = true,
        )

        assertEquals(1, pruned.models.size)
        assertEquals("gpt-4o", pruned.models.first().id)

        assertTrue(pruned.models.first().isDefault)
    }

    @Test
    fun `case 5 flag off keeps manual retained entries untouched`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val provider = officialProvider(
            models = listOf(
                model("gpt-4o", isDefault = true),
                model("legacy-model"),
            ),
        )

        val pruned = ManualRetainedPruner.prune(
            provider = provider,
            isPruningEnabled = false,
        )

        assertEquals(2, pruned.models.size)
    }

    @Test
    fun `case 5 pruning falls back default to metadata when user default is manual`() {

        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val provider = officialProvider(
            models = listOf(
                model("gpt-4o"),
                model("legacy-model", isDefault = true),
            ),
        )

        val pruned = ManualRetainedPruner.prune(
            provider = provider,
            isPruningEnabled = true,
        )

        assertEquals(1, pruned.models.size)
        assertEquals("gpt-4o", pruned.models.first().id)
        assertTrue(
            "after pruning default legacy-model, gpt-4o (metadata defaultModelId) becomes the new default",
            pruned.models.first().isDefault,
        )
    }

    @Test
    fun `case 6 metadata miss and not enabled does not appear`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val provider = officialProvider(models = listOf(model("gpt-4o", isDefault = true)))

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertFalse(resolved.catalog.any { it.model.id == "deprecated-model" })
    }

    @Test
    fun `case 7 metadata miss and not enabled flag on still does not appear`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val provider = officialProvider(models = listOf(model("gpt-4o", isDefault = true)))

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertFalse(resolved.catalog.any { it.model.id == "legacy-model" })
    }

    @Test
    fun `case 8 alias hit canonical renders via canonical row`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf(
                    "gpt-4o" to "gpt-4o",
                    "gpt-4o-2024-08-06" to "gpt-4o",
                ),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )

        val provider = officialProvider(
            models = listOf(model("gpt-4o-2024-08-06", isDefault = true)),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertTrue(resolved.enabledModels.any { it.model.id == "gpt-4o" })

        assertFalse(resolved.hasManualModels)
    }

    @Test
    fun `offline with no metadata and no catalog retains only enabled models`() {

        MetadataTestFixtures.clear()
        val provider = officialProvider(
            models = listOf(model("previously-enabled", isDefault = true)),
            catalogModels = emptyList(),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertTrue(resolved.hasManualModels)
        assertEquals(1, resolved.catalog.size)
        assertEquals("previously-enabled", resolved.catalog.first().model.id)
    }

    @Test
    fun `metadata unavailable must not fall back to catalogModels for official provider`() {
        MetadataTestFixtures.clear()
        val provider = officialProvider(
            models = emptyList(),

            catalogModels = listOf(
                model("leaked-from-catalog"),
                model("another-leaked"),
            ),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertFalse(
            "official provider must not fall back to catalogModels",
            resolved.catalog.any { it.model.id == "leaked-from-catalog" },
        )
        assertFalse(resolved.catalog.any { it.model.id == "another-leaked" })
    }

    @Test
    fun `relay continues to use catalogModels regardless of metadata`() {
        MetadataTestFixtures.clear()
        val relay = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(model("custom", isDefault = true)),
            catalogModels = listOf(model("custom"), model("also-custom")),
        )

        val resolved = ProviderCatalogResolver.resolve(relay)

        assertEquals(2, resolved.catalog.size)
        assertTrue(resolved.catalog.any { it.model.id == "custom" })
        assertTrue(resolved.catalog.any { it.model.id == "also-custom" })
    }

    // ── Helpers ──

    private fun officialProvider(
        models: List<AIModel>,
        catalogModels: List<AIModel> = emptyList(),
    ): Provider = Provider(
        id = "official-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
    )

    private fun model(
        id: String,
        isDefault: Boolean = false,
        canonicalModelId: String? = null,
    ): AIModel = AIModel(
        id = id,
        name = id,
        isAvailable = true,
        isDefault = isDefault,
        canonicalModelId = canonicalModelId,
    )
}
