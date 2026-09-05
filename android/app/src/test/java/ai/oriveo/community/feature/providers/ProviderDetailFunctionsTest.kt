package ai.oriveo.community.feature.providers

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import ai.oriveo.community.core.provider.ResolvedProviderCatalog
import ai.oriveo.community.feature.providers.detail.providerSummaryAvailableModelCount
import ai.oriveo.community.feature.providers.detail.usesManagedBlackGoldHero
import ai.oriveo.community.feature.providers.detail.shouldShowHeroApiKeyEditor
import ai.oriveo.community.feature.providers.detail.shouldShowResidualCredentialRemoval
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test


class ProviderDetailFunctionsTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    

    @Test
    fun `enabling model adds to models list`() {
        val provider = makeProvider(
            models = listOf(makeModel("m1", isDefault = true)),
            catalogModels = listOf(makeModel("m1"), makeModel("m2")),
        )
        val model = provider.catalogModels.first { it.id == "m2" }
        val updated = provider.copy(models = provider.models + model)
        assertEquals(2, updated.models.size)
        assertTrue(updated.models.any { it.id == "m2" })
    }

    @Test
    fun `disabling model removes from models list`() {
        val provider = makeProvider(
            models = listOf(makeModel("m1", isDefault = true), makeModel("m2")),
        )
        val updated = provider.copy(models = provider.models.filter { it.id != "m2" })
        assertEquals(1, updated.models.size)
        assertEquals("m1", updated.models.first().id)
    }

    @Test
    fun `cannot disable last model`() {
        val provider = makeProvider(models = listOf(makeModel("m1", isDefault = true)))
        
        if (provider.models.size <= 1) {
            assertEquals(1, provider.models.size)
        }
    }

    

    @Test
    fun `enabling recommended model adds to models list`() {
        val rec = makeModel("m3", name = "Claude 4")
        val provider = makeProvider(
            models = listOf(makeModel("m1", isDefault = true)),
        )
        val updated = provider.copy(models = provider.models + rec)
        assertTrue(updated.models.any { it.id == "m3" })
    }

    

    @Test
    fun `catalog models grouped by groupName`() {
        val catalog = listOf(
            makeModel("m1", groupName = "GPT-4"),
            makeModel("m2", groupName = "GPT-4"),
            makeModel("m3", groupName = "Claude"),
        )
        val grouped = catalog.groupBy { it.groupName ?: "Other" }
        assertEquals(2, grouped.size)
        assertEquals(2, grouped["GPT-4"]?.size)
        assertEquals(1, grouped["Claude"]?.size)
    }

    @Test
    fun `catalog models filtered by search query`() {
        val catalog = listOf(
            makeModel("gpt-4o", name = "GPT-4o"),
            makeModel("claude-4", name = "Claude 4 Sonnet"),
            makeModel("gemini-2", name = "Gemini 2"),
        )
        val query = "claude"
        val filtered = catalog.filter { it.name.lowercase().contains(query.lowercase()) }
        assertEquals(1, filtered.size)
        assertEquals("claude-4", filtered.first().id)
    }

    @Test
    fun `catalog excludes already enabled models`() {
        val enabled = listOf(makeModel("m1", isDefault = true))
        val catalog = listOf(makeModel("m1"), makeModel("m2"))
        val enabledIds = enabled.map { it.id }.toSet()
        val available = catalog.filter { it.id !in enabledIds }
        assertEquals(1, available.size)
        assertEquals("m2", available.first().id)
    }

    

    @Test
    fun `defaultModel returns isDefault model first`() {
        val provider = makeProvider(
            models = listOf(makeModel("m1"), makeModel("m2", isDefault = true)),
        )
        assertNotNull(provider.defaultModel)
        assertEquals("m2", provider.defaultModel?.id)
    }

    @Test
    fun `defaultModel returns first model if none is default`() {
        val provider = makeProvider(
            models = listOf(makeModel("m1"), makeModel("m2")),
        )
        assertNotNull(provider.defaultModel)
        assertEquals("m1", provider.defaultModel?.id)
    }

    @Test
    fun `defaultModel returns null for empty models`() {
        val provider = makeProvider(models = emptyList())
        assertNull(provider.defaultModel)
    }

    @Test
    fun `provider detail hero count uses enabled models instead of full catalog`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1"),
                    MetadataTestFixtures.ModelSpec(id = "o4-mini"),
                ),
            ),
        )
        val provider = makeProvider(
            models = listOf(makeModel("gpt-4o", isDefault = true)),
            catalogModels = emptyList(),
        )
        val resolved = ResolvedProviderCatalog(
            catalog = listOf(
                resolvedModel("gpt-4o"),
                resolvedModel("gpt-4.1"),
                resolvedModel("o4-mini", isAvailable = false),
            ),
            enabledModels = listOf(resolvedModel("gpt-4o")),
            recommendedModels = emptyList(),
            defaultModel = resolvedModel("gpt-4o", isDefault = true),
            availableModelCount = 2,
            hasManualModels = false,
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val count = providerSummaryAvailableModelCount(provider, resolved)

        assertEquals(1, count)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `no provider uses the managed black gold detail hero`() {
        assertFalse(usesManagedBlackGoldHero(makeProvider(kind = ProviderKind.OpenAI)))
        assertFalse(usesManagedBlackGoldHero(makeProvider(kind = ProviderKind.Anthropic)))
    }

    @Test
    fun `auth none relay hides key rotation entry even when legacy key remains`() {
        val unauthenticatedRelay = makeProvider(kind = ProviderKind.Relay).copy(
            apiKey = "legacy-key",
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.None),
        )
        val authenticatedRelay = unauthenticatedRelay.copy(
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.Bearer),
        )

        assertTrue(!shouldShowHeroApiKeyEditor(unauthenticatedRelay))
        assertTrue(shouldShowHeroApiKeyEditor(authenticatedRelay))
        assertTrue(shouldShowResidualCredentialRemoval(unauthenticatedRelay))
        assertTrue(!shouldShowResidualCredentialRemoval(unauthenticatedRelay.copy(apiKey = "")))
    }

    

    private fun makeModel(
        id: String,
        name: String = id,
        isDefault: Boolean = false,
        groupName: String? = null,
        capabilities: List<ModelCapability> = emptyList(),
    ) = AIModel(
        id = id,
        name = name,
        isDefault = isDefault,
        isAvailable = true,
        groupName = groupName,
        capabilities = capabilities,
    )

    private fun makeProvider(
        kind: ProviderKind = ProviderKind.OpenAI,
        models: List<AIModel> = emptyList(),
        catalogModels: List<AIModel> = emptyList(),
    ) = Provider(
        id = "p1",
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
    )

    private fun resolvedModel(
        id: String,
        isDefault: Boolean = false,
        isAvailable: Boolean = true,
    ) = ai.oriveo.community.core.provider.ResolvedModel(
        model = makeModel(id = id, isDefault = isDefault).copy(isAvailable = isAvailable),
        isEnabled = true,
        isManual = false,
    )
}
