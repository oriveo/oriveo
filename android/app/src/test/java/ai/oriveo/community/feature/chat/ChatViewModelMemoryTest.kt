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
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    /** Local memory items of the current account (injection reads items, not the whole memoryText). */
    private val memoryItems = MutableStateFlow(
        listOf(
            ai.oriveo.community.core.context.MemoryItem(
                id = "memory-1",
                kind = ai.oriveo.community.core.context.MemoryKind.FACT,
                content = "I use Kotlin",
                mutationId = "mutation-1",
                deviceId = "device-1",
            ),
        ),
    )

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
        // Multi-conversation streaming: state goes through chatStreamingManager.streamingText(convId) / streamingMessageId(convId),
        // which ChatViewModel re-subscribes to via flatMapLatest(activeConversationId).
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow(null)
        ai.oriveo.community.testing.installChatStreamingManagerForwardingStub(chatStreamingManager, chatRepository)

        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>(), any()) } returns Unit
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
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
            )
        } returns Unit
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `sendMessage injects memory system prompt without anti forget reminder`() = runTest {
        val textSlot = io.mockk.slot<String>()
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
                text = capture(textSlot),
                provider = any(),
                modelID = any(),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = capture(requestOptionsSlot),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
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
            memoryItemsSource = memoryItems,
        )
        advanceUntilIdle()

        viewModel.onInputTextChanged("What should I build next?")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        // The system prompt is written only by the assembler plan and the view model no longer builds systemPrompt; memory is handed to chatContext as local items.
        val chatContext = requireNotNull(requestOptionsSlot.captured.chatContext)
        assertEquals(listOf("memory-1" to "I use Kotlin"), chatContext.memoryItems.map { it.id to it.content })
        assertTrue(chatContext.conversation.useMemory)
        // Even with the Anti-Forget preference on and 10 turns reached, no [Reminder: ...] is injected into the request.
        assertEquals("What should I build next?", textSlot.captured)
        assertFalse(textSlot.captured.contains("[Reminder:"))
        assertFalse(requestOptionsSlot.captured.systemPrompt.orEmpty().contains("[Reminder:"))
    }

    /**
     * Toggling the conversation's "use memory" switch persists right away through
     * ConversationRepository.updateUseMemory instead of waiting for the next send.
     */
    @Test
    fun `toggleUseMemory persists immediately without waiting for a send`() = runTest {
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 1)

        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("I use Kotlin")
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns conversation
        coEvery { conversationRepository.updateUseMemory("conversation-1", false) } returns Unit
        windowStore.put("conversation-1", conversation.messages)

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
            memoryItemsSource = memoryItems,
        )
        advanceUntilIdle()

        viewModel.toggleUseMemory()
        advanceUntilIdle()

        coVerify(exactly = 1) { conversationRepository.updateUseMemory("conversation-1", false) }
        coVerify(exactly = 0) {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), requestOptions = any(), outputs = any(),
                quoteContext = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
            )
        }
    }

    @Test
    fun `sendMessage skips memory injection when conversation memory is disabled`() = runTest {
        val textSlot = io.mockk.slot<String>()
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
                text = capture(textSlot),
                provider = any(),
                modelID = any(),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = capture(requestOptionsSlot),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
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
            memoryItemsSource = memoryItems,
        )
        advanceUntilIdle()

        viewModel.onInputTextChanged("What should I build next?")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("", requestOptionsSlot.captured.systemPrompt)
        assertEquals(emptyList<String>(), requestOptionsSlot.captured.chatContext?.memoryItems.orEmpty().map { it.content })
        assertFalse(textSlot.captured.contains("[Reminder:"))
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
                requestOptions = capture(requestOptionsSlot),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
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
            memoryItemsSource = memoryItems,
        )
        advanceUntilIdle()

        viewModel.onInputTextChanged("Improve this paragraph")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        // The skill text goes into chatContext.conversation.skillPrompt and the assembler writes it into system; with memory off for the conversation no memory items are carried.
        val chatContext = requireNotNull(requestOptionsSlot.captured.chatContext)
        assertEquals("Write clearly.", chatContext.conversation.skillPrompt)
        assertTrue(chatContext.memoryItems.isEmpty())
    }

    /** The memory indicator looks at "conversation switch on and an active semantic item exists", not at the whole memoryText. */
    @Test
    fun indicator_follows_items() = runTest {
        val conversationFlow = MutableStateFlow(buildConversation(useMemory = true))

        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        // The old whole-text memory still has text, but the indicator only counts items
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("I use Kotlin")
        every { conversationRepository.observeMetadata("conversation-1") } returns conversationFlow
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversationFlow.value
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns conversationFlow.value
        coEvery { conversationRepository.updateUseMemory("conversation-1", any()) } returns Unit

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
            memoryItemsSource = memoryItems,
        )
        backgroundScope.launch { viewModel.showMemoryIndicator.collect {} }
        advanceUntilIdle()

        assertTrue(viewModel.showMemoryIndicator.value)

        // Only tombstones / non-active / episodic-layer items left -> not shown
        val base = memoryItems.value.single()
        memoryItems.value = listOf(
            base.copy(status = ai.oriveo.community.core.context.MemoryStatus.DELETED, deletedAt = "2026-10-01T00:00:00Z"),
            base.copy(id = "memory-2", status = ai.oriveo.community.core.context.MemoryStatus.PAUSED),
            base.copy(id = "memory-3", layer = ai.oriveo.community.core.context.MemoryLayer.EPISODIC, kind = ai.oriveo.community.core.context.MemoryKind.EVENT),
        )
        advanceUntilIdle()
        assertFalse(viewModel.showMemoryIndicator.value)

        // An active semantic item exists but memory is off for the conversation -> not shown
        memoryItems.value = listOf(base)
        conversationFlow.value = buildConversation(useMemory = false)
        advanceUntilIdle()
        assertFalse(viewModel.showMemoryIndicator.value)

        conversationFlow.value = buildConversation(useMemory = true)
        advanceUntilIdle()
        assertTrue(viewModel.showMemoryIndicator.value)
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
