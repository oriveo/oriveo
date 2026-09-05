package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayImageConfig
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatRepositoryHotPathTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `send model selection keeps historical metadata model without catalog projection`() {
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
        val selection = resolveSendModelSelection(
            provider = provider,
            modelID = "o4-mini-2026-04-10",
        )

        assertEquals("o4-mini", selection.runtimeModelId)
        assertEquals("o4-mini", selection.storedModelId)
        assertEquals("o4-mini", selection.modelName)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `relay image config does not drive send model selection image capability`() {
        
        
        val provider = Provider(
            id = "provider-relay",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-5.4",
                    name = "gpt-5.4",
                    isDefault = true,
                ),
            ),
            catalogModels = listOf(
                AIModel(
                    id = "gpt-5.4",
                    name = "gpt-5.4",
                    isDefault = true,
                ),
            ),
            relayImage = RelayImageConfig(enabled = true),
        )

        val selection = resolveSendModelSelection(
            provider = provider,
            modelID = "gpt-5.4",
        )

        assertFalse(selection.supportsImageGen)
    }

    @Test
    fun `model with image gen capability marks send model selection as image capable`() {
        val provider = Provider(
            id = "provider-relay",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-image-1",
                    name = "gpt-image-1",
                    capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.ImageGen),
                    isDefault = true,
                ),
            ),
            catalogModels = listOf(
                AIModel(
                    id = "gpt-image-1",
                    name = "gpt-image-1",
                    capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.ImageGen),
                    isDefault = true,
                ),
            ),
        )

        val selection = resolveSendModelSelection(
            provider = provider,
            modelID = "gpt-image-1",
        )

        assertTrue(selection.supportsImageGen)
    }

    @Test
    fun `official image gen capability without profile is not image capable for send selection`() {
        val provider = Provider(
            id = "provider-openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-image-1",
                    name = "gpt-image-1",
                    capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.ImageGen),
                    isDefault = true,
                ),
            ),
            catalogModels = listOf(
                AIModel(
                    id = "gpt-image-1",
                    name = "gpt-image-1",
                    capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.ImageGen),
                    isDefault = true,
                ),
            ),
        )

        val selection = resolveSendModelSelection(
            provider = provider,
            modelID = "gpt-image-1",
        )

        assertFalse(selection.supportsImageGen)
    }

    @Test
    fun `relay web search send flag is constrained by transport envelope`() {
        val relayChatCompletions = Provider(
            id = "relay-chat",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
        )
        val relayResponses = Provider(
            id = "relay-responses",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIResponses),
        )

        assertFalse(shouldEnableWebSearchForSend(relayChatCompletions, requested = true))
        assertTrue(shouldEnableWebSearchForSend(relayResponses, requested = true))
        assertFalse(shouldEnableWebSearchForSend(relayResponses, requested = false))
    }
}
