package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.streaming.ChatStreamingManager
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A failed message whose parameter was rejected is resent without that parameter: the continuation
 * target that [ChatRetryCoordinator.retryWithoutLocalCustomFields] hands to the send carries a
 * one-shot omit marker (omit_parameter_once:<name>), and the outbound request drops the parameter.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatRetryCoordinatorParameterOmitTest {
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)

    private val provider = Provider(
        id = "provider-openai",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = listOf(AIModel(id = "gpt-test", name = "GPT Test", isDefault = true, capabilities = listOf(ModelCapability.Text))),
    )

    private val conversation = Conversation(
        id = "conversation-1",
        title = "Parameter rejected",
        providerID = provider.id,
        providerKind = provider.kind,
        modelID = "gpt-test",
        messages = listOf(
            ChatMessage(id = "u1", role = ChatRole.User, text = "hi", providerKind = ProviderKind.OpenAI, providerName = "OpenAI", modelName = "GPT Test", state = ChatMessageState.Delivered),
            ChatMessage(
                id = "a1",
                role = ChatRole.Assistant,
                text = "",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "GPT Test",
                state = ChatMessageState.Failed,
                customRetryWithoutFieldsCode = "input_parameter_rejected:temperature",
            ),
        ),
    )

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `resend on a parameter rejected message carries the omit once marker to launchSend`() = runTest {
        coEvery { providerRepository.getById(provider.id) } returns provider
        val launchedCodes = mutableListOf<String?>()
        val retry = ChatRetryCoordinator(
            viewModelScope = this,
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true),
            currentConversation = { conversation },
            activeProviderId = { provider.id },
            activeModelId = { conversation.modelID },
            providers = { listOf(provider) },
            requestPin = {},
            launchSend = ChatSendLauncher { _, _, _, _, _, _, _, appendToAssistant, _, _, _ ->
                launchedCodes += appendToAssistant?.customRetryWithoutFieldsCode
            },
        )

        retry.retryWithoutLocalCustomFields("a1")
        advanceUntilIdle()

        val code = launchedCodes.single()
        assertTrue("$code", code?.startsWith("omit_parameter_once:") == true)
        assertEquals("temperature", omitParameterOnceName(code))
    }
}
