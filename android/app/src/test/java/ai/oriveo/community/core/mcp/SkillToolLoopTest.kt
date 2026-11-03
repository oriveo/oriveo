package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.library.LibraryAgentLoop
import ai.oriveo.community.core.library.LibraryChatResearchRunner
import ai.oriveo.community.core.library.LibraryListResponse
import ai.oriveo.community.core.library.LibraryProvider
import ai.oriveo.community.core.library.LibraryQuota
import ai.oriveo.community.core.library.LibraryReadResponse
import ai.oriveo.community.core.library.LibrarySearchResponse
import ai.oriveo.community.core.library.LibraryToolClient
import ai.oriveo.community.core.library.LibraryToolsUnsupportedError
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LibraryConfirmationChoice
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillKnowledgeRetrievalContext
import ai.oriveo.community.core.model.SkillKnowledgeSnippet
import ai.oriveo.community.core.model.SkillKnowledgeUsage
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.model.UsedSkill
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.skills.SkillChannel
import ai.oriveo.community.core.skills.SkillRuntime
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolExecutionContext
import ai.oriveo.community.core.tools.ToolExecutionOutcome
import ai.oriveo.community.core.tools.ToolLoopLegEvent
import ai.oriveo.community.core.tools.ToolLoopLegRequest
import ai.oriveo.community.core.tools.ToolLoopLegRunning
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolCallDelta
import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolLoopToolFunction
import ai.oriveo.community.core.tools.ToolRegistryEntry
import ai.oriveo.community.core.tools.ToolScope
import ai.oriveo.community.core.usage.BudgetAlertChecker
import ai.oriveo.community.core.usage.UsageReporter
import ai.oriveo.community.feature.chat.SkillTurn
import ai.oriveo.community.feature.chat.SkillTurnInputs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.util.ArrayDeque
import java.util.Collections
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P3 contract 12 / 13 / 18: oriveo_use_skill joins the shared tool loop (MCP, web search, library) with the same
 * step limit, and a tools rejection on the first leg resends once without tools through the marker gate.
 * The skill entry under test is the one production builds ([SkillTurn.toolEntry]).
 */
class SkillToolLoopTest {

    private val mcp = McpScriptedTransport()
    private val steps: MutableList<McpToolStepUpdate> = Collections.synchronizedList(mutableListOf())
    private val used = mutableListOf<Pair<String, String>>()

    private fun skill(n: Int) = Skill(
        id = "AAAAAAAA-AAAA-AAAA-AAAA-00000000000$n",
        name = "Skill $n",
        systemPrompt = "Follow rule $n.",
        whenToUse = "When rule $n applies",
        autoInvoke = true,
    )

    private val writer = skill(1)
    private val writerId = SkillRuntime.canonicalId(writer.id)

    private fun retrieval(skill: Skill) = SkillKnowledgeRetrievalContext(
        snippets = listOf(SkillKnowledgeSnippet(fileId = "f1", fileName = "guide.md", text = "Knowledge for ${skill.name}", score = 0.9)),
        usage = SkillKnowledgeUsage(promptTokens = 7, completionTokens = 0, totalTokens = 7),
        estimatedCost = 0.25,
        providerId = "openai-1",
        modelId = "text-embedding-3-small",
    )

    private fun turn(
        skills: List<Skill> = listOf(writer),
        channel: SkillChannel = SkillChannel.TOOL,
        resendLoaded: MutableList<List<String>> = mutableListOf(),
        withRetrieval: Boolean = false,
    ): SkillTurn {
        val runtime = skills.map(SkillTurn::runtimeSkill)
        return SkillTurn(
            channel = channel,
            manifestIds = skills.map { SkillRuntime.canonicalId(it.id) }.sorted(),
            attachedSkills = emptyList(),
            skills = skills,
            resendInputs = { loaded ->
                resendLoaded += loaded
                SkillTurnInputs(skillPrompt = "Resent with skill.", knowledgeFiles = emptyList(), retrieval = null)
            },
            recordUsed = { id, via -> used += id to via },
            markerInputs = {
                val marker = SkillRuntime.buildManifest(runtime, emptyList(), emptyList(), true, SkillChannel.MARKER, emptyList())
                SkillTurnInputs(skillPrompt = marker.skillPrompt, knowledgeFiles = emptyList(), retrieval = null)
            },
            toolRetrieve = { skill -> if (withRetrieval) retrieval(skill) else null },
        )
    }

    // -- loop scaffolding (same shape as McpToolBridgeTest) --

    private fun weatherPlan() = McpToolBridge.plan(
        listOf(
            McpBridgeServerInput(
                record = McpServerRecord(WEATHER_ID, "Weather", "weather", MCP_ENDPOINT, McpAuthKind.Auto, false, null, 1L, 1L),
                endpoint = McpServerEndpointResolution.Ready(MCP_ENDPOINT),
                connectionStatus = McpConnectionStatus.Connected,
                snapshots = listOf(
                    McpToolSnapshot(
                        serverId = WEATHER_ID,
                        toolName = "get_weather",
                        title = "get_weather",
                        description = "Tool get_weather",
                        inputSchema = buildJsonObject {
                            put("type", "object")
                            put("properties", JsonObject(listOf("city").associateWith { buildJsonObject { put("type", "string") } }))
                            put("required", JsonArray(emptyList<JsonPrimitive>()))
                        },
                        annotations = buildJsonObject { put("readOnlyHint", true) },
                        contentHash = mcpSha256Hex("$WEATHER_ID:get_weather"),
                        readOnly = true,
                        updatedAt = 1L,
                    ),
                ),
                permissions = mapOf("get_weather" to McpToolPermission.Auto),
            ),
        ),
        McpRuntimeConfig.fallback,
    )

    private fun executor() = McpToolExecutor(
        conversationId = "conversation-1",
        gate = McpDenyingConfirmationGate,
        grants = McpConversationGrants(),
        tokenProvider = { null },
        makeClient = { McpClient(endpoint = it, transport = mcp) },
        onStep = { steps += it },
    )

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

    private fun useSkill(id: String, skillId: String, reason: String = "fits") =
        Triple(id, SkillRuntime.TOOL_NAME, """{"skill_id":"$skillId","reason":"$reason"}""")

    private fun toolResults(legs: ScriptedLegs, leg: Int): Map<String, String> =
        legs.requests[leg].messages.filter { it.role == "tool" }.associate { it.toolCallId.orEmpty() to it.textContent.orEmpty() }

    private suspend fun runLoop(
        legs: ScriptedLegs,
        skillEntry: ToolRegistryEntry?,
        plan: McpToolPlan = McpToolPlan.Empty,
        webSearchEntry: ToolRegistryEntry? = null,
        config: McpRuntimeConfig = McpRuntimeConfig(maxSteps = 8),
    ): ToolCallLoop.Result = McpChatToolRunner.makeLoop(
        plan, executor(), legs, config, webSearchEntry = webSearchEntry, skillEntry = skillEntry,
    ) { }.run(listOf(ToolLoopMessage("user", "Help me write?")))

    private class FakeWebSearch : ToolRegistryEntry {
        var calls = 0
        override val name: String = "web_search"
        override val scope: ToolScope = ToolScope.Web
        override val definition = ToolLoopToolDefinition(
            function = ToolLoopToolFunction("web_search", "Search the web", buildJsonObject { put("type", "object") }),
        )

        override suspend fun execute(call: ToolLoopToolCall, context: ToolExecutionContext): ToolExecutionOutcome {
            calls += 1
            return ToolExecutionOutcome("web results")
        }
    }

    private class FakeLibraryClient : LibraryToolClient {
        var searches = 0

        override suspend fun search(query: String, sources: List<String>, limit: Int, toolCallId: String?): LibrarySearchResponse {
            searches += 1
            return LibrarySearchResponse(quota = LibraryQuota())
        }

        override suspend fun list(source: String, containerId: String?, cursor: String?, toolCallId: String?) =
            LibraryListResponse(quota = LibraryQuota())

        override suspend fun read(docId: String, source: String, section: String?, cursor: String?, toolCallId: String?): LibraryReadResponse =
            error("not used")
    }

    // -- loop cases --

    @Test
    fun `skill and mcp share one loop request and only the mcp call becomes a tool step`() = runBlocking {
        mcp.enqueue(
            McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"),
            McpScriptedTransport.stub("protocol/stateless/tools-call.response.json"),
        )
        val turn = turn()
        val legs = ScriptedLegs(
            listOf(
                toolLeg(Triple("w1", WEATHER_OUTBOUND, """{"city":"Melbourne"}"""), useSkill("k1", writerId)),
                textLeg("Done."),
            ),
        )

        val result = runLoop(legs, turn.toolEntry(), plan = weatherPlan())

        assertEquals("Done.", result.text)
        assertEquals(listOf(WEATHER_OUTBOUND, SkillRuntime.TOOL_NAME), legs.requests.first().tools.map { it.function.name })
        val fed = toolResults(legs, 1)
        assertTrue(fed.getValue("k1").contains("<oriveo-skill name=\"Skill 1\">\nFollow rule 1.\n</oriveo-skill>"))
        assertEquals(1, mcp.requests("tools/call").size)
        assertTrue("skill calls never become tool steps", steps.none { it.id == "k1" })
        assertEquals(setOf(McpToolStepUpdate.Status.Running, McpToolStepUpdate.Status.Done), steps.map { it.status }.toSet())
        assertEquals(2, steps.size)
    }

    @Test
    fun `web search and skill share the loop with the skill tool registered after web_search`() = runBlocking {
        val web = FakeWebSearch()
        val legs = ScriptedLegs(
            listOf(toolLeg(Triple("s1", "web_search", "{}"), useSkill("k1", writerId)), textLeg("Searched.")),
        )

        val result = runLoop(legs, turn().toolEntry(), webSearchEntry = web)

        assertEquals("Searched.", result.text)
        assertEquals(listOf("web_search", SkillRuntime.TOOL_NAME), legs.requests.first().tools.map { it.function.name })
        assertEquals(1, web.calls)
        assertTrue(toolResults(legs, 1).getValue("k1").startsWith("Skill \"Skill 1\" loaded."))
    }

    @Test
    fun `library loop carries the skill entry after the library tools and keeps it out of library steps`() = runBlocking {
        val turn = turn()
        val legs = ScriptedLegs(
            listOf(
                toolLeg(useSkill("k1", writerId), Triple("s1", "library_search", """{"query":"plan"}""")),
                textLeg("Library answer."),
            ),
        )
        val library = FakeLibraryClient()
        val loop = LibraryAgentLoop(
            client = library,
            modelRunner = legs,
            activeSources = listOf(LibraryProvider.Notion),
            requestConfirmation = { LibraryConfirmationChoice.Continue },
            additionalEntries = listOfNotNull(turn.toolEntry()),
        )

        val result = loop.run(listOf(ToolLoopMessage("system", LibraryAgentLoop.SAFETY_PROMPT), ToolLoopMessage("user", "Plan?")))

        assertEquals("Library answer.", result.text)
        assertEquals(
            listOf("library_search", "library_list", "library_read", SkillRuntime.TOOL_NAME),
            legs.requests.first().tools.map { it.function.name },
        )
        assertEquals(1, library.searches)
        assertTrue(toolResults(legs, 1).getValue("k1").startsWith("Skill \"Skill 1\" loaded."))
        assertTrue(result.steps.none { it.tool == SkillRuntime.TOOL_NAME })
        assertEquals(listOf(writer.id), turn.loadedSkills.map { it.id })
    }

    @Test
    fun `a skill call in the loop records the auto use with its reason and retrieval`() = runBlocking {
        val turn = turn(withRetrieval = true)
        val legs = ScriptedLegs(listOf(toolLeg(useSkill("k1", writerId, reason = "user wants writing")), textLeg("Written.")))

        val result = runLoop(legs, turn.toolEntry())

        assertEquals("Written.", result.text)
        assertEquals(listOf(SkillRuntime.TOOL_NAME), legs.requests.first().tools.map { it.function.name })
        val definition = legs.requests.first().tools.single().function.parameters.toString()
        assertTrue(definition.contains(writerId))
        val fed = toolResults(legs, 1).getValue("k1")
        assertTrue(fed.contains("<entry name=\"guide.md\">Knowledge for Skill 1</entry>"))
        assertEquals(
            listOf(UsedSkill(id = writer.id, name = "Skill 1", via = SkillTurn.VIA_AUTO, reason = "user wants writing")),
            turn.usedSkills(),
        )
        assertEquals(listOf(writer.id), turn.toolRetrievals.map { it.skillId })
        assertEquals(0.25, turn.toolRetrievals.single().estimatedCost, 0.0)
        turn.recordAutoUses()
        assertEquals(listOf(writer.id to "auto"), used)
        assertTrue(steps.isEmpty())
    }

    @Test
    fun `the fourth skill of one answer gets limit_reached and is not loaded`() = runBlocking {
        val skills = (1..4).map(::skill)
        val turn = turn(skills)
        val ids = skills.map { SkillRuntime.canonicalId(it.id) }
        val legs = ScriptedLegs(
            listOf(
                toolLeg(*ids.mapIndexed { i, id -> useSkill("k${i + 1}", id) }.toTypedArray()),
                textLeg("Answer."),
            ),
        )

        runLoop(legs, turn.toolEntry())

        val fed = toolResults(legs, 1)
        assertEquals("Error: at most 3 skills can be loaded for one answer. Continue with the ones already loaded.", fed.getValue("k4"))
        assertEquals(skills.take(3).map { it.id }, turn.loadedSkills.map { it.id })
    }

    @Test
    fun `skill calls count toward the shared step limit instead of getting their own`() = runBlocking {
        val web = FakeWebSearch()
        val turn = turn()
        val legs = ScriptedLegs(listOf(toolLeg(Triple("s1", "web_search", "{}"), useSkill("k1", writerId)), textLeg("Summary.")))

        val result = runLoop(legs, turn.toolEntry(), webSearchEntry = web, config = McpRuntimeConfig(maxSteps = 1))

        assertTrue(result.stepLimitReached)
        assertEquals(1, web.calls)
        assertFalse(toolResults(legs, 1).getValue("k1").contains("<oriveo-skill"))
        assertTrue(turn.loadedSkills.isEmpty())
    }

    // -- channel choice and 4xx fallback through ChatRepository.sendMessage --

    private class RepositorySend(
        val turn: SkillTurn,
        val resendLoaded: List<List<String>>,
        val loopSkillEntries: List<ToolRegistryEntry?>,
        val sentOptions: List<ChatRequestOptions>,
        val memory: ToolCallMemoryStore,
        val mcpRunner: McpChatToolRunner,
        val conversationRepository: ConversationRepository,
        val provider: Provider,
        val tailTransports: List<ai.oriveo.community.core.data.repository.TransportInput>,
    )

    /** Sends one turn with a tool-channel skill (the tool verdict allowed it); the plain stream answers with a marker hit. */
    private suspend fun sendThroughRepository(
        plan: McpToolPlan,
        resendLeg: Flow<StreamEvent> = flowOf(StreamEvent.Delta("Loaded answer"), StreamEvent.Done(ProviderChatResult(text = "Loaded answer"))),
        memoryPropose: ai.oriveo.community.core.memory.MemoryProposeSendHook? = null,
    ): RepositorySend {
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        val providerRepository = mockk<ProviderRepository>()
        val memory = mockk<ToolCallMemoryStore>(relaxed = true)
        val mcpRunner = mockk<McpChatToolRunner>()
        val service = mockk<ProviderService>()
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { providerRepository.currentCapabilityPartitionId() } returns "user-1"
        every { providerRepository.serviceFor(any<Provider>(), any()) } returns service
        coEvery { mcpRunner.plan(any(), any(), any(), any(), any()) } returns plan
        every { mcpRunner.clearStepLimitReached(any()) } returns Unit
        val loopSkillEntries = mutableListOf<ToolRegistryEntry?>()
        coEvery {
            mcpRunner.run(
                any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(),
                captureNullable(loopSkillEntries),
            )
        } throws LibraryToolsUnsupportedError(ProviderServiceError.Upstream(400, "tools is not supported"))
        val sentOptions = mutableListOf<ChatRequestOptions>()
        every {
            service.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), capture(sentOptions))
        } returnsMany listOf(
            flowOf(StreamEvent.Delta("\u27e6skill:$writerId|fits\u27e7"), StreamEvent.Done(ProviderChatResult(text = "\u27e6skill:$writerId|fits\u27e7"))),
            resendLeg,
        )
        val tailTransports = mutableListOf<ai.oriveo.community.core.data.repository.TransportInput>()
        every {
            mcpRunner.proposeTailLeg(any(), any(), any(), capture(tailTransports), any(), any(), any())
        } returns flowOf(ToolLoopLegEvent.TextDelta("Tail answer"))
        val resendLoaded = mutableListOf<List<String>>()
        val turn = turn(resendLoaded = resendLoaded)
        val provider = Provider(
            id = "official-openai",
            kind = ProviderKind.OpenAI,
            apiKey = "local-key",
            models = listOf(AIModel(id = MANUAL_MODEL, name = MANUAL_MODEL, isManual = true)),
        )
        val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            usageReporter = mockk<UsageReporter>(relaxed = true),
            budgetAlertChecker = mockk<BudgetAlertChecker>(relaxed = true),
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            libraryChatResearchRunner = mockk<LibraryChatResearchRunner>(),
            toolCallMemoryStore = memory,
            mcpChatToolRunner = mcpRunner,
            relayNegativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L }),
        )

        repository.sendMessage(
            conversation = Conversation(
                id = "conversation-1", title = "Skills", providerID = provider.id, providerKind = provider.kind, modelID = MANUAL_MODEL,
            ),
            text = "Help me write?", provider = provider, modelID = MANUAL_MODEL,
            existingMessages = emptyList(),
            requestOptions = if (memoryPropose == null) {
                ChatRequestOptions()
            } else {
                ChatRequestOptions(
                    clientTools = listOf(ai.oriveo.community.core.context.MemoryPropose.tool),
                    clientToolChoice = ai.oriveo.community.core.tools.ToolLoopToolChoice.Auto,
                )
            },
            outputs = ConversationStreamingOutputs(streamingText = MutableStateFlow(""), streamingMessageId = MutableStateFlow(null)),
            skillTurn = turn,
            memoryPropose = memoryPropose,
        )
        return RepositorySend(
            turn, resendLoaded, loopSkillEntries, sentOptions, memory, mcpRunner, conversationRepository, provider, tailTransports,
        )
    }

    /** The first plain request went without tools, the skill list rendered for the marker channel, and the hit resent once. */
    private fun assertMarkerChannelAnswer(send: RepositorySend) {
        assertEquals(2, send.sentOptions.size)
        val markerSend = send.sentOptions.first()
        assertTrue(markerSend.clientTools.isEmpty())
        assertTrue(markerSend.systemPrompt.orEmpty().contains(SkillRuntime.MARKER_NOTE))
        assertFalse(markerSend.systemPrompt.orEmpty().contains(SkillRuntime.TOOL_NOTE))
        assertEquals(listOf(listOf(writerId)), send.resendLoaded)
        assertEquals(SkillChannel.MARKER, send.turn.channel)
        val updates = mutableListOf<ChatMessage>()
        coVerify { send.conversationRepository.updateMessage(eq("conversation-1"), capture(updates)) }
        assertEquals(ChatMessageState.Delivered, updates.last().state)
        assertEquals("Loaded answer", updates.last().text)
        assertEquals(listOf(writer.id to "auto"), updates.last().usedSkills.map { it.id to it.via })
    }

    @Test
    fun `skill only stays on the plain stream through the marker channel even when tools are supported`() = runTest {
        val send = sendThroughRepository(McpToolPlan.Empty)

        // No MCP tools, web_search tool or library agent: the skill alone never starts a tool loop.
        coVerify(exactly = 0) {
            send.mcpRunner.run(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
        }
        assertTrue(send.loopSkillEntries.isEmpty())
        verify(exactly = 0) { send.memory.record(any(), any(), any(), observedToolCall = any(), reason = any()) }
        assertMarkerChannelAnswer(send)
    }

    @Test
    fun `tools 4xx on the skill loop records the negative cache and resends once through the marker gate`() = runTest {
        val send = sendThroughRepository(weatherPlan())

        // The MCP loop got the skill entry, its first leg was rejected, and the rejection went to the existing negative cache.
        assertEquals(SkillRuntime.TOOL_NAME, send.loopSkillEntries.single()?.name)
        verify(exactly = 1) {
            send.memory.record("user-1", send.provider, match { it.id == MANUAL_MODEL }, observedToolCall = false, reason = "tools_rejected_4xx")
        }
        coVerify(exactly = 1) {
            send.mcpRunner.run(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
        }
        // Resend without tools, skill list rendered for the marker channel; the marker hit then loads the skill once.
        assertMarkerChannelAnswer(send)
    }

    @Test
    fun markerHitProposeMemoryTailUsesResend() = runTest {
        // Marker hit on the first leg, the resend only calls propose_memory, then the tail leg answers.
        val proposeLeg = flowOf(
            StreamEvent.ToolCallDeltas(
                listOf(
                    ai.oriveo.community.core.model.ToolCallDelta(
                        index = 0, id = "call_1", type = "function",
                        name = ai.oriveo.community.core.context.MemoryPropose.TOOL_NAME,
                        arguments = "{\"proposition\":\"Writes in Kotlin\",\"kind\":\"fact\",\"scope\":\"global\",\"sourceQuote\":\"hi\"}",
                    ),
                ),
            ),
            StreamEvent.Done(
                ProviderChatResult(text = ""),
                ai.oriveo.community.core.context.StreamFinish(
                    ai.oriveo.community.core.context.StopFamily.OPENAI_CHAT,
                    ai.oriveo.community.core.context.StreamEnding.CLEAN,
                    "tool_calls",
                ),
            ),
        )
        val proposals = mutableListOf<String>()
        val hook = object : ai.oriveo.community.core.memory.MemoryProposeSendHook {
            override suspend fun onProposeCall(argumentsJson: String) {
                proposals += argumentsJson
            }
            override suspend fun onToolsRejected() = Unit
        }

        val send = sendThroughRepository(McpToolPlan.Empty, resendLeg = proposeLeg, memoryPropose = hook)

        assertEquals(2, send.sentOptions.size)
        assertTrue(send.sentOptions.first().systemPrompt.orEmpty().contains(SkillRuntime.MARKER_NOTE))
        assertEquals(1, proposals.size)
        // The tail leg continues the resent request: loaded skill system, no skill list and no marker note.
        val tailSystem = send.tailTransports.single().options.systemPrompt.orEmpty()
        assertTrue("tail system carries the loaded skill: $tailSystem", tailSystem.contains("Resent with skill."))
        assertFalse("tail system drops the marker note", tailSystem.contains(SkillRuntime.MARKER_NOTE))
        assertFalse("tail system drops the skill list", tailSystem.contains("<oriveo-skills>"))
        val updates = mutableListOf<ChatMessage>()
        coVerify { send.conversationRepository.updateMessage(eq("conversation-1"), capture(updates)) }
        assertEquals(ChatMessageState.Delivered, updates.last().state)
        assertFalse(updates.last().text.contains("\u27e6skill"))
        assertEquals("Tail answer", updates.last().text)
        assertEquals(listOf(writer.id to "auto"), updates.last().usedSkills.map { it.id to it.via })
    }

    private companion object {
        const val WEATHER_ID = "aaaaaaaa-0000-4000-8000-000000000001"
        const val MCP_ENDPOINT = "https://mcp.example.com/mcp"
        const val WEATHER_OUTBOUND = "mcp_weather_get_weather"
        const val MANUAL_MODEL = "my-handfilled-model"
    }
}
