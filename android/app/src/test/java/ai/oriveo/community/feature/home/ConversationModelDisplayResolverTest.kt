package ai.oriveo.community.feature.home

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationModelDisplayResolverTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `conversation row model display resolves by metadata without catalog projection`() {
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
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-4o",
                    name = "GPT-4o Local",
                    canonicalModelId = "gpt-4o",
                ),
            ),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Test",
            providerID = provider.id,
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o-2024-08-06",
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val displayLookup = ModelDisplayLookup(listOf(provider))
        val modelName = resolveConversationModelName(
            conversation = conversation,
            provider = provider,
            displayLookup = displayLookup,
        )

        assertEquals("GPT-4o Latest", modelName)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }
}
