package ai.oriveo.community.core.data.repository

import androidx.room.Room
import ai.oriveo.community.core.context.MemoryPropose
import ai.oriveo.community.core.context.MemoryProposeMode
import ai.oriveo.community.core.context.MemoryProposePurpose
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.ContextRecallEntry
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryRecall
import ai.oriveo.community.core.context.MemorySearch
import ai.oriveo.community.core.memory.MemorySearchTurn
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.mcp.InMemoryPrefs
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.memory.MemoryProposeSendHook
import ai.oriveo.community.core.memory.ProposeMemoryRuntime
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.tools.ToolLoopToolChoice
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import java.util.Collections
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * propose_memory on the Android send path: the real `ChatRepository.sendMessage` → real Relay service and the
 * real tool-leg executor (via `McpChatToolRunner`) → Ktor MockEngine. Assertions read the bytes the engine received
 * and the assistant message the repository delivered.
 */
@RunWith(RobolectricTestRunner::class)
class ChatRepositoryProposeMemoryTest {

    private lateinit var db: OriveoDatabase
    private lateinit var runner: McpChatToolRunner
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val requests: MutableList<Pair<String, String>> = Collections.synchronizedList(mutableListOf())
    /** Scripted replies to `/chat/completions`, in order. */
    private val replies = ArrayDeque<Pair<HttpStatusCode, String>>()
    private val providerRepository = mockk<ProviderRepository>(relaxed = true)
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
    private val delivered = slot<ChatMessage>()

    private val client = HttpClient(
        MockEngine { request ->
            val path = request.url.encodedPath
            requests += path to bodyText(request)
            val (status, body) = synchronized(replies) { replies.removeFirst() }
            val type = if (status == HttpStatusCode.OK) "text/event-stream" else ContentType.Application.Json.toString()
            respond(body, status, headersOf(HttpHeaders.ContentType, type))
        },
    )

    private class RecordingHook : MemoryProposeSendHook {
        val calls = mutableListOf<String>()
        var rejected = 0

        override suspend fun onProposeCall(argumentsJson: String) {
            calls += argumentsJson
        }

        override suspend fun onToolsRejected() {
            rejected++
        }
    }

    private fun bodyText(request: HttpRequestData): String = when (val body = request.body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().toString(Charsets.UTF_8)
        else -> ""
    }

    @Before
    fun setUp() {
        ProposeMemoryRuntime.clearForTest()
        // Rejection cases are recorded in the process-wide negative cache; if it is not cleared, the tool verdict of later cases turns false (the search mode decision reads it).
        ai.oriveo.community.core.provider.relay.RelayNegativeCache.shared.clearConnection("relay-1")
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        val credentials = McpCredentialStore(InMemoryPrefs())
        runner = McpChatToolRunner(
            httpClient = client,
            json = json,
            store = McpServerStore(db.mcpServerDao(), credentials),
            credentialStore = credentials,
            mcpTransport = { McpScriptedTransport() },
        )
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { providerRepository.currentCapabilityPartitionId() } returns "u1"
        coEvery { conversationRepository.updateMessage(any(), capture(delivered)) } returns Unit
    }

    @After
    fun tearDown() {
        db.close()
        ProposeMemoryRuntime.clearForTest()
        ai.oriveo.community.core.provider.relay.RelayNegativeCache.shared.clearConnection("relay-1")
    }

    private fun repository() = ChatRepository(
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        attachmentStore = mockk<AttachmentStore>(relaxed = true),
        mcpChatToolRunner = runner,
    )

    private val identity = CapabilityEvidenceIdentity(
        partitionId = "u1", connectionInstanceId = "relay-1", connectionGeneration = "g1", credentialEpoch = "c1",
        providerKind = ProviderKind.Relay.rawValue, metadataRevision = "m1", generationRevision = "g1",
        authMode = ProviderAuthMode.ApiKey.rawValue,
    )

    private val model = AIModel(id = "relay-model", name = "Relay Model", toolCall = true)

    private val relay = Provider(
        id = "relay-1", kind = ProviderKind.Relay, status = ProviderConnectionState.Connected, apiKey = "local-key",
        baseUrlText = "https://relay.test/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions), models = listOf(model),
    ).also { every { providerRepository.serviceFor(it, any()) } returns RelayService(client, json, TransportRegistry(json)) }

    private fun modeFor(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceIdentity?,
        webSearch: Boolean = false,
        structuredOutput: Boolean = false,
    ): MemoryProposeMode =
        ProposeMemoryRuntime.mode(
            purpose = MemoryProposePurpose.CHAT,
            freshSend = true,
            memoryEnabled = true,
            autoSuggest = true,
            connectionSupportsTools = ProposeMemoryRuntime.connectionSupportsTools(
                provider = provider,
                model = model,
                memoryVerdict = null,
                localIdentity = identity,
                moonshotBuiltinSearch = false,
            ),
            connectionId = provider.id,
            modelId = model.id,
            geminiWebSearch = ProposeMemoryRuntime.geminiWebSearch(provider, model, webSearch),
            structuredOutput = structuredOutput,
        )

    private val anthropicRelay = Provider(
        id = "relay-1", kind = ProviderKind.Relay, status = ProviderConnectionState.Connected, apiKey = "local-key",
        baseUrlText = "https://relay.test/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.AnthropicMessages), models = listOf(model),
    ).also { every { providerRepository.serviceFor(it, any()) } returns RelayService(client, json, TransportRegistry(json)) }

    private suspend fun send(
        hook: MemoryProposeSendHook?,
        provider: Provider = relay,
        search: MemorySearchTurn? = null,
        recall: List<ContextRecallEntry> = emptyList(),
        generationParameters: ai.oriveo.community.core.model.GenerationParameterOverrides? = null,
        activeModel: AIModel? = null,
    ) {
        repository().sendMessage(
            conversation = Conversation(
                id = CONVERSATION, title = "Memory", providerID = provider.id, providerKind = provider.kind, modelID = model.id,
            ),
            text = USER_TEXT,
            provider = provider,
            modelID = model.id,
            existingMessages = emptyList(),
            requestOptions = ChatRequestOptions(
                capabilityEvidenceIdentity = identity,
                generationParameters = generationParameters,
                activeModel = activeModel,
                // The order used by ChatSendCoordinator: propose_memory first and search_memory after it (memory-search.v1 legRules 1).
                clientTools = listOfNotNull(MemoryPropose.tool.takeIf { hook != null }, MemorySearch.tool.takeIf { search != null }),
                clientToolChoice = ToolLoopToolChoice.Auto,
                chatContext = if (search == null && recall.isEmpty()) {
                    null
                } else {
                    ChatContextRequest(ContextConversation(id = CONVERSATION, useMemory = true), recall = recall)
                },
            ),
            outputs = ConversationStreamingOutputs(streamingText = MutableStateFlow(""), streamingMessageId = MutableStateFlow(null)),
            memoryPropose = hook,
            memorySearch = search,
        )
    }

    private fun chatBodies(suffix: String = "/chat/completions"): List<JsonObject> = requests.toList()
        .filter { it.first.endsWith(suffix) }
        .map { json.parseToJsonElement(it.second).jsonObject }

    private fun toolNames(body: JsonObject): List<String> = (body["tools"] as? JsonArray).orEmpty().map {
        it.jsonObject["function"]!!.jsonObject["name"]!!.jsonPrimitive.content
    }

    private fun textStream(text: String, promptTokens: Int, completionTokens: Int): String =
        "data: {\"choices\":[{\"delta\":{\"content\":\"$text\"}}]}\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]," +
            "\"usage\":{\"prompt_tokens\":$promptTokens,\"completion_tokens\":$completionTokens}}\n" +
            "data: [DONE]\n"

    private fun anthropicEvent(type: String, data: String) = "event: $type\ndata: $data\n\n"

    private fun anthropicProposeStream(
        callId: String,
        arguments: String,
        thinking: String? = null,
        name: String = MemoryPropose.TOOL_NAME,
    ): String {
        val toolIndex = if (thinking == null) 0 else 1
        val start = buildJsonObject {
            put("type", "content_block_start")
            put("index", toolIndex)
            putJsonObject("content_block") {
                put("type", "tool_use")
                put("id", callId)
                put("name", name)
                putJsonObject("input") {}
            }
        }
        val delta = buildJsonObject {
            put("type", "content_block_delta")
            put("index", toolIndex)
            putJsonObject("delta") {
                put("type", "input_json_delta")
                put("partial_json", arguments)
            }
        }
        val thinkingBlock = thinking?.let {
            anthropicEvent(
                "content_block_start",
                "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
            ) + anthropicEvent(
                "content_block_delta",
                "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"$it\"}}",
            ) + anthropicEvent(
                "content_block_delta",
                "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}",
            ) + anthropicEvent("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
        }.orEmpty()
        return anthropicEvent("message_start", ANTHROPIC_MESSAGE_START) + thinkingBlock +
            anthropicEvent("content_block_start", start.toString()) +
            anthropicEvent("content_block_delta", delta.toString()) +
            anthropicEvent("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":$toolIndex}") +
            anthropicEvent(
                "message_delta",
                "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":4}}",
            ) +
            anthropicEvent("message_stop", "{\"type\":\"message_stop\"}")
    }

    private fun anthropicTextStream(text: String): String =
        anthropicEvent("message_start", ANTHROPIC_MESSAGE_START) +
            anthropicEvent(
                "content_block_start",
                "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            ) +
            anthropicEvent(
                "content_block_delta",
                "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$text\"}}",
            ) +
            anthropicEvent("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}") +
            anthropicEvent(
                "message_delta",
                "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":6}}",
            ) +
            anthropicEvent("message_stop", "{\"type\":\"message_stop\"}")

    private fun proposeStream(
        callId: String,
        arguments: String,
        promptTokens: Int,
        completionTokens: Int,
        text: String? = null,
    ): String {
        val preface = text?.let { "data: {\"choices\":[{\"delta\":{\"content\":\"$it\"}}]}\n" }.orEmpty()
        val chunk = buildJsonObject {
            putJsonArray("choices") {
                add(buildJsonObject {
                    putJsonObject("delta") {
                        putJsonArray("tool_calls") {
                            add(buildJsonObject {
                                put("index", 0)
                                put("id", callId)
                                put("type", "function")
                                putJsonObject("function") {
                                    put("name", MemoryPropose.TOOL_NAME)
                                    put("arguments", arguments)
                                }
                            })
                        }
                    }
                })
            }
        }
        return preface + "data: $chunk\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]," +
            "\"usage\":{\"prompt_tokens\":$promptTokens,\"completion_tokens\":$completionTokens}}\n" +
            "data: [DONE]\n"
    }

    @Test
    fun `a new send that can carry tools attaches them`() = runBlocking {
        assertEquals(MemoryProposeMode.TOOL, modeFor(relay, model, identity))
        replies += HttpStatusCode.OK to textStream("Sure.", 5, 2)

        send(RecordingHook())

        val body = chatBodies().single()
        assertEquals("propose_memory is the last tool", MemoryPropose.TOOL_NAME, toolNames(body).last())
        assertEquals("auto", body["tool_choice"]!!.jsonPrimitive.content)
        assertEquals("Sure.", delivered.captured.text)
    }

    /** Gemini generateContent does not accept a search tool and a function tool in the same request: with web search on, propose uses the fallback. */
    @Test
    fun `Gemini with web search on uses the fallback`() {
        val geminiRelay = relay.copy(relayRequested = RelayRequestedConfig(transport = RelayTransport.GeminiGenerateContent))
        assertEquals("web off keeps tool mode", MemoryProposeMode.TOOL, modeFor(geminiRelay, model, identity))
        assertEquals(MemoryProposeMode.FALLBACK, modeFor(geminiRelay, model, identity, webSearch = true))
        assertEquals("other transports keep tools with web on", MemoryProposeMode.TOOL, modeFor(relay, model, identity, webSearch = true))

        val official = Provider(
            id = "gemini-1", kind = ProviderKind.Gemini, status = ProviderConnectionState.Connected, apiKey = "local-key",
            models = listOf(model),
        )
        assertTrue(ProposeMemoryRuntime.geminiWebSearch(official, model, webSearchEnabled = true))
        assertFalse(ProposeMemoryRuntime.geminiWebSearch(official, model, webSearchEnabled = false))
        assertEquals(MemoryProposeMode.FALLBACK, modeFor(official, model, null, webSearch = true))
    }

    @Test
    fun `a propose-only call adds a tail leg`() = runBlocking {
        val arguments = proposeArguments()
        replies += HttpStatusCode.OK to proposeStream("call_1", arguments, 10, 4, text = "Okay.")
        replies += HttpStatusCode.OK to textStream("Got it, TypeScript it is.", 20, 6)
        val hook = RecordingHook()

        send(hook)

        assertEquals(listOf(arguments), hook.calls)
        val bodies = chatBodies()
        assertEquals("first leg + one tail leg", 2, bodies.size)
        val tail = bodies[1]
        assertEquals("none", tail["tool_choice"]!!.jsonPrimitive.content)
        assertEquals("tools kept on the tail leg", listOf(MemoryPropose.TOOL_NAME), toolNames(tail))
        val messages = tail["messages"]!!.jsonArray.map { it.jsonObject }
        val assistant = messages.single { it["role"]!!.jsonPrimitive.content == "assistant" }
        val call = assistant["tool_calls"]!!.jsonArray.single().jsonObject
        assertEquals("call_1", call["id"]!!.jsonPrimitive.content)
        assertEquals(arguments, call["function"]!!.jsonObject["arguments"]!!.jsonPrimitive.content)
        assertEquals("first-leg text rides the proposal", "Okay.", assistant["content"]!!.jsonPrimitive.content)
        val tool = messages.single { it["role"]!!.jsonPrimitive.content == "tool" }
        assertEquals("call_1", tool["tool_call_id"]!!.jsonPrimitive.content)
        assertEquals(MemoryPropose.TOOL_RESULT, tool["content"]!!.jsonPrimitive.content)
        assertTrue("the user turn precedes the proposal", messages.any { it["role"]!!.jsonPrimitive.content == "user" })

        val message = delivered.captured
        assertEquals(ChatMessageState.Delivered, message.state)
        assertEquals("the two legs join with one blank line", "Okay.\n\nGot it, TypeScript it is.", message.text)
        assertEquals("usage of both legs adds up", 30, message.inputTokens)
        assertEquals(10, message.outputTokens)
        assertEquals("stopReason comes from the tail leg", ai.oriveo.community.core.context.StopReason.STOP, message.stopReason)
        assertTrue("propose calls never surface as unhandled", message.unhandledToolCalls.isEmpty())
    }

    @Test
    fun `a propose call in the tail leg adds no further leg`() = runBlocking {
        val first = proposeArguments()
        val second = proposeArguments(proposition = "Prefers concise answers", quote = "keep it short")
        replies += HttpStatusCode.OK to proposeStream("call_1", first, 10, 4)
        replies += HttpStatusCode.OK to proposeStream("call_2", second, 20, 6)
        val hook = RecordingHook()

        send(hook)

        assertEquals("both calls reach the hook", listOf(first, second), hook.calls)
        assertEquals("no third leg", 2, chatBodies().size)
        assertTrue(delivered.captured.unhandledToolCalls.isEmpty())
    }

    @Test
    fun `first leg tools rejected resends without tools and degrades`() = runBlocking {
        replies += HttpStatusCode.BadRequest to """{"error":{"message":"tools is not supported for this model","type":"invalid_request_error"}}"""
        replies += HttpStatusCode.OK to textStream("Sure.", 5, 2)
        val hook = RecordingHook()

        send(hook)

        val bodies = chatBodies()
        assertEquals(2, bodies.size)
        assertEquals(MemoryPropose.TOOL_NAME, toolNames(bodies[0]).last())
        assertFalse("resent without tools: ${bodies[1]}", bodies[1].containsKey("tools"))
        assertEquals("degrade reported once (fallback + degraded set)", 1, hook.rejected)
        assertTrue(hook.calls.isEmpty())
        assertEquals("Sure.", delivered.captured.text)
        assertNull(delivered.captured.errorTitle)
    }

    @Test
    fun `Anthropic without thinking also adds one tail leg`() = runBlocking {
        val arguments = proposeArguments()
        replies += HttpStatusCode.OK to anthropicProposeStream("toolu_1", arguments)
        replies += HttpStatusCode.OK to anthropicTextStream("Noted.")
        val hook = RecordingHook()

        send(hook, provider = anthropicRelay)

        assertEquals(listOf(arguments), hook.calls)
        val bodies = requests.toList().filter { it.first.endsWith("/messages") }.map { it.second }
        assertEquals("first leg + one tail leg: $requests", 2, bodies.size)
        assertTrue("first leg carries the tool: ${bodies[0]}", bodies[0].contains(MemoryPropose.TOOL_NAME))
        val tail = json.parseToJsonElement(bodies[1]).jsonObject
        assertTrue("tools kept on the tail leg", tail["tools"].toString().contains(MemoryPropose.TOOL_NAME))
        assertEquals("none", tail["tool_choice"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        val messages = tail["messages"].toString()
        assertTrue("assistant tool_use replayed: $messages", messages.contains("\"tool_use\"") && messages.contains("toolu_1"))
        assertTrue("tool_result answers it: $messages", messages.contains("\"tool_result\"") && messages.contains(MemoryPropose.TOOL_RESULT))
        assertEquals("Noted.", delivered.captured.text)
        assertTrue(delivered.captured.unhandledToolCalls.isEmpty())
    }

    @Test
    fun `thinking first leg with empty text resends once without tools`() = runBlocking {
        val arguments = proposeArguments()
        replies += HttpStatusCode.OK to anthropicProposeStream("toolu_1", arguments, thinking = "Thinking")
        replies += HttpStatusCode.OK to anthropicTextStream("Sure, noted.")
        val hook = RecordingHook()

        send(hook, provider = anthropicRelay)

        assertEquals("the candidate call is kept", listOf(arguments), hook.calls)
        assertEquals("not a degrade", 0, hook.rejected)
        val bodies = chatBodies("/messages")
        assertEquals("$requests", 2, bodies.size)
        assertTrue("first leg carries the tool", bodies[0]["tools"].toString().contains(MemoryPropose.TOOL_NAME))
        assertFalse("resent without tools: ${bodies[1]}", bodies[1].containsKey("tools"))
        assertFalse("the resend is the original request, no replayed tool call", bodies[1].toString().contains("tool_result"))
        val message = delivered.captured
        assertEquals("Sure, noted.", message.text)
        assertEquals("both requests are paid for", 20, message.inputTokens)
        assertEquals(10, message.outputTokens)
        assertTrue(message.unhandledToolCalls.isEmpty())
    }

    // ---- search_memory (memory-search.v1 legRules 1-5) ----

    /**
     * A json_schema resolved for this send (session override, declared under the profile) conflicts with tools,
     * so propose_memory and search_memory both fall back; the body keeps response_format and carries no memory tool.
     */
    @Test
    fun `json_schema_active_uses_fallback_memory_mode`() = runBlocking {
        val schemaModel = model.copy(
            generationProfile = ai.oriveo.community.core.model.GenerationProfileRef(
                template = "openai_chat_completions",
                parameters = listOf(
                    ai.oriveo.community.core.model.GenerationParameterRef(
                        id = "json_schema", support = "supported", valueSchema = "json-schema", conflictsWith = listOf("tools"),
                    ),
                ),
                wire = mapOf("json_schema" to "response_format"),
            ),
        )
        val schemaRelay = relay.copy(models = listOf(schemaModel))
            .also { every { providerRepository.serviceFor(it, any()) } returns RelayService(client, json, TransportRegistry(json)) }
        val store = ai.oriveo.community.core.model.GenerationParameterSettingsStore.from(RuntimeEnvironment.getApplication())
        assertFalse(
            "no stored value, no structured output",
            ProposeMemoryRuntime.structuredOutputActive(store, schemaRelay, schemaModel, schemaModel.id, CONVERSATION),
        )
        val schema = buildJsonObject { put("type", "object") }
        store.setSessionOverrides(
            ai.oriveo.community.core.model.GenerationParameterOverrides(
                mapOf(
                    "json_schema" to ai.oriveo.community.core.model.GenerationParameterOverride(
                        ai.oriveo.community.core.model.GenerationOverrideState.Value, schema,
                    ),
                ),
            ),
            schemaRelay.id, schemaModel.id, CONVERSATION,
            ai.oriveo.community.core.model.GenerationParameterProfileFingerprint.make(schemaRelay, schemaModel),
        )
        val structured = ProposeMemoryRuntime.structuredOutputActive(store, schemaRelay, schemaModel, schemaModel.id, CONVERSATION)
        assertTrue("json_schema goes out on this send", structured)

        assertEquals("tools could ride without json_schema", MemoryProposeMode.TOOL, modeFor(schemaRelay, schemaModel, identity))
        assertEquals(MemoryProposeMode.FALLBACK, modeFor(schemaRelay, schemaModel, identity, structuredOutput = structured))
        assertTrue("search rides without json_schema", turnFor(provider = schemaRelay, sendModel = schemaModel) != null)
        assertNull("search falls back", turnFor(provider = schemaRelay, sendModel = schemaModel, structuredOutput = structured))

        // Fallback hands neither hook nor turn to the send.
        replies += HttpStatusCode.OK to textStream("{}", 5, 2)
        send(
            hook = null,
            provider = schemaRelay,
            generationParameters = store.resolve(
                transient = null, providerID = schemaRelay.id, modelID = schemaModel.id, conversationID = CONVERSATION,
                profileFingerprint = ai.oriveo.community.core.model.GenerationParameterProfileFingerprint.make(schemaRelay, schemaModel),
            ),
            activeModel = schemaModel,
        )
        val body = chatBodies().single()
        assertEquals("response_format kept: $body", "json_schema", body["response_format"]?.jsonObject?.get("type")?.jsonPrimitive?.content)
        assertFalse("no memory tool beside response_format: $body", body.containsKey("tools"))
    }

    private fun l3(id: String, content: String, occurredAt: String = "2026-09-01T10:00:00Z") = MemoryItem(
        id = id, layer = MemoryLayer.EPISODIC, kind = MemoryKind.DECISION, content = content,
        mutationId = "00000000-0000-4000-8000-000000000000", deviceId = "d", occurredAt = occurredAt,
    )

    private val l3Items = listOf(l3(RECALLED_ID, "Moved the launch to Friday"), l3(TESLA_ID, "Bought a Tesla Model 3 after the test drive"))

    /** Items the automatic recall of this round's [D] has already placed (search no longer returns them). */
    private val recalled = listOf(ContextRecallEntry(RECALLED_ID, "Moved the launch to Friday", "2026-09-01"))

    private fun turnFor(
        provider: Provider = relay,
        items: List<MemoryItem> = l3Items,
        useMemory: Boolean = true,
        purpose: MemoryProposePurpose = MemoryProposePurpose.CHAT,
        localIdentity: CapabilityEvidenceIdentity? = identity,
        sendModel: AIModel = model,
        structuredOutput: Boolean = false,
    ): MemorySearchTurn? = MemorySearchTurn.forSend(
        purpose = purpose,
        useMemory = useMemory,
        provider = provider,
        model = sendModel,
        modelId = sendModel.id,
        memoryVerdict = null,
        localIdentity = localIdentity,
        webSearchEnabled = false,
        index = MemoryRecall.buildIndex(items),
        conversationId = CONVERSATION,
        folderId = null,
        now = java.time.Instant.parse("2026-10-17T00:00:00Z"),
        structuredOutput = structuredOutput,
    )

    private fun toolCallsStream(
        calls: List<Triple<String, String, String>>,
        promptTokens: Int,
        completionTokens: Int,
        text: String? = null,
    ): String {
        val preface = text?.let { "data: {\"choices\":[{\"delta\":{\"content\":\"$it\"}}]}\n" }.orEmpty()
        val chunk = buildJsonObject {
            putJsonArray("choices") {
                add(buildJsonObject {
                    putJsonObject("delta") {
                        putJsonArray("tool_calls") {
                            calls.forEachIndexed { i, (id, name, arguments) ->
                                add(buildJsonObject {
                                    put("index", i)
                                    put("id", id)
                                    put("type", "function")
                                    putJsonObject("function") {
                                        put("name", name)
                                        put("arguments", arguments)
                                    }
                                })
                            }
                        }
                    }
                })
            }
        }
        return preface + "data: $chunk\n" +
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]," +
            "\"usage\":{\"prompt_tokens\":$promptTokens,\"completion_tokens\":$completionTokens}}\n" +
            "data: [DONE]\n"
    }

    private fun searchArguments(query: String = "Tesla launch"): String = buildJsonObject { put("query", query) }.toString()

    @Test
    fun `search follows propose, and is not attached without L3, with memory off, when degraded, or on continue`() = runBlocking {
        val turn = turnFor()
        assertTrue("tool mode with a recallable L3 item", turn != null)
        replies += HttpStatusCode.OK to textStream("Sure.", 5, 2)
        send(RecordingHook(), search = turn)
        val body = chatBodies().single()
        assertEquals("search_memory goes after propose_memory", listOf(MemoryPropose.TOOL_NAME, MemorySearch.TOOL_NAME), toolNames(body))
        assertEquals("auto", body["tool_choice"]!!.jsonPrimitive.content)
        assertEquals(
            "the tool rides the body as the fixture projection",
            ai.oriveo.community.core.context.ContextContractFixture.load("memory-search.v1.json")["projections"]!!.jsonObject["openai_chat"]!!.jsonArray.single(),
            body["tools"]!!.jsonArray.last(),
        )

        assertNull("no L3 item", turnFor(items = emptyList()))
        assertNull("only semantic items", turnFor(items = l3Items.map { it.copy(layer = MemoryLayer.SEMANTIC) }))
        assertNull("memory off", turnFor(useMemory = false))
        assertNull("continue", turnFor(purpose = MemoryProposePurpose.CONTINUE))
        ProposeMemoryRuntime.markDegraded(relay.id, model.id)
        assertNull("degraded", turnFor())
    }

    @Test
    fun `a tail leg with both propose and search results puts the returned ids into memoryIds`() = runBlocking {
        val propose = proposeArguments()
        val search = searchArguments()
        replies += HttpStatusCode.OK to toolCallsStream(
            listOf(Triple("call_1", MemoryPropose.TOOL_NAME, propose), Triple("call_2", MemorySearch.TOOL_NAME, search)), 10, 4,
        )
        replies += HttpStatusCode.OK to textStream("You bought a Tesla Model 3.", 20, 6)
        val hook = RecordingHook()
        val turn = turnFor()!!

        send(hook, search = turn, recall = recalled)

        assertEquals(listOf(propose), hook.calls)
        val bodies = chatBodies()
        assertEquals("first leg + one shared tail leg", 2, bodies.size)
        val tail = bodies[1]
        assertEquals("none", tail["tool_choice"]!!.jsonPrimitive.content)
        val messages = tail["messages"]!!.jsonArray.map { it.jsonObject }
        val assistant = messages.single { it["role"]!!.jsonPrimitive.content == "assistant" }
        assertEquals(listOf("call_1", "call_2"), assistant["tool_calls"]!!.jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.content })
        val tools = messages.filter { it["role"]!!.jsonPrimitive.content == "tool" }
        assertEquals(listOf("call_1", "call_2"), tools.map { it["tool_call_id"]!!.jsonPrimitive.content })
        assertEquals(MemoryPropose.TOOL_RESULT, tools[0]["content"]!!.jsonPrimitive.content)
        assertEquals(
            "the [D] id is skipped; the search answers with the other hit",
            "<oriveo-recall>\n<note>${MemorySearch.NOTE}</note>\n" +
                "<entry date=\"2026-09-01\">Bought a Tesla Model 3 after the test drive</entry>\n</oriveo-recall>",
            tools[1]["content"]!!.jsonPrimitive.content,
        )
        val message = delivered.captured
        assertEquals("You bought a Tesla Model 3.", message.text)
        assertEquals("[D] recall then the search hit", listOf(RECALLED_ID, TESLA_ID), message.memoryItemIds)
        assertEquals("usage of both legs adds up", 30, message.inputTokens)
        assertTrue(message.unhandledToolCalls.isEmpty())
    }

    @Test
    fun `search in the tail leg is neither executed nor adds a leg`() = runBlocking {
        replies += HttpStatusCode.OK to toolCallsStream(listOf(Triple("call_1", MemorySearch.TOOL_NAME, searchArguments("Riverside"))), 10, 4)
        replies += HttpStatusCode.OK to toolCallsStream(listOf(Triple("call_2", MemorySearch.TOOL_NAME, searchArguments())), 20, 6, text = "No record.")
        val turn = turnFor()!!

        send(hook = null, search = turn, recall = recalled)

        assertEquals("no third leg", 2, chatBodies().size)
        assertEquals("the tail-leg search ran nothing (the first one found nothing either)", emptyList<String>(), turn.returnedIds)
        val message = delivered.captured
        assertTrue("a search call never surfaces as unhandled", message.unhandledToolCalls.isEmpty())
        assertEquals(listOf(RECALLED_ID), message.memoryItemIds)
    }

    @Test
    fun `thinking model empty-body resend drops the tools, and the search entry follows the recall of the D block`() = runBlocking {
        replies += HttpStatusCode.OK to anthropicProposeStream("toolu_1", searchArguments(), thinking = "Thinking", name = MemorySearch.TOOL_NAME)
        replies += HttpStatusCode.OK to anthropicTextStream("A Tesla Model 3.")
        val turn = turnFor()!!

        send(hook = null, provider = anthropicRelay, search = turn, recall = recalled)

        val bodies = chatBodies("/messages")
        assertEquals("$requests", 2, bodies.size)
        assertTrue("first leg carries the tool", bodies[0]["tools"].toString().contains(MemorySearch.TOOL_NAME))
        assertFalse("resent without tools: ${bodies[1]}", bodies[1].containsKey("tools"))
        assertFalse("no replayed tool call", bodies[1].toString().contains("tool_result"))
        val resent = bodies[1].toString()
        val recallAt = resent.indexOf("Moved the launch to Friday")
        val searchAt = resent.indexOf("Bought a Tesla Model 3 after the test drive")
        assertTrue("[D] recall kept: $resent", recallAt >= 0)
        assertTrue("search hit appended after the automatic entry: $resent", searchAt > recallAt)
        assertEquals("one <oriveo-recall> block", 1, Regex("<oriveo-recall>").findAll(resent).count())
        assertFalse("not a degrade", ProposeMemoryRuntime.isDegraded(anthropicRelay.id, model.id))
        val message = delivered.captured
        assertEquals("A Tesla Model 3.", message.text)
        assertEquals(listOf(RECALLED_ID, TESLA_ID), message.memoryItemIds)
        assertTrue(message.unhandledToolCalls.isEmpty())
    }

    @Test
    fun `a search-only first leg that is rejected resends without tools and degrades`() = runBlocking {
        replies += HttpStatusCode.BadRequest to """{"error":{"message":"tools is not supported for this model","type":"invalid_request_error"}}"""
        replies += HttpStatusCode.OK to textStream("Sure.", 5, 2)

        send(hook = null, search = turnFor()!!, recall = recalled)

        val bodies = chatBodies()
        assertEquals(2, bodies.size)
        assertEquals(listOf(MemorySearch.TOOL_NAME), toolNames(bodies[0]))
        assertFalse("resent without tools: ${bodies[1]}", bodies[1].containsKey("tools"))
        assertTrue("the shared degraded set", ProposeMemoryRuntime.isDegraded(relay.id, model.id))
        assertNull("next send carries neither tool", turnFor())
        assertEquals("Sure.", delivered.captured.text)
    }

    private fun proposeArguments(
        proposition: String = "Uses TypeScript at work",
        quote: String = "I use TypeScript at work",
    ): String = buildJsonObject {
        put("proposition", proposition)
        put("kind", "fact")
        put("scope", "global")
        put("sourceQuote", quote)
    }.toString()

    private companion object {
        const val CONVERSATION = "conversation-propose"
        const val RECALLED_ID = "40000000-0000-4000-8000-0000000000d1"
        const val TESLA_ID = "40000000-0000-4000-8000-000000000005"
        const val ANTHROPIC_MESSAGE_START =
            "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"," +
                "\"content\":[],\"model\":\"relay-model\",\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}"
        const val USER_TEXT = "Remember that I use TypeScript at work, and keep it short."
    }
}
