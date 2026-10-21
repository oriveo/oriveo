package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A Relay image route configuration error (protocol cannot generate images / no chat driver model) must go through the
 * failure handling of sendMessage: it does not throw, the assistant message is persisted as failed, and the error detail
 * is a localized key that ErrorMapper recognizes.
 */
class ChatRepositoryRelayImageRouteFailureTest {

    private val updates = mutableListOf<ChatMessage>()

    @Test
    fun `unsupported image route fails the assistant message instead of escaping`() = runTest {
        val failed = send(
            transport = RelayTransport.AnthropicMessages,
            models = listOf(imageModel()),
        )

        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals("relay_image_route_unsupported", failed.errorDetail)
    }

    @Test
    fun `missing chat driver model fails the assistant message instead of escaping`() = runTest {
        val failed = send(
            transport = RelayTransport.OpenAIResponses,
            models = listOf(imageModel()),
        )

        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals("relay_image_chat_model_required", failed.errorDetail)
    }

    private fun imageModel() = AIModel(
        id = IMAGE_MODEL,
        name = IMAGE_MODEL,
        capabilities = listOf(ModelCapability.ImageGen),
    )

    private suspend fun send(transport: RelayTransport, models: List<AIModel>): ChatMessage {
        val provider = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            apiKey = "relay-key",
            baseUrlText = "https://relay.example.com/v1",
            status = ProviderConnectionState.Connected,
            relayRequested = RelayRequestedConfig(
                transport = transport,
                authMode = RelayAuthMode.Bearer,
                resolvedAPIBaseURL = "https://relay.example.com/v1",
            ),
            models = models,
        )
        val providerRepository = mockk<ProviderRepository>(relaxed = true)
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        coEvery { conversationRepository.updateMessage(any(), capture(updates)) } returns Unit
        val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        repository.sendMessage(
            conversation = Conversation(
                id = "conversation-1", title = "t", providerID = provider.id,
                providerKind = provider.kind, modelID = IMAGE_MODEL,
            ),
            text = "draw a cat",
            provider = provider,
            modelID = IMAGE_MODEL,
            existingMessages = emptyList(),
            requestOptions = ChatRequestOptions(activeModel = models.first()),
            outputs = ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow(null),
            ),
        )
        return updates.last()
    }

    private companion object {
        const val IMAGE_MODEL = "gpt-image-1"
    }
}
