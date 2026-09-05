package ai.oriveo.community.feature.chat

import android.content.Context
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.streaming.ChatStreamingManager
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Test


@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelSendGuardTest {

    private val dispatcher = StandardTestDispatcher()
    private val applicationScope = kotlinx.coroutines.CoroutineScope(dispatcher + kotlinx.coroutines.SupervisorJob())
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val chatRepository = mockk<ChatRepository>()
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)
    private val skillRepository = mockk<SkillRepository>(relaxed = true)
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)
    private val windowStore = MessageWindowFakeStore()

    private val provider = Provider(
        id = "provider-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = listOf(
            AIModel(
                id = "gpt-4o-mini",
                name = "GPT-4o mini",
                isDefault = true,
                capabilities = listOf(ModelCapability.Text),
            ),
        ),
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        coEvery { providerRepository.getById("provider-1") } returns provider
        every { providerRepository.currentCapabilityPartitionId() } returns "test-partition"
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any(), "test-partition") } returns null
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        
        
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns null
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("")
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(false)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow("")
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow(null)
        ai.oriveo.community.testing.installChatStreamingManagerForwardingStub(chatStreamingManager, chatRepository)
        
        every { appPreferencesRepository.primeLastUsedModel(any(), any()) } just runs
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) } returns Unit
        coEvery { appPreferencesRepository.markMemoryUsedInConversation(any()) } returns Unit
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { appPreferencesRepository.markProviderDisclosureAccepted(any()) } returns Unit
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
        coEvery { conversationRepository.getWithMessages(any()) } returns null
        coEvery { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) } returns Unit
        coEvery { conversationRepository.updateDraft(any(), any()) } returns Unit
        coEvery {
            chatRepository.sendMessage(
                conversation = any(),
                text = any(),
                provider = any(),
                modelID = any(),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                antiForgetText = any(),
                requestOptions = any(),
                retrieval = any(),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        } returns Unit
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `double tap on new conversation creates one conversation and sends once`() = runTest {
        coEvery { conversationRepository.create(any(), any(), any(), any()) } returns buildConversation("conversation-new")

        val viewModel = createViewModel(conversationId = null)
        advanceUntilIdle()

        viewModel.onInputTextChanged("hello twice")
        
        viewModel.sendMessage()
        viewModel.sendMessage()
        advanceUntilIdle()

        
        coVerify(exactly = 1) { conversationRepository.create(any(), any(), any(), any()) }
        verifySendMessageCount(1)
    }

    @Test
    fun `double tap on existing conversation sends once`() = runTest {
        stubExistingConversation("conversation-1")

        val viewModel = createViewModel(conversationId = "conversation-1")
        advanceUntilIdle()

        viewModel.onInputTextChanged("hello twice")
        advanceUntilIdle()
        viewModel.sendMessage()
        viewModel.sendMessage()
        advanceUntilIdle()

        verifySendMessageCount(1)
        coVerify(exactly = 0) { conversationRepository.create(any(), any(), any(), any()) }
    }

    @Test
    fun `failed send resets guard and allows resend`() = runTest {
        stubExistingConversation("conversation-1")
        
        coEvery { providerRepository.getById("provider-1") } returns null

        val viewModel = createViewModel(conversationId = "conversation-1")
        advanceUntilIdle()

        viewModel.onInputTextChanged("hello again")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        verifySendMessageCount(0)
        
        assertEquals("hello again", viewModel.inputText)

        
        coEvery { providerRepository.getById("provider-1") } returns provider
        viewModel.sendMessage()
        advanceUntilIdle()

        verifySendMessageCount(1)
    }

    @Test
    fun `disclosure interception resets guard and confirm double tap sends once`() = runTest {
        stubExistingConversation("conversation-1")
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns false

        val viewModel = createViewModel(conversationId = "conversation-1")
        advanceUntilIdle()

        viewModel.onInputTextChanged("needs disclosure")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        
        verifySendMessageCount(0)
        assertEquals("needs disclosure", viewModel.inputText)
        assertNotNull(viewModel.providerDisclosurePrompt)

        
        viewModel.confirmProviderDisclosure()
        viewModel.confirmProviderDisclosure()
        advanceUntilIdle()

        verifySendMessageCount(1)
        assertEquals("", viewModel.inputText)
    }

    @Test
    fun `sending after switching model uses the selected model in request and conversation snapshot`() = runTest {
        val oldModel = AIModel(
            id = "gpt-5.4",
            name = "GPT-5.4",
            isDefault = true,
            capabilities = listOf(ModelCapability.Text),
        )
        val newModel = AIModel(
            id = "minimax-m3",
            name = "MiniMax M3",
            capabilities = listOf(ModelCapability.Text),
        )
        val switchableProvider = provider.copy(models = listOf(oldModel, newModel))
        every { providerRepository.observeAll() } returns flowOf(listOf(switchableProvider))
        coEvery { providerRepository.getById("provider-1") } returns switchableProvider
        stubExistingConversation(
            buildConversation("conversation-1").copy(
                modelID = oldModel.id,
                messages = emptyList(),
            ),
        )

        val requestConversationSlot = io.mockk.slot<Conversation>()
        val requestModelSlot = io.mockk.slot<String>()
        val requestProviderSlot = io.mockk.slot<Provider>()
        coEvery {
            chatRepository.sendMessage(
                conversation = capture(requestConversationSlot),
                text = any(),
                provider = capture(requestProviderSlot),
                modelID = capture(requestModelSlot),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                antiForgetText = any(),
                requestOptions = any(),
                retrieval = any(),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createViewModel(conversationId = "conversation-1")
        advanceUntilIdle()

        viewModel.selectModel("provider-1", newModel.id)
        viewModel.onInputTextChanged("use the selected model")
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals(newModel.id, requestModelSlot.captured)
        assertEquals(newModel.id, requestConversationSlot.captured.modelID)
        assertSame(switchableProvider, requestProviderSlot.captured)
        coVerify {
            conversationRepository.updateProviderAndModel(
                id = "conversation-1",
                providerId = "provider-1",
                providerKind = ProviderKind.OpenAI,
                modelId = newModel.id,
                relayKind = null,
            )
        }
    }

    private fun verifySendMessageCount(expected: Int) {
        coVerify(exactly = expected) {
            chatRepository.sendMessage(
                conversation = any(),
                text = any(),
                provider = any(),
                modelID = any(),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                antiForgetText = any(),
                requestOptions = any(),
                retrieval = any(),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        }
    }

    private fun stubExistingConversation(id: String) {
        stubExistingConversation(buildConversation(id))
    }

    private fun stubExistingConversation(conversation: Conversation) {
        val id = conversation.id
        every { conversationRepository.observeMetadata(id) } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages(id) } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow(id, any()) } returns conversation
        windowStore.put(id, conversation.messages)
    }

    private fun createViewModel(conversationId: String?): ChatViewModel = ChatViewModel(
        savedStateHandle = if (conversationId != null) {
            SavedStateHandle(mapOf("conversationId" to conversationId))
        } else {
            SavedStateHandle()
        },
        context = mockk<Context>(relaxed = true),
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        conversationRepository = conversationRepository,
        noteRepository = mockk(relaxed = true),
        chatStreamingManager = chatStreamingManager,
        skillRepository = skillRepository,
        attachmentProcessor = mockk(relaxed = true),
        globalSnackbarManager = globalSnackbarManager,
        applicationScope = applicationScope,
    )

    private fun buildConversation(id: String): Conversation = Conversation(
        id = id,
        title = "Send guard test",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o-mini",
        messages = emptyList(),
    )
}
