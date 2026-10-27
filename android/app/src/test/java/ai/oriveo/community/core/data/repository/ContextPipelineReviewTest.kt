package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
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
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.OpenRouterService
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.ContextConfirmAttempt
import ai.oriveo.community.feature.chat.ChatRetryCoordinator
import ai.oriveo.community.feature.chat.ChatSendLauncher
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import java.util.Collections
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Review blockers: rho is only recorded for a single-leg chat, overflow recovery when retrying a failed message, a regenerate refusal does not delete the old answer,
 * OpenRouter does not newly send an output limit, and a relay image prompt carries no dynamic block.
 *
 * Production path: the real ChatRepository.sendMessage (with chatContext) -> the real provider service, with MockEngine replaying by path and capturing request bodies.
 * Model W=16000 / output 8192 -> U=B=8000; a history of 8 messages x 1600 bytes, so the fallback after an overflow can cut a checkpoint.
 */
class ContextPipelineReviewTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun overflow_resend_reuses_this_turn_external_search_without_calling_the_executor() = runTest {
        // Internal resend within this turn (over-window recovery) rebuilds the result already obtained this turn via reuse: no new request, no extra charge
        var executions = 0
        val service = ai.oriveo.community.core.search.SearchTurnService(id = "s1", name = "DeepSeek", protocol = "catalog")
        val search = ai.oriveo.community.core.search.ExternalSearchSend(
            path = "external_presearch",
            toolCall = "unsupported",
            modelKey = "anthropic-1:${MODEL.id}",
            binding = ai.oriveo.community.core.search.ExternalSearchBinding(
                service = service,
                otherServices = emptyList(),
                defaultCount = 5,
                execute = { _, _ ->
                    executions++
                    ai.oriveo.community.core.search.SearchCallOutcome.Results(
                        listOf(ai.oriveo.community.core.search.SearchResultItem(title = "W1", url = "https://a.example.com/1", snippet = "one")),
                        1,
                    )
                },
            ),
        )
        val harness = Harness(anthropicProvider(), chatReplies = listOf(anthropicOverflow(), anthropicSuccess(inputTokens = null)))
        harness.send("Next question", existing = history(), externalSearch = search)

        assertEquals("overflow resends once: ${harness.requests}", 2, harness.chatBodies().size)
        assertEquals("the resend does not call the executor again", 1, executions)
        harness.chatBodies().forEach { body ->
            assertTrue("both requests carry the web results in [D]", body.toString().contains("oriveo-web"))
        }
        val delivered = harness.lastAssistantUpdate()
        assertEquals(ChatMessageState.Delivered, delivered.state)
        val web = delivered.citations.orEmpty().filter { it.source == "external_search" }
        assertEquals(listOf("https://a.example.com/1"), web.map { it.url })
        // Sources line and message facts keep this turn's actual values: searched once, not marked as "reusing the previous search"
        val line = delivered.searchSourcesLine!!
        assertFalse("internal resend is not a reused search", line.reused)
        assertEquals(1, line.searchCount)
        assertEquals(1, line.sourceCount)
        assertEquals("observed", delivered.capabilityExecutionResults.single { it.source == "external_search" }.state)
    }

    @Test
    fun history_search_record_line_skips_the_retry_target_and_stands_alone_on_empty_text() {
        val web = ai.oriveo.community.core.model.Citation(url = "https://a.example.com/1", title = "W1", index = 1, source = "external_search", query = "q1")
        val answered = message("a1", ChatRole.Assistant, "Answer").copy(citations = listOf(web))
        val empty = message("a2", ChatRole.Assistant, "").copy(citations = listOf(web))
        val raw = listOf(message("u1", ChatRole.User, "first"), answered, message("u2", ChatRole.User, "second"), empty, message("u3", ChatRole.User, "now"))
        fun project(exclude: String?) = ChatContextProjector.project(
            request = ChatContextRequest(ContextConversation(id = CONVERSATION_ID, useMemory = false)),
            rawMessages = raw,
            window = ai.oriveo.community.core.context.ContextWindowInput(
                W = 128_000, windowKind = ai.oriveo.community.core.context.ContextWindowKind.TOTAL,
                maxOutput = ai.oriveo.community.core.context.ContextMaxOutput(model = 8_000),
            ),
            rhoHi = 1.0,
            recordExcludeId = exclude,
        )!!.messages.associate { it.id to it.text }
        val all = project(null)
        val line = ai.oriveo.community.core.search.searchedRecordLineFor(listOf(web))!!
        assertEquals("Answer\n\n$line", all["a1"])
        assertEquals("empty body carries only the record line", line, all["a2"])
        assertEquals("retry target gets no record line", "", project("a2")["a2"].orEmpty())
    }

    @Test
    fun search_thinking_on_means_the_request_carries_a_reasoning_tier() {
        assertFalse(ai.oriveo.community.core.search.searchThinkingOn(ai.oriveo.community.core.model.ReasoningMode.Automatic))
        assertFalse(ai.oriveo.community.core.search.searchThinkingOn(ai.oriveo.community.core.model.ReasoningMode.Fast))
        assertTrue(ai.oriveo.community.core.search.searchThinkingOn(ai.oriveo.community.core.model.ReasoningMode.Balanced))
        assertTrue(ai.oriveo.community.core.search.searchThinkingOn(ai.oriveo.community.core.model.ReasoningMode.Max))
    }

    @Test
    fun rho_skipped_on_context_window_exceeded() = runTest {
        val harness = Harness(anthropicProvider(), chatReplies = listOf(anthropicWindowExceeded(inputTokens = 900)))
        harness.send("Hello there")

        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, harness.lastAssistantUpdate().stopReason)
        assertNull("context_window_exceeded ending writes no rho sample", harness.dao.rho[harness.key])
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, harness.dao.manifestsOf(CONVERSATION_ID).single().stopReason)
    }

    @Test
    fun retry_overflow_recovers_once() = runTest {
        // Retrying a failed message: ChatRetryCoordinator passes appendToAssistant (the cleared original assistant slot) + userMessageAlreadyInHistory.
        val user = message("u-now", ChatRole.User, "Next question")
        val failed = message("a-failed", ChatRole.Assistant, "", ChatMessageState.Failed)
        val harness = Harness(anthropicProvider(), chatReplies = listOf(anthropicOverflow(), anthropicSuccess(inputTokens = 3_000)))
        harness.send(
            "Next question",
            existing = history() + user + failed,
            appendToAssistant = failed,
            userMessageAlreadyInHistory = true,
            persistUserMessage = false,
            attemptKind = ContextConfirmAttempt.RETRY,
        )

        assertEquals("retry recovers once: ${harness.chatBodies().size}", 2, harness.chatBodies().size)
        assertTrue(harness.turnsOf(harness.chatBodies()[1]).first().second.startsWith(CHECKPOINT_OPEN))
        val final = harness.lastAssistantUpdate()
        assertEquals(failed.id, final.id)
        assertEquals(ChatMessageState.Delivered, final.state)
        assertEquals("Answer", final.text)

        // Continue goes through the same pipeline as chat: an overflow also falls back and resends once, and the body is still appended to the target.
        val partial = message("a-partial", ChatRole.Assistant, "Partial", ChatMessageState.Interrupted)
        val cont = Harness(anthropicProvider(), chatReplies = listOf(anthropicOverflow(), anthropicSuccess(inputTokens = 3_000)))
        cont.send(
            "Continue",
            existing = history() + user + partial,
            appendToAssistant = partial,
            persistUserMessage = false,
            attemptKind = ContextConfirmAttempt.CONTINUE,
        )
        assertEquals("continue recovers once: ${cont.chatBodies().size}", 2, cont.chatBodies().size)
        assertEquals(partial.id, cont.lastAssistantUpdate().id)
        assertEquals("PartialAnswer", cont.lastAssistantUpdate().text)
    }

    @Test
    fun regenerate_reject_keeps_old_answer() = runTest {
        val provider = anthropicProvider()
        val longUser = message("u-long", ChatRole.User, "x".repeat(40_000))
        val oldAnswer = message("a-old", ChatRole.Assistant, "Old answer")
        val harness = Harness(provider, chatReplies = listOf(anthropicSuccess(inputTokens = 100)))
        val launches = mutableListOf<suspend () -> Unit>()
        val conversation = CONVERSATION.copy(messages = listOf(longUser, oldAnswer))
        coEvery { harness.conversationRepository.getWithMessages(CONVERSATION_ID) } returns conversation
        val launcher = ChatSendLauncher { conv, prov, modelId, text, existing, attachments, persistUser, append,
            alreadyInHistory, quote, attemptKind ->
            launches += {
                harness.repository.sendMessage(
                    conversation = conv,
                    text = text,
                    provider = prov,
                    modelID = modelId,
                    existingMessages = existing,
                    attachments = attachments,
                    quoteContext = quote,
                    requestOptions = harness.requestOptions(),
                    outputs = outputs(),
                    persistUserMessage = persistUser,
                    userMessageAlreadyInHistory = alreadyInHistory,
                    appendToAssistant = append,
                    attemptKind = attemptKind,
                )
            }
        }
        val coordinator = ChatRetryCoordinator(
            viewModelScope = this,
            conversationRepository = harness.conversationRepository,
            providerRepository = harness.providerRepository,
            chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true),
            currentConversation = { conversation },
            activeProviderId = { provider.id },
            activeModelId = { MODEL.id },
            providers = { listOf(provider) },
            requestPin = {},
            launchSend = launcher,
        )
        coordinator.regenerateMessage(oldAnswer.id)
        advanceUntilIdle()
        launches.forEach { it() }

        assertEquals("rejected: no request", 0, harness.chatBodies().size)
        coVerify(exactly = 0) { harness.conversationRepository.deleteMessagesAfter(any(), any()) }

        // Control: a regenerate that can be sent deletes everything after lastUser as usual and then sends.
        val shortUser = message("u-short", ChatRole.User, "Short question")
        val okConversation = CONVERSATION.copy(messages = listOf(shortUser, oldAnswer))
        val ok = Harness(provider, chatReplies = listOf(anthropicSuccess(inputTokens = 100)))
        ok.send(
            shortUser.text,
            existing = listOf(shortUser),
            userMessageAlreadyInHistory = true,
            persistUserMessage = false,
            attemptKind = ContextConfirmAttempt.REGENERATE,
            conversation = okConversation,
        )
        assertEquals(1, ok.chatBodies().size)
        coVerify(exactly = 1) { ok.conversationRepository.deleteMessagesAfter(CONVERSATION_ID, shortUser.id) }
        assertEquals(listOf("user" to "Short question"), ok.turnsOf(ok.chatBodies().single()))
    }

    @Test
    fun openrouter_no_cap_when_not_sent_before() = runTest {
        // The metadata has no maxOutputTokens and the user set none: no limit was sent before, so oWire is not newly sent.
        val model = AIModel(id = "vendor/no-cap", name = "No cap", contextLength = 16_000)
        val provider = Provider(id = "openrouter-1", kind = ProviderKind.OpenRouter, apiKey = "byok-key", models = listOf(model))
        val harness = Harness(
            provider,
            model = model,
            service = { client -> OpenRouterService(client, json, TransportRegistry(json)) },
            chatPath = "/chat/completions",
            chatReplies = listOf(openAiSuccess()),
        )
        harness.send("Hello there")

        val body = harness.chatBodies().single()
        assertFalse("no max_tokens: $body", body.containsKey("max_tokens"))
        assertFalse("no max_completion_tokens: $body", body.containsKey("max_completion_tokens"))
    }

    @Test
    fun user_abort_throw_message_interrupted() = runTest {
        // User stop cancels the job; OkHttp then surfaces IOException("Canceled") instead of CancellationException.
        userAbortCase { stop ->
            emit(StreamEvent.Delta("Partial"))
            stop()
            throw java.io.IOException("Canceled")
        }
    }

    @Test
    fun user_abort_silent_close_records_interrupted() = runTest {
        // User stop cancels the job and the stream just ends without a Done event.
        userAbortCase { stop ->
            emit(StreamEvent.Delta("Partial"))
            stop()
        }
    }

    @Test
    fun system_interrupt_writes_no_manifest() = runTest {
        // A system interrupt (for example an account switch) cancels the job with systemInterrupted set: no manifest,
        // and the message stopReason follows the transport-error mapping, not interrupted.
        val cancelled = systemInterruptCase { stop ->
            emit(StreamEvent.Delta("Partial"))
            stop()
        }
        val thrown = systemInterruptCase { stop ->
            emit(StreamEvent.Delta("Partial"))
            stop()
            throw java.io.IOException("Canceled")
        }
        for (harness in listOf(cancelled, thrown)) {
            val final = harness.lastAssistantUpdate()
            assertTrue("stopReason=${final.stopReason}", final.stopReason != StopReason.INTERRUPTED)
            assertTrue("manifests=${harness.dao.manifestsOf(CONVERSATION_ID)}", harness.dao.manifests(CONVERSATION_ID).isEmpty())
        }
    }

    private suspend fun kotlinx.coroutines.test.TestScope.systemInterruptCase(
        body: suspend kotlinx.coroutines.flow.FlowCollector<StreamEvent>.(stop: () -> Unit) -> Unit,
    ): Harness {
        val streamOutputs = outputs()
        var job: kotlinx.coroutines.Job? = null
        val harness = abortHarness(body) {
            streamOutputs.systemInterrupted.set(true)
            job?.cancel()
        }
        val launched = launch { harness.send("Next question", existing = history(), streamOutputs = streamOutputs) }
        job = launched
        launched.join()
        return harness
    }

    private fun abortHarness(
        body: suspend kotlinx.coroutines.flow.FlowCollector<StreamEvent>.(stop: () -> Unit) -> Unit,
        stop: () -> Unit,
    ) = Harness(
        anthropicProvider(),
        service = { client ->
            val real = AnthropicService(client, json, TransportRegistry(json))
            object : ProviderService by real {
                override fun sendMessageStream(
                    apiKey: String,
                    modelID: String,
                    messages: List<ChatMessage>,
                    baseUrl: String?,
                    supportsImageGen: Boolean,
                    reasoningMode: ai.oriveo.community.core.model.ReasoningMode,
                    webSearchEnabled: Boolean,
                    requestOptions: ChatRequestOptions,
                ) = kotlinx.coroutines.flow.flow { body { stop() } }
            }
        },
        chatReplies = emptyList(),
    )

    private suspend fun kotlinx.coroutines.test.TestScope.userAbortCase(
        body: suspend kotlinx.coroutines.flow.FlowCollector<StreamEvent>.(stop: () -> Unit) -> Unit,
    ) {
        var job: kotlinx.coroutines.Job? = null
        val harness = Harness(
            anthropicProvider(),
            service = { client ->
                val real = AnthropicService(client, json, TransportRegistry(json))
                object : ProviderService by real {
                    override fun sendMessageStream(
                        apiKey: String,
                        modelID: String,
                        messages: List<ChatMessage>,
                        baseUrl: String?,
                        supportsImageGen: Boolean,
                        reasoningMode: ai.oriveo.community.core.model.ReasoningMode,
                        webSearchEnabled: Boolean,
                        requestOptions: ChatRequestOptions,
                    ) = kotlinx.coroutines.flow.flow { body { job?.cancel() } }
                }
            },
            chatReplies = emptyList(),
        )
        val launched = launch { harness.send("Next question", existing = history()) }
        job = launched
        launched.join()

        val final = harness.lastAssistantUpdate()
        assertEquals(ChatMessageState.Interrupted, final.state)
        assertEquals(StopReason.INTERRUPTED, final.stopReason)
        assertEquals(StopReason.INTERRUPTED, harness.dao.manifestsOf(CONVERSATION_ID).last().stopReason)
    }

    @Test
    fun relay_image_prompt_has_no_dynamic_block() = runTest {
        // Relay image generation on Android (the images_endpoint route) does not go through a chat request; the prompt is the last user message among the outbound messages, and the assertion is that it is the user's original text.
        val model = AIModel(id = "gpt-image-1", name = "Image", contextLength = 16_000, capabilities = listOf(ModelCapability.ImageGen))
        val provider = Provider(
            id = "relay-1", kind = ProviderKind.Relay, status = ProviderConnectionState.Connected, apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions), models = listOf(model),
        )
        val harness = Harness(
            provider,
            model = model,
            service = { client -> RelayService(client, json, TransportRegistry(json)) },
            chatPath = "/images/generations",
            chatReplies = listOf(Reply(HttpStatusCode.OK, """{"created":1,"data":[{"b64_json":"aGk="}]}""", JSON_TYPE)),
            attachmentGuide = "ATTACHMENT-GUIDE-BLOCK",
        )
        harness.send("Draw a red fox")

        val body = harness.chatBodies().single()
        assertEquals("Draw a red fox", body.getValue("prompt").jsonPrimitive.content)
    }

    // ── harness ──

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

        fun manifestsOf(conversationId: String) = manifests.filter { it.conversationId == conversationId }.map { it.manifest }
    }

    private inner class Harness(
        private val provider: Provider,
        private val model: AIModel = MODEL,
        service: (HttpClient) -> ProviderService = { client -> AnthropicService(client, json, TransportRegistry(json)) },
        private val chatPath: String = "/v1/messages",
        chatReplies: List<Reply>,
        private val attachmentGuide: String? = null,
    ) {
        val requests: MutableList<Pair<String, String>> = Collections.synchronizedList(mutableListOf())
        val dao = FakeLedgerDao()
        val key = ChatContextProjector.rhoTransportKey(provider) to model.id
        private val queue = ArrayDeque(chatReplies)
        private val client = HttpClient(MockEngine { request ->
            val path = request.url.encodedPath
            requests += path to bodyText(request.body)
            when {
                path.endsWith(chatPath) -> {
                    val reply = queue.removeFirst()
                    respond(reply.body, reply.status, headersOf(HttpHeaders.ContentType, reply.contentType))
                }
                else -> respond("{}", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, JSON_TYPE))
            }
        }).also { openClients += it }
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        private val updated = mutableListOf<ChatMessage>()
        val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            val built = service(client)
            every { it.serviceFor(any<Provider>(), any()) } returns built
            coEvery { it.getById(provider.id) } returns provider
            every { it.toolCallMemoryVerdict(any(), any()) } returns null
        }
        val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextLedgerDao = dao,
        )

        init {
            coEvery { conversationRepository.updateMessage(any(), any()) } answers { updated += secondArg<ChatMessage>() }
        }

        fun chatBodies(): List<JsonObject> = requests.toList()
            .filter { it.first.endsWith(chatPath) }
            .map { json.parseToJsonElement(it.second).jsonObject }

        fun lastAssistantUpdate(): ChatMessage = updated.last { it.role == ChatRole.Assistant }

        fun requestOptions() = ChatRequestOptions(
            activeModel = model,
            chatContext = ChatContextRequest(
                ContextConversation(id = CONVERSATION_ID, useMemory = false),
                attachmentGuide = attachmentGuide,
            ),
        )

        suspend fun send(
            text: String,
            existing: List<ChatMessage> = emptyList(),
            appendToAssistant: ChatMessage? = null,
            userMessageAlreadyInHistory: Boolean = false,
            persistUserMessage: Boolean = true,
            attemptKind: ContextConfirmAttempt = ContextConfirmAttempt.SEND,
            conversation: Conversation = CONVERSATION,
            streamOutputs: ConversationStreamingOutputs = outputs(),
            externalSearch: ai.oriveo.community.core.search.ExternalSearchSend? = null,
        ) {
            runCatching {
                repository.sendMessage(
                    conversation = conversation.copy(providerID = provider.id, providerKind = provider.kind, modelID = model.id),
                    text = text,
                    provider = provider,
                    modelID = model.id,
                    existingMessages = existing,
                    requestOptions = requestOptions(),
                    outputs = streamOutputs,
                    persistUserMessage = persistUserMessage,
                    userMessageAlreadyInHistory = userMessageAlreadyInHistory,
                    appendToAssistant = appendToAssistant,
                    attemptKind = attemptKind,
                    externalSearch = externalSearch,
                )
            }.exceptionOrNull()?.let { if (it is AssertionError) throw it }
        }

        fun turnsOf(body: JsonObject): List<Pair<String, String>> =
            body["messages"].let { it as? kotlinx.serialization.json.JsonArray }.orEmpty()
                .map { it.jsonObject }
                .filter { it["role"]?.jsonPrimitive?.content in setOf("user", "assistant") }
                .map { it.getValue("role").jsonPrimitive.content to textOf(it) }
    }

    private fun outputs() = ConversationStreamingOutputs(
        streamingText = MutableStateFlow(""),
        streamingMessageId = MutableStateFlow(null),
    )

    private fun anthropicProvider() =
        Provider(id = "anthropic-1", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(MODEL))

    private fun anthropicOverflow() = Reply(
        HttpStatusCode.BadRequest,
        """{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 20412 tokens > 16000 maximum"}}""",
        JSON_TYPE,
    )

    private fun anthropicSuccess(inputTokens: Int?) = anthropicStream(inputTokens, text = "Answer", stopReason = "end_turn")

    private fun anthropicWindowExceeded(inputTokens: Int) =
        anthropicStream(inputTokens, text = "Partial", stopReason = "model_context_window_exceeded")

    private fun anthropicStream(inputTokens: Int?, text: String, stopReason: String): Reply {
        val usage = inputTokens?.let { ""","usage":{"input_tokens":$it,"output_tokens":1}""" }.orEmpty()
        return Reply(
            HttpStatusCode.OK,
            """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","content":[]$usage}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"$text"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"$stopReason"},"usage":{"output_tokens":2}}

            event: message_stop
            data: {"type":"message_stop"}

            """.trimIndent() + "\n\n",
            SSE_TYPE,
        )
    }

    private fun openAiSuccess() = Reply(
        HttpStatusCode.OK,
        ProviderTestFixtures.openAiStream(
            ProviderTestFixtures.openAiChunk(delta = "Answer", model = "m"),
            ProviderTestFixtures.openAiChunk(promptTokens = 5, completionTokens = 2, model = "m"),
        ),
        SSE_TYPE,
    )

    private fun history(): List<ChatMessage> = (0 until 4).flatMap { i ->
        listOf(
            message("u$i", ChatRole.User, "user-$i " + "a".repeat(1_592)),
            message("a$i", ChatRole.Assistant, "assistant-$i " + "b".repeat(1_587)),
        )
    }

    private fun textOf(item: JsonObject): String = when (val content = item["content"]) {
        is kotlinx.serialization.json.JsonPrimitive -> content.content
        is kotlinx.serialization.json.JsonArray -> content.map { it.jsonObject }
            .filter { it["type"]?.jsonPrimitive?.content == "text" }
            .joinToString("") { it["text"]?.jsonPrimitive?.content.orEmpty() }
        else -> ""
    }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> ""
    }

    private fun message(
        id: String,
        role: ChatRole,
        text: String,
        state: ChatMessageState = ChatMessageState.Delivered,
    ) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = "anthropic-1",
        providerKind = ProviderKind.Anthropic,
        providerName = "Anthropic",
        modelID = MODEL.id,
        modelName = MODEL.name,
        state = state,
    )

    private companion object {
        const val CONVERSATION_ID = "conversation-1"
        const val CHECKPOINT_OPEN = "<oriveo-context-checkpoint v=\"1\""
        const val JSON_TYPE = "application/json"
        const val SSE_TYPE = "text/event-stream"
        val MODEL = AIModel(id = "window-16k", name = "Window 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val CONVERSATION = Conversation(
            id = CONVERSATION_ID,
            title = "Review",
            providerID = "anthropic-1",
            providerKind = ProviderKind.Anthropic,
            modelID = MODEL.id,
            useMemory = false,
        )
    }
}
