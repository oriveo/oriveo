package ai.oriveo.community.core.memory

import android.content.Context
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
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
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.feature.chat.ChatViewModel
import ai.oriveo.community.feature.chat.MessageWindowFakeStore
import ai.oriveo.community.feature.chat.stubMessageWindowLoaderDefaults
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.slot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MemoryPhase2Test {

    private val dispatcher = StandardTestDispatcher()
    private val applicationScope = kotlinx.coroutines.CoroutineScope(dispatcher + kotlinx.coroutines.SupervisorJob())
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val chatRepository = mockk<ChatRepository>()
    private val chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true)
    private val attachmentStore = mockk<AttachmentStore>()
    private val windowStore = MessageWindowFakeStore()
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)
    private val skillRepository = mockk<SkillRepository>(relaxed = true)

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
        coEvery { conversationRepository.create(any(), any(), any(), any()) } returns buildConversation()
        coEvery { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) } returns Unit
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
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
            )
        } returns Unit
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `MEM-2-01 - new conversation first message injects memory as system prompt`() = runTest {
        val requestOptionsSlot = slot<ChatRequestOptions>()
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 0)

        stubMemoryFields(memoryText = "I prefer Kotlin and Go")
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = any(),
                requestOptions = capture(requestOptionsSlot), outputs = any(),
                persistUserMessage = any(), userMessageAlreadyInHistory = any(), appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Hello AI")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("I prefer Kotlin and Go", requestOptionsSlot.captured.systemPrompt)
        coVerify { appPreferencesRepository.markMemoryUsedInConversation("conversation-1") }
    }

    @Test
    fun `MEM-2-02 - existing conversation continue sending still injects memory`() = runTest {
        val requestOptionsSlot = slot<ChatRequestOptions>()
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 5)

        stubMemoryFields(memoryText = "Always use Chinese")
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = any(),
                requestOptions = capture(requestOptionsSlot), outputs = any(),
                persistUserMessage = any(), userMessageAlreadyInHistory = any(), appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Continue our chat")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("Always use Chinese", requestOptionsSlot.captured.systemPrompt)
        coVerify { appPreferencesRepository.markMemoryUsedInConversation("conversation-1") }
    }

    @Test
    fun `MEM-2-05 - useMemory false skips injection and does not increment usage count`() = runTest {
        val requestOptionsSlot = slot<ChatRequestOptions>()
        val conversation = buildConversation(useMemory = false, existingUserMessageCount = 5)

        stubMemoryFields(memoryText = "I use Kotlin")
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = any(),
                requestOptions = capture(requestOptionsSlot), outputs = any(),
                persistUserMessage = any(), userMessageAlreadyInHistory = any(), appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Test message")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("", requestOptionsSlot.captured.systemPrompt)
        coVerify(exactly = 0) { appPreferencesRepository.markMemoryUsedInConversation(any()) }
    }

    @Test
    fun `MEM-2-06 - empty memory text skips injection`() = runTest {
        val requestOptionsSlot = slot<ChatRequestOptions>()
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 0)

        stubMemoryFields(memoryText = "")
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = any(),
                requestOptions = capture(requestOptionsSlot), outputs = any(),
                persistUserMessage = any(), userMessageAlreadyInHistory = any(), appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Hello")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("", requestOptionsSlot.captured.systemPrompt)
        coVerify(exactly = 0) { appPreferencesRepository.markMemoryUsedInConversation(any()) }
    }

    @Test
    fun `MEM-2-06 - whitespace-only memory text skips injection`() = runTest {
        val requestOptionsSlot = slot<ChatRequestOptions>()
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 0)

        stubMemoryFields(memoryText = "   ")
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = any(),
                requestOptions = capture(requestOptionsSlot), outputs = any(),
                persistUserMessage = any(), userMessageAlreadyInHistory = any(), appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Hello")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        // "   ".trim() → "" → isNotBlank() = false → no injection
        assertEquals("", requestOptionsSlot.captured.systemPrompt)
        coVerify(exactly = 0) { appPreferencesRepository.markMemoryUsedInConversation(any()) }
    }

    @Test
    fun `MEM-2-13 - anti-forget triggers at exactly 10 user messages`() = runTest {
        val antiForgetSlot = slot<String?>()
        // 9 existing + 1 new = 10 → triggers
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 9)

        stubMemoryFields(
            memoryText = "I use Kotlin",
            antiForgetEnabled = true,
            antiForgetText = "Prefer concise Chinese answers",
        )
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = captureNullable(antiForgetSlot),
                requestOptions = any(), outputs = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Message 10")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertEquals("[Reminder: Prefer concise Chinese answers]", antiForgetSlot.captured)
    }

    @Test
    fun `MEM-2-14 - anti-forget returns null when less than 10 user messages`() = runTest {
        val antiForgetSlot = slot<String?>()
        // 8 existing + 1 new = 9 < 10 → no anti-forget
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 8)

        stubMemoryFields(
            memoryText = "I use Kotlin",
            antiForgetEnabled = true,
            antiForgetText = "Prefer concise Chinese answers",
        )
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = captureNullable(antiForgetSlot),
                requestOptions = any(), outputs = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Message 9")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertNull(antiForgetSlot.captured)
    }

    @Test
    fun `MEM-2-15 - anti-forget returns null when disabled`() = runTest {
        val antiForgetSlot = slot<String?>()
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 15)

        stubMemoryFields(
            memoryText = "I use Kotlin",
            antiForgetEnabled = false,
            antiForgetText = "Prefer concise Chinese answers",
        )
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = captureNullable(antiForgetSlot),
                requestOptions = any(), outputs = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Hello")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertNull(antiForgetSlot.captured)
    }

    @Test
    fun `MEM-2-15 - anti-forget returns null when anti-forget text is empty`() = runTest {
        val antiForgetSlot = slot<String?>()
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 15)

        stubMemoryFields(
            memoryText = "I use Kotlin",
            antiForgetEnabled = true,
            antiForgetText = "",
        )
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = captureNullable(antiForgetSlot),
                requestOptions = any(), outputs = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Hello")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertNull(antiForgetSlot.captured)
    }

    @Test
    fun `MEM-2-15 - anti-forget returns null when memory text is blank`() = runTest {
        val antiForgetSlot = slot<String?>()
        val conversation = buildConversation(useMemory = true, existingUserMessageCount = 15)

        stubMemoryFields(
            memoryText = "",
            antiForgetEnabled = true,
            antiForgetText = "Some context",
        )
        stubConversation(conversation)
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = captureNullable(antiForgetSlot),
                requestOptions = any(), outputs = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.onInputTextChanged("Hello")
        advanceUntilIdle()
        viewModel.sendMessage()
        advanceUntilIdle()

        assertNull(antiForgetSlot.captured)
    }

    @Test
    fun `MEM-2-16 - anti-forget only in outbound copy not persisted to DB`() {

        val userText = "What should I build?"
        val antiForgetContext = "Prefer concise Chinese answers"

        val userMessage = userMessage(userText)
        val outbound = userMessage.copy(
            text = "${userMessage.text}\n\n[Reminder: $antiForgetContext]",
        )

        assertEquals(userText, userMessage.text)
        assertFalse(userMessage.text.contains("[Reminder:"))

        assertTrue(outbound.text.contains("[Reminder: $antiForgetContext]"))
        assertEquals("$userText\n\n[Reminder: $antiForgetContext]", outbound.text)
    }

    @Test
    fun `MEM-2-19 - regenerate uses current latest memory text`() = runTest {
        val requestOptionsSlot = slot<ChatRequestOptions>()

        val messages = listOf(
            userMessage("Original question", id = "user-0"),
            assistantMessage("Original answer", id = "assistant-0"),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Test",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o-mini",
            useMemory = true,
            messages = messages,
        )

        stubMemoryFields(memoryText = "Updated memory: use Go instead")
        stubConversation(conversation)
        coEvery { conversationRepository.deleteMessagesAfter(any(), any()) } returns Unit
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = any(),
                requestOptions = capture(requestOptionsSlot), outputs = any(),
                persistUserMessage = any(), userMessageAlreadyInHistory = any(), appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.regenerateMessage("assistant-0")
        advanceUntilIdle()

        assertEquals("Updated memory: use Go instead", requestOptionsSlot.captured.systemPrompt)
    }

    @Test
    fun `MEM-2-20 - continue message follows memory injection rules`() = runTest {
        val requestOptionsSlot = slot<ChatRequestOptions>()
        val messages = listOf(
            userMessage("Question", id = "user-0"),
            assistantMessage("Partial answer...", id = "assistant-0"),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Test",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o-mini",
            useMemory = true,
            messages = messages,
        )

        stubMemoryFields(memoryText = "I prefer detailed explanations")
        stubConversation(conversation)
        coEvery { conversationRepository.deleteMessagesAfter(any(), any()) } returns Unit
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = any(),
                requestOptions = capture(requestOptionsSlot), outputs = any(),
                persistUserMessage = any(), userMessageAlreadyInHistory = any(), appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.continueMessage("assistant-0")
        advanceUntilIdle()

        assertEquals("I prefer detailed explanations", requestOptionsSlot.captured.systemPrompt)
        coVerify { appPreferencesRepository.markMemoryUsedInConversation("conversation-1") }
    }

    @Test
    fun `MEM-2-20 - continue message with useMemory false does not inject`() = runTest {
        val requestOptionsSlot = slot<ChatRequestOptions>()
        val messages = listOf(
            userMessage("Question", id = "user-0"),
            assistantMessage("Partial answer...", id = "assistant-0"),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Test",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-4o-mini",
            useMemory = false,
            messages = messages,
        )

        stubMemoryFields(memoryText = "I prefer detailed explanations")
        stubConversation(conversation)
        coEvery { conversationRepository.deleteMessagesAfter(any(), any()) } returns Unit
        coEvery {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(),
                existingMessages = any(), attachments = any(), reasoningMode = any(),
                webSearchEnabled = any(), antiForgetText = any(),
                requestOptions = capture(requestOptionsSlot), outputs = any(),
                persistUserMessage = any(), userMessageAlreadyInHistory = any(), appendToAssistant = any(),
            )
        } returns Unit

        val viewModel = createChatViewModel()
        advanceUntilIdle()

        viewModel.continueMessage("assistant-0")
        advanceUntilIdle()

        assertEquals("", requestOptionsSlot.captured.systemPrompt)
        coVerify(exactly = 0) { appPreferencesRepository.markMemoryUsedInConversation(any()) }
    }

    // ── MEM-2-22: OpenAI-compatible providers → buildOpenAIMessages prepends system ──

    @Test
    fun `MEM-2-22 - OpenAI buildOpenAIMessages prepends system prompt with memory`() {
        val msgs = listOf(userMessage("Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "User prefers Kotlin",
        )
        assertTrue(result.startsWith("""{"role":"system","content":"""))
        assertTrue(result.contains("User prefers Kotlin"))
        assertTrue(result.contains("""{"role":"user","content":"Hello"}"""))
    }

    @Test
    fun `MEM-2-22 - all OpenAI-compatible providers inject system prompt identically`() {
        val openAICompatible = listOf(
            ProviderKind.OpenAI,
            ProviderKind.OpenRouter,
            ProviderKind.Groq,
            ProviderKind.Together,
            ProviderKind.Fireworks,
            ProviderKind.Relay,
        )
        val msgs = listOf(userMessage("Hello"))
        val memoryPrompt = "Remember my preferences"

        for (kind in openAICompatible) {
            val result = MessageBuilder.buildOpenAIMessages(
                messages = msgs,
                providerKind = kind,
                systemPrompt = memoryPrompt,
            )
            assertTrue(
                "Provider $kind should prepend system message",
                result.startsWith("""{"role":"system","content":"Remember my preferences"}"""),
            )
        }
    }

    @Test
    fun `MEM-2-23 - Anthropic system prompt produces correct format`() {
        val result = MessageBuilder.anthropicSystemJson("User prefers Kotlin and Go")
        assertEquals(""""system":"User prefers Kotlin and Go"""", result)
    }

    @Test
    fun `MEM-2-23 - Anthropic system prompt null for null or blank`() {
        assertNull(MessageBuilder.anthropicSystemJson(null))
        assertNull(MessageBuilder.anthropicSystemJson(""))
        assertNull(MessageBuilder.anthropicSystemJson("   "))
    }

    @Test
    fun `MEM-2-24 - Gemini system instruction produces correct nested structure`() {
        val result = MessageBuilder.geminiSystemInstructionJson("User prefers Kotlin and Go")
        assertEquals(
            """"systemInstruction":{"parts":[{"text":"User prefers Kotlin and Go"}]}""",
            result,
        )
    }

    @Test
    fun `MEM-2-24 - Gemini system instruction null for null or blank`() {
        assertNull(MessageBuilder.geminiSystemInstructionJson(null))
        assertNull(MessageBuilder.geminiSystemInstructionJson(""))
        assertNull(MessageBuilder.geminiSystemInstructionJson("  \n  "))
    }

    @Test
    fun `MEM-2-27 - markMemoryUsedInConversation increments once per conversation`() = runTest {
        val preferenceDao = FakePreferenceDao()
        val repository = AppPreferencesRepository(preferenceDao)

        repository.markMemoryUsedInConversation("conv-1")
        assertEquals("1", preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_COUNT))

        repository.markMemoryUsedInConversation("conv-1")
        assertEquals("1", preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_COUNT))

        repository.markMemoryUsedInConversation("conv-2")
        assertEquals("2", preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_COUNT))
    }

    @Test
    fun `MEM-2-27 - markMemoryUsedInConversation ignores blank id`() = runTest {
        val preferenceDao = FakePreferenceDao()
        val repository = AppPreferencesRepository(preferenceDao)

        repository.markMemoryUsedInConversation("")
        assertNull(preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_COUNT))

        repository.markMemoryUsedInConversation("  ")
        assertNull(preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_COUNT))
    }

    @Test
    fun `MEM-2-27 - markMemoryUsedInConversation stores sorted conversation ids as JSON`() = runTest {
        val preferenceDao = FakePreferenceDao()
        val repository = AppPreferencesRepository(preferenceDao)

        repository.markMemoryUsedInConversation("conv-b")
        repository.markMemoryUsedInConversation("conv-a")
        repository.markMemoryUsedInConversation("conv-c")

        val storedIds = preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_CONVERSATION_IDS)

        assertEquals("""["conv-a","conv-b","conv-c"]""", storedIds)
        assertEquals("3", preferenceDao.get(AppPreferenceKeys.MEMORY_USAGE_COUNT))
    }

    // ── Helper ──

    private fun stubMemoryFields(
        memoryText: String = "",
        antiForgetEnabled: Boolean = false,
        antiForgetText: String = "",
    ) {
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.memoryText } returns MutableStateFlow(memoryText)
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(antiForgetEnabled)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow(antiForgetText)
    }

    private fun createChatViewModel(): ChatViewModel = ChatViewModel(
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

    private fun stubConversation(conversation: Conversation) {
        every { conversationRepository.observeMetadata(conversation.id) } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages(conversation.id) } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow(conversation.id, any()) } returns conversation
        windowStore.put(conversation.id, conversation.messages)
    }

    private fun userMessage(
        text: String,
        id: String = "msg-1",
    ) = ChatMessage(
        id = id,
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4o mini",
        state = ChatMessageState.Delivered,
    )

    private fun assistantMessage(
        text: String,
        id: String = "assistant-1",
    ) = ChatMessage(
        id = id,
        role = ChatRole.Assistant,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4o mini",
        state = ChatMessageState.Delivered,
    )

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

    private class FakePreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()

        override fun observe(key: String): Flow<String?> =
            values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? =
            values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }
}
