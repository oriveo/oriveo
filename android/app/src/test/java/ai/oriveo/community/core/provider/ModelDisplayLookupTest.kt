package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class ModelDisplayLookupTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `official provider display lookup resolves alias by metadata without catalog projection`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf(
                    "gpt-4o" to "gpt-4o",
                    "gpt-4o-2024-08-06" to "gpt-4o",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "gpt-4o",
                        canonicalModelId = "gpt-4o",
                        displayName = "GPT-4o Latest",
                    ),
                ),
            ),
        )
        val provider = Provider(
            id = "provider-openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(id = "gpt-4o", name = "GPT-4o Local", canonicalModelId = "gpt-4o"),
            ),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val lookup = ModelDisplayLookup(listOf(provider))
        val providerName = lookup.providerDisplayName(provider.id)
        val modelName = lookup.modelDisplayName(
            providerId = provider.id,
            modelId = "gpt-4o-2024-08-06",
            fallback = "Legacy Snapshot",
        )

        assertEquals(ProviderKind.OpenAI.displayName, providerName)
        assertEquals("GPT-4o Latest", modelName)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `relay display lookup uses local provider and model name`() {
        val provider = Provider(
            id = "provider-relay",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(id = "custom-model", name = "Custom Relay Model", isDefault = true),
            ),
            catalogModels = listOf(
                AIModel(id = "custom-model", name = "Custom Relay Model"),
            ),
            customName = "My Relay",
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val lookup = ModelDisplayLookup(listOf(provider))
        val providerName = lookup.providerDisplayName(provider.id)
        val modelName = lookup.modelDisplayName(
            providerId = provider.id,
            modelId = "custom-model",
            fallback = "Fallback",
        )

        assertEquals("My Relay", providerName)
        assertEquals("Custom Relay Model", modelName)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }
}
