package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextCapConfirmChoice
import ai.oriveo.community.core.context.ContextCapConfirmCoordinator
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.PendingContextCapConfirmation
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.notice.ContextPriceLineAcknowledgement
import ai.oriveo.community.core.notice.ContextPriceLineConfirmStore
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.ContextConfirmAttempt
import ai.oriveo.community.feature.chat.ContextConfirmKind
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
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The confirmation gate: the production ChatRepository.sendMessage suspends on decide after compaction and before the transport;
 * a confirmation sends exactly once, a cancel rolls back (deletes locally only, sends no request, and the refill payload carries the original text).
 *
 * Data: grok-4.7, W = 2000000; the price line T only enters through [MetadataTestFixtures.applyRaw].
 */
class ContextCapConfirmGateTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun gate_over_cap_cancel_rolls_back() = runTest {
        MetadataTestFixtures.applyRaw(metadata(threshold = 200_000))
        val harness = Harness(choice = ContextCapConfirmChoice.Cancel)
        harness.observe(backgroundScope)
        val text = overCapText()
        harness.send(text, capConversation(ContextBudgetCap.Custom(32_000)))

        val asked = harness.asks.single()
        assertEquals(ContextConfirmKind.OVER_CAP, asked.decision.kind)
        assertEquals(0, harness.chatRequests.get())
        // This pair of messages (user + assistant placeholder) is not in the conversation, and only the local delete path ran.
        assertTrue("rolled back pair still in conversation: ${harness.messages}", harness.messages.isEmpty())
        coVerify(exactly = 0) { harness.conversationRepository.deleteMessagesStartingAt(any(), any()) }
        val restored = harness.rejections.single()
        assertTrue(restored.rolledBack)
        assertNull(restored.reject)
        assertEquals(text, restored.text)
        assertTrue(restored.restoresComposer)
        // The event carries the id of the deleted user message: the suggestion strip is withdrawn by it.
        assertEquals(harness.added.first { it.role == ChatRole.User }.id, restored.userMessageId)
    }

    @Test
    fun gate_pending_per_conversation() = runTest {
        MetadataTestFixtures.applyRaw(metadata(threshold = 200_000))
        val harness = Harness(choice = null)
        harness.observe(backgroundScope)
        val conversation = capConversation(ContextBudgetCap.Custom(32_000))
        val first = launch(Dispatchers.Default) { harness.send(overCapText(), conversation) }
        val older = realTime { harness.coordinator.pending.first { it.isNotEmpty() } }.single()

        // A newer suspension in the same conversation replaces the older one: the older is rolled back as a cancel and only the newer remains.
        val second = launch(Dispatchers.Default) { harness.send(overCapText(), conversation) }
        realTime { first.join() }
        val newer = harness.coordinator.pending.value.single()
        assertTrue(newer.id != older.id)
        assertEquals(CONVERSATION_ID, newer.conversationId)
        val rolledBack = harness.rejections.single()
        assertTrue(rolledBack.rolledBack)
        val (olderUser, newerUser) = harness.added.filter { it.role == ChatRole.User }
        assertEquals(olderUser.id, rolledBack.userMessageId)
        // Only the older pair is deleted; the newer pair is still in the conversation.
        assertEquals(listOf(newerUser.id, newer.messageId), harness.messages.map { it.id })
        assertEquals(0, harness.chatRequests.get())

        harness.coordinator.resolve(newer.id, ContextCapConfirmChoice.Send())
        realTime { second.join() }
        assertEquals(1, harness.chatRequests.get())
        assertEquals(1, harness.rejections.size)
        assertEquals(listOf(newerUser.id, newer.messageId), harness.messages.map { it.id })
    }

    @Test
    fun gate_over_cap_confirm_sends_once() = runTest {
        MetadataTestFixtures.applyRaw(metadata(threshold = 200_000))
        val harness = Harness(choice = ContextCapConfirmChoice.Send())
        harness.observe(backgroundScope)
        harness.send(overCapText(), capConversation(ContextBudgetCap.Custom(32_000)))

        assertEquals(ContextConfirmKind.OVER_CAP, harness.asks.single().decision.kind)
        assertEquals(1, harness.chatRequests.get())
        assertEquals(listOf(ChatRole.User, ChatRole.Assistant), harness.messages.map { it.role })
        assertTrue(harness.rejections.isEmpty())
    }

    @Test
    fun gate_price_line_asks_once_per_conversation() = runTest {
        MetadataTestFixtures.applyRaw(metadata(threshold = PRICE_LINE))
        val harness = Harness(choice = ContextCapConfirmChoice.Send())
        harness.observe(backgroundScope)
        harness.send(priceLineText())
        harness.send(priceLineText())

        // The second send with the same model and the same T does not ask; both are sent.
        assertEquals(ContextConfirmKind.PRICE_LINE, harness.asks.single().decision.kind)
        assertEquals(2, harness.chatRequests.get())
        assertEquals(ContextPriceLineAcknowledgement(MODEL_ID, PRICE_LINE), harness.store.state(CONVERSATION_ID).acknowledged)
    }

    @Test
    fun gate_regenerate_skips_confirm() = runTest {
        MetadataTestFixtures.applyRaw(metadata(threshold = PRICE_LINE))
        val harness = Harness(choice = ContextCapConfirmChoice.Cancel)
        harness.observe(backgroundScope)
        val text = priceLineText()
        harness.send(
            text,
            existing = listOf(message("u1", ChatRole.User, text)),
            attemptKind = ContextConfirmAttempt.REGENERATE,
            persistUserMessage = false,
            userMessageAlreadyInHistory = true,
        )

        assertTrue(harness.asks.isEmpty())
        assertEquals(1, harness.chatRequests.get())
    }

    @Test
    fun gate_reminder_off_skips_price_line() = runTest {
        MetadataTestFixtures.applyRaw(metadata(threshold = PRICE_LINE))
        val harness = Harness(choice = ContextCapConfirmChoice.Cancel, reminderEnabled = false)
        harness.observe(backgroundScope)
        harness.send(priceLineText())

        assertTrue(harness.asks.isEmpty())
        assertEquals(1, harness.chatRequests.get())
        assertTrue(harness.rejections.isEmpty())
    }

    // ── helpers ──

    /** The sends run on Dispatchers.Default; wait on real time (runTest's withTimeout is virtual). */
    private suspend fun <T> realTime(block: suspend () -> T): T =
        withContext(Dispatchers.Default) { withTimeout(TIMEOUT_MS) { block() } }

    /** The estimate is far above the custom cap 32000 and far below the price line 200000 and U. */
    private fun overCapText(): String = "token ".repeat(40_000).also {
        val estimate = ContextBudget.estimateText(it, ContextBudget.RHO0)
        assertTrue("estimate $estimate", estimate in 40_000..150_000)
    }

    /** The estimate crosses the price line [PRICE_LINE] and is far below the automatic cap. */
    private fun priceLineText(): String = "word ".repeat(2_000).also {
        assertTrue(ContextBudget.estimateText(it, ContextBudget.RHO0) > PRICE_LINE)
    }

    private fun capConversation(cap: ContextBudgetCap?) = Conversation(
        id = CONVERSATION_ID,
        title = "Gate",
        providerID = GROK_PROVIDER.id,
        providerKind = GROK_PROVIDER.kind,
        modelID = MODEL_ID,
        useMemory = false,
        contextCap = cap,
    )

    /** [choice] null = do not answer automatically; the case finishes through [coordinator]. */
    private inner class Harness(
        private val choice: ContextCapConfirmChoice?,
        reminderEnabled: Boolean = true,
    ) {
        val chatRequests = AtomicInteger(0)
        val messages: MutableList<ChatMessage> = Collections.synchronizedList(mutableListOf())
        /** Every row that was ever stored (including the ones the rollback deleted). */
        val added: MutableList<ChatMessage> = Collections.synchronizedList(mutableListOf())
        val asks: MutableList<PendingContextCapConfirmation> = Collections.synchronizedList(mutableListOf())
        val rejections: MutableList<ChatContextRejection> = Collections.synchronizedList(mutableListOf())
        val store = ContextPriceLineConfirmStore { TestSharedPreferences() }
        private val contextRejections = ChatContextRejections()
        val coordinator = ContextCapConfirmCoordinator(store = store, reminderEnabled = { reminderEnabled })
        private val client = HttpClient(MockEngine {
            chatRequests.incrementAndGet()
            respond(SUCCESS_SSE, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also { openClients += it }
        val conversationRepository = mockk<ConversationRepository>(relaxed = true).also { repo ->
            coEvery { repo.getWithMessages(any()) } returns null
            coEvery { repo.addMessage(any(), any()) } coAnswers {
                messages += secondArg<ChatMessage>()
                added += secondArg<ChatMessage>()
            }
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

        /** Each suspended confirmation is answered by the script; rollback / rejection events are collected into [rejections]. */
        fun observe(scope: CoroutineScope) {
            val dispatcher = Dispatchers.Unconfined
            scope.launch(dispatcher) {
                coordinator.pending.collect { list ->
                    list.forEach { pending ->
                        if (asks.none { it.id == pending.id }) asks += pending
                        choice?.let { coordinator.resolve(pending.id, it) }
                    }
                }
            }
            scope.launch(dispatcher) { contextRejections.events.collect { rejections += it } }
        }

        suspend fun send(
            text: String,
            conversation: Conversation = capConversation(cap = null),
            existing: List<ChatMessage> = emptyList(),
            attemptKind: ContextConfirmAttempt = ContextConfirmAttempt.SEND,
            persistUserMessage: Boolean = true,
            userMessageAlreadyInHistory: Boolean = false,
        ) {
            repository.sendMessage(
                conversation = conversation,
                text = text,
                provider = GROK_PROVIDER,
                modelID = MODEL_ID,
                existingMessages = existing,
                requestOptions = ChatRequestOptions(
                    activeModel = MODEL,
                    chatContext = ChatContextRequest(ContextConversation(id = conversation.id, useMemory = false)),
                ),
                outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow(null),
                ),
                persistUserMessage = persistUserMessage,
                userMessageAlreadyInHistory = userMessageAlreadyInHistory,
                attemptKind = attemptKind,
            )
        }
    }

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

    private companion object {
        const val CONVERSATION_ID = "conversation-gate"
        const val MODEL_ID = "grok-4.7"
        const val PRICE_LINE = 1_000
        const val TIMEOUT_MS = 10_000L

        val MODEL = AIModel(id = MODEL_ID, name = "Grok 4.7", contextLength = 2_000_000)
        val GROK_PROVIDER = Provider(id = "grok-1", kind = ProviderKind.Grok, apiKey = "byok-key", models = listOf(MODEL))

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

        val SUCCESS_SSE = """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":900,"output_tokens":1}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Answer"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

            event: message_stop
            data: {"type":"message_stop"}

        """.trimIndent() + "\n\n"
    }
}
