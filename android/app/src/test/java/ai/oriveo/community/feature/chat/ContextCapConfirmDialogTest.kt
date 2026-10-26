package ai.oriveo.community.feature.chat

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.room.Room
import ai.oriveo.community.R
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextBudgetLimit
import ai.oriveo.community.core.context.ContextCapConfirmCoordinator
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.PendingContextCapConfirmation
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.repository.ChatContextRejection
import ai.oriveo.community.core.data.repository.ChatContextRejections
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ContextCompactionStore
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuoteContentKind
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.notice.ContextPriceLineConfirmState
import ai.oriveo.community.core.notice.ContextPriceLineConfirmStore
import ai.oriveo.community.core.notice.DirectiveSuggestionStore
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.ContextConfirmAttempt
import ai.oriveo.community.testing.TestSharedPreferences
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Confirmation dialog, input refill and suggestion-strip withdrawal after a cancel rollback, and pressing stop while waiting for confirmation.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ContextCapConfirmDialogTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun confirm_dialog_dont_ask_only_for_price_line() {
        val priceLine = pending(
            estimatedInput = 213_000, B = 2_000_000, limitedBy = ContextBudgetLimit.WINDOW, priceLineTokens = 200_000,
        )
        val overCap = pending(
            estimatedInput = 152_000, B = 128_000, limitedBy = ContextBudgetLimit.CUSTOM, priceLineTokens = null,
        )
        assertTrue(priceLine.decision.priceLine && !priceLine.decision.overCap)
        assertTrue(overCap.decision.overCap && !overCap.decision.priceLine)

        val sent = mutableListOf<Boolean>()
        var cancels = 0
        var shown by mutableStateOf(priceLine)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            ai.oriveo.community.ui.theme.OriveoTheme(darkTheme = false) {
                ContextCapConfirmDialog(pending = shown, onSend = { sent += it }, onCancel = { cancels++ })
            }
        }
        composeRule.waitForIdle()
        val app = RuntimeEnvironment.getApplication()

        // Price line: title and checkbox (unchecked by default); sending unchecked = false, checking and then sending = true.
        composeRule.onNodeWithText(app.getString(R.string.context_confirm_price_line_title)).assertExists()
        composeRule.onNode(hasTestTag(DONT_ASK_TAG)).assertExists().assertIsOff()
        composeRule.onNode(hasTestTag(SEND_TAG)).performClick()
        composeRule.onNode(hasTestTag(DONT_ASK_TAG)).performClick()
        composeRule.onNode(hasTestTag(DONT_ASK_TAG)).assertIsOn()
        composeRule.onNode(hasTestTag(SEND_TAG)).performClick()
        assertEquals(listOf(false, true), sent)

        // Over the cap: no checkbox; [Cancel] uses the generic key.
        shown = overCap
        composeRule.waitForIdle()
        composeRule.onNodeWithText(app.getString(R.string.context_confirm_over_cap_title)).assertExists()
        composeRule.onNode(hasTestTag(DONT_ASK_TAG)).assertDoesNotExist()
        composeRule.onNode(hasTestTag(CANCEL_TAG)).assertExists()
        composeRule.onNodeWithText(app.getString(R.string.cancel)).performClick()
        assertEquals(1, cancels)
        assertEquals(listOf(false, true), sent)
    }

    @Test
    fun composer_restored_after_cancel_only_when_empty() = runTest(UnconfinedTestDispatcher()) {
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        val draft = ChatDraftCoordinator(backgroundScope, conversationRepository)
        val quotes = ChatQuoteCoordinator()
        val restoredAttachments = mutableListOf<List<Attachment>>()
        val toasts = mutableListOf<Any>()
        observeChatContextRejections(
            backgroundScope, { toasts += it }, draft, { CONVERSATION_ID }, quotes,
            composerAttachments = { emptyList() },
        ) { restoredAttachments += it }

        // Draft is empty: text, attachments and quote are all put back; no refusal notice is shown.
        val attachment = Attachment(id = "a1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png")
        ChatContextRejections.shared.emit(rolledBack(text = "first message", attachments = listOf(attachment)))
        assertEquals("first message", draft.text)
        assertEquals(listOf(listOf(attachment)), restoredAttachments)
        assertEquals(QUOTE, quotes.pending)
        assertTrue(toasts.isEmpty())

        // Draft is non-empty: nothing is refilled.
        draft.pushText("typing something new")
        quotes.clear()
        ChatContextRejections.shared.emit(rolledBack(text = "second message", attachments = listOf(attachment)))
        assertEquals("typing something new", draft.text)
        assertEquals(1, restoredAttachments.size)
        assertNull(quotes.pending)

        // Whitespace only also counts as empty (text is empty after trimming and there are no attachments): everything is refilled.
        draft.pushText("   ")
        ChatContextRejections.shared.emit(rolledBack(text = "third message", attachments = listOf(attachment)))
        assertEquals("third message", draft.text)
        assertEquals(2, restoredAttachments.size)
        assertEquals(QUOTE, quotes.pending)

        // The rollback withdraws the "Set as instruction" and "Save as memory?" strips posted by this send.
        val user = message("u1", ChatRole.User, "")
        var conversation = conversation(listOf(user))
        coEvery { conversationRepository.getWithMessages(CONVERSATION_ID) } answers { conversation }
        val settings = ChatConversationSettingsCoordinator(
            scope = backgroundScope,
            conversationRepository = conversationRepository,
            activeConversationId = MutableStateFlow(CONVERSATION_ID),
            directiveSuggestionStore = DirectiveSuggestionStore { TestSharedPreferences() },
            showToast = {},
        )
        val directive = requireNotNull(settings.directiveSuggestions)
        directive.onUserMessageCreated(CONVERSATION_ID, "u1", DIRECTIVE_TEXT)
        awaitState(directive.pending) { CONVERSATION_ID in it }
        ChatContextRejections.shared.emit(rolledBack(text = DIRECTIVE_TEXT, userMessageId = "u1"))
        awaitState(directive.pending) { CONVERSATION_ID !in it }

        val memoryUser = message("u2", ChatRole.User, "")
        conversation = conversation(listOf(memoryUser))
        settings.memorySuggestions.onUserMessageCreated(CONVERSATION_ID, "u2", "Remember that I use TypeScript", useMemory = false)
        awaitState(settings.memorySuggestions.pending) { CONVERSATION_ID in it }
        ChatContextRejections.shared.emit(rolledBack(text = "Remember that I use TypeScript", userMessageId = "u2"))
        awaitState(settings.memorySuggestions.pending) { CONVERSATION_ID !in it }
    }

    @Test
    fun composer_not_restored_when_only_attachments_present() = runTest(UnconfinedTestDispatcher()) {
        val draft = ChatDraftCoordinator(backgroundScope, mockk<ConversationRepository>(relaxed = true))
        val quotes = ChatQuoteCoordinator()
        val composer = Attachment(id = "c1", kind = AttachmentKind.Image, fileName = "c.png", mimeType = "image/png")
        val restoredAttachments = mutableListOf<List<Attachment>>()
        observeChatContextRejections(
            backgroundScope, {}, draft, { CONVERSATION_ID }, quotes,
            composerAttachments = { listOf(composer) },
        ) { restoredAttachments += it }

        // Empty text but existing attachments = the input is non-empty: nothing is refilled.
        val uploaded = Attachment(id = "a1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png")
        val local = Attachment(id = "a2", kind = AttachmentKind.Image, fileName = "b.png", mimeType = "image/png")
        ChatContextRejections.shared.emit(rolledBack(text = "first message", attachments = listOf(uploaded, local)))
        assertEquals("", draft.text)
        assertTrue(restoredAttachments.isEmpty())
        assertNull(quotes.pending)

        // A refusal follows the same rule: with a non-empty input nothing is refilled (attachments are no longer topped up alone); a refusal stores no message.
        ChatContextRejections.shared.emit(
            rolledBack(text = "too long", attachments = listOf(local))
                .copy(reject = ai.oriveo.community.core.context.ContextReject.MESSAGE_TOO_LONG, rolledBack = false),
        )
        assertEquals("", draft.text)
        assertTrue(restoredAttachments.isEmpty())
        assertNull(quotes.pending)
    }

    @Test
    fun withdraw_only_rolled_back_message_suggestion() = runTest(UnconfinedTestDispatcher()) {
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        val rejections = ChatContextRejections()
        var conversation = conversation(listOf(message("u1", ChatRole.User, "")))
        coEvery { conversationRepository.getWithMessages(CONVERSATION_ID) } answers { conversation }
        val settings = ChatConversationSettingsCoordinator(
            scope = backgroundScope,
            conversationRepository = conversationRepository,
            activeConversationId = MutableStateFlow(CONVERSATION_ID),
            directiveSuggestionStore = DirectiveSuggestionStore { TestSharedPreferences() },
            showToast = {},
            contextRejections = rejections.events,
        )

        // The "Set as instruction" strip hangs under u1, the "Save to memory?" strip under u2.
        val directive = requireNotNull(settings.directiveSuggestions)
        directive.onUserMessageCreated(CONVERSATION_ID, "u1", DIRECTIVE_TEXT)
        awaitState(directive.pending) { CONVERSATION_ID in it }
        conversation = conversation(listOf(message("u1", ChatRole.User, ""), message("u2", ChatRole.User, "")))
        val memory = settings.memorySuggestions
        memory.onUserMessageCreated(CONVERSATION_ID, "u2", "Remember that I use TypeScript", useMemory = false)
        awaitState(memory.pending) { CONVERSATION_ID in it }

        // Rolling back u2 withdraws only the memory strip under u2; a rollback that did not delete the user message and a rollback of another message both leave the instruction strip under u1.
        // One collector handles events in order, so when the memory strip disappears the earlier events have all been handled.
        rejections.emit(rolledBack(text = "no user message", userMessageId = null))
        rejections.emit(rolledBack(text = "another send", userMessageId = "u0"))
        rejections.emit(rolledBack(text = "Remember that I use TypeScript", userMessageId = "u2"))
        awaitState(memory.pending) { CONVERSATION_ID !in it }
        assertEquals("u1", directive.pending.value[CONVERSATION_ID]?.messageId)

        // The memory strip hangs under u3 again; rolling back u1 withdraws only the instruction strip. When the instruction strip disappears the earlier u0 events have been handled, and the memory strip is still there.
        conversation = conversation(listOf("u1", "u2", "u3").map { message(it, ChatRole.User, "") })
        memory.onUserMessageCreated(CONVERSATION_ID, "u3", "Remember that I use Kotlin", useMemory = false)
        awaitState(memory.pending) { CONVERSATION_ID in it }
        rejections.emit(rolledBack(text = "another send", userMessageId = "u0"))
        rejections.emit(rolledBack(text = DIRECTIVE_TEXT, userMessageId = "u1"))
        awaitState(directive.pending) { CONVERSATION_ID !in it }
        assertEquals("u3", memory.pending.value[CONVERSATION_ID]?.userMessageId)
    }

    @Test
    fun first_message_cancel_returns_to_draft() = runTest {
        MetadataTestFixtures.applyRaw(metadata(threshold = 1_000))
        val db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        try {
            val conversations = ConversationRepository(
                conversationDao = db.conversationDao(),
                messageDao = db.messageDao(),
            )
            val created = conversations.create(GROK_PROVIDER.id, GROK_PROVIDER.kind, MODEL_ID, useMemory = false)
            val harness = GateHarness(conversations)
            harness.ui(backgroundScope)
            val text = "word ".repeat(2_000)
            val send = launch(Dispatchers.Default) { harness.send(text, created) }
            val waiting = realTime { harness.coordinator.pending.first { it.isNotEmpty() } }.single()
            val sending = requireNotNull(conversations.getWithMessages(created.id))
            assertFalse(sending.isDraft)
            val user = sending.messages.first { it.role == ChatRole.User }
            assertEquals(listOf(ChatRole.User, ChatRole.Assistant), sending.messages.map { it.role })

            // Cancelling the first message: the pair is deleted and the conversation returns to a draft (same as iOS isDraft = messages.isEmpty).
            harness.coordinator.resolve(waiting.id, ai.oriveo.community.core.context.ContextCapConfirmChoice.Cancel)
            realTime { send.join() }
            val after = requireNotNull(conversations.getWithMessages(created.id))
            assertTrue(after.isDraft)
            assertTrue("rolled back pair still in conversation: ${after.messages}", after.messages.isEmpty())
            assertEquals(0, harness.chatRequests.get())
            val rolledBack = harness.rejections.single()
            assertTrue(rolledBack.rolledBack && rolledBack.restoresComposer)
            assertEquals(text, rolledBack.text)
            assertEquals(user.id, rolledBack.userMessageId)
        } finally {
            db.close()
        }
    }

    @Test
    fun gate_stop_while_waiting_rolls_back() = runTest {
        MetadataTestFixtures.applyRaw(metadata(threshold = 200_000))
        val harness = GateHarness()
        val ui = harness.ui(backgroundScope)
        // With no confirmation pending, the stop button stops generation as usual.
        assertFalse(ui.stopWaitingConfirmHere())

        val text = "token ".repeat(40_000)
        assertTrue(ContextBudget.estimateText(text, ContextBudget.RHO0) > 32_000)
        val send = launch(Dispatchers.Default) { harness.send(text) }
        val waiting = awaitState(ui.pendingConfirm) { it != null }
        assertEquals(CONVERSATION_ID, waiting?.conversationId)

        // Pressing stop while waiting = cancel: no chat request, the pair is rolled back, nothing is stored as interrupted, and nothing is recorded as stopped.
        assertTrue(ui.stopWaitingConfirmHere())
        realTime { send.join() }
        assertEquals(0, harness.chatRequests.get())
        assertTrue("rolled back pair still in conversation: ${harness.messages}", harness.messages.isEmpty())
        coVerify(exactly = 0) { harness.conversationRepository.updateMessage(any(), match { it.state == ChatMessageState.Interrupted }) }
        assertNull(harness.outputs.streamingMessageId.value)
        val rolledBack = harness.rejections.single()
        assertTrue(rolledBack.rolledBack)
        assertEquals(text, rolledBack.text)
        assertNull(ui.pendingConfirm.value)

        // Stopping generation (cancelAiCompaction) likewise cancels the pending confirmation.
        val again = launch(Dispatchers.Default) { harness.send(text) }
        awaitState(ui.pendingConfirm) { it != null }
        ui.cancelAiCompaction(CONVERSATION_ID)
        realTime { again.join() }
        assertEquals(0, harness.chatRequests.get())
        assertTrue(harness.messages.isEmpty())
        assertEquals(2, harness.rejections.size)
    }

    // ── helpers ──

    /** The controllers judge on Dispatchers.IO; wait on real time (runTest's withTimeout is virtual). */
    private suspend fun <T> awaitState(flow: StateFlow<T>, predicate: (T) -> Boolean): T =
        realTime { flow.first(predicate) }

    private suspend fun <T> realTime(block: suspend () -> T): T =
        withContext(Dispatchers.Default) { withTimeout(TIMEOUT_MS) { block() } }

    private fun pending(estimatedInput: Int, B: Int, limitedBy: ContextBudgetLimit, priceLineTokens: Int?): PendingContextCapConfirmation {
        val input = ContextConfirmInput(
            attempt = ContextConfirmAttempt.SEND,
            model = MODEL_ID,
            reminderEnabled = true,
            state = ContextPriceLineConfirmState(),
            pricing = null,
            estimatedInput = estimatedInput,
            B = B,
            limitedBy = limitedBy,
            priceLineTokens = priceLineTokens,
        )
        return PendingContextCapConfirmation(
            conversationId = CONVERSATION_ID,
            messageId = "assistant-$estimatedInput",
            modelName = MODEL.name,
            input = input,
            decision = ContextCapConfirmPresentation.decide(input),
        )
    }

    private fun rolledBack(
        text: String,
        attachments: List<Attachment>? = null,
        userMessageId: String? = null,
    ) = ChatContextRejection(
        conversationId = CONVERSATION_ID,
        reject = null,
        text = text,
        attachments = attachments,
        quoteContext = QUOTE,
        restoresComposer = true,
        rolledBack = true,
        userMessageId = userMessageId,
    )

    private fun conversation(messages: List<ChatMessage>, cap: ContextBudgetCap? = null) = Conversation(
        id = CONVERSATION_ID,
        title = "Gate",
        providerID = GROK_PROVIDER.id,
        providerKind = GROK_PROVIDER.kind,
        modelID = MODEL_ID,
        useMemory = false,
        contextCap = cap,
        messages = messages,
    )

    private fun message(id: String, role: ChatRole, text: String) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = GROK_PROVIDER.id,
        providerKind = GROK_PROVIDER.kind,
        providerName = GROK_PROVIDER.displayName,
        modelID = MODEL_ID,
        modelName = MODEL.name,
        state = ChatMessageState.Delivered,
    )

    /** The production ChatRepository gate + the production coordinator; the confirmation does not answer itself and is finished by a chat page action (stop / cancel). */
    private inner class GateHarness(conversations: ConversationRepository? = null) {
        val chatRequests = AtomicInteger(0)
        val messages: MutableList<ChatMessage> = Collections.synchronizedList(mutableListOf())
        val rejections: MutableList<ChatContextRejection> = Collections.synchronizedList(mutableListOf())
        private val contextRejections = ChatContextRejections()
        val coordinator = ContextCapConfirmCoordinator(
            store = ContextPriceLineConfirmStore { TestSharedPreferences() },
            reminderEnabled = { true },
        )
        val outputs = ConversationStreamingOutputs(
            streamingText = MutableStateFlow(""),
            streamingMessageId = MutableStateFlow(null),
        )
        private val client = HttpClient(MockEngine {
            chatRequests.incrementAndGet()
            respond("", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also { openClients += it }
        /** Simulated by the message list by default; with a real repository (Room) [messages] is not recorded. */
        val conversationRepository = conversations ?: mockk<ConversationRepository>(relaxed = true).also { repo ->
            coEvery { repo.getWithMessages(any()) } returns null
            coEvery { repo.addMessage(any(), any()) } coAnswers { messages += secondArg<ChatMessage>() }
            coEvery { repo.deleteMessagesLocally(any(), any(), any()) } coAnswers {
                val ids = secondArg<Collection<String>>().toSet()
                val removed = messages.filter { it.id in ids }
                messages.removeAll { it.id in ids }
                removed
            }
        }
        private val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
            coEvery { it.getById(GROK_PROVIDER.id) } returns GROK_PROVIDER
        }
        private val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextRejections = contextRejections,
            contextCapConfirm = coordinator,
        )

        /** Confirmation actions of the chat page: the same coordinator entry points as ChatCompactionUiCoordinator.wire. */
        fun ui(scope: CoroutineScope): ChatCompactionUiCoordinator {
            scope.launch(Dispatchers.Unconfined) { contextRejections.events.collect { rejections += it } }
            return ChatCompactionUiCoordinator(
                store = mockk<ContextCompactionStore>(relaxed = true),
                accountId = { "account" },
                loadConversation = { null },
                memoryItems = { emptyList() },
                chatContext = { c, _ -> ChatContextRequest(ContextConversation(c.id, c.useMemory)) },
                requestOptions = { ChatRequestOptions() },
                compactNow = { _, _, _ -> error("manual compaction not expected") },
                host = ChatCompactionUiCoordinator.Host(
                    scope,
                    MutableStateFlow(ConversationRenderState(conversation(emptyList()))),
                ) { null },
                pendingConfirmations = coordinator.pending,
                resolveConfirm = coordinator::resolve,
                cancelConfirm = coordinator::cancelConversation,
            )
        }

        suspend fun send(text: String, target: Conversation = conversation(emptyList(), ContextBudgetCap.Custom(32_000))) {
            repository.sendMessage(
                conversation = target,
                text = text,
                provider = GROK_PROVIDER,
                modelID = MODEL_ID,
                existingMessages = emptyList(),
                requestOptions = ChatRequestOptions(
                    activeModel = MODEL,
                    chatContext = ChatContextRequest(ContextConversation(id = target.id, useMemory = false)),
                ),
                outputs = outputs,
                persistUserMessage = true,
                userMessageAlreadyInHistory = false,
                attemptKind = ContextConfirmAttempt.SEND,
            )
        }
    }


    private companion object {
        const val CONVERSATION_ID = "conversation-confirm"
        const val MODEL_ID = "grok-4.7"
        // The lexical "set as instruction" bar only recognizes suggestionLanguages, so use an in-gate zh-Hans sentence.
        const val DIRECTIVE_TEXT = "\u4ee5\u540e\u6bcf\u6b21\u56de\u7b54\u90fd\u5148\u7ed9\u7ed3\u8bba"
        const val DONT_ASK_TAG = "context_confirm_dont_ask"
        const val SEND_TAG = "context_confirm_send"
        const val CANCEL_TAG = "context_confirm_cancel"
        const val TIMEOUT_MS = 10_000L

        val MODEL = AIModel(id = MODEL_ID, name = "Grok 4.7", contextLength = 2_000_000)
        val GROK_PROVIDER = Provider(id = "grok-1", kind = ProviderKind.Grok, apiKey = "byok-key", models = listOf(MODEL))
        val QUOTE = QuoteContext(
            sourceMessageId = "m0",
            sourceRole = ChatRole.Assistant,
            contentKind = QuoteContentKind.Prose,
            leadingText = "",
            selectedText = "quoted",
            trailingText = "",
            contextTruncated = false,
        )

        fun metadata(threshold: Int): String {
            val longContext = """{"thresholdTokens":$threshold,"promptPerMToken":4,"completionPerMToken":12}"""
            val model = """
                "$MODEL_ID": {
                  "canonicalModelId": "$MODEL_ID",
                  "displayName": "Grok 4.7",
                  "contextLength": 2000000,
                  "pricingStatus": "paid",
                  "pricing": {"promptPerMToken": 2, "completionPerMToken": 6, "longContext": $longContext}
                }
            """.trimIndent()
            val grok = """"grok": {"displayName": "grok", "resolveMap": {"$MODEL_ID": "$MODEL_ID"}, "models": {$model}}"""
            return """{"version": 1, "contractVersion": 1, "providers": {$grok}}"""
        }
    }
}
