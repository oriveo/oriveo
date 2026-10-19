package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ContextAssembler
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.data.dao.MessageContinuationDao
import ai.oriveo.community.core.data.entity.MessageContinuationEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.MessageContinuationStore
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.streaming.StreamRequest
import ai.oriveo.community.feature.chat.ChatRetryCoordinator
import ai.oriveo.community.feature.chat.ChatSendCoordinator
import ai.oriveo.community.feature.chat.ChatSendLauncher
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
import io.mockk.verify
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * "Continue generating" is produced by ContextAssembler (purpose continue).
 *
 * Production path: ChatRetryCoordinator.continueMessage -> ChatSendCoordinator.launchSend -> StreamRequest ->
 * the real ChatRepository.sendMessage -> the real OpenAIService, with MockEngine only capturing the request body.
 */
class ContextPipelineContinueTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun continue_uses_continue_prompt_and_keeps_target() = runTest {
        val harness = Harness(this, CHAT_MODEL)
        val user = message("u-1", ChatRole.User, "First question", CHAT_MODEL)
        val partial = message("a-1", ChatRole.Assistant, "Partial answer", CHAT_MODEL, ChatMessageState.Interrupted)
        harness.continueOn(conversation(CHAT_MODEL).copy(messages = listOf(user, partial)), partial.id)

        val body = harness.bodies.single()
        assertEquals(memorySystem(), systemOf(body))
        assertEquals(
            listOf("user" to "First question", "assistant" to "Partial answer", "user" to ContextAssembler.CONTINUE_PROMPT),
            turnsOf(body),
        )
        assertFalse("legacy continue sentence gone: $body", "Continue from where you stopped" in body.toString())
        assertFalse("continue carries no reminder: $body", "<oriveo-reminder>" in body.toString())
        // The continuation text is still appended to the target assistant message.
        assertEquals("Partial answerok", harness.lastUpdate(partial.id)?.text)
    }

    @Test
    fun continue_keeps_leading_whitespace_non_streaming() = runTest {
        // An image-generation model takes the non-streaming service.sendMessage branch: Done delivers the whole text at once, text is trimmed and rawText is the original.
        val harness = Harness(this, IMAGE_MODEL, service = doneOnlyService())
        val user = message("u-1", ChatRole.User, "Write a story", IMAGE_MODEL)
        val partial = message("a-1", ChatRole.Assistant, "Chapter 1.", IMAGE_MODEL, ChatMessageState.Interrupted)
        harness.continueOn(conversation(IMAGE_MODEL).copy(messages = listOf(user, partial)), partial.id)

        assertEquals("Chapter 1.$CONTINUATION_RAW", harness.lastUpdate(partial.id)?.text)
    }

    @Test
    fun continue_keeps_leading_whitespace_done_only() = runTest {
        // Streaming branch with no Delta: the whole text only arrives in Done.
        val harness = Harness(this, CHAT_MODEL, service = doneOnlyService())
        val user = message("u-1", ChatRole.User, "Write a story", CHAT_MODEL)
        val partial = message("a-1", ChatRole.Assistant, "Chapter 1.", CHAT_MODEL, ChatMessageState.Interrupted)
        harness.continueOn(conversation(CHAT_MODEL).copy(messages = listOf(user, partial)), partial.id)

        assertEquals("Chapter 1.$CONTINUATION_RAW", harness.lastUpdate(partial.id)?.text)
    }

    @Test
    fun continue_keeps_leading_whitespace_relay_non_streaming() = runTest {
        // The real RelayService: the Responses protocol with stream=false takes the non-streaming runtime (coordinator sendResponses).
        val harness = Harness(this, CHAT_MODEL, relayNonStreaming = true)
        val user = message("u-1", ChatRole.User, "Write a story", CHAT_MODEL)
        val partial = message("a-1", ChatRole.Assistant, "Chapter 1.", CHAT_MODEL, ChatMessageState.Interrupted)
        harness.continueOn(conversation(CHAT_MODEL).copy(messages = listOf(user, partial)), partial.id)

        assertTrue("went to relay /responses non-streaming: ${harness.bodies}", harness.bodies.single()["stream"]?.jsonPrimitive?.content != "true")
        assertEquals("Chapter 1.$CONTINUATION_RAW", harness.lastUpdate(partial.id)?.text)
    }

    /** Same rule as the OpenAI / compatible-family services: text is the trimmed body and rawText keeps the original leading newline. */
    private fun doneOnlyService(): ProviderService {
        val done = StreamEvent.Done(ProviderChatResult(text = CONTINUATION_RAW.trim(), rawText = CONTINUATION_RAW))
        return mockk<ProviderService>(relaxed = true).also {
            every { it.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), any()) } returns flowOf(done)
            coEvery { it.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) } returns done
        }
    }

    @Test
    fun continue_stateful_omit_drops_instructions() = runTest {
        applyResponsesRuntime("omit")
        val harness = Harness(this, RESPONSES_MODEL, forceWeb = true, continuations = true)
        val (conversation, assistantId) = harness.answerThenPartial()
        harness.continueOn(conversation, assistantId)

        val body = harness.bodies.last()
        assertEquals("r1", body["previous_response_id"]?.jsonPrimitive?.content)
        assertFalse("omit drops instructions: $body", "instructions" in body)
        assertEquals(listOf("user" to ContextAssembler.CONTINUE_PROMPT), turnsOf(body))
    }

    @Test
    fun continue_mode_missing_sends_full_plan() = runTest {
        applyResponsesRuntime(null)
        val harness = Harness(this, RESPONSES_MODEL, forceWeb = true, continuations = true)
        val (conversation, assistantId) = harness.answerThenPartial()
        harness.continueOn(conversation, assistantId)

        val body = harness.bodies.last()
        assertNull(body["previous_response_id"])
        assertEquals(memorySystem(), systemOf(body))
        assertEquals(
            listOf("user" to "q", "assistant" to "ok", "user" to ContextAssembler.CONTINUE_PROMPT),
            turnsOf(body),
        )
    }

    /** Only the replay kind (the service replays the target itself) drops the target assistant; previous_id and tool_loop keep it (same on all platforms, by kind and not by field). */
    @Test
    fun continue_replay_kind_drops_target() = runTest {
        val cases = listOf(
            "replay_blocks" to JsonObject(mapOf("blocks" to JsonArray(emptyList()))),
            "previous_id" to JsonObject(mapOf("previousResponseId" to JsonPrimitive("r0"))),
            "tool_loop" to JsonObject(mapOf("completedMessages" to JsonArray(emptyList()))),
        )
        cases.forEach { (kind, state) ->
            val harness = Harness(this, CHAT_MODEL, continuations = true)
            val conv = conversation(CHAT_MODEL)
            val user = message("u-1", ChatRole.User, "First question", CHAT_MODEL)
            val partial = message("a-1", ChatRole.Assistant, "Partial answer", CHAT_MODEL, ChatMessageState.Interrupted)
            harness.store!!.save("account", conv.id, partial.id, kind, state)
            harness.continueOn(conv.copy(messages = listOf(user, partial)), partial.id)

            val expected = if (kind == "replay_blocks") {
                listOf("user" to "First question", "user" to ContextAssembler.CONTINUE_PROMPT)
            } else {
                listOf("user" to "First question", "assistant" to "Partial answer", "user" to ContextAssembler.CONTINUE_PROMPT)
            }
            assertEquals("kind=$kind", expected, turnsOf(harness.bodies.single()))
        }
    }

    /** Continue is a text continuation: no MCP tool plan and no tool loop (same on iOS: textContinuationOnly). */
    @Test
    fun continue_no_tool_loop() = runTest {
        val mcpRunner = mockk<McpChatToolRunner>(relaxed = true)
        val harness = Harness(this, CHAT_MODEL, mcpRunner = mcpRunner)
        val user = message("u-1", ChatRole.User, "First question", CHAT_MODEL)
        val partial = message("a-1", ChatRole.Assistant, "Partial answer", CHAT_MODEL, ChatMessageState.Interrupted)
        harness.continueOn(conversation(CHAT_MODEL).copy(messages = listOf(user, partial)), partial.id)

        coVerify(exactly = 0) { mcpRunner.plan(any(), any(), any(), any(), any()) }
        val body = harness.bodies.single()
        assertFalse("continue sends no tools: $body", "tools" in body)
        assertEquals(
            listOf("user" to "First question", "assistant" to "Partial answer", "user" to ContextAssembler.CONTINUE_PROMPT),
            turnsOf(body),
        )
    }

    /** Stateful (previous_id) continue sends only the continue prompt. */
    @Test
    fun continue_stateful_sends_prompt_only() = runTest {
        applyResponsesRuntime("omit")
        val harness = Harness(this, RESPONSES_MODEL, forceWeb = true, continuations = true)
        val (conversation, assistantId) = harness.answerThenPartial()
        harness.continueOn(conversation, assistantId)

        val body = harness.bodies.last()
        assertEquals("r1", body["previous_response_id"]?.jsonPrimitive?.content)
        assertEquals(listOf("user" to ContextAssembler.CONTINUE_PROMPT), turnsOf(body))
    }

    // ── harness ──

    private inner class Harness(
        private val scope: TestScope,
        private val model: AIModel,
        private val forceWeb: Boolean = false,
        continuations: Boolean = false,
        mcpRunner: McpChatToolRunner? = null,
        service: ProviderService? = null,
        relayNonStreaming: Boolean = false,
    ) {
        val bodies = mutableListOf<JsonObject>()
        private val provider = if (relayNonStreaming) {
            Provider(
                id = "openai-1",
                kind = ProviderKind.Relay,
                apiKey = "relay-key",
                baseUrlText = "https://relay.test/v1",
                relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIResponses, stream = false),
                models = listOf(model),
            )
        } else {
            Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "byok-key", models = listOf(model))
        }
        private val requests = mutableListOf<StreamRequest>()
        private val updates = mutableListOf<ChatMessage>()
        private val dao = FakeContinuationDao()
        val store = if (continuations) MessageContinuationStore(dao, Json { ignoreUnknownKeys = true }) else null
        private val client = HttpClient(MockEngine { request ->
            bodies += json.parseToJsonElement(bodyText(request.body)).jsonObject
            if (relayNonStreaming) {
                respond(
                    buildJsonObject {
                        put("id", "r1")
                        put("status", "completed")
                        put("output_text", CONTINUATION_RAW)
                    }.toString(),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            } else if (request.url.encodedPath.endsWith("/responses")) {
                respond(
                    "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n" +
                        "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"output\":[]}}\n\n",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            } else {
                respond(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        }).also { openClients += it }
        private val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns (
                service ?: if (relayNonStreaming) RelayService(client, json, TransportRegistry(json)) else OpenAIService(client, json, TransportRegistry(json))
            )
            coEvery { it.getById(provider.id) } returns provider
        }
        private val conversationRepository = mockk<ConversationRepository>(relaxed = true).also {
            coEvery { it.updateMessage(any(), any()) } answers { updates += secondArg<ChatMessage>() }
        }
        private val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            continuationStore = store,
            continuationAccountId = { "account".takeIf { continuations } },
            mcpChatToolRunner = mcpRunner,
        )
        private val streamingManager = mockk<ChatStreamingManager>(relaxed = true).also {
            every { it.startStream(any()) } answers { requests += firstArg<StreamRequest>() }
        }
        private val sendCoordinator = ChatSendCoordinator(
            chatStreamingManager = streamingManager,
            applicationScope = scope,
            skillProvider = { null },
            providersProvider = { listOf(provider) },
            untitledNoteFallback = "Untitled",
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
        )
        private val launcher = ChatSendLauncher { conversation, provider, modelId, text, existingMessages, attachments,
            persistUserMessage, appendToAssistant, userMessageAlreadyInHistory, quoteContext, attemptKind ->
            sendCoordinator.launchSend(
                conversation = conversation,
                provider = provider,
                modelId = modelId,
                text = text,
                memoryItems = MEMORY_ITEMS,
                existingMessages = existingMessages,
                attachments = attachments,
                quoteContext = quoteContext,
                persistUserMessage = persistUserMessage,
                appendToAssistant = appendToAssistant,
                userMessageAlreadyInHistory = userMessageAlreadyInHistory,
                attemptKind = attemptKind,
            )
        }

        fun lastUpdate(id: String): ChatMessage? = updates.lastOrNull { it.id == id }

        /** Answers once normally (the server returns r1 and stores the continuation state), then hands that answer to the continue as an interrupted partial. */
        suspend fun answerThenPartial(): Pair<Conversation, String> {
            val conv = conversation(model)
            sendCoordinator.launchSend(
                conversation = conv,
                provider = provider,
                modelId = model.id,
                text = "q",
                memoryItems = MEMORY_ITEMS,
                existingMessages = emptyList(),
            )
            drain()
            val assistantId = requireNotNull(dao.rows.values.singleOrNull()?.messageId) { "no continuation saved: $bodies" }
            val user = message("u-q", ChatRole.User, "q", model)
            val partial = message(assistantId, ChatRole.Assistant, "ok", model, ChatMessageState.Interrupted)
            return conv.copy(messages = listOf(user, partial)) to assistantId
        }

        suspend fun continueOn(conversation: Conversation, assistantId: String) {
            coEvery { conversationRepository.getWithMessages(conversation.id) } returns conversation
            val coordinator = ChatRetryCoordinator(
                viewModelScope = scope,
                conversationRepository = conversationRepository,
                providerRepository = providerRepository,
                chatStreamingManager = streamingManager,
                currentConversation = { conversation },
                activeProviderId = { provider.id },
                activeModelId = { model.id },
                providers = { listOf(provider) },
                requestPin = {},
                launchSend = launcher,
            )
            coordinator.continueMessage(assistantId)
            drain()
        }

        private suspend fun drain() {
            scope.advanceUntilIdle()
            val pending = requests.toList()
            requests.clear()
            pending.forEach { request ->
                repository.sendMessage(
                    conversation = request.conversation,
                    text = request.text,
                    provider = request.provider,
                    modelID = request.modelID,
                    existingMessages = request.existingMessages,
                    attachments = request.attachments,
                    quoteContext = request.quoteContext,
                    reasoningMode = request.reasoningMode,
                    webSearchEnabled = request.webSearchEnabled || forceWeb,
                    requestOptions = request.requestOptions,
                    outputs = ConversationStreamingOutputs(
                        streamingText = MutableStateFlow(""),
                        streamingMessageId = MutableStateFlow(null),
                    ),
                    persistUserMessage = request.persistUserMessage,
                    userMessageAlreadyInHistory = request.userMessageAlreadyInHistory,
                    appendToAssistant = request.appendToAssistant,
                    attemptKind = request.attemptKind,
                )
            }
        }
    }

    /** Sets the continuationInstructionsMode of the Responses web recipe in the shared registry to the given value (null = remove the field). */
    private fun applyResponsesRuntime(mode: String?) {
        val root = File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val execution = Json.parseToJsonElement(
            File(root, "shared/model-contracts/provider_recipe_execution.v1.json").readText(),
        ).jsonObject
        val registry = Json.parseToJsonElement(
            File(root, execution["registryPath"]!!.jsonPrimitive.content).readText(),
        ).jsonObject
        val recipes = registry["recipes"]!!.jsonObject
        val recipe = recipes[RECIPE_REF]!!.jsonObject.toMutableMap().apply {
            remove("continuationInstructionsMode")
            mode?.let { put("continuationInstructionsMode", JsonPrimitive(it)) }
        }
        val runtime = JsonObject(registry + mapOf(
            "recipes" to JsonObject(recipes + (RECIPE_REF to JsonObject(recipe))),
            "revision" to JsonPrimitive("sha256:continue"),
            "generatedAt" to JsonPrimitive("2026-10-15T00:00:00Z"),
        ))
        val model = RESPONSES_MODEL.id
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1); put("capabilityRuntime", runtime)
            put("providers", buildJsonObject { put("openAI", buildJsonObject {
                put("resolveMap", buildJsonObject { put(model, model) })
                put("models", buildJsonObject { put(model, buildJsonObject {
                    put("transport", "openai_responses")
                    put("capabilityControls", buildJsonObject { put("web", buildJsonObject {
                        put("state", "auto_available"); put("recipeRef", RECIPE_REF)
                    }) })
                }) })
            }) })
        }.toString())
    }

    // ── body readers ──

    private fun systemOf(body: JsonObject): String? {
        (body["instructions"] as? JsonPrimitive)?.content?.let { return it }
        val items = (body["messages"] ?: body["input"])?.jsonArray.orEmpty()
        return items.map { it.jsonObject }
            .filter { it["role"]?.jsonPrimitive?.content in setOf("system", "developer") }
            .map { textOf(it) }
            .takeIf { it.isNotEmpty() }
            ?.joinToString("\n\n")
    }

    private fun turnsOf(body: JsonObject): List<Pair<String, String>> {
        val items = (body["messages"] ?: body["input"])?.jsonArray.orEmpty()
        return items.map { it.jsonObject }
            .filter { it["role"]?.jsonPrimitive?.content in setOf("user", "assistant") }
            .map { it.getValue("role").jsonPrimitive.content to textOf(it) }
    }

    private fun textOf(item: JsonObject): String = when (val content = item["content"]) {
        is JsonPrimitive -> content.content
        is JsonArray -> content.map { it.jsonObject }
            .filter { it["type"]?.jsonPrimitive?.content in setOf("text", "input_text", "output_text") }
            .joinToString("") { it["text"]?.jsonPrimitive?.content.orEmpty() }
        else -> ""
    }

    private fun memorySystem(): String =
        "<oriveo-memory>\n<note>${ContextAssembler.ENVELOPE_NOTES.getValue("oriveo-memory")}</note>\n<entry>$MEMORY</entry>\n</oriveo-memory>"

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun conversation(model: AIModel) = Conversation(
        id = "conversation-1",
        title = "Context",
        providerID = "openai-1",
        providerKind = ProviderKind.OpenAI,
        modelID = model.id,
        useMemory = true,
    )

    private fun message(
        id: String,
        role: ChatRole,
        text: String,
        model: AIModel,
        state: ChatMessageState = ChatMessageState.Delivered,
    ) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = "openai-1",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelID = model.id,
        modelName = model.name,
        state = state,
    )

    private class FakeContinuationDao : MessageContinuationDao {
        val rows = linkedMapOf<Pair<String, String>, MessageContinuationEntity>()
        override suspend fun upsert(entity: MessageContinuationEntity) { rows[entity.accountId to entity.messageId] = entity }
        override suspend fun get(accountId: String, messageId: String): MessageContinuationEntity? = rows[accountId to messageId]
        override suspend fun delete(accountId: String, messageId: String) { rows.remove(accountId to messageId) }
        override suspend fun deleteOtherProcessSessions(currentToken: String) {
            rows.entries.removeAll { it.value.processSessionToken != currentToken }
        }
        override suspend fun deleteMessages(accountId: String, messageIds: List<String>) { messageIds.forEach { rows.remove(accountId to it) } }
        override suspend fun deleteIfUnchanged(accountId: String, messageId: String, updatedAt: Long, processSessionToken: String, stateJson: String): Int {
            val key = accountId to messageId
            val row = rows[key]
            return if (row?.updatedAt == updatedAt && row.processSessionToken == processSessionToken &&
                row.stateJson == stateJson && !row.interrupted
            ) { rows.remove(key); 1 } else 0
        }
        override suspend fun markInterrupted(accountId: String, messageId: String, updatedAt: Long) {
            val key = accountId to messageId; rows[key]?.let { rows[key] = it.copy(interrupted = true, updatedAt = updatedAt) }
        }
        override suspend fun deleteForConversation(accountId: String, conversationId: String) {
            rows.entries.removeAll { it.value.accountId == accountId && it.value.conversationId == conversationId }
        }
        override suspend fun listForAccount(accountId: String) = rows.values.filter { it.accountId == accountId }
    }

    private companion object {
        const val MEMORY = "Likes green tea."
        val MEMORY_ITEMS = listOf(
            ai.oriveo.community.core.context.MemoryItem(
                id = "memory-1", kind = ai.oriveo.community.core.context.MemoryKind.FACT, content = MEMORY,
                mutationId = "mutation-1", deviceId = "device-1",
            ),
        )
        const val RECIPE_REF = "openai.responses.web.v1"
        val CHAT_MODEL = AIModel(id = "gpt-4o", name = "GPT-4o", contextLength = 128_000, maxOutputTokens = 16_384)
        const val CONTINUATION_RAW = "\n\nChapter 2…"
        val IMAGE_MODEL = AIModel(
            id = "gpt-image-chat",
            name = "GPT Image Chat",
            contextLength = 128_000,
            maxOutputTokens = 16_384,
            capabilities = listOf(ModelCapability.ImageGen),
            imageGenProfile = "chat_api",
        )
        val RESPONSES_MODEL = AIModel(id = "gpt-5.6-terra", name = "GPT Terra", contextLength = 400_000, maxOutputTokens = 32_000)
    }
}
