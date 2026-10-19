package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextBasis
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.ContextReject
import ai.oriveo.community.core.context.StopFamily
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.dao.ContextLedgerDao
import ai.oriveo.community.core.data.entity.ContextManifestEntity
import ai.oriveo.community.core.data.entity.ContextRhoCalibrationEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuoteContentKind
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.SseParser
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.ContextConfirmAttempt
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Alignment across platforms: overflow protocol families, refusals, the transport / O / basis of the manifest, one cancel row,
 * no resend when no checkpoint can be cut, and the raw error body is only used for the overflow decision.
 *
 * Production path: the real ChatRepository.sendMessage (with chatContext) -> the real Anthropic / Gemini / Relay service, with MockEngine replaying in order.
 * Model W=16000 / output 8192 -> O=8192, oWire=R=8000, U=B=8000.
 */
class ContextPipelineAlignTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()
    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun relay_anthropic_overflow_uses_anthropic_family() = runTest {
        // Only the anthropic group's regex recognises this sentence (the openai_compatible group does not): judging it as openai_chat would not resend.
        val harness = Harness(this, relay(RelayTransport.AnthropicMessages), ::RelayService, listOf(anthropicOnlyOverflow(), anthropicOnlyOverflow()))
        harness.send("Next question", existing = history())

        assertEquals("overflow recognized → one resend: ${harness.bodies.size}", 2, harness.bodies.size)
        val final = harness.lastAssistantUpdate()
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, final.stopReason)
        assertTrue(harness.dao.manifestsOf().all { it.transport == StopFamily.ANTHROPIC.wire })
    }

    @Test
    fun official_anthropic_overflow_uses_anthropic_family() = runTest {
        val harness = Harness(this, ANTHROPIC, ::AnthropicService, listOf(anthropicOnlyOverflow(), anthropicOnlyOverflow()))
        harness.send("Next question", existing = history())

        assertEquals("overflow recognized → one resend: ${harness.bodies.size}", 2, harness.bodies.size)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, harness.lastAssistantUpdate().stopReason)
        val manifests = harness.dao.manifestsOf()
        assertEquals(2, manifests.size)
        assertTrue(manifests.all { it.transport == StopFamily.ANTHROPIC.wire && it.stopReason == StopReason.CONTEXT_WINDOW_EXCEEDED })
    }

    @Test
    fun official_gemini_overflow_uses_gemini_family() = runTest {
        val body = """{"error":{"code":400,"message":"The input token count (20412) exceeds the maximum number of tokens allowed (16000).","status":"INVALID_ARGUMENT"}}"""
        val harness = Harness(this, GEMINI, ::GeminiService, listOf(Reply(HttpStatusCode.BadRequest, body, JSON_TYPE), Reply(HttpStatusCode.BadRequest, body, JSON_TYPE)))
        harness.send("Next question", existing = history())

        assertEquals("overflow recognized → one resend: ${harness.bodies.size}", 2, harness.bodies.size)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, harness.lastAssistantUpdate().stopReason)
        assertTrue(harness.dao.manifestsOf().all { it.transport == StopFamily.GEMINI.wire })
    }

    @Test
    fun retry_rejected_no_request() = runTest {
        val longText = "m".repeat(17_000)
        val harness = Harness(this, ANTHROPIC, ::AnthropicService, emptyList())
        val user = message("u-long", ChatRole.User, longText, ANTHROPIC, MODEL)
        harness.send(
            longText,
            existing = listOf(user),
            persistUserMessage = false,
            userMessageAlreadyInHistory = true,
            attemptKind = ContextConfirmAttempt.RETRY,
        )

        assertTrue("no request leaves the device: ${harness.bodies}", harness.bodies.isEmpty())
        coVerify(exactly = 0) { harness.conversationRepository.addMessage(any(), any()) }
        val rejection = harness.rejections.single()
        assertEquals(ContextReject.MESSAGE_TOO_LONG, rejection.reject)
        assertFalse("retry has no composer input to restore", rejection.restoresComposer)
        assertTrue("reject writes no manifest", harness.dao.manifestsOf().isEmpty())
    }

    @Test
    fun send_rejected_carries_full_composer_payload() = runTest {
        // Refusal refill: the quote is carried back with the refusal event, and the chat screen puts it all back when the draft is empty.
        val longText = "m".repeat(17_000)
        val quote = QuoteContext(
            sourceMessageId = "a0",
            sourceRole = ChatRole.Assistant,
            contentKind = QuoteContentKind.Prose,
            leadingText = "",
            selectedText = "quoted words",
            trailingText = "",
            contextTruncated = false,
        )
        val harness = Harness(this, ANTHROPIC, ::AnthropicService, emptyList())
        harness.send(longText, quoteContext = quote)

        assertTrue(harness.bodies.isEmpty())
        val rejection = harness.rejections.single()
        assertTrue(rejection.restoresComposer)
        assertEquals(longText, rejection.text)
        assertEquals(quote, rejection.quoteContext)
    }

    @Test
    fun relay_openai_chat_clean_end_records_stop() = runTest {
        val sse = listOf(
            """{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Answer"},"finish_reason":null}]}""",
            """{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}""",
            "[DONE]",
        ).joinToString("") { "data: $it\n\n" }
        val harness = Harness(this, relay(RelayTransport.OpenAIChatCompletions), ::RelayService, listOf(Reply(HttpStatusCode.OK, sse, SSE_TYPE)))
        harness.send("Hello there")

        assertEquals(1, harness.bodies.size)
        val final = harness.lastAssistantUpdate()
        assertEquals(ChatMessageState.Delivered, final.state)
        assertEquals(StopReason.STOP, final.stopReason)
        val manifest = harness.dao.manifestsOf().single()
        assertEquals(StopReason.STOP, manifest.stopReason)
        assertEquals(StopFamily.OPENAI_CHAT.wire, manifest.transport)
        assertEquals(RELAY_MODEL.id, manifest.model)
        assertEquals(8_192, manifest.O)
        assertEquals(if (manifest.observedInput != null) ContextBasis.OBSERVED else ContextBasis.ESTIMATED, manifest.basis)
    }

    @Test
    fun manifest_written_on_user_cancel() = runTest {
        val requested = CompletableDeferred<Unit>()
        val harness = Harness(this, ANTHROPIC, ::AnthropicService, emptyList(), onRequest = {
            requested.complete(Unit)
            awaitCancellation()
        })
        val job = backgroundScope.launch { harness.sendRaw("Hello there") }
        requested.await()
        job.cancel()
        job.join()

        val manifest = harness.dao.manifestsOf().single()
        assertEquals(StopReason.INTERRUPTED, manifest.stopReason)
        assertEquals(StopFamily.ANTHROPIC.wire, manifest.transport)
        assertEquals(8_192, manifest.O)
    }

    @Test
    fun overflow_no_checkpoint_no_retry() = runTest {
        // No history: the fallback cannot cut a checkpoint, so there is no resend and context_window_exceeded is recorded.
        val harness = Harness(this, ANTHROPIC, ::AnthropicService, listOf(anthropicOnlyOverflow()))
        harness.send("Hello there")

        assertEquals(1, harness.bodies.size)
        val final = harness.lastAssistantUpdate()
        assertEquals(ChatMessageState.Failed, final.state)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, final.stopReason)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, harness.dao.manifestsOf().single().stopReason)
    }

    @Test
    fun raw_body_not_in_error_details() = runTest {
        val body = """{"type":"error","error":{"type":"invalid_request_error","message":"Bad field"},"request_id":"$RAW_SENTINEL"}"""
        val overflowBody = """{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 20412 tokens > 16000 maximum"},"request_id":"$RAW_SENTINEL"}"""

        // In the mapped error only rawBody carries the original text; message / toString / technical detail (what logs read) do not.
        val mapped = SseParser.mapHttpError(400, body)
        assertTrue(mapped.rawBody.orEmpty().contains(RAW_SENTINEL))
        assertNoSentinel("error surfaces", listOf(mapped.message, mapped.toString(), mapped.technicalDetail, mapped.userMessage, mapped.title))

        // Production path: neither the failure card nor the manifest carries the raw body.
        val harness = Harness(this, ANTHROPIC, ::AnthropicService, listOf(Reply(HttpStatusCode.BadRequest, body, JSON_TYPE)))
        harness.send("Hello there")
        val failed = harness.lastAssistantUpdate()
        assertEquals(ChatMessageState.Failed, failed.state)
        assertNoSentinel("failure card", listOf(failed.errorTitle, failed.errorDetail, failed.text, failed.toString()))
        assertNoSentinel("manifest rows", harness.dao.manifests.map { it.toString() })

        val overflow = Harness(this, ANTHROPIC, ::AnthropicService, listOf(Reply(HttpStatusCode.BadRequest, overflowBody, JSON_TYPE)))
        overflow.send("Hello there")
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, overflow.lastAssistantUpdate().stopReason)
        assertNoSentinel("overflow failure card", listOf(overflow.lastAssistantUpdate().toString()))
        assertNoSentinel("overflow ledger", overflow.dao.manifests.map { it.toString() } + overflow.dao.rho.values.map { it.toString() })
    }

    // ── harness ──

    private fun assertNoSentinel(where: String, values: List<Any?>) {
        values.forEach { value ->
            assertFalse("$where leaks the raw body: $value", value?.toString().orEmpty().contains(RAW_SENTINEL))
        }
    }

    private class Reply(val status: HttpStatusCode, val body: String, val contentType: String)

    private class FakeLedgerDao : ContextLedgerDao {
        val rho = linkedMapOf<Pair<String, String>, ContextRhoCalibrationEntity>()
        val manifests = mutableListOf<ContextManifestEntity>()

        override suspend fun upsertRho(entity: ContextRhoCalibrationEntity) {
            rho[entity.transportInstanceId to entity.modelId] = entity
        }

        override suspend fun rho(transportInstanceId: String, modelId: String) = rho[transportInstanceId to modelId]

        override suspend fun allRho() = rho.values.toList()

        override suspend fun insertManifest(entity: ContextManifestEntity) {
            manifests += entity
        }

        override suspend fun trimManifests(conversationId: String, keep: Int) = Unit

        override suspend fun manifests(conversationId: String) = manifests.filter { it.conversationId == conversationId }

        fun manifestsOf() = manifests.filter { it.conversationId == CONVERSATION_ID }.map { it.manifest }
    }

    private inner class Harness(
        scope: TestScope,
        private val provider: Provider,
        service: (HttpClient, Json, TransportRegistry) -> ProviderService,
        replies: List<Reply>,
        onRequest: (suspend () -> Unit)? = null,
    ) {
        val bodies = mutableListOf<JsonObject>()
        val rejections = mutableListOf<ChatContextRejection>()
        val dao = FakeLedgerDao()
        private val model = provider.models.single()
        private val channel = ChatContextRejections()
        private val queue = ArrayDeque(replies)
        private val client = HttpClient(MockEngine { request ->
            bodies += json.parseToJsonElement(bodyText(request.body)).jsonObject
            onRequest?.invoke()
            val reply = queue.removeFirst()
            respond(reply.body, reply.status, headersOf(HttpHeaders.ContentType, reply.contentType))
        }).also { openClients += it }
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        private val added = mutableListOf<ChatMessage>()
        private val updated = mutableListOf<ChatMessage>()
        private val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns service(client, json, TransportRegistry(json))
            coEvery { it.getById(provider.id) } returns provider
        }
        private val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextLedgerDao = dao,
            contextRejections = channel,
        )

        init {
            coEvery { conversationRepository.addMessage(any(), any()) } answers { added += secondArg<ChatMessage>() }
            coEvery { conversationRepository.updateMessage(any(), any()) } answers { updated += secondArg<ChatMessage>() }
            scope.backgroundScope.launch(UnconfinedTestDispatcher(scope.testScheduler)) {
                channel.events.collect { rejections += it }
            }
        }

        fun lastAssistantUpdate(): ChatMessage = updated.last { it.role == ChatRole.Assistant }

        suspend fun send(
            text: String,
            existing: List<ChatMessage> = emptyList(),
            persistUserMessage: Boolean = true,
            userMessageAlreadyInHistory: Boolean = false,
            attemptKind: ContextConfirmAttempt = ContextConfirmAttempt.SEND,
            quoteContext: QuoteContext? = null,
        ) {
            runCatching {
                sendRaw(text, existing, persistUserMessage, userMessageAlreadyInHistory, attemptKind, quoteContext)
            }
        }

        suspend fun sendRaw(
            text: String,
            existing: List<ChatMessage> = emptyList(),
            persistUserMessage: Boolean = true,
            userMessageAlreadyInHistory: Boolean = false,
            attemptKind: ContextConfirmAttempt = ContextConfirmAttempt.SEND,
            quoteContext: QuoteContext? = null,
        ) {
            repository.sendMessage(
                conversation = Conversation(
                    id = CONVERSATION_ID,
                    title = "Align",
                    providerID = provider.id,
                    providerKind = provider.kind,
                    modelID = model.id,
                    useMemory = false,
                ),
                text = text,
                provider = provider,
                modelID = model.id,
                existingMessages = existing,
                requestOptions = ChatRequestOptions(
                    activeModel = model,
                    chatContext = ChatContextRequest(ContextConversation(id = CONVERSATION_ID, useMemory = false)),
                ),
                outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow(null),
                ),
                persistUserMessage = persistUserMessage,
                userMessageAlreadyInHistory = userMessageAlreadyInHistory,
                attemptKind = attemptKind,
                quoteContext = quoteContext,
            )
        }
    }

    private fun anthropicOnlyOverflow() = Reply(
        HttpStatusCode.BadRequest,
        """{"type":"error","error":{"type":"invalid_request_error","message":"input length and `max_tokens` exceed context limit: 20412 + 8000 > 16000"}}""",
        JSON_TYPE,
    )

    private fun history(): List<ChatMessage> = (0 until 4).flatMap { i ->
        listOf(
            message("u$i", ChatRole.User, "user-$i " + "a".repeat(1_592), ANTHROPIC, MODEL),
            message("a$i", ChatRole.Assistant, "assistant-$i " + "b".repeat(1_587), ANTHROPIC, MODEL),
        )
    }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun message(id: String, role: ChatRole, text: String, provider: Provider, model: AIModel) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = provider.id,
        providerKind = provider.kind,
        providerName = provider.displayName,
        modelID = model.id,
        modelName = model.name,
        state = ChatMessageState.Delivered,
    )

    private fun relay(transport: RelayTransport) = Provider(
        id = "relay-${transport.value}",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        apiKey = "relay-key",
        baseUrlText = "https://relay.test/v1",
        relayRequested = RelayRequestedConfig(transport = transport),
        models = listOf(RELAY_MODEL),
    )

    private companion object {
        const val CONVERSATION_ID = "conversation-align"
        const val JSON_TYPE = "application/json"
        const val SSE_TYPE = "text/event-stream"
        const val RAW_SENTINEL = "RAW-BODY-SENTINEL-7f3a"
        val MODEL = AIModel(id = "claude-window-16k", name = "Claude 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val GEMINI_MODEL = AIModel(id = "gemini-window-16k", name = "Gemini 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val RELAY_MODEL = AIModel(id = "relay-window-16k", name = "Relay 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val ANTHROPIC = Provider(id = "anthropic-1", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(MODEL))
        val GEMINI = Provider(id = "gemini-1", kind = ProviderKind.Gemini, apiKey = "byok-key", models = listOf(GEMINI_MODEL))
    }
}
