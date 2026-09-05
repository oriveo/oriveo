package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatConversationStateTest {

    @Test
    fun `missing provider keeps existing conversation readable even when provider list is empty`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Missing provider",
            providerID = "provider-missing",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-1",
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = emptyList(),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
        )

        assertFalse(state.isReadOnly)
        assertEquals(null, state.issue)
        assertEquals(null, state.provider)
        assertEquals(null, state.model)
    }

    @Test
    fun `new chat without providers is still blocked`() {
        val state = resolveChatConversationState(
            conversation = null,
            providers = emptyList(),
            activeProviderId = null,
            activeModelId = null,
        )

        assertTrue(state.isReadOnly)
        assertEquals(ChatConversationIssueKind.NoProvidersAvailable, state.issue?.kind)
    }

    @Test
    fun `missing provider falls back to another configured provider`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Missing provider",
            providerID = "provider-missing",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-missing",
        )
        val fallbackModel = AIModel(id = "fallback-model", name = "Fallback Model", isDefault = true)
        val fallbackProvider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(fallbackModel),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(fallbackProvider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
        )

        assertFalse(state.isReadOnly)
        assertEquals(null, state.issue)
        assertEquals(fallbackProvider.id, state.provider?.id)
        assertEquals(fallbackModel.id, state.model?.id)
    }

    @Test
    fun `missing model keeps conversation readable without issue banner`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Missing model",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-missing",
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "model-available", name = "Available")),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
        )

        assertFalse(state.isReadOnly)
        assertEquals(null, state.issue)
        assertEquals("model-available", state.model?.id)
    }

    @Test
    fun `unavailable model keeps conversation readable without issue banner`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Unavailable model",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-unavailable",
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "model-unavailable",
                    name = "Unavailable",
                    isAvailable = false,
                ),
            ),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
        )

        assertFalse(state.isReadOnly)
        assertEquals(null, state.issue)
        assertEquals("model-unavailable", state.model?.id)
    }

    @Test
    fun `provider issue keeps conversation available without extra attention state`() {
        val model = AIModel(id = "model-1", name = "GPT-4o")
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Issue("Key expired"),
            models = listOf(model),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Provider issue",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-1",
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
        )

        assertFalse(state.isReadOnly)
        assertEquals(null, state.issue)
    }
}
