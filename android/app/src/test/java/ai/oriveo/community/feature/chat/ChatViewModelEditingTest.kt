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
import ai.oriveo.community.testing.BundledAttachmentSupportFixture
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
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
    private val quote = ai.oriveo.community.core.model.QuoteContext(
        sourceMessageId = "assistant-1",
        sourceRole = ChatRole.Assistant,
        contentKind = ai.oriveo.community.core.model.QuoteContentKind.Prose,
        leadingText = "",
        selectedText = "Original answer",
        trailingText = "",
        contextTruncated = false,
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
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        conversationRepository.stubMessageWindowLoaderDefaults(windowStore)
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(conversation)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns conversation
        windowStore.put("conversation-1", conversation.messages)

        every { chatStreamingManager.streamingText(any()) } returns MutableStateFlow("")
        every { chatStreamingManager.streamingMessageId(any()) } returns MutableStateFlow(null)
        ai.oriveo.community.testing.installChatStreamingManagerForwardingStub(chatStreamingManager, chatRepository)

        coEvery { conversationRepository.deleteMessagesStartingAt(any(), any()) } returns true
        coEvery { conversationRepository.deleteMessagesAfter(any(), any()) } returns Unit
        coEvery { conversationRepository.updateDraft(any(), any()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<String>()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>(), any()) } returns Unit
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
                externalSearch = any(),
                skillTurn = any(),
            )
        } returns Unit
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        // Official provider attachment capability only comes from metadata: clear the MetadataClient.instance table after cases that injected it.
        BundledAttachmentSupportFixture.clear()
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
            ioDispatcher = dispatcher,
        )
        advanceUntilIdle()

        val restoredText = viewModel.editMessageInline("assistant-1")
        advanceUntilIdle()

        assertNotNull(restoredText)
        assertEquals("Original question", restoredText)

        coVerify { conversationRepository.deleteMessagesStartingAt("conversation-1", "user-1") }
    }

    /** Editing puts attachments back into the composer only from the local original image: give the image fixture a readable local original. */
    private fun storeWithLocalImage(key: String): AttachmentStore = mockk<AttachmentStore>(relaxed = true) {
        every { loadImageBytes(key) } returns byteArrayOf(1, 2, 3)
        every { loadThumbnailBytes(any()) } returns null
        every { loadBlobBytes(any()) } returns null
    }

    private fun editingViewModel(store: AttachmentStore? = null) = ChatViewModel(
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
        ioDispatcher = dispatcher,
        attachmentStore = store,
    )

    private fun editingConversationWith(attachments: List<Attachment>) {
        val edited = conversation.copy(messages = listOf(userMessage.copy(attachments = attachments), assistantMessage))
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(edited)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns edited
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns edited
        windowStore.put("conversation-1", edited.messages)
    }

    /** Changing one word must not lose the files: the original message's attachments return to the composer with the text. */
    @Test
    fun `editing puts the original attachments back into the composer`() = runTest {
        BundledAttachmentSupportFixture.install("openAI")
        editingConversationWith(listOf(attachment))
        val viewModel = editingViewModel()
        advanceUntilIdle()

        val restoredText = viewModel.editMessageInline("assistant-1")
        advanceUntilIdle()

        assertEquals("Original question", restoredText)
        val restored = viewModel.pendingAttachments.single()
        assertEquals("notes.txt", restored.fileName)
        assertEquals("bm90ZXM=", restored.base64Data)
    /**
     * The model panel's file card predicts the route from the outbound history. Videos in earlier turns not trimmed by the attachment budget -> true;
     * trimmed (history videos exceeding the 10MiB budget are downgraded to placeholder lines) -> false.
     */
    @Test
    fun `outbound history video flag follows the outbound trim`() = runTest {
        fun video(bytes: Int) = Attachment(
            id = "video-1", kind = AttachmentKind.Video, fileName = "clip.mp4", mimeType = "video/mp4",
            base64Data = "A".repeat(bytes),
        )

        editingConversationWith(listOf(video(16)))
        val kept = editingViewModel()
        backgroundScope.launch { kept.outboundHistoryHasVideo.collect {} }
        advanceUntilIdle()
        assertTrue("earlier video that was not trimmed should count toward the outbound history", kept.outboundHistoryHasVideo.value)

        editingConversationWith(listOf(video(11 * 1024 * 1024)))
        val trimmed = editingViewModel()
        backgroundScope.launch { trimmed.outboundHistoryHasVideo.collect {} }
        advanceUntilIdle()
        org.junit.Assert.assertFalse("video trimmed by the budget is not in the outbound history", trimmed.outboundHistoryHasVideo.value)
    }

        // The original message was deleted by the edit: the copy in the composer is a new attachment with its own id.
        assertTrue(restored.id != "attachment-1")
    }

    @Test
    fun `restored attachments go through the model capability filter and the count limit`() = runTest {
        BundledAttachmentSupportFixture.install("openAI")
        // With the fixture, gpt-4o-mini's image verdict key is missing = unknown, so the entry stays open and the image is restored as usual; 5 attachments (image + files) against a limit of 3.
        val image = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", localImageId = "img-local")
        val files = (1..4).map { attachment.copy(id = "f$it", fileName = "f$it.txt") }
        editingConversationWith(listOf(image) + files)
        val viewModel = editingViewModel(storeWithLocalImage("img-local"))
        advanceUntilIdle()

        viewModel.editMessageInline("user-1")
        advanceUntilIdle()

        assertEquals(listOf("p.png", "f1.txt", "f2.txt"), viewModel.pendingAttachments.map { it.fileName })
    }

    /** Relay connection: edit restore goes through the same gate as import, judged after resolving the connection identity, so the image of an image message returns to the composer. */
    @Test
    fun `editing an image message on a relay connection restores the image into the composer`() = runTest {
        val relay = Provider(
            id = "provider-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            relayRequested = ai.oriveo.community.core.model.RelayRequestedConfig(
                transport = ai.oriveo.community.core.model.RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = "https://relay.example.com/v1",
            ),
            models = listOf(AIModel(id = "gpt-4o-mini", name = "GPT-4o mini")),
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(relay))
        coEvery { providerRepository.getById("provider-1") } returns relay
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any()) } returns
            ai.oriveo.community.core.model.CapabilityEvidenceIdentity(
                partitionId = "test-partition",
                connectionInstanceId = relay.id,
                connectionGeneration = "generation",
                credentialEpoch = "epoch",
                providerKind = relay.kind.rawValue,
                authMode = relay.authMode.rawValue,
            )
        val image = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", localImageId = "img-local")
        editingConversationWith(listOf(image))
        val viewModel = editingViewModel(storeWithLocalImage("img-local"))
        advanceUntilIdle()

        viewModel.editMessageInline("user-1")
        advanceUntilIdle()

        assertEquals(listOf("p.png"), viewModel.pendingAttachments.map { it.fileName })
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
            ioDispatcher = dispatcher,
        )
        advanceUntilIdle()

        viewModel.regenerateMessage("assistant-1")
        advanceUntilIdle()

        // Deletion moved into ChatRepository (it only happens after the context refusal check passes), so the entry point no longer deletes; history is cut at lastUser (inclusive) and handed to the send pipeline.
        coVerify(exactly = 0) { conversationRepository.deleteMessagesAfter(any(), any()) }
        // Regenerate does not persist a second user message (persistUserMessage=false) and is not a continuation (appendToAssistant=null).
        coVerify {
            chatRepository.sendMessage(
                conversation = any(),
                text = any(),
                provider = any(),
                modelID = any(),
                existingMessages = match { it.lastOrNull()?.id == "user-1" },
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = true,
                appendToAssistant = null,
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
                externalSearch = any(),
                skillTurn = any(),
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
            ioDispatcher = dispatcher,
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
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = true,
                appendToAssistant = match { it.id == "assistant-1" },
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
                externalSearch = any(),
                skillTurn = any(),
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
            ioDispatcher = dispatcher,
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
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = any(),
                appendToAssistant = match { it.id == "assistant-1" },
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
                externalSearch = any(),
                skillTurn = any(),
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
            ioDispatcher = dispatcher,
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
    fun `editMessageInline stops read aloud of truncated messages`() = runTest {
        val readAloud = mockk<ai.oriveo.community.core.voice.ReadAloudController>(relaxed = true)
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
            ioDispatcher = dispatcher,
            readAloudController = readAloud,
        )
        advanceUntilIdle()

        viewModel.editMessageInline("user-1")
        advanceUntilIdle()

        // Old behavior: truncation deleted the answer being read aloud without stopping it, so read-aloud kept speaking a deleted message.
        verify {
            readAloud.stopIfSpeaking("user-1", ai.oriveo.community.core.voice.ReadAloudEndReason.NAVIGATED)
            readAloud.stopIfSpeaking("assistant-1", ai.oriveo.community.core.voice.ReadAloudEndReason.NAVIGATED)
        }
    }

    // ── voiceAmend: a voice conversation's "interrupt while thinking" is attached to the end of the last user message and regenerated in the same bubble ──

    private fun voiceAmendViewModel(
        contextRejections: kotlinx.coroutines.flow.Flow<ai.oriveo.community.core.data.repository.ChatContextRejection> =
            kotlinx.coroutines.flow.emptyFlow(),
    ) = ChatViewModel(
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
        ioDispatcher = dispatcher,
        contextRejections = contextRejections,
    )

    private fun verifyVoiceAmendSent(expectedText: String) {
        coVerify(exactly = 1) {
            chatRepository.sendMessage(
                conversation = any(),
                text = expectedText,
                provider = any(),
                modelID = any(),
                existingMessages = match { it.lastOrNull()?.id == "user-1" && it.last().text == expectedText },
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
                retrieval = any(),
                outputs = any(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = true,
                appendToAssistant = null,
                quoteContext = any(),
                libraryResearchEnabled = any(),
                libraryContextDocuments = any(),
                libraryContextCancelledText = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
                externalSearch = any(),
                skillTurn = any(),
            )
        }
    }

    @Test
    fun `voiceAmend joins the text to the last user message in place and regenerates`() = runTest {
        coEvery { conversationRepository.updateMessage(any(), any()) } returns Unit
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()

        assertTrue(viewModel.amendLastUserMessage("  and why"))
        advanceUntilIdle()

        // Same bubble: the rewrite targets the user message with the original id; no new user message is created.
        coVerify(exactly = 1) {
            conversationRepository.updateMessage(
                "conversation-1",
                match { it.id == "user-1" && it.role == ChatRole.User && it.text == "Original question and why" },
            )
        }
        verifyVoiceAmendSent("Original question and why")
    }

    @Test
    fun `voiceAmend with empty text regenerates the last user message unchanged`() = runTest {
        coEvery { conversationRepository.updateMessage(any(), any()) } returns Unit
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()

        assertTrue(viewModel.amendLastUserMessage(""))
        advanceUntilIdle()

        coVerify(exactly = 0) { conversationRepository.updateMessage(any(), any()) }
        verifyVoiceAmendSent("Original question")
    }

    @Test
    fun `voiceAmend returns false without a user message`() = runTest {
        val onlyAssistant = conversation.copy(messages = listOf(assistantMessage))
        every { conversationRepository.observeMetadata("conversation-1") } returns flowOf(onlyAssistant)
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns onlyAssistant
        coEvery { conversationRepository.getWithLatestMessageWindow("conversation-1", any()) } returns onlyAssistant
        windowStore.put("conversation-1", onlyAssistant.messages)
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()
        assertEquals(false, viewModel.amendLastUserMessage("more"))
        advanceUntilIdle()

        coVerify(exactly = 0) { conversationRepository.updateMessage(any(), any()) }
        coVerify(exactly = 0) { chatStreamingManager.stopStreamAndJoin(any()) }
    }

    @Test
    fun `voiceAmend blocked by a missing provider returns false and leaves the messages alone`() = runTest {
        every { providerRepository.observeAll() } returns flowOf(emptyList())
        coEvery { providerRepository.getById("provider-1") } returns null
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()

        assertEquals(false, viewModel.amendLastUserMessage("more"))
        advanceUntilIdle()

        coVerify(exactly = 0) { chatStreamingManager.stopStreamAndJoin(any()) }
        coVerify(exactly = 0) { conversationRepository.updateMessage(any(), any()) }
    }

    @Test
    fun `voiceAmend while generating stops the stream before rewriting and regenerating`() = runTest {
        coEvery { conversationRepository.updateMessage(any(), any()) } returns Unit
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()

        assertTrue(viewModel.amendLastUserMessage("second day Nara"))
        advanceUntilIdle()

        coVerifyOrder {
            chatStreamingManager.stopStreamAndJoin("conversation-1")
            conversationRepository.updateMessage("conversation-1", match { it.id == "user-1" })
            chatRepository.sendMessage(
                conversation = any(),
                text = "Original question second day Nara",
                provider = any(),
                modelID = any(),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
                retrieval = any(),
                outputs = any(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = true,
                appendToAssistant = null,
                quoteContext = any(),
                libraryResearchEnabled = any(),
                libraryContextDocuments = any(),
                libraryContextCancelledText = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
                externalSearch = any(),
                skillTurn = any(),
            )
        }
    }

    private fun verifyVoiceAmendSentAsNewTurn(expectedText: String) {
        coVerify(exactly = 1) {
            chatRepository.sendMessage(
                conversation = any(),
                text = expectedText,
                provider = any(),
                modelID = any(),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = match { it.chatContext?.delivery == ai.oriveo.community.core.context.ContextDelivery.VOICE },
                retrieval = any(),
                outputs = any(),
                persistUserMessage = true,
                userMessageAlreadyInHistory = false,
                appendToAssistant = null,
                quoteContext = any(),
                libraryResearchEnabled = any(),
                libraryContextDocuments = any(),
                libraryContextCancelledText = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
                externalSearch = any(),
                skillTurn = any(),
            )
        }
    }

    @Test
    fun `voiceAmend on a turn rolled back at the confirmation gate sends the joined text as a new voice turn`() = runTest {
        coEvery { conversationRepository.updateMessage(any(), any()) } returns Unit
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()
        viewModel.inputText = "typed meanwhile"

        // user-2 (this turn) was rolled back by the confirmation gate: only the previous turn is left.
        assertTrue(viewModel.amendLastUserMessage("  and why", VoiceAmendTarget("user-2", "Second question")))
        advanceUntilIdle()

        verifyVoiceAmendSentAsNewTurn("Second question and why")
        // The previous turn is not rewritten, and the composer is neither filled nor cleared.
        coVerify(exactly = 0) { conversationRepository.updateMessage(any(), any()) }
        assertEquals("typed meanwhile", viewModel.inputText)
    }

    @Test
    fun `voiceAmend on a turn whose user message never landed takes the same new-turn fallback`() = runTest {
        coEvery { conversationRepository.updateMessage(any(), any()) } returns Unit
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()

        assertTrue(viewModel.amendLastUserMessage("and why", VoiceAmendTarget(null, "Second question")))
        advanceUntilIdle()

        verifyVoiceAmendSentAsNewTurn("Second question and why")
        coVerify(exactly = 0) { conversationRepository.updateMessage(any(), any()) }
    }

    @Test
    fun `voiceAmend with a target id still in the conversation rewrites that user message in place`() = runTest {
        coEvery { conversationRepository.updateMessage(any(), any()) } returns Unit
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()

        assertTrue(viewModel.amendLastUserMessage("and why", VoiceAmendTarget("user-1", "Original question")))
        advanceUntilIdle()

        coVerify(exactly = 1) {
            conversationRepository.updateMessage("conversation-1", match { it.id == "user-1" && it.text == "Original question and why" })
        }
        verifyVoiceAmendSent("Original question and why")
    }

    // ── An interruption that cannot be sent does not hang in "thinking": every send-failure path after returning true calls the failure exit ──

    /** Drives the interruption coordinator directly: [conversation] reads the current conversation (it can be rewritten when the stream stops), [sendVoiceTurn] is the fallback to a new send. */
    private fun TestScope.amendCoordinator(
        conversation: () -> Conversation,
        modelId: () -> String? = { "gpt-4o-mini" },
        launches: MutableList<String> = mutableListOf(),
        sendVoiceTurn: (String, List<Attachment>?, ai.oriveo.community.core.model.QuoteContext?, () -> Unit) -> Boolean = { _, _, _, _ -> false },
    ) = ChatRetryCoordinator(
        viewModelScope = this,
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        chatStreamingManager = chatStreamingManager,
        currentConversation = conversation,
        activeProviderId = { "provider-1" },
        activeModelId = modelId,
        providers = { listOf(provider) },
        requestPin = {},
        launchSend = ChatSendLauncher { _, _, _, text, _, _, _, _, _, _, _, _, _, _ -> launches += text },
        sendVoiceTurn = sendVoiceTurn,
    )

    private fun verifyNothingSent() {
        coVerify(exactly = 0) {
            chatRepository.sendMessage(
                conversation = any(), text = any(), provider = any(), modelID = any(), existingMessages = any(),
                attachments = any(), reasoningMode = any(), webSearchEnabled = any(), requestOptions = any(),
                retrieval = any(), outputs = any(), persistUserMessage = any(), userMessageAlreadyInHistory = any(),
                appendToAssistant = any(), quoteContext = any(), libraryResearchEnabled = any(),
                libraryContextDocuments = any(), libraryContextCancelledText = any(), attemptKind = any(),
                overflowRecovery = any(), onUserMessageCreated = any(), memoryPropose = any(), memorySearch = any(), externalSearch = any(), skillTurn = any(),
            )
        }
    }

    @Test
    fun `voiceAmend whose user message is gone after the stop reports failure instead of hanging`() = runTest {
        var current = conversation
        // The turn is withdrawn when the stream stops (only the reply remains): there is no user message to rewrite.
        coEvery { chatStreamingManager.stopStreamAndJoin("conversation-1") } coAnswers {
            current = conversation.copy(messages = listOf(assistantMessage))
        }
        val launches = mutableListOf<String>()
        val coordinator = amendCoordinator(conversation = { current }, launches = launches)
        var failures = 0

        assertTrue(coordinator.amendLastUserMessage("more", onFailed = { failures++ }))
        advanceUntilIdle()

        assertEquals(1, failures)
        assertEquals(emptyList<String>(), launches)
    }

    @Test
    fun `voiceAmend whose model is gone after the stop reports failure`() = runTest {
        var modelId: String? = "gpt-4o-mini"
        val launches = mutableListOf<String>()
        val coordinator = amendCoordinator(conversation = { conversation }, modelId = { modelId }, launches = launches)
        var failures = 0

        assertTrue(coordinator.amendLastUserMessage("more", onFailed = { failures++ }))
        // The model is cleared while the stream is stopping (e.g. the connection was switched away): still present at the gate, gone before sending.
        modelId = null
        advanceUntilIdle()

        assertEquals(1, failures)
        assertEquals(emptyList<String>(), launches)
    }

    @Test
    fun `voiceAmend whose new-turn fallback is refused reports failure`() = runTest {
        // The fallback new send passes the voice-turn gate: the conversation is still streaming = refused.
        every { chatStreamingManager.isBusyStreaming(any()) } returns true
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()
        var failures = 0

        assertTrue(viewModel.amendLastUserMessage("and why", VoiceAmendTarget("user-2", "Second question"), onFailed = { failures++ }))
        advanceUntilIdle()

        assertEquals(1, failures)
        verifyNothingSent()
    }

    @Test
    fun `voiceAmend going out does not report failure`() = runTest {
        coEvery { conversationRepository.updateMessage(any(), any()) } returns Unit
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()
        var failures = 0

        assertTrue(viewModel.amendLastUserMessage("and why", VoiceAmendTarget("user-2", "Second question"), onFailed = { failures++ }))
        advanceUntilIdle()

        assertEquals(0, failures)
        verifyVoiceAmendSentAsNewTurn("Second question and why")
    }

    @Test
    fun `voiceAmend fallback after a rollback resends the rolled-back message's attachments and quote`() = runTest {
        val secondAttachment = attachment.copy(id = "attachment-2", fileName = "plan.txt")
        val secondUser = userMessage.copy(
            id = "user-2", text = "Second question", attachments = listOf(secondAttachment), quoteContext = quote,
        )
        var current = conversation.copy(messages = conversation.messages + secondUser)
        // The confirmation gate rolls this turn back during the stream stop: user-2 is no longer in the conversation.
        coEvery { chatStreamingManager.stopStreamAndJoin("conversation-1") } coAnswers { current = conversation }
        val fallbacks = mutableListOf<Triple<String, List<Attachment>?, ai.oriveo.community.core.model.QuoteContext?>>()
        val coordinator = amendCoordinator(
            conversation = { current },
            sendVoiceTurn = { text, attachments, quoteContext, _ -> fallbacks += Triple(text, attachments, quoteContext); true },
        )
        var failures = 0

        assertTrue(coordinator.amendLastUserMessage("and why", VoiceAmendTarget("user-2", "Second question"), onFailed = { failures++ }))
        advanceUntilIdle()

        assertEquals(0, failures)
        assertEquals(listOf(Triple("Second question and why", listOf(secondAttachment), quote)), fallbacks)
    }

    @Test
    fun `voiceAmend fallback blocked after it went out reports failure`() = runTest {
        var current = conversation.copy(messages = conversation.messages + userMessage.copy(id = "user-2", text = "Second question"))
        coEvery { chatStreamingManager.stopStreamAndJoin("conversation-1") } coAnswers { current = conversation }
        // The fallback new send passed the synchronous gate (returned true) and is then blocked on the async path: the blocked exit must connect to the interruption's failure exit.
        val coordinator = amendCoordinator(conversation = { current }, sendVoiceTurn = { _, _, _, onBlocked -> onBlocked(); true })
        var failures = 0

        assertTrue(coordinator.amendLastUserMessage("and why", VoiceAmendTarget("user-2", "Second question"), onFailed = { failures++ }))
        advanceUntilIdle()

        assertEquals(1, failures)
    }

    // ── Ordinary voice send: attachments / quote passed as-is to sendMessage; reported back when blocked on the async path ──

    @Test
    fun `voice send carries its attachments and quote to sendMessage and reports no failure`() = runTest {
        BundledAttachmentSupportFixture.install("openAI")
        // Use an image rather than a file: the file attachment's preflight reads the outbound history through ChatOutboundHistoryProbe.trim on the real Dispatchers.IO,
        // advanceUntilIdle cannot wait for it, so the assertion would run before the send (the reason the card kept failing 3 times in a row, not a production drop of the quote).
        val image = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", localImageId = "img-local")
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()
        var failures = 0

        assertTrue(viewModel.voice.send("Look at this", listOf(image), quote, onBlocked = { failures++ }))
        advanceUntilIdle()

        assertEquals(0, failures)
        // The assertion is on the request the send path hands to the streaming layer: the test's forwarding stub (installChatStreamingManagerForwardingStub) does not forward quoteContext,
        // so asserting on chatRepository.sendMessage's arguments always sees quote as null (the other half of the repeated failures, not a production drop of the quote).
        val requests = mutableListOf<ai.oriveo.community.core.streaming.StreamRequest>()
        verify(exactly = 1) { chatStreamingManager.startStream(capture(requests)) }
        val request = requests.single()
        assertEquals("Look at this", request.text)
        assertEquals(listOf(image), request.attachments)
        assertEquals(quote, request.quoteContext)
        assertEquals(ai.oriveo.community.core.context.ContextDelivery.VOICE, request.requestOptions.chatContext?.delivery)
        assertTrue(request.persistUserMessage)
    }

    @Test
    fun `voice send blocked inside sendMessage reports failure`() = runTest {
        val viewModel = voiceAmendViewModel()
        advanceUntilIdle()
        // The synchronous gate has passed (returned true), but on the async path the connection cannot be found: the request is not sent, and the voice turn must receive a failure instead of no event.
        coEvery { providerRepository.getById("provider-1") } returns null
        var failures = 0

        assertTrue(viewModel.voice.send("Hello", onBlocked = { failures++ }))
        advanceUntilIdle()

        assertEquals(1, failures)
        verifyNothingSent()
    }

    @Test
    fun `voice turn rolled back at the pre-send confirmation is reported, other rollbacks are not`() = runTest {
        val rejections = kotlinx.coroutines.flow.MutableSharedFlow<ai.oriveo.community.core.data.repository.ChatContextRejection>(
            extraBufferCapacity = 8,
        )
        val viewModel = voiceAmendViewModel(contextRejections = rejections)
        advanceUntilIdle()
        var rolledBack = 0
        backgroundScope.launch { viewModel.voice.turnRolledBack.collect { rolledBack++ } }
        assertTrue(viewModel.voice.send("Hello"))
        advanceUntilIdle()
        // Background collection only runs inside runCurrent (advanceUntilIdle returns once only background tasks remain).
        runCurrent()

        fun rollback(conversationId: String, text: String, userMessageId: String?) = rejections.tryEmit(
            ai.oriveo.community.core.data.repository.ChatContextRejection(
                conversationId = conversationId, reject = null, text = text, attachments = null,
                restoresComposer = true, rolledBack = true, userMessageId = userMessageId,
            ),
        )
        // Other conversations, user messages that existed before this turn, and text that is not from this turn: none of them belong to this turn.
        rollback("conversation-2", "Hello", "user-new")
        rollback("conversation-1", "Hello", "user-1")
        rollback("conversation-1", "Something else", "user-new")
        runCurrent()
        assertEquals(0, rolledBack)

        // Confirmation dialog cancelled / stop tapped while waiting: the user message newly persisted in this turn is rolled back and deleted.
        rollback("conversation-1", "Hello", "user-new")
        runCurrent()
        assertEquals(1, rolledBack)
    }

    @Test
    fun `voice turn refused by the context plan before streaming is reported, other refusals are not`() = runTest {
        val rejections = kotlinx.coroutines.flow.MutableSharedFlow<ai.oriveo.community.core.data.repository.ChatContextRejection>(
            extraBufferCapacity = 8,
        )
        val viewModel = voiceAmendViewModel(contextRejections = rejections)
        advanceUntilIdle()
        var refused = 0
        backgroundScope.launch { viewModel.voice.turnRolledBack.collect { refused++ } }
        assertTrue(viewModel.voice.send("Hello"))
        advanceUntilIdle()
        runCurrent()

        // Context planning refused the send: no rollback, and no userMessageId carried (ChatRepository refuses in plan before sending).
        fun refuse(conversationId: String, text: String) = rejections.tryEmit(
            ai.oriveo.community.core.data.repository.ChatContextRejection(
                conversationId = conversationId, reject = null, text = text, attachments = null,
                restoresComposer = true,
            ),
        )
        // Other conversations and text that is not from this turn: none of them belong to this turn.
        refuse("conversation-2", "Hello")
        refuse("conversation-1", "Something else")
        runCurrent()
        assertEquals(0, refused)

        refuse("conversation-1", "Hello")
        runCurrent()
        assertEquals(1, refused)
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
            ioDispatcher = dispatcher,
        )
        advanceUntilIdle()

        viewModel.regenerateMessage("assistant-1")
        advanceUntilIdle()

        // Order is locked: the deletion range (after lastUser) may cover the assistant that is still generating, so stop the stream and wait for it to persist before handing off to the send pipeline (deletion happens after the refusal check).
        coVerifyOrder {
            chatStreamingManager.stopStreamAndJoin("conversation-1")
            chatRepository.sendMessage(
                conversation = any(),
                text = any(),
                provider = any(),
                modelID = any(),
                existingMessages = match { it.lastOrNull()?.id == "user-1" },
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = true,
                appendToAssistant = null,
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
                externalSearch = any(),
                skillTurn = any(),
            )
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
            ioDispatcher = dispatcher,
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
            ioDispatcher = dispatcher,
        )
        advanceUntilIdle()

        viewModel.continueMessage("assistant-1")
        advanceUntilIdle()

        // Degrades to regenerate: history is cut at lastUser (user-1) and nothing is continued (appendToAssistant=null); deletion happens after the send pipeline's refusal check.
        coVerify(exactly = 0) { conversationRepository.deleteMessagesAfter(any(), any()) }
        coVerify {
            chatRepository.sendMessage(
                conversation = any(),
                text = any(),
                provider = any(),
                modelID = any(),
                existingMessages = match { it.lastOrNull()?.id == "user-1" },
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = true,
                appendToAssistant = null,
                quoteContext = any(),
                attemptKind = any(),
                overflowRecovery = any(),
                onUserMessageCreated = any(),
                memoryPropose = any(),
                memorySearch = any(),
                externalSearch = any(),
                skillTurn = any(),
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
            ioDispatcher = dispatcher,
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
