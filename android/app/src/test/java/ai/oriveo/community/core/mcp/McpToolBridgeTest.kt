package ai.oriveo.community.core.mcp

import androidx.room.Room
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolLoopLegEvent
import ai.oriveo.community.core.tools.ToolLoopLegRequest
import ai.oriveo.community.core.tools.ToolLoopLegRunning
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCallDelta
import ai.oriveo.community.core.tools.ToolLoopToolChoice
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import java.io.File
import java.util.ArrayDeque
import java.util.Collections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * MCP tools plugged into the generic loop.
 *
 * The model side runs the production leg executors (four wire protocols) with a Ktor MockEngine replaying the shared
 * corpus `provider-toolcall/` (only the corpus's `get_weather` is swapped for the name sent in this request; the corpus
 * files stay untouched). The MCP server side runs the production `McpClient` with [McpScriptedTransport] replaying the
 * `mcp/protocol/` fixtures. Assembly reads from a real Room store, and the confirmation gate is a fake implemented in
 * the test. Assertions are on the request bodies the production path actually sent and the steps it actually handed
 * over.
 */
@RunWith(RobolectricTestRunner::class)
class McpToolBridgeTest {

    private lateinit var db: OriveoDatabase
    private lateinit var credentials: McpCredentialStore
    private lateinit var store: McpServerStore
    private lateinit var mcp: McpScriptedTransport
    private lateinit var grants: McpConversationGrants
    private val steps: MutableList<McpToolStepUpdate> = Collections.synchronizedList(mutableListOf())
    private val unhandled: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        credentials = McpCredentialStore(InMemoryPrefs())
        store = McpServerStore(db.mcpServerDao(), credentials)
        mcp = McpScriptedTransport()
        grants = McpConversationGrants()
        steps.clear()
        unhandled.clear()
    }

    @After
    fun tearDown() {
        db.close()
    }

    // ── Setup ────────────────────────────────────────

    private fun schema(properties: List<String>, required: List<String> = emptyList()): JsonElement = buildJsonObject {
        put("type", "object")
        put("properties", JsonObject(properties.associateWith { buildJsonObject { put("type", "string") } }))
        put("required", JsonArray(required.map(::JsonPrimitive)))
    }

    private fun snapshot(
        toolName: String,
        serverId: String = WEATHER_ID,
        readOnly: Boolean = true,
        pendingReview: Boolean = false,
        oversized: Boolean = false,
        inputSchema: JsonElement = schema(listOf("city", "unit")),
    ) = McpToolSnapshot(
        serverId = serverId,
        toolName = toolName,
        title = toolName,
        description = "Tool $toolName",
        inputSchema = inputSchema,
        annotations = buildJsonObject { put("readOnlyHint", readOnly) },
        contentHash = mcpSha256Hex("$serverId:$toolName"),
        readOnly = readOnly,
        pendingReview = pendingReview,
        oversized = oversized,
        updatedAt = 1L,
    )

    /** Stores a server in the real store and enables it in the conversation: the snapshot is confirmed (not quarantined). */
    private suspend fun seedServer(
        snapshots: List<McpToolSnapshot>,
        permissions: Map<String, McpToolPermission> = emptyMap(),
        enabledIn: List<String> = listOf(CONV_A),
        status: McpConnectionStatus = McpConnectionStatus.Connected,
        id: String = WEATHER_ID,
        name: String = "Weather",
        url: String = MCP_ENDPOINT,
        localOnly: Boolean = false,
    ) {
        store.addServer(
            McpServerAddition(
                id = id, name = name, url = url, authKind = McpAuthKind.Auto, localOnly = localOnly, iconURL = null,
                createdAt = 1_700_000_000_000L, snapshots = snapshots.map { it.copy(serverId = id) }, permissions = permissions,
                connectionState = McpConnectionState(id, status, generation = McpProtocolGeneration.Stateless),
            ),
            maxServers = 20,
        )
        enabledIn.forEach { store.setServerEnabled(true, it, id) }
    }

    private suspend fun storedPlan(conversationId: String = CONV_A, config: McpRuntimeConfig = McpRuntimeConfig.fallback) =
        McpToolBridge.plan(conversationId, store, credentials, LOCAL_PARTITION_ID, config)

    private fun weatherPlan(permission: McpToolPermission = McpToolPermission.Auto, snapshots: List<McpToolSnapshot> = listOf(snapshot("get_weather"))) =
        McpToolBridge.plan(
            listOf(
                McpBridgeServerInput(
                    record = McpServerRecord(WEATHER_ID, "Weather", "weather", MCP_ENDPOINT, McpAuthKind.Auto, false, null, 1L, 1L),
                    endpoint = McpServerEndpointResolution.Ready(MCP_ENDPOINT),
                    connectionStatus = McpConnectionStatus.Connected,
                    snapshots = snapshots,
                    permissions = snapshots.associate { it.toolName to permission },
                ),
            ),
            McpRuntimeConfig.fallback,
        )

    private fun executor(gate: McpConfirmationGate = McpDenyingConfirmationGate, conversationId: String = CONV_A) = McpToolExecutor(
        conversationId = conversationId,
        gate = gate,
        grants = grants,
        tokenProvider = { null },
        makeClient = { McpClient(endpoint = it, transport = mcp) },
        onStep = { steps += it },
    )

    private fun toolsList() = McpScriptedTransport.stub("protocol/stateless/tools-list.response.json")

    private fun toolsCall() = McpScriptedTransport.stub("protocol/stateless/tools-call.response.json")

    /** Scripted model legs: emit events in order and record every request the loop hands over. */
    private class ScriptedLegs(legs: List<List<ToolLoopLegEvent>>) : ToolLoopLegRunning {
        private val legs = ArrayDeque(legs)
        val requests: MutableList<ToolLoopLegRequest> = Collections.synchronizedList(mutableListOf())

        override fun run(request: ToolLoopLegRequest): Flow<ToolLoopLegEvent> = flow {
            requests += request
            (legs.pollFirst() ?: error("No scripted model leg")).forEach { emit(it) }
        }
    }

    private fun toolLeg(vararg calls: Triple<String, String, String>) = listOf<ToolLoopLegEvent>(
        ToolLoopLegEvent.ToolCallDeltas(
            calls.mapIndexed { index, (id, name, arguments) -> ToolLoopToolCallDelta(index, id = id, type = "function", name = name, arguments = arguments) },
        ),
    )

    private fun textLeg(text: String) = listOf<ToolLoopLegEvent>(ToolLoopLegEvent.TextDelta(text))

    private suspend fun runLoop(
        plan: McpToolPlan,
        legs: ScriptedLegs,
        executor: McpToolExecutor = executor(),
        config: McpRuntimeConfig = McpRuntimeConfig.fallback,
    ): ToolCallLoop.Result = McpChatToolRunner.makeLoop(plan, executor, legs, config) { calls -> unhandled += calls.map { it.function.name } }
        .run(McpToolBridge.initialMessages(listOf(ToolLoopMessage("user", "Weather in Melbourne?")), "Be brief."))

    /** Tool results fed back to the model after leg n (taken from the history the loop hands to the next leg). */
    private fun toolResults(legs: ScriptedLegs, legIndex: Int): List<String> =
        legs.requests[legIndex].messages.filter { it.role == "tool" }.mapNotNull { it.textContent }

    // ── Four wire protocols ────────────────────────────────────────

    private fun corpusLeg(file: String): String {
        val root = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/provider-toolcall") }.first { it.isDirectory }
        return File(root, file).readText().replace("\"get_weather\"", "\"$WEATHER_OUTBOUND\"")
    }

    private fun modelTextLeg(transport: RelayTransport, text: String): String = when (transport) {
        RelayTransport.AnthropicMessages -> listOf(
            "message_start" to """{"type":"message_start","message":{"id":"m2","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"usage":{"input_tokens":200,"output_tokens":1}}}""",
            "content_block_start" to """{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}""",
            "content_block_delta" to """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"$text"}}""",
            "content_block_stop" to """{"type":"content_block_stop","index":0}""",
            "message_delta" to """{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}""",
            "message_stop" to """{"type":"message_stop"}""",
        ).joinToString("") { (event, data) -> "event: $event\ndata: $data\n\n" }
        RelayTransport.OpenAIResponses -> listOf(
            "response.created" to """{"type":"response.created","response":{"id":"r2","status":"in_progress","output":[]}}""",
            "response.output_item.added" to """{"type":"response.output_item.added","output_index":0,"item":{"id":"m2","type":"message","status":"in_progress","role":"assistant","content":[]}}""",
            "response.output_text.delta" to """{"type":"response.output_text.delta","item_id":"m2","output_index":0,"content_index":0,"delta":"$text"}""",
            "response.completed" to """{"type":"response.completed","response":{"id":"r2","status":"completed","output":[],"usage":{"input_tokens":200,"output_tokens":9,"total_tokens":209}}}""",
        ).joinToString("") { (event, data) -> "event: $event\ndata: $data\n\n" }
        RelayTransport.GeminiGenerateContent ->
            """data: {"candidates":[{"content":{"parts":[{"text":"$text"}],"role":"model"},"finishReason":"STOP","index":0}]}""" + "\n\n"
        else -> listOf(
            """{"choices":[{"delta":{"content":"$text"}}]}""",
            """{"choices":[{"delta":{},"finish_reason":"stop"}]}""",
        ).joinToString("") { "data: $it\n\n" } + "data: [DONE]\n\n"
    }

    /** Production entry point [McpChatToolRunner]: MockEngine on the model side, scripted transport on the MCP side. */
    private fun chatRunner(responses: List<String>, bodies: MutableList<String>): McpChatToolRunner {
        val queue = ArrayDeque(responses)
        val engine = MockEngine { request ->
            bodies += (request.body as TextContent).text
            respond(
                queue.pollFirst() ?: error("No scripted model response"),
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        }
        return McpChatToolRunner(
            httpClient = HttpClient(engine),
            json = json,
            store = store,
            credentialStore = credentials,
            grants = grants,
            mcpTransport = { mcp },
        )
    }

    private fun relay(transport: RelayTransport) = Provider(
        id = "relay",
        kind = ProviderKind.Relay,
        apiKey = "key",
        baseUrlText = "https://relay.test/gateway/v1",
        relayRequested = RelayRequestedConfig(
            transport = transport,
            authMode = when (transport) {
                RelayTransport.AnthropicMessages -> RelayAuthMode.XApiKey
                RelayTransport.GeminiGenerateContent -> RelayAuthMode.XGoogApiKey
                else -> RelayAuthMode.Bearer
            },
        ),
    )

    private val relayModel = AIModel("model", "Model", toolCall = true)

    private val relayOptions = ChatRequestOptions(
        capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
            partitionId = "user", connectionInstanceId = "relay", connectionGeneration = "g1", credentialEpoch = "c1",
            providerKind = ProviderKind.Relay.rawValue, metadataRevision = "m1", generationRevision = "g1",
        ),
    )

    private fun userMessage(text: String) = ChatMessage(
        id = "u1", role = ChatRole.User, text = text, providerID = "relay", providerKind = ProviderKind.Relay,
        providerName = "Relay", modelID = "model", modelName = "Model", state = ChatMessageState.Delivered, createdAt = 1L,
    )

    @Test
    fun `every wire protocol round-trips proposal to tools-call to result feedback to answer`() = runBlocking {
        seedServer(listOf(snapshot("get_weather")), mapOf("get_weather" to McpToolPermission.Auto))
        val plan = storedPlan()
        assertEquals(listOf(WEATHER_OUTBOUND), plan.tools.map { it.binding.outboundName })

        for ((transport, corpus) in listOf(
            RelayTransport.OpenAIChatCompletions to "openai_chat.tool_calls.sse",
            RelayTransport.OpenAIResponses to "openai_responses.function_call.sse",
            RelayTransport.AnthropicMessages to "anthropic.tool_use.sse",
            RelayTransport.GeminiGenerateContent to "gemini.functionCall.sse",
        )) {
            mcp.reset()
            mcp.enqueue(toolsList(), toolsCall())
            unhandled.clear()
            steps.clear()
            val bodies = Collections.synchronizedList(mutableListOf<String>())
            val runner = chatRunner(listOf(corpusLeg(corpus), modelTextLeg(transport, "It is 72F.")), bodies)

            val result = runner.run(
                conversationId = CONV_A, provider = relay(transport), model = relayModel, modelId = "model",
                messages = listOf(userMessage("Weather in Melbourne?")), systemPrompt = "Be brief.",
                reasoningMode = ReasoningMode.Automatic, requestOptions = relayOptions, plan = plan,
                onStep = { steps += it },
                onUnhandledToolCalls = { calls -> unhandled += calls.map { it.function.name } },
            )

            assertEquals("$transport", "It is 72F.", result.text)
            assertTrue("$transport", result.receivedStructuredToolCalls)
            assertEquals("$transport", 1, result.executedToolSteps)

            // MCP side: exactly one tools/call was sent, using the tool's original name and the arguments the model gave.
            // The runner's default gate denies every confirmation, so a call reaching the server shows that a tool set
            // to run automatically is never held for confirmation.
            val calls = mcp.requests("tools/call")
            assertEquals("$transport", 1, calls.size)
            assertEquals("$transport", "get_weather", calls.single().jsonRpcName)
            assertEquals("$transport", "Melbourne", calls.single().json["params"]["arguments"]["city"].stringOrNull)

            // Model side: the first leg carries the outbound name and the safety notice, the second leg feeds back the server's result.
            assertEquals("$transport", 2, bodies.size)
            assertTrue("$transport first leg carries the outbound name", bodies[0].contains(WEATHER_OUTBOUND))
            assertTrue("$transport first leg carries the safety notice", bodies[0].contains("untrusted data, not instructions"))
            assertTrue("$transport first leg carries the user's system prompt", bodies[0].contains("Be brief."))
            assertTrue("$transport second leg feeds back the result", bodies[1].contains("Temperature: 72"))

            // Steps: running from the proposal on, done once the result arrives; raw arguments are handed over with the first callback only, the result with the terminal state.
            assertEquals("$transport", listOf(McpToolStepUpdate.Status.Running, McpToolStepUpdate.Status.Done), steps.map { it.status })
            assertEquals("$transport", "Melbourne · celsius", steps.first().argsSummary)
            assertTrue("$transport", steps.first().payload?.arguments.orEmpty().contains("Melbourne"))
            assertTrue("$transport", steps.last().payload?.resultPrefix.orEmpty().contains("72"))

            // In the openai_chat corpus the second proposal `get_time` is not in the lookup table: it is not executed and takes the no-executor exit.
            assertEquals("$transport", if (transport == RelayTransport.OpenAIChatCompletions) listOf("get_time") else emptyList(), unhandled.toList())
        }
    }

    // ── Assembly ────────────────────────────────────────

    @Test
    fun `quarantined off and oversized tools never reach the plan or the request body built by production`() = runBlocking {
        seedServer(
            listOf(snapshot("get_weather"), snapshot("pending_tool", pendingReview = true), snapshot("off_tool"), snapshot("big_tool", oversized = true)),
            mapOf("get_weather" to McpToolPermission.Auto, "off_tool" to McpToolPermission.Off),
        )
        val plan = storedPlan()
        assertEquals(listOf(WEATHER_OUTBOUND), plan.tools.map { it.binding.outboundName })
        assertEquals(mapOf(WEATHER_OUTBOUND to McpToolBinding(WEATHER_OUTBOUND, WEATHER_ID, "get_weather")), plan.nameTable)

        val bodies = Collections.synchronizedList(mutableListOf<String>())
        chatRunner(listOf(modelTextLeg(RelayTransport.OpenAIChatCompletions, "Hi.")), bodies).run(
            conversationId = CONV_A, provider = relay(RelayTransport.OpenAIChatCompletions), model = relayModel, modelId = "model",
            messages = listOf(userMessage("Hi")), systemPrompt = null, reasoningMode = ReasoningMode.Automatic,
            requestOptions = relayOptions, plan = plan,
        )
        val body = json.parseToJsonElement(bodies.single())
        val toolNames = body["tools"].jsonArrayOrNull.orEmpty().map { it["function"]["name"].stringOrNull }
        assertEquals(listOf<String?>(WEATHER_OUTBOUND), toolNames)
        for (hidden in listOf("pending_tool", "off_tool", "big_tool")) {
            assertFalse("$hidden must not appear in the request body", bodies.single().contains(hidden))
        }
        assertTrue("the MCP server was not touched", mcp.requests().isEmpty())
    }

    @Test
    fun `nothing enabled means no tools and switches are per conversation`() = runBlocking {
        seedServer(listOf(snapshot("get_weather")), enabledIn = listOf(CONV_A))

        assertTrue("another conversation having it enabled does not leak over", storedPlan(CONV_B).isEmpty)
        assertEquals(listOf(WEATHER_OUTBOUND), storedPlan(CONV_A).tools.map { it.binding.outboundName })

        // Nothing is carried when the master switch is off either.
        assertTrue(storedPlan(CONV_A, McpRuntimeConfig(enabled = false)).isEmpty)
        // After switching it off, the same conversation carries nothing either.
        store.setServerEnabled(false, CONV_A, WEATHER_ID)
        assertTrue(storedPlan(CONV_A).isEmpty)
    }

    @Test
    fun `servers needing sign-in or missing their full address are left out and tools are capped in enable order`() = runBlocking {
        seedServer(listOf(snapshot("a_tool")), id = SERVER_B, name = "Needs Auth", status = McpConnectionStatus.NeedsAuth)
        val full = "https://secret.example.com/mcp?token=sk-secret"
        seedServer(listOf(snapshot("b_tool")), id = SERVER_C, name = "Secret", url = full, localOnly = true)
        seedServer(listOf(snapshot("get_weather"), snapshot("second_tool")))

        // The full address is not on this device (restored from a backup): the whole server is left out, and the display URL is never used to send requests.
        assertEquals(listOf(WEATHER_OUTBOUND, "mcp_weather_second_tool"), storedPlan().tools.map { it.binding.outboundName })

        // The full address is on this device: the request address comes from the credential store.
        credentials.saveEndpoint(full, SERVER_C, LOCAL_PARTITION_ID)
        val plan = storedPlan()
        assertEquals(full, plan.tools.single { it.binding.serverId == SERVER_C }.endpoint)
        assertFalse("the full address must not appear in the string description", plan.tools.joinToString().contains("sk-secret"))

        // Over maxToolsPerRequest: the tail is cut in the order the servers were enabled.
        val capped = storedPlan(config = McpRuntimeConfig(maxToolsPerRequest = 2))
        assertEquals(listOf("mcp_secret_b_tool", WEATHER_OUTBOUND), capped.tools.map { it.binding.outboundName })
        assertTrue(capped.truncated)
    }

    @Test
    fun `a missing model or a model known not to support tools carries no mcp tools`() = runBlocking {
        seedServer(listOf(snapshot("get_weather")))
        val runner = chatRunner(emptyList(), mutableListOf())
        val connection = relay(RelayTransport.OpenAIChatCompletions)
        // Nothing is carried when the model is absent (the selected model is not in the connection) or this connection is recorded as not supporting tools.
        assertTrue(runner.plan(CONV_A, connection, null, memoryVerdict = null).isEmpty)
        val unsupported = AIModel("model", "Model", toolCall = false)
        assertFalse(runner.connectionSupportsTools(connection, unsupported, memoryVerdict = null))
        assertTrue(runner.plan(CONV_A, connection, unsupported, memoryVerdict = null).isEmpty)
        assertEquals(McpToolAvailability.ModelUnsupported, runner.availability(connection, unsupported, memoryVerdict = null))
        // Nothing is reported as unavailable before a model is chosen.
        assertEquals(McpToolAvailability.Available, runner.availability(connection, null, memoryVerdict = null))
        assertEquals(McpToolAvailability.Available, runner.availability(null, null, memoryVerdict = null))
    }

    // ── Confirmation gate ────────────────────────────────────────

    @Test
    fun `an ask tool without user approval never reaches the server and the default gate denies`() = runBlocking {
        val legs = ScriptedLegs(listOf(toolLeg(Triple("c1", WEATHER_OUTBOUND, """{"city":"Melbourne"}""")), textLeg("I could not check.")))
        val result = runLoop(weatherPlan(McpToolPermission.Ask), legs)

        assertEquals("I could not check.", result.text)
        assertTrue("zero requests to the server after a denial (not even a connection)", mcp.requests().isEmpty())
        assertEquals(listOf(McpToolStepUpdate.Status.Running, McpToolStepUpdate.Status.Denied), steps.map { it.status })
        assertEquals(McpErrorCode.UserDenied, steps.last().errorCode)
        val fed = toolResults(legs, 1).single()
        assertTrue(fed, fed.contains("\"ok\":false") && fed.contains("user_denied"))
    }

    @Test
    fun `confirmation choices - once asks every time and conversation grants only that tool in that conversation`() = runBlocking {
        val asked = Collections.synchronizedList(mutableListOf<McpConfirmationRequest>())
        val answers = ArrayDeque(listOf(McpConfirmationChoice.Once, McpConfirmationChoice.Conversation))
        val gate = McpConfirmationGate { request ->
            asked += request
            answers.pollFirst() ?: McpConfirmationChoice.Deny
        }
        val plan = weatherPlan(McpToolPermission.Ask, listOf(snapshot("get_weather", readOnly = false), snapshot("other_tool", readOnly = false)))
        mcp.enqueue(toolsList())
        mcp.setFallback(toolsCall())
        val weather = Triple("c", WEATHER_OUTBOUND, """{"city":"Melbourne"}""")
        val legs = ScriptedLegs(
            listOf(
                toolLeg(weather.copy(first = "c1")), // allow once
                toolLeg(weather.copy(first = "c2")), // asked again: allow for this conversation
                toolLeg(weather.copy(first = "c3")), // not asked again
                toolLeg(Triple("c4", "mcp_weather_other_tool", """{"city":"X"}""")), // a different tool: still asked (script exhausted → deny)
                textLeg("Done."),
            ),
        )
        val result = runLoop(plan, legs, executor(gate))

        assertEquals("Done.", result.text)
        assertEquals(listOf("get_weather", "get_weather", "other_tool"), asked.map { it.toolName })
        assertEquals("mcp.example.com", asked.first().serverHost)
        assertEquals("Melbourne", asked.first().arguments["city"].stringOrNull)
        assertEquals(3, mcp.requests("tools/call").size)
        assertEquals("each server is connected only once per run", 1, mcp.requests("tools/list").size)

        // Grants live in memory only, keyed by conversation + server + tool; other conversations do not inherit them.
        assertTrue(grants.isGranted(CONV_A, WEATHER_ID.uppercase(), "get_weather"))
        assertFalse(grants.isGranted(CONV_B, WEATHER_ID, "get_weather"))
        assertFalse(grants.isGranted(CONV_A, WEATHER_ID, "other_tool"))
    }

    @Test
    fun `stopping while waiting for confirmation interrupts the step and sends nothing`() = runBlocking {
        val asked = CompletableDeferred<Unit>()
        val gate = McpConfirmationGate {
            asked.complete(Unit)
            CompletableDeferred<McpConfirmationChoice>().await()
        }
        val legs = ScriptedLegs(listOf(toolLeg(Triple("c1", WEATHER_OUTBOUND, """{"city":"Melbourne"}"""))))
        val job = launch(Dispatchers.Default) { runLoop(weatherPlan(McpToolPermission.Ask), legs, executor(gate)) }
        asked.await()
        job.cancelAndJoin()

        assertTrue(job.isCancelled)
        assertTrue(mcp.requests().isEmpty())
        assertEquals(listOf(McpToolStepUpdate.Status.Running, McpToolStepUpdate.Status.Interrupted), steps.map { it.status })
    }

    // ── Lookup table, self-correction and degradation ────────────────────────────────────────

    @Test
    fun `a name outside the table is never executed and goes to the unhandled exit`() = runBlocking {
        val legs = ScriptedLegs(listOf(toolLeg(Triple("c1", "mcp_weather_delete_everything", "{}"), Triple("c2", "get_weather", "{}"))))
        val result = runLoop(weatherPlan(), legs)

        assertEquals(listOf("mcp_weather_delete_everything", "get_weather"), unhandled.toList())
        assertTrue(mcp.requests().isEmpty())
        assertEquals(0, result.executedToolSteps)
        assertTrue(steps.isEmpty())
    }

    @Test
    fun `malformed or incomplete arguments are fed back for self-correction without calling the server`() = runBlocking {
        val plan = weatherPlan(snapshots = listOf(snapshot("get_weather", inputSchema = schema(listOf("city"), required = listOf("city")))))
        mcp.enqueue(toolsList(), toolsCall())
        val legs = ScriptedLegs(
            listOf(
                toolLeg(Triple("c1", WEATHER_OUTBOUND, "[1,2]")),
                toolLeg(Triple("c2", WEATHER_OUTBOUND, """{"unit":"celsius"}""")),
                toolLeg(Triple("c3", WEATHER_OUTBOUND, """{"city":"Melbourne"}""")),
                textLeg("72F."),
            ),
        )
        val result = runLoop(plan, legs)

        assertEquals("72F.", result.text)
        assertTrue(toolResults(legs, 1).single().contains("invalid_arguments"))
        assertTrue(toolResults(legs, 2).last().contains("missing_required_arguments"))
        assertEquals("tools/call is only sent for the attempt with correct arguments", 1, mcp.requests("tools/call").size)
        assertEquals(1, result.executedToolSteps)
    }

    @Test
    fun `consecutive server failures degrade one by one and never abort the answer`() = runBlocking {
        // The server is unreachable: every call fails. By default the generic loop aborts the whole run after 3 consecutive failures; with MCP that breaker is off.
        mcp.setFallback(McpScriptedTransport.networkError())
        val call = Triple("c", WEATHER_OUTBOUND, """{"city":"Melbourne"}""")
        val legs = ScriptedLegs((1..4).map { toolLeg(call.copy(first = "c$it")) } + listOf(textLeg("The weather service is down.")))
        val result = runLoop(weatherPlan(), legs)

        assertEquals("The weather service is down.", result.text)
        assertEquals(4, result.executedToolSteps)
        assertEquals(Int.MAX_VALUE, McpToolBridge.limits(McpRuntimeConfig.fallback).maxConsecutiveToolFailures)
        assertEquals(List(4) { McpToolStepUpdate.Status.Failed }, steps.filter { it.status != McpToolStepUpdate.Status.Running }.map { it.status })
        // Only the closed-set code and one fixed sentence are fed back to the model, never the server's own text.
        val fed = toolResults(legs, 4)
        assertTrue(fed.all { it.contains("\"ok\":false") && it.contains("unreachable") && it.contains("Do not invent its result") })
    }

    @Test
    fun `a tool error keeps the server text out of the model feedback and the step summary while needs-auth is its own status`() = runBlocking {
        mcp.enqueue(toolsList(), McpScriptedTransport.stub("protocol/shared/tools-call.is-error.response.json"), McpScriptedTransport.stub("auth/401.www-authenticate.json"))
        val call = Triple("c", WEATHER_OUTBOUND, """{"city":"Melbourne"}""")
        val legs = ScriptedLegs(listOf(toolLeg(call.copy(first = "c1")), toolLeg(call.copy(first = "c2")), textLeg("Sorry.")))
        runLoop(weatherPlan(), legs)

        val terminal = steps.filter { it.status != McpToolStepUpdate.Status.Running }
        assertEquals(listOf(McpToolStepUpdate.Status.Failed, McpToolStepUpdate.Status.NeedsAuth), terminal.map { it.status })
        assertEquals(listOf(McpErrorCode.ToolError, McpErrorCode.NeedsAuth), terminal.map { it.errorCode })
        // The server's error text only goes into the per-step payload (truncated to 200 characters): it is not fed back to the model and is not part of the summary stored on the message.
        val serverText = terminal.first().payload?.resultPrefix.orEmpty()
        assertTrue(serverText.isNotEmpty() && serverText.length <= McpToolStepPayload.MAX_FAILURE_TEXT_LENGTH)
        assertFalse(McpToolStep.from(terminal.first()).toString().contains(serverText))
        val fed = toolResults(legs, 2)
        assertTrue(fed.none { it.contains(serverText) })
        assertTrue(fed.first().contains("tool_error") && fed.last().contains("needs_auth"))
    }

    @Test
    fun `step limit feeds the neutral stopped code to skipped calls and forces a tool-less synthesis leg`() = runBlocking {
        mcp.enqueue(toolsList())
        mcp.setFallback(toolsCall())
        val call = Triple("c", WEATHER_OUTBOUND, """{"city":"Melbourne"}""")
        val legs = ScriptedLegs(listOf(toolLeg(call.copy(first = "c1"), call.copy(first = "c2"), call.copy(first = "c3")), textLeg("Summary.")))
        val result = runLoop(weatherPlan(), legs, config = McpRuntimeConfig(maxSteps = 2))

        assertEquals("Summary.", result.text)
        assertTrue(result.stepLimitReached)
        assertEquals(2, mcp.requests("tools/call").size)
        assertTrue(toolResults(legs, 1).last().contains(McpToolBridge.STOPPED_ERROR_CODE))
        assertEquals(ToolLoopToolChoice.None, legs.requests.last().toolChoice)
        assertFalse("the synthesis leg carries no citation wording", legs.requests.last().messages.any { it.textContent.orEmpty().contains("[n]") })
    }

    private companion object {
        const val WEATHER_ID = "aaaaaaaa-0000-4000-8000-000000000001"
        const val SERVER_B = "bbbbbbbb-0000-4000-8000-000000000002"
        const val SERVER_C = "cccccccc-0000-4000-8000-000000000003"
        const val CONV_A = "conversation-a"
        const val CONV_B = "conversation-b"
        const val MCP_ENDPOINT = "https://mcp.example.com/mcp"
        const val WEATHER_OUTBOUND = "mcp_weather_get_weather"
    }
}
