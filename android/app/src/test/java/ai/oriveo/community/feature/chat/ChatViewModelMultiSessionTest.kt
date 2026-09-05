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
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.coEvery
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

/**
 * ChatViewModel multi-session streaming unit tests:
 *  1. switching activeConversationId re-subscribes streamingText/streamingMessageId to the new conversation's flow
 *  2. isGenerating reflects only the current conversation's streaming state (another conversation streaming does not affect composer send/stop)
 *  3. stopGeneration only calls chatStreamingManager.stopStream(current convId)
 *  4. deleteConversation calls stopStream(convId) before conversationRepository.delete
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelMultiSessionTest {

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

    /**
     * sessionsVersion is subscribed inside ChatViewModel.streamingText / streamingMessageId's combine;
     * a relaxed mock returns a child mock StateFlow for a StateFlow-typed getter (its collect behavior
     * is uncontrollable), so a real MutableStateFlow must be injected explicitly, or the upstream of
     * combine never emits and stateIn never sees anything beyond its initial value.
     *
     * Shared as a single instance: a test can bump its .value internally to trigger a sessions
     * mutation re-subscription (the same-convId regenerate scenario).
     */
    private val sessionsVersionFlow = MutableStateFlow(0L)

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))
        coEvery { providerRepository.getById("provider-1") } returns provider
        every { appPreferencesRepository.lastUsedModelRef } returns flowOf(null)
        every { appPreferencesRepository.memoryText } returns MutableStateFlow("")
        every { appPreferencesRepository.memoryAntiForgetEnabled } returns MutableStateFlow(false)
        every { appPreferencesRepository.memoryAntiForgetText } returns MutableStateFlow("")
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>()) } returns Unit
        coEvery { appPreferencesRepository.markMemoryUsedInConversation(any()) } returns Unit
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { appPreferencesRepository.markProviderDisclosureAccepted(any()) } returns Unit
        coEvery { conversationRepository.updateDraft(any(), any()) } returns Unit
        every { chatStreamingManager.sessionsVersion } returns sessionsVersionFlow
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `each ChatViewModel instance subscribes to a separate streaming flow keyed by conversationId`() = runTest {
        // Android design: each chat route gets a fresh ChatViewModel instance (conversationId bound
        // inside its SavedStateHandle). iOS uses a singleton ChatManager with multiple conversations;
        // the Android equivalent is constructing two view models, each watching its own stream.
        // Key contract: viewModel.streamingText/streamingMessageId subscribe to
        // chatStreamingManager.streamingText(convId) via flatMapLatest(activeConversationId), so A and
        // B each see their own tokens without overwriting each other.
        val convA = buildConversation("conversation-A")
        val convB = buildConversation("conversation-B")
        val flowAText = MutableStateFlow("text-A")
        val flowBText = MutableStateFlow("text-B")
        val flowAMsgId = MutableStateFlow<String?>("msg-A")
        val flowBMsgId = MutableStateFlow<String?>("msg-B")

        every { conversationRepository.observeMetadata("conversation-A") } returns flowOf(convA)
        coEvery { conversationRepository.getWithMessages("conversation-A") } returns convA
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-A", any()) } returns convA
        windowStore.put("conversation-A", convA.messages)
        every { conversationRepository.observeMetadata("conversation-B") } returns flowOf(convB)
        coEvery { conversationRepository.getWithMessages("conversation-B") } returns convB
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-B", any()) } returns convB
        windowStore.put("conversation-B", convB.messages)
        every { chatStreamingManager.streamingText("conversation-A") } returns flowAText
        every { chatStreamingManager.streamingText("conversation-B") } returns flowBText
        every { chatStreamingManager.streamingMessageId("conversation-A") } returns flowAMsgId
        every { chatStreamingManager.streamingMessageId("conversation-B") } returns flowBMsgId

        val viewModelA = createChatViewModel(initialConversationId = "conversation-A")
        val viewModelB = createChatViewModel(initialConversationId = "conversation-B")
        // Start collectors to activate the WhileSubscribed StateFlow (stateIn never subscribes upstream without an active collector)
        val collectAText = backgroundScope.launch { viewModelA.streamingText.collect {} }
        val collectAMsgId = backgroundScope.launch { viewModelA.streamingMessageId.collect {} }
        val collectBText = backgroundScope.launch { viewModelB.streamingText.collect {} }
        val collectBMsgId = backgroundScope.launch { viewModelB.streamingMessageId.collect {} }
        advanceUntilIdle()

        // instance A sees its own streaming state
        assertEquals("text-A", viewModelA.streamingText.value)
        assertEquals("msg-A", viewModelA.streamingMessageId.value)
        // instance B sees its own streaming state (isolated from A)
        assertEquals("text-B", viewModelB.streamingText.value)
        assertEquals("msg-B", viewModelB.streamingMessageId.value)

        // verify A and B each subscribed to the streamingText for their own conversationId (flatMapLatest landed on the right convId)
        verify(atLeast = 1) { chatStreamingManager.streamingText("conversation-A") }
        verify(atLeast = 1) { chatStreamingManager.streamingText("conversation-B") }

        collectAText.cancel()
        collectAMsgId.cancel()
        collectBText.cancel()
        collectBMsgId.cancel()
    }

    @Test
    fun `isGenerating reflects only the current conversation streaming state -- other conversations don't affect the composer`() = runTest {
        // Key contract: isGenerating = streamingMessageId.value != null. streamingMessageId
        // subscribes to chatStreamingManager.streamingMessageId(convId) via flatMapLatest(activeConversationId),
        // so ChatViewModel(C)'s isGenerating only looks at streamingMessageId("conversation-C") --
        // even while A/B are streaming (their messageId is non-null), C's composer send/stop state is unaffected.
        val convA = buildConversation("conversation-A")
        val convB = buildConversation("conversation-B")
        val convC = buildConversation("conversation-C")
        every { conversationRepository.observeMetadata("conversation-A") } returns flowOf(convA)
        coEvery { conversationRepository.getWithMessages("conversation-A") } returns convA
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-A", any()) } returns convA
        windowStore.put("conversation-A", convA.messages)
        every { conversationRepository.observeMetadata("conversation-B") } returns flowOf(convB)
        coEvery { conversationRepository.getWithMessages("conversation-B") } returns convB
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-B", any()) } returns convB
        windowStore.put("conversation-B", convB.messages)
        every { conversationRepository.observeMetadata("conversation-C") } returns flowOf(convC)
        coEvery { conversationRepository.getWithMessages("conversation-C") } returns convC
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-C", any()) } returns convC
        windowStore.put("conversation-C", convC.messages)
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId("conversation-A") } returns MutableStateFlow<String?>("msg-A")
        every { chatStreamingManager.streamingMessageId("conversation-B") } returns MutableStateFlow<String?>("msg-B")
        every { chatStreamingManager.streamingMessageId("conversation-C") } returns MutableStateFlow<String?>(null)

        val viewModelA = createChatViewModel(initialConversationId = "conversation-A")
        val viewModelB = createChatViewModel(initialConversationId = "conversation-B")
        val viewModelC = createChatViewModel(initialConversationId = "conversation-C")
        val collectA = backgroundScope.launch { viewModelA.streamingMessageId.collect {} }
        val collectB = backgroundScope.launch { viewModelB.streamingMessageId.collect {} }
        val collectC = backgroundScope.launch { viewModelC.streamingMessageId.collect {} }
        advanceUntilIdle()

        // A is streaming -> isGenerating=true
        assertTrue("ChatViewModel(A): its own streaming conversation should mean isGenerating=true", viewModelA.isGenerating)
        // B is streaming -> isGenerating=true (B's own stream, unrelated to A)
        assertTrue("ChatViewModel(B): its own streaming conversation should mean isGenerating=true", viewModelB.isGenerating)
        // C has no stream -> isGenerating=false (A/B streaming must not leak into C)
        assertFalse(
            "ChatViewModel(C): should be isGenerating=false when it isn't streaming itself (A/B streaming has no effect)",
            viewModelC.isGenerating,
        )

        collectA.cancel()
        collectB.cancel()
        collectC.cancel()
    }

    @Test
    fun `stopGeneration only calls stopStream for the current convId`() = runTest {
        val convA = buildConversation("conversation-A")
        every { conversationRepository.observeMetadata("conversation-A") } returns flowOf(convA)
        coEvery { conversationRepository.getWithMessages("conversation-A") } returns convA
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-A", any()) } returns convA
        windowStore.put("conversation-A", convA.messages)
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow<String?>("msg-A")

        val viewModel = createChatViewModel(initialConversationId = "conversation-A")
        advanceUntilIdle()

        viewModel.stopGeneration()
        advanceUntilIdle()

        verify(exactly = 1) { chatStreamingManager.stopStream("conversation-A") }
        verify(exactly = 0) { chatStreamingManager.stopAllStreams() }
    }

    @Test
    fun `regenerate in the same conversation re-subscribes streamingText to the new StateFlow`() = runTest {
        // Key contract: after a same-convId regenerate replaces sessions[convId], activeConversationId
        // doesn't change, so flatMapLatest(activeConversationId) alone would never re-subscribe -- it
        // must instead rely on combine(activeConversationId, sessionsVersion), where bumping
        // sessionsVersion triggers the re-subscription -- only then can the UI see the new
        // StreamingSession's tokens; writes to the old StateFlow must be treated as stale and no
        // longer affect the UI.
        val convA = buildConversation("conversation-A")
        every { conversationRepository.observeMetadata("conversation-A") } returns flowOf(convA)
        coEvery { conversationRepository.getWithMessages("conversation-A") } returns convA
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-A", any()) } returns convA
        windowStore.put("conversation-A", convA.messages)

        // the old StreamingSession's MutableStateFlow (before the regenerate swap)
        val oldText = MutableStateFlow("OLD")
        val oldMsgId = MutableStateFlow<String?>("old-msg")
        // the new StreamingSession's MutableStateFlow (after the regenerate swap)
        val newText = MutableStateFlow("NEW")
        val newMsgId = MutableStateFlow<String?>("new-msg")

        // key: calls for the same convId's streamingText/streamingMessageId return different instances
        // -- first collect sees oldText/oldMsgId; after sessionsVersion bumps, re-subscription sees newText/newMsgId
        every { chatStreamingManager.streamingText("conversation-A") } returnsMany listOf(oldText, newText)
        every {
            chatStreamingManager.streamingMessageId("conversation-A")
        } returnsMany listOf(oldMsgId, newMsgId)

        val viewModel = createChatViewModel(initialConversationId = "conversation-A")
        val collectText = backgroundScope.launch { viewModel.streamingText.collect {} }
        val collectMsgId = backgroundScope.launch { viewModel.streamingMessageId.collect {} }
        advanceUntilIdle()

        // first subscription: UI sees the old StateFlow's value
        assertEquals("OLD", viewModel.streamingText.value)
        assertEquals("old-msg", viewModel.streamingMessageId.value)

        // simulate ChatStreamingManager bumping sessionsVersion after startStream replaces sessions[convA]
        sessionsVersionFlow.value = sessionsVersionFlow.value + 1
        advanceUntilIdle()

        // re-subscription succeeded -- UI switched to newText/newMsgId
        assertEquals(
            "streamingText must re-subscribe to the new StreamingSession's StateFlow once sessionsVersion bumps",
            "NEW",
            viewModel.streamingText.value,
        )
        assertEquals(
            "streamingMessageId must re-subscribe to the new StreamingSession's StateFlow once sessionsVersion bumps",
            "new-msg",
            viewModel.streamingMessageId.value,
        )

        // writes to the old StateFlow should no longer affect the UI (UI is no longer subscribed to the old flow)
        oldText.value = "OLD-LATER"
        oldMsgId.value = "old-msg-later"
        advanceUntilIdle()
        assertEquals("a write to the old StateFlow must not affect the UI (superseded by flatMapLatest)", "NEW", viewModel.streamingText.value)
        assertEquals(
            "a write to the old StateFlow must not affect the UI (superseded by flatMapLatest)",
            "new-msg",
            viewModel.streamingMessageId.value,
        )

        // writes to the new StateFlow are visible to the UI
        newText.value = "NEW-2"
        newMsgId.value = "new-msg-2"
        advanceUntilIdle()
        assertEquals("a write to the new StateFlow must be visible to the UI", "NEW-2", viewModel.streamingText.value)
        assertEquals("a write to the new StateFlow must be visible to the UI", "new-msg-2", viewModel.streamingMessageId.value)

        collectText.cancel()
        collectMsgId.cancel()
    }

    @Test
    fun `deleteConversation calls stopStream before conversationRepository delete`() = runTest {
        val convA = buildConversation("conversation-A")
        every { conversationRepository.observeMetadata("conversation-A") } returns flowOf(convA)
        coEvery { conversationRepository.getWithMessages("conversation-A") } returns convA
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-A", any()) } returns convA
        windowStore.put("conversation-A", convA.messages)
        coEvery { conversationRepository.delete("conversation-A") } returns Unit
        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow<String?>("msg-A")

        val viewModel = createChatViewModel(initialConversationId = "conversation-A")
        advanceUntilIdle()

        viewModel.deleteConversation()
        advanceUntilIdle()

        // stopStream must happen before delete (otherwise a stream could write to an already-deleted conversation, tripping an FK cascade error, or wasting tokens)
        coVerifyOrder {
            chatStreamingManager.stopStream("conversation-A")
            conversationRepository.delete("conversation-A")
        }
        verify(exactly = 0) { chatStreamingManager.stopAllStreams() }
    }

    private fun createChatViewModel(initialConversationId: String): ChatViewModel = ChatViewModel(
        savedStateHandle = SavedStateHandle(mapOf("conversationId" to initialConversationId)),
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
        title = "Conv $id",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4o-mini",
        useMemory = true,
        messages = listOf(
            ChatMessage(
                id = "user-0",
                role = ChatRole.User,
                text = "First user message",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "GPT-4o mini",
                state = ChatMessageState.Delivered,
            ),
            ChatMessage(
                id = "assistant-0",
                role = ChatRole.Assistant,
                text = "Streaming reply",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "GPT-4o mini",
                state = ChatMessageState.Generating,
            ),
        ),
    )
}
