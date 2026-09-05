package ai.oriveo.community.feature.chat

import android.content.Context
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.coVerifyOrder
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.verify
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
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelEditingTest {

    private val dispatcher = StandardTestDispatcher()
    private val applicationScope = kotlinx.coroutines.CoroutineScope(dispatcher + kotlinx.coroutines.SupervisorJob())
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val chatRepository = mockk<ChatRepository>()
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)
    private val skillRepository = mockk<SkillRepository>(relaxed = true)
    private val attachmentStore = mockk<AttachmentStore>()
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)
    private val windowStore = MessageWindowFakeStore()

    private val attachment = Attachment(
        id = "attachment-1",
        kind = AttachmentKind.File,
        fileName = "notes.txt",
        mimeType = "text/plain",
        base64Data = "bm90ZXM=",
    )
    private val userMessage = ChatMessage(
        id = "user-1",
        role = ChatRole.User,
        text = "Original question",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "gpt-4o-mini",
        state = ChatMessageState.Delivered,
        attachments = listOf(attachment),
    )
    private val assistantMessage = ChatMessage(
        id = "assistant-1",
        role = ChatRole.Assistant,
        text = "Original answer",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "gpt-4o-mini",
        state = ChatMessageState.Delivered,
    )
    private val conversation = Conversation(
        id = "conversation-1",
        title = "Editing test",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o-mini",
        messages = listOf(userMessage, assistantMessage),
    )
    private val provider = Provider(
        id = "provider-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = listOf(AIModel(id = "gpt-4o-mini", name = "GPT-4o mini")),
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("")
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(false)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow("")
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        coEvery { providerRepository.getById("provider-1") } returns provider
        every { providerRepository.currentCapabilityPartitionId() } returns "test-partition"
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any(), "test-partition") } returns null
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns conversation
        windowStore.put("conversation-1", conversation.messages)
        
        
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow(null)
        ai.oriveo.community.testing.installChatStreamingManagerForwardingStub(chatStreamingManager, chatRepository)
        
        coEvery { conversationRepository.deleteMessagesStartingAt(any(), any()) } returns Unit
        coEvery { conversationRepository.deleteMessagesAfter(any(), any()) } returns Unit
        coEvery { conversationRepository.updateDraft(any(), any()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<String>()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) } returns Unit
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { appPreferencesRepository.markProviderDisclosureAccepted(any()) } returns Unit
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
    fun `editing assistant recovery targets previous user message and returns original text`() = runTest {
        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()

        val restoredText = viewModel.editMessageInline("assistant-1")
        advanceUntilIdle()

        assertNotNull(restoredText)
        assertEquals("Original question", restoredText)

        coVerify { conversationRepository.deleteMessagesStartingAt("conversation-1", "user-1") }
    }

    @Test
    fun `regenerate truncates to the user message and re-streams without persisting a new user`() = runTest {
        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()

        viewModel.regenerateMessage("assistant-1")
        advanceUntilIdle()

        
        coVerify { conversationRepository.deleteMessagesAfter("conversation-1", "user-1") }
        
        coVerify {
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
                persistUserMessage = false,
                userMessageAlreadyInHistory = any(),
                appendToAssistant = null,
            )
        }
    }

    @Test
    fun `retrying a failed assistant keeps the original assistant slot and does not persist another user`() = runTest {
        val failedAssistant = assistantMessage.copy(
            state = ChatMessageState.Failed,
            text = "",
            errorTitle = "Request Failed",
            errorDetail = "temporary upstream error",
        )
        val failedConversation = conversation.copy(messages = listOf(userMessage, failedAssistant))
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(failedConversation)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns failedConversation
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns failedConversation
        windowStore.put("conversation-1", failedConversation.messages)

        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()

        viewModel.retryMessage("assistant-1")
        advanceUntilIdle()

        coVerify(exactly = 0) { conversationRepository.deleteMessagesAfter(any(), any()) }
        coVerify {
            chatRepository.sendMessage(
                conversation = any(),
                text = "Original question",
                provider = any(),
                modelID = any(),
                existingMessages = match { it.map(ChatMessage::id) == listOf("user-1", "assistant-1") },
                attachments = listOf(attachment),
                reasoningMode = any(),
                webSearchEnabled = any(),
                antiForgetText = any(),
                requestOptions = any(),
                retrieval = any(),
                outputs = any(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = true,
                appendToAssistant = match { it.id == "assistant-1" },
            )
        }
    }

    @Test
    fun `continue re-streams the original assistant without persisting the instruction`() = runTest {
        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()

        viewModel.continueMessage("assistant-1")
        advanceUntilIdle()

        
        coVerify(exactly = 0) { conversationRepository.deleteMessagesAfter(any(), any()) }
        
        coVerify {
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
                persistUserMessage = false,
                userMessageAlreadyInHistory = any(),
                appendToAssistant = match { it.id == "assistant-1" },
            )
        }
    }

    @Test
    fun `editMessageInline stops the stream and joins before deleting messages`() = runTest {
        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()

        viewModel.editMessageInline("user-1")
        advanceUntilIdle()

        
        
        coVerifyOrder {
            chatStreamingManager.stopStreamAndJoin("conversation-1")
            conversationRepository.deleteMessagesStartingAt("conversation-1", "user-1")
        }
    }

    @Test
    fun `regenerate stops the stream and joins before truncating messages`() = runTest {
        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()

        viewModel.regenerateMessage("assistant-1")
        advanceUntilIdle()

        
        coVerifyOrder {
            chatStreamingManager.stopStreamAndJoin("conversation-1")
            conversationRepository.deleteMessagesAfter("conversation-1", "user-1")
        }
    }

    @Test
    fun `continue stops the stream and joins before re-streaming without deleting later messages`() = runTest {
        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()

        viewModel.continueMessage("assistant-1")
        advanceUntilIdle()

        
        coVerify { chatStreamingManager.stopStreamAndJoin("conversation-1") }
        coVerify(exactly = 0) { conversationRepository.deleteMessagesAfter(any(), any()) }
    }

    @Test
    fun `continue on an empty interrupted assistant falls back to regenerate`() = runTest {
        
        
        val emptyInterrupted = assistantMessage.copy(text = "", state = ChatMessageState.Interrupted)
        val convEmpty = conversation.copy(messages = listOf(userMessage, emptyInterrupted))
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(convEmpty)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns convEmpty
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns convEmpty
        windowStore.put("conversation-1", convEmpty.messages)

        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()

        viewModel.continueMessage("assistant-1")
        advanceUntilIdle()

        
        coVerify { conversationRepository.deleteMessagesAfter("conversation-1", "user-1") }
        coVerify {
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
                persistUserMessage = false,
                userMessageAlreadyInHistory = any(),
                appendToAssistant = null,
            )
        }
    }

    @Test
    fun `leaving chat screen flushes draft but does not stop active generation (L1)`() = runTest {
        
        
        
        val streamingMessageIdFlow = MutableStateFlow<String?>("assistant-streaming-1")
        every { chatStreamingManager.streamingMessageId("conversation-1") } returns streamingMessageIdFlow

        val viewModel = ChatViewModel(
            savedStateHandle = SavedStateHandle(mapOf("conversationId" to "conversation-1")),
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
        advanceUntilIdle()
        viewModel.inputText = "draft before leaving"

        viewModel.handleChatScreenLeaving()
        advanceUntilIdle()

        coVerify(exactly = 1) {
            conversationRepository.updateDraft("conversation-1", "draft before leaving")
        }
        
        verify(exactly = 0) { chatStreamingManager.stopStream(any()) }
        verify(exactly = 0) { chatStreamingManager.stopAllStreams() }
    }
}
