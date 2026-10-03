package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpBridgeServerInput
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpClient
import ai.oriveo.community.core.mcp.McpConnectionStatus
import ai.oriveo.community.core.mcp.McpConfirmationChoice
import ai.oriveo.community.core.mcp.McpConfirmationCoordinator
import ai.oriveo.community.core.mcp.McpConfirmationGate
import ai.oriveo.community.core.mcp.McpConversationGrants
import ai.oriveo.community.core.mcp.McpDenyingConfirmationGate
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.core.mcp.McpServerEndpointResolution
import ai.oriveo.community.core.mcp.McpServerRecord
import ai.oriveo.community.core.mcp.McpToolBridge
import ai.oriveo.community.core.mcp.McpToolExecutor
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.core.mcp.McpToolPlan
import ai.oriveo.community.core.mcp.McpToolSnapshot
import ai.oriveo.community.core.mcp.McpToolStep
import ai.oriveo.community.core.mcp.McpToolStepUpdate
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamActivity
import ai.oriveo.community.core.model.UnhandledToolCall
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolLoopLegEvent
import ai.oriveo.community.core.tools.ToolLoopLegRunning
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolCallDelta
import ai.oriveo.community.core.tools.ToolLoopUsage
import ai.oriveo.community.core.tools.ToolsUnsupportedError
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Remote MCP wired into the chat send path.
 *
 * The runner is a mock (its assembly and execution are covered in `McpToolBridgeTest` with real storage and a
 * real leg executor), but in the "MCP only" case the events and result it hands back come from the **real**
 * generic loop plus the real `McpToolExecutor` (built by the production `McpChatToolRunner.makeLoop`),
 * not from a result object assembled by the test.
 */
class ChatRepositoryMcpTest {
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val attachmentStore = mockk<AttachmentStore>(relaxed = true)
    private val mcpRunner = mockk<McpChatToolRunner>()
    private val memory = mockk<ToolCallMemoryStore>(relaxed = true)
    private val mcp = McpScriptedTransport()
    private val savedPayloadUpdates = mutableListOf<McpToolStepUpdate>()
    private val limitReachedMessageIds = mutableListOf<String>()

    private val plan: McpToolPlan = planWith(McpToolPermission.Auto)

    /** The confirmation gate: denies by default; confirmation cases swap in the real [McpConfirmationCoordinator]. */
    private var gate: McpConfirmationGate = McpDenyingConfirmationGate
    private val grants = McpConversationGrants()
    private var activePlan: McpToolPlan? = null
    private var confirmationsShown = 0

    private fun planWith(permission: McpToolPermission): McpToolPlan = McpToolBridge.plan(
        listOf(
            McpBridgeServerInput(
                record = McpServerRecord(SERVER_ID, "Weather", "weather", ENDPOINT, McpAuthKind.Auto, false, null, 1L, 1L),
                endpoint = McpServerEndpointResolution.Ready(ENDPOINT),
                connectionStatus = McpConnectionStatus.Connected,
                snapshots = listOf(
                    McpToolSnapshot(
                        serverId = SERVER_ID, toolName = "get_weather", title = "Get weather", description = "Weather",
                        inputSchema = buildJsonObject {
                            put("type", "object")
                            putJsonObject("properties") { putJsonObject("city") { put("type", "string") } }
                        },
                        annotations = buildJsonObject { put("readOnlyHint", true) },
                        contentHash = "h", readOnly = true, updatedAt = 1L,
                    ),
                ),
                permissions = mapOf("get_weather" to permission),
            ),
        ),
        McpRuntimeConfig.fallback,
    )

    private fun arrange() {
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { providerRepository.currentCapabilityPartitionId() } returns LOCAL_PARTITION_ID
        coEvery { mcpRunner.plan(any(), any(), any(), any(), any()) } answers { activePlan ?: plan }
        coEvery { mcpRunner.saveStepPayload(any(), capture(savedPayloadUpdates)) } returns Unit
        every { mcpRunner.clearStepLimitReached(any()) } returns Unit
        every { mcpRunner.markStepLimitReached(capture(limitReachedMessageIds)) } returns Unit
    }

    /** Makes the mock runner forward `run` to the real generic loop (a scripted model leg plus a scripted MCP server). */
    private fun answerWithRealLoop(
        legs: List<List<ToolLoopLegEvent>>,
        config: McpRuntimeConfig = McpRuntimeConfig.fallback,
        /** Thrown by the model leg that follows the scripted ones. */
        failure: ProviderServiceError? = null,
    ) {
        val remaining = ArrayDeque(legs)
        coEvery {
            mcpRunner.run(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
        } coAnswers {
            // The production `McpChatToolRunner.run` simply hands the caller's onStep to the executor; this does the same, so step callbacks come from the real executor.
            val executor = McpToolExecutor(
                conversationId = "conversation-1",
                gate = gate,
                grants = grants,
                tokenProvider = { null },
                makeClient = { McpClient(endpoint = it, transport = mcp) },
                onStep = arg<suspend (McpToolStepUpdate) -> Unit>(9),
            )
            val onUnhandled = arg<suspend (List<ToolLoopToolCall>) -> Unit>(10)
            val onProgress = arg<suspend (ToolCallLoop.ProgressEvent) -> Unit>(11)
            McpChatToolRunner.makeLoop(
                plan = activePlan ?: plan,
                executor = executor,
                legRunner = ToolLoopLegRunning {
                    flow {
                        val leg = remaining.removeFirstOrNull()
                        if (leg == null && failure != null) throw failure
                        leg?.forEach { emit(it) }
                    }
                },
                runtimeConfig = config,
                onUnhandledToolCalls = onUnhandled,
            ).run(listOf(ToolLoopMessage("user", "Weather?")), onProgress)
        }
    }

    private fun toolCall(id: String, name: String, arguments: String) =
        ToolLoopLegEvent.ToolCallDeltas(listOf(ToolLoopToolCallDelta(0, id = id, type = "function", name = name, arguments = arguments)))

    @Test
    fun `mcp only - the tool loop answers the message without a second provider request`() = runTest {
        arrange()
        mcp.enqueue(
            McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"),
            McpScriptedTransport.stub("protocol/stateless/tools-call.response.json"),
        )
        answerWithRealLoop(
            listOf(
                listOf(
                    ToolLoopLegEvent.TextDelta("Let me check."),
                    toolCall("c1", OUTBOUND, "{\"city\":\"Melbourne\"}"),
                    ToolLoopLegEvent.Usage(ToolLoopUsage(100, 10, 110)),
                ),
                listOf(ToolLoopLegEvent.TextDelta("It is 72F."), ToolLoopLegEvent.Usage(ToolLoopUsage(150, 20, 170))),
            ),
        )
        val delivered = slot<ChatMessage>()
        coEvery { conversationRepository.updateMessage(eq("conversation-1"), capture(delivered)) } returns Unit
        val outputs = outputs()

        repository().sendMessage(
            conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
            existingMessages = emptyList(), outputs = outputs,
        )

        assertEquals(ChatMessageState.Delivered, delivered.captured.state)
        assertEquals("the lead-in text of the tool_calls leg stays out of the final body", "It is 72F.", delivered.captured.text)
        assertTrue("usage of both legs is billed", delivered.captured.estimatedCost > 0.0)
        assertEquals("the tool really was called once", 1, mcp.requests("tools/call").size)
        verify(exactly = 0) { providerRepository.serviceFor(any<Provider>()) }
        verify { memory.record(LOCAL_PARTITION_ID, any(), any(), toolCall = true, reason = "structured_tool_calls_observed") }
    }

    /**
     * The message keeps a summary of each step; raw arguments and returned results go to the step payload store.
     *
     * Every asserted object comes from the production path: the real executor callback -> `ChatRepository` merging it
     * into the message. `apiSecret` is not among the properties of the parameter definition, so it stays out of the
     * argument summary; it may only appear in the copy handed to the payload store.
     */
    @Test
    fun `the message keeps step summaries only - raw arguments and results go to the payload store`() = runTest {
        arrange()
        mcp.enqueue(
            McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"),
            McpScriptedTransport.stub("protocol/stateless/tools-call.response.json"),
        )
        answerWithRealLoop(
            listOf(
                listOf(toolCall("c1", OUTBOUND, "{\"city\":\"Melbourne\",\"apiSecret\":\"RAW-ARG-SECRET\"}")),
                listOf(ToolLoopLegEvent.TextDelta("It is 72F.")),
            ),
        )
        val progress = mutableListOf<List<McpToolStep>>()
        coEvery { conversationRepository.updateMcpToolStepsProgress(any(), capture(progress)) } returns 1
        val delivered = slot<ChatMessage>()
        coEvery { conversationRepository.updateMessage(eq("conversation-1"), capture(delivered)) } returns Unit

        repository().sendMessage(
            conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
            existingMessages = emptyList(), outputs = outputs(),
        )

        // Progress: running first, then done, the same step updated in place.
        assertEquals(listOf(listOf("running"), listOf("done")), progress.map { steps -> steps.map { it.status } })
        val step = delivered.captured.toolSteps!!.single()
        assertEquals("1:c1", step.id)
        assertEquals(SERVER_ID, step.serverId)
        assertEquals("Weather", step.serverName)
        assertEquals("get_weather", step.toolName)
        assertEquals("Get weather", step.title)
        assertEquals("Melbourne", step.argsSummary)
        assertEquals("done", step.status)
        assertEquals(null, step.errorCode)
        assertEquals(1, step.step)

        assertEquals("mcp", step.scope)
        val dump = delivered.captured.toString()
        assertTrue("raw arguments must not be stored on the message - $dump", "RAW-ARG-SECRET" !in dump && "apiSecret" !in dump)
        assertTrue("returned results must not be stored on the message - $dump", "Partly cloudy" !in dump && "72°F" !in dump)

        // Payloads take a different route: arguments arrive with the first callback, the result with the terminal state.
        assertEquals(2, savedPayloadUpdates.size)
        assertTrue(savedPayloadUpdates[0].payload!!.arguments!!.contains("RAW-ARG-SECRET"))
        assertTrue(savedPayloadUpdates[1].payload!!.resultPrefix!!.contains("Partly cloudy"))
        coVerify(exactly = 2) { mcpRunner.saveStepPayload(delivered.captured.id, any()) }
    }

    /**
     * Reasoning deltas from the tool loop go into the same reasoning block, and the activity status line is set and
     * cleared along with the running step.
     * The activity value is read on the production callback chain: outputs are read at the moment the payload is stored.
     */
    @Test
    fun `loop reasoning feeds the reasoning block and the mcp_tool activity follows the running step`() = runTest {
        arrange()
        mcp.enqueue(
            McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"),
            McpScriptedTransport.stub("protocol/stateless/tools-call.response.json"),
        )
        answerWithRealLoop(
            listOf(
                listOf(ToolLoopLegEvent.ReasoningDelta("I should check the weather.\n"), toolCall("c1", OUTBOUND, "{\"city\":\"Melbourne\"}")),
                listOf(ToolLoopLegEvent.ReasoningDelta("Now I can answer.\n"), ToolLoopLegEvent.TextDelta("It is 72F.")),
            ),
        )
        val outputs = outputs()
        val activityAtStep = mutableListOf<StreamActivity?>()
        coEvery { mcpRunner.saveStepPayload(any(), any()) } answers { activityAtStep += outputs.streamingActivity.value }
        val delivered = slot<ChatMessage>()
        coEvery { conversationRepository.updateMessage(eq("conversation-1"), capture(delivered)) } returns Unit

        repository().sendMessage(
            conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
            existingMessages = emptyList(), outputs = outputs,
        )

        assertEquals("set on running, cleared on leaving running", listOf(StreamActivity.McpTool, null), activityAtStep)
        assertEquals(null, outputs.streamingActivity.value)
        assertEquals("reasoning of both legs accumulates in order", "I should check the weather.\nNow I can answer.", delivered.captured.reasoningText)
        assertEquals("I should check the weather.\nNow I can answer.\n", outputs.streamingReasoning.value)
        assertTrue(outputs.reasoningStartedAtMs.value != null)
        assertEquals("It is 72F.", delivered.captured.text)
    }

    /**
     * The three-way confirmation goes through the real gate: `McpConfirmationCoordinator` suspends the loop and the
     * test plays the UI, reading the head of the queue and answering. The assertions look at how many times the user
     * was asked, how many `tools/call` requests the scripted server actually received and at the steps actually
     * recorded on the message.
     */
    private suspend fun kotlinx.coroutines.test.TestScope.sendWithConfirmation(
        coordinator: McpConfirmationCoordinator,
        choice: McpConfirmationChoice?,
        legs: List<List<ToolLoopLegEvent>>,
    ): ChatMessage {
        arrange()
        activePlan = planWith(McpToolPermission.Ask)
        gate = coordinator
        answerWithRealLoop(legs)
        val delivered = slot<ChatMessage>()
        coEvery { conversationRepository.updateMessage(eq("conversation-1"), capture(delivered)) } returns Unit
        val user = backgroundScope.launch {
            while (choice != null) {
                val pending = coordinator.pending.first { it.isNotEmpty() }.first()
                assertEquals("the confirmation carries the server name, host name and tool title", "Weather|mcp.example.com|Get weather",
                    "${pending.request.serverName}|${pending.request.serverHost}|${pending.request.toolTitle}")
                confirmationsShown += 1
                coordinator.resolve(pending.id, choice)
                coordinator.pending.first { list -> list.none { it.id == pending.id } }
            }
        }
        repository().sendMessage(
            conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
            existingMessages = emptyList(), outputs = outputs(),
        )
        user.cancel()
        return delivered.captured
    }

    private fun askLegs(calls: Int) = (1..calls).map { toolCall("c$it", OUTBOUND, "{\"city\":\"Melbourne\"}").let(::listOf) } +
        listOf(listOf(ToolLoopLegEvent.TextDelta("Done.")))

    @Test
    fun `confirm - allow once runs this call and asks again next time`() = runTest {
        mcp.enqueue(McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"))
        mcp.setFallback(McpScriptedTransport.stub("protocol/stateless/tools-call.response.json"))
        val message = sendWithConfirmation(McpConfirmationCoordinator(), McpConfirmationChoice.Once, askLegs(2))

        assertEquals(listOf("done", "done"), message.toolSteps!!.map { it.status })
        assertEquals(2, mcp.requests("tools/call").size)
        assertEquals("each call is asked once", 2, confirmationsShown)
        assertTrue("allowing once grants nothing for later calls", !grants.isGranted("conversation-1", SERVER_ID, "get_weather"))
    }

    @Test
    fun `confirm - always allow in this chat asks once for the same server and tool`() = runTest {
        mcp.enqueue(McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"))
        mcp.setFallback(McpScriptedTransport.stub("protocol/stateless/tools-call.response.json"))
        val message = sendWithConfirmation(McpConfirmationCoordinator(), McpConfirmationChoice.Conversation, askLegs(2))

        assertEquals(listOf("done", "done"), message.toolSteps!!.map { it.status })
        assertEquals(2, mcp.requests("tools/call").size)
        assertEquals("the second call runs without asking", 1, confirmationsShown)
        assertTrue(grants.isGranted("conversation-1", SERVER_ID, "get_weather"))
        assertTrue("it does not apply to another conversation", !grants.isGranted("conversation-2", SERVER_ID, "get_weather"))
    }

    @Test
    fun `confirm - decline never reaches the server and the answer continues`() = runTest {
        val message = sendWithConfirmation(McpConfirmationCoordinator(), McpConfirmationChoice.Deny, askLegs(1))

        assertEquals(1, confirmationsShown)
        val step = message.toolSteps!!.single()
        assertEquals("denied", step.status)
        assertEquals("user_denied", step.errorCode)
        assertTrue("after a denial no request at all is sent to the server", mcp.requests().isEmpty())
        assertEquals(ChatMessageState.Delivered, message.state)
        assertEquals("Done.", message.text)
    }

    /** At the step limit the answer is still delivered and the message is marked as having hit the limit (the step block's last line shows it). */
    @Test
    fun `step limit - the answer is delivered from the results so far and the message is flagged`() = runTest {
        arrange()
        mcp.enqueue(McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"))
        mcp.setFallback(McpScriptedTransport.stub("protocol/stateless/tools-call.response.json"))
        answerWithRealLoop(
            listOf(
                listOf(toolCall("c1", OUTBOUND, "{\"city\":\"Melbourne\"}")),
                listOf(toolCall("c2", OUTBOUND, "{\"city\":\"Sydney\"}")),
                listOf(ToolLoopLegEvent.TextDelta("Two cities so far.")),
            ),
            config = McpRuntimeConfig(maxSteps = 2),
        )
        val delivered = slot<ChatMessage>()
        coEvery { conversationRepository.updateMessage(eq("conversation-1"), capture(delivered)) } returns Unit

        repository().sendMessage(
            conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
            existingMessages = emptyList(), outputs = outputs(),
        )

        assertEquals(ChatMessageState.Delivered, delivered.captured.state)
        assertEquals("Two cities so far.", delivered.captured.text)
        assertEquals(listOf("done", "done"), delivered.captured.toolSteps!!.map { it.status })
        assertEquals(listOf(delivered.captured.id), limitReachedMessageIds)
    }

    /** The user taps stop while a confirmation is pending: the message ends as interrupted, that step is recorded as interrupted, and the server receives no call. */
    @Test
    fun `user stop while a confirmation is pending leaves an interrupted message with an interrupted step`() = runTest {
        arrange()
        activePlan = planWith(McpToolPermission.Ask)
        val coordinator = McpConfirmationCoordinator()
        gate = coordinator
        answerWithRealLoop(listOf(listOf(toolCall("c1", OUTBOUND, "{\"city\":\"Melbourne\"}")), listOf(ToolLoopLegEvent.TextDelta("never"))))
        val updates = mutableListOf<ChatMessage>()
        coEvery { conversationRepository.updateMessage(eq("conversation-1"), capture(updates)) } returns Unit

        val send = launch {
            repository().sendMessage(
                conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
                existingMessages = emptyList(), outputs = outputs(),
            )
        }
        coordinator.pending.first { it.isNotEmpty() }
        // Same order as the chat screen's stop: withdraw the confirmation first, then cancel the send.
        coordinator.cancelConversation("conversation-1")
        send.cancel()
        send.join()

        val last = updates.last()
        assertEquals(ChatMessageState.Interrupted, last.state)
        val step = last.toolSteps!!.single()
        assertEquals("interrupted", step.status)
        assertEquals("cancelled", step.errorCode)
        assertTrue(coordinator.pending.value.isEmpty())
        assertTrue("a call that was not allowed is never sent", mcp.requests().isEmpty())
    }

    @Test
    fun `a tool outside the name table surfaces the no executor card instead of being executed`() = runTest {
        arrange()
        answerWithRealLoop(listOf(listOf(toolCall("x1", "mcp_weather_delete_all", "{}"))))
        val delivered = slot<ChatMessage>()
        coEvery { conversationRepository.updateMessage(eq("conversation-1"), capture(delivered)) } returns Unit

        repository().sendMessage(
            conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
            existingMessages = emptyList(), outputs = outputs(),
        )

        assertEquals(ChatMessageState.Delivered, delivered.captured.state)
        assertEquals(listOf(UnhandledToolCall(id = "x1", name = "mcp_weather_delete_all", arguments = "{}")), delivered.captured.unhandledToolCalls)
        assertTrue("a name outside the lookup table sends no request", mcp.requests().isEmpty())
    }

    @Test
    fun `a first-leg tools rejection is remembered for the connection and fails this message with the upstream error`() = runTest {
        arrange()
        coEvery {
            mcpRunner.run(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
        } throws ToolsUnsupportedError(ProviderServiceError.Upstream(400, "tools is not supported"))

        repository().sendMessage(
            conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
            existingMessages = emptyList(), outputs = outputs(),
        )

        val updates = mutableListOf<ChatMessage>()
        coVerify { conversationRepository.updateMessage(eq("conversation-1"), capture(updates)) }
        assertEquals(ChatMessageState.Failed, updates.last().state)
        verify { memory.record(LOCAL_PARTITION_ID, any(), any(), toolCall = false, reason = "tools_rejected_4xx") }
        verify(exactly = 0) { providerRepository.serviceFor(any<Provider>()) }
    }

    @Test
    fun `a failure after a tool ran keeps the finished step on the failed message`() = runTest {
        arrange()
        mcp.enqueue(
            McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"),
            McpScriptedTransport.stub("protocol/stateless/tools-call.response.json"),
        )
        answerWithRealLoop(
            listOf(listOf(toolCall("c1", OUTBOUND, "{\"city\":\"Melbourne\"}"))),
            failure = ProviderServiceError.Upstream(500, "upstream unavailable"),
        )
        val updates = mutableListOf<ChatMessage>()
        coEvery { conversationRepository.updateMessage(eq("conversation-1"), capture(updates)) } returns Unit

        repository().sendMessage(
            conversation = conversation(), text = "Weather?", provider = provider(), modelID = "relay-model",
            existingMessages = emptyList(), outputs = outputs(),
        )

        val last = updates.last()
        assertEquals(ChatMessageState.Failed, last.state)
        assertEquals(listOf("done"), last.toolSteps!!.map { it.status })
        assertEquals("the tool was called before the failing leg", 1, mcp.requests("tools/call").size)
    }

    private fun repository() = ChatRepository(
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        attachmentStore = attachmentStore,
        toolCallMemoryStore = memory,
        mcpChatToolRunner = mcpRunner,
    )

    private fun provider(): Provider {
        val model = AIModel(id = "relay-model", name = "Relay Model", promptPrice = 0.000001, completionPrice = 0.000002, toolCall = true)
        return Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            models = listOf(model),
        )
    }

    private fun conversation() = Conversation(
        id = "conversation-1", title = "MCP", providerID = "relay-1", providerKind = ProviderKind.Relay, modelID = "relay-model",
    )

    private fun outputs() = ConversationStreamingOutputs(
        streamingText = MutableStateFlow(""),
        streamingMessageId = MutableStateFlow(null),
    )

    private companion object {
        const val SERVER_ID = "aaaaaaaa-0000-4000-8000-000000000001"
        const val ENDPOINT = "https://mcp.example.com/mcp"
        const val OUTBOUND = "mcp_weather_get_weather"
    }
}
