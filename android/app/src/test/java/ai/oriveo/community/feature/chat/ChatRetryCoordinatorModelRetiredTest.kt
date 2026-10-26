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
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The conversation model has been retired (tombstoned): regenerate / retry / continue never send a
 * request and never touch the messages.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatRetryCoordinatorModelRetiredTest {
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)

    private val provider = Provider(
        id = "provider-openai",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = listOf(
            AIModel(id = "gpt-legacy", name = "GPT Legacy", capabilities = listOf(ModelCapability.Text)),
            AIModel(id = "gpt-next", name = "GPT Next", isDefault = true, capabilities = listOf(ModelCapability.Text)),
        ),
    )

    private val conversation = Conversation(
        id = "conversation-1",
        title = "Retired model",
        providerID = provider.id,
        providerKind = provider.kind,
        modelID = "gpt-legacy",
        messages = listOf(
            ChatMessage(id = "u1", role = ChatRole.User, text = "hi", providerKind = ProviderKind.OpenAI, providerName = "OpenAI", modelName = "GPT Legacy", state = ChatMessageState.Delivered),
            ChatMessage(id = "a1", role = ChatRole.Assistant, text = "partial", providerKind = ProviderKind.OpenAI, providerName = "OpenAI", modelName = "GPT Legacy", state = ChatMessageState.Failed),
        ),
    )

    @Before
    fun setUp() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        coEvery { providerRepository.getById(provider.id) } returns provider
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `regenerate retry and continue on a tombstoned conversation make zero requests`() = runTest {
        var launches = 0
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
            launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> launches++ },
        )

        retry.regenerateMessage("a1")
        retry.retryMessage("a1")
        retry.continueMessage("a1")
        advanceUntilIdle()

        assertEquals(0, launches)
        coVerify(exactly = 0) { conversationRepository.deleteMessagesAfter(any(), any()) }
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { providerRepository.getById(any()) }
        assertTrue(conversation.messages.last().text == "partial")
    }

    private companion object {
        val OPENAI_CATALOG = """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-next",
                  "retiredModels": [
                    { "id": "gpt-legacy", "displayName": "GPT Legacy", "retiredAt": "2026-07-24T00:00:00Z", "routedTo": "gpt-next" }
                  ],
                  "resolveMap": { "gpt-next": "gpt-next" },
                  "models": { "gpt-next": { "canonicalModelId": "gpt-next", "displayName": "GPT Next" } }
                }
              }
            }
        """.trimIndent()
    }
}
