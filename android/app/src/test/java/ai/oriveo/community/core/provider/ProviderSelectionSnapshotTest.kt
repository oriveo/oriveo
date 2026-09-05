package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProviderSelectionSnapshotTest {
    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `current and default model resolve from enabled models without catalog projection`() {
        val provider = Provider(
            id = "provider-openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-4o",
                    name = "GPT-4o",
                    canonicalModelId = "gpt-4o",
                    isDefault = true,
                ),
                AIModel(
                    id = "gpt-4o-mini",
                    name = "GPT-4o Mini",
                    canonicalModelId = "gpt-4o-mini",
                ),
            ),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val currentModel = ProviderSelectionSnapshot.currentModel(
            provider = provider,
            storedModelId = "gpt-4o-2024-08-06",
        )
        val defaultModel = ProviderSelectionSnapshot.defaultModel(provider)

        assertEquals("gpt-4o", currentModel?.id)
        assertEquals("gpt-4o", defaultModel?.id)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `empty enabled models returns null default without catalog fallback`() {
        val provider = Provider(
            id = "provider-openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = emptyList(),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val defaultModel = ProviderSelectionSnapshot.defaultModel(provider)

        assertNull(defaultModel)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `metadata default model is used when user default is absent and no catalog projection occurs`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "o4-mini",
                resolveMap = mapOf(
                    "o4-mini" to "o4-mini",
                    "o4-mini-2026-04-10" to "o4-mini",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "o4-mini",
                        canonicalModelId = "o4-mini",
                        displayName = "o4-mini",
                    ),
                ),
            ),
        )
        val provider = Provider(
            id = "provider-openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-4o",
                    name = "GPT-4o",
                    canonicalModelId = "gpt-4o",
                ),
                AIModel(
                    id = "o4-mini-2026-04-10",
                    name = "o4-mini",
                    canonicalModelId = "o4-mini",
                ),
            ),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val defaultModel = ProviderSelectionSnapshot.defaultModel(provider)

        assertEquals("o4-mini-2026-04-10", defaultModel?.id)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `persisted selection resolves canonical requested id without catalog projection`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                resolveMap = mapOf(
                    "gpt-5.4" to "gpt-5.4",
                    "gpt-5.4-2026-03-05" to "gpt-5.4",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "gpt-5.4",
                        canonicalModelId = "gpt-5.4",
                        displayName = "GPT-5.4",
                    ),
                ),
            ),
        )
        val provider = Provider(
            id = "provider-openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-5.4-2026-03-05",
                    name = "GPT-5.4",
                    canonicalModelId = "gpt-5.4",
                ),
            ),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val selection = ProviderSelectionSnapshot.persistedSelection(
            provider = provider,
            requestedModelId = "gpt-5.4",
        )

        assertEquals("gpt-5.4-2026-03-05", selection?.model?.id)
        assertEquals("gpt-5.4", selection?.storedModelId)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `disabled historical model still resolves as current model via metadata without catalog projection`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf(
                    "gpt-4o" to "gpt-4o",
                    "o4-mini-2026-04-10" to "o4-mini",
                    "o4-mini" to "o4-mini",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "gpt-4o",
                        canonicalModelId = "gpt-4o",
                        displayName = "GPT-4o",
                    ),
                    MetadataTestFixtures.ModelSpec(
                        id = "o4-mini",
                        canonicalModelId = "o4-mini",
                        displayName = "o4-mini",
                    ),
                ),
            ),
        )
        val provider = Provider(
            id = "provider-openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-4o",
                    name = "GPT-4o",
                    canonicalModelId = "gpt-4o",
                    isDefault = true,
                ),
            ),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val currentModel = ProviderSelectionSnapshot.currentModel(
            provider = provider,
            storedModelId = "o4-mini-2026-04-10",
        )
        val defaultModel = ProviderSelectionSnapshot.defaultModel(provider)

        assertEquals("o4-mini", currentModel?.id)
        assertEquals("o4-mini", currentModel?.canonicalModelId)
        assertEquals("o4-mini", currentModel?.name)
        assertEquals("gpt-4o", defaultModel?.id)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }
}
