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
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
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
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelMemoryTest {

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

        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow(null)
        ai.oriveo.community.testing.installChatStreamingManagerForwardingStub(chatStreamingManager, chatRepository)

        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) } returns Unit
        coEvery { appPreferencesRepository.markMemoryUsedInConversation(any()) } returns Unit
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { appPreferencesRepository.markProviderDisclosureAccepted(any()) } returns Unit
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns null
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns null
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
        coEvery { conversationRepository.create(any(), any(), any(), any()) } returns buildConversation()
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
    fun `sendMessage injects memory system prompt and anti forget context`() = runTest {
        val antiForgetSlot = io.mockk.slot<String?>()
        val requestOptionsSlot = io.mockk.slot<ChatRequestOptions>()
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 9)

        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("I use Kotlin")
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(true)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow("Prefer concise Chinese answers")
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns conversation
        windowStore.put("conversation-1", conversation.messages)
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
                antiForgetText = captureNullable(antiForgetSlot),
                requestOptions = capture(requestOptionsSlot),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        } returns Unit

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

        viewModel.onInputTextChanged("What should I build next?")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("I use Kotlin", requestOptionsSlot.captured.systemPrompt)
        assertEquals("[Reminder: Prefer concise Chinese answers]", antiForgetSlot.captured)
        coVerify { appPreferencesRepository.markMemoryUsedInConversation("conversation-1") }
    }

    @Test
    fun `sendMessage skips memory injection when conversation memory is disabled`() = runTest {
        val antiForgetSlot = io.mockk.slot<String?>()
        val requestOptionsSlot = io.mockk.slot<ChatRequestOptions>()
        val conversation = buildConversation(useMemory = false, existingUserMessageCount = 9)

        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("I use Kotlin")
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(true)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow("Prefer concise Chinese answers")
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns conversation
        windowStore.put("conversation-1", conversation.messages)
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
                antiForgetText = captureNullable(antiForgetSlot),
                requestOptions = capture(requestOptionsSlot),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        } returns Unit

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

        viewModel.onInputTextChanged("What should I build next?")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("", requestOptionsSlot.captured.systemPrompt)
        assertEquals(null, antiForgetSlot.captured)
        coVerify(exactly = 0) { appPreferencesRepository.markMemoryUsedInConversation(any()) }
    }

    @Test
    fun `sendMessage skips skill memory when conversation memory is disabled`() = runTest {
        val requestOptionsSlot = io.mockk.slot<ChatRequestOptions>()
        val conversation = buildConversation(useMemory = false).copy(skillId = "skill-1")
        val skill = Skill(
            id = "skill-1",
            name = "Writer",
            systemPrompt = "Write clearly.",
            useMemory = true,
        )

        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("I use Kotlin")
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(false)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow("")
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns conversation
        windowStore.put("conversation-1", conversation.messages)
        coEvery { skillRepository.getById("skill-1") } returns skill
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
                requestOptions = capture(requestOptionsSlot),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        } returns Unit

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

        viewModel.onInputTextChanged("Improve this paragraph")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("Write clearly.", requestOptionsSlot.captured.systemPrompt)
        coVerify(exactly = 0) { appPreferencesRepository.markMemoryUsedInConversation(any()) }
    }

    private fun buildConversation(
        useMemory: Boolean = true,
        existingUserMessageCount: Int = 0,
    ): Conversation {
        val messages = List(existingUserMessageCount) { index ->
            ChatMessage(
                id = "user-$index",
                role = ChatRole.User,
                text = "User message $index",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "GPT-4o mini",
                state = ChatMessageState.Delivered,
            )
        }

        return Conversation(
            id = "conversation-1",
            title = "Memory test",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o-mini",
            useMemory = useMemory,
            messages = messages,
        )
    }
}
