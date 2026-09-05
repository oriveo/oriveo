package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class ChatMessageDisplayResolverTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `assistant message metadata resolves by metadata without catalog projection`() {
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
        val message = ChatMessage(
            id = "message-1",
            role = ChatRole.Assistant,
            text = "Hello",
            providerID = provider.id,
            providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI",
            modelID = "gpt-4o-2024-08-06",
            modelName = "Stored Snapshot Name",
            state = ChatMessageState.Delivered,
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val metadata = resolveMessageDisplayMetadata(
            message = message,
            displayLookup = ModelDisplayLookup(listOf(provider)),
        )

        assertEquals("OpenAI", metadata.providerName)
        assertEquals("GPT-4o Latest", metadata.modelName)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }
}
