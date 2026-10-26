package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpSafetyPrompt
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.mcp.McpToolPlan
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
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
import io.mockk.every
import io.mockk.mockk
import io.mockk.spyk
import java.util.Collections
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MCP agent legs carry a single system produced by the assembler
 * (purpose toolLoopLeg, tool safety as the last segment), byte-identical on every leg.
 *
 * Production path: real ChatRepository.sendMessage (with chatContext) → real
 * McpChatToolRunner.run; MockEngine captures every leg body.
 */
class ContextPipelineToolLoopTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()
    /** Every [TransportInput] the production path handed to the MCP runner in the last [send]. */
    private val mcpTransports: MutableList<TransportInput> = Collections.synchronizedList(mutableListOf())

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun tool_loop_single_system_with_safety() = runTest {
        // MCP only: one system, MCP safety appended once as the last segment.
        val mcpOnly = systemsOf(send(mcp = true).first())
        assertEquals(1, mcpOnly.size)
        assertTrue(mcpOnly.single().contains(INSTRUCTIONS))
        assertTrue(mcpOnly.single().endsWith(McpSafetyPrompt.TEXT))
        assertEquals(1, Regex(Regex.escape(McpSafetyPrompt.TEXT)).findAll(mcpOnly.single()).count())
    }

    @Test
    fun tool_leg_transport_carries_plan_system_and_dynamic() = runTest {
        val legs = send(mcp = true, attachmentGuide = GUIDE)
        val transport = mcpTransports.single()
        // Expected values come from the production projector: purpose toolLoopLeg with the MCP safety segment.
        val options = ChatRequestOptions(activeModel = MODEL, capabilityEvidenceIdentity = IDENTITY)
        val expected = checkNotNull(
            ChatContextProjector.project(
                request = ChatContextRequest(
                    ContextConversation(id = CONVERSATION.id, useMemory = false, instructions = INSTRUCTIONS),
                    attachmentGuide = GUIDE,
                ),
                rawMessages = listOf(
                    ChatMessage(
                        id = "user-1",
                        role = ChatRole.User,
                        text = "Find the plan",
                        providerKind = ProviderKind.Relay,
                        providerName = "Relay",
                        modelName = MODEL.name,
                        state = ChatMessageState.Delivered,
                    ),
                ),
                window = ChatContextProjector.window(PROVIDER, MODEL, options),
                rhoHi = ContextBudget.RHO0,
                purpose = RequestPurpose.TOOL_LOOP_LEG,
                toolSafety = McpSafetyPrompt.TEXT,
            ),
        )
        val planSystem = checkNotNull(expected.plan.system)
        val dynamic = checkNotNull(expected.planned.dynamicText)
        assertTrue(dynamic.contains(GUIDE))

        // First leg, first message: the toolLoopLeg plan system, byte for byte.
        val first = (legs.first()["messages"] as JsonArray).first().jsonObject
        assertEquals("system", first["role"]?.jsonPrimitive?.content)
        assertEquals(planSystem, textOf(first))
        // The transport carries the same plan system and the [D] of the current user.
        assertEquals(planSystem, transport.options.systemPrompt)
        assertEquals(dynamic, transport.options.dynamicText)
        assertTrue(transport.messages.last().text.endsWith("\n\n" + dynamic))
    }

    @Test
    fun tool_loop_first_leg_ignores_stored_checkpoint() = runTest {
        // stored checkpoint rows apply to purpose=chat only; the tool loop first leg keeps P2 history.
        val history = listOf(
            historyMessage("u0", ChatRole.User, "First question"),
            historyMessage("a0", ChatRole.Assistant, "First answer"),
        )
        val stored = ContextCheckpointRecord(
            conversationId = CONVERSATION.id,
            checkpointId = "checkpoint-1",
            kind = ContextCheckpointKind.FALLBACK,
            coversFrom = "u0",
            coversTo = "a0",
            coversDigest = "digest",
            messagesCovered = 2,
            userMessageIds = listOf("u0"),
            text = "<oriveo-context-checkpoint v=\"1\" covers=\"u0..a0\">\nsummary\n</oriveo-context-checkpoint>",
            summary = null,
            language = null,
            model = MODEL.id,
            packerVersion = "1",
            createdAt = 0L,
            cost = null,
        )
        val compaction = mockk<ContextCompactionCoordinator>(relaxed = true).also {
            coEvery { it.latestValid(CONVERSATION.id, any()) } returns stored
        }
        val first = send(mcp = true, existing = history, compaction = compaction).first()

        val turns = (first["messages"] as JsonArray).map { it.jsonObject }
            .filter { it["role"]?.jsonPrimitive?.content in setOf("user", "assistant") }
        val firstUser = textOf(turns.first())
        assertTrue("first user is not the stored checkpoint: ${firstUser.take(80)}", !firstUser.startsWith("<oriveo-context-checkpoint"))
        assertEquals("First question", firstUser)
        assertEquals("First answer", textOf(turns[1]))
        assertEquals(3, turns.size)
    }

    private fun historyMessage(id: String, role: ChatRole, text: String) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = PROVIDER.id,
        providerKind = PROVIDER.kind,
        providerName = "Relay",
        modelID = MODEL.id,
        modelName = MODEL.name,
        state = ChatMessageState.Delivered,
    )

    private fun systemsOf(body: JsonObject): List<String> = (body["messages"] as JsonArray)
        .map { it.jsonObject }
        .filter { it["role"]?.jsonPrimitive?.content == "system" }
        .map { textOf(it) }

    /** Sends one message through the tool loop route and returns every leg request body in order. */
    private suspend fun send(
        mcp: Boolean,
        attachmentGuide: String? = null,
        existing: List<ChatMessage> = emptyList(),
        compaction: ContextCompactionCoordinator? = null,
    ): List<JsonObject> {
        mcpTransports.clear()
        val bodies: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val paths: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val client = HttpClient(MockEngine { request ->
            val path = request.url.encodedPath
            paths += request.url.toString()
            if (path.endsWith("/chat/completions")) {
                bodies += bodyText(request.body)
                respond(
                    content = TEXT_LEG,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            } else {
                respond("{}", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            }
        }).also { openClients += it }

        val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            coEvery { it.getById(PROVIDER.id) } returns PROVIDER
            every { it.toolCallMemoryVerdict(any(), any()) } returns null
        }
        val mcpRunner = spyk(
            McpChatToolRunner(
                httpClient = client,
                json = json,
                store = mockk<McpServerStore>(relaxed = true),
                credentialStore = mockk<McpCredentialStore>(relaxed = true),
            ),
        )
        val plan = if (mcp) {
            mockk<McpToolPlan>().also {
                every { it.isEmpty } returns false
                every { it.tools } returns emptyList()
                every { it.truncated } returns false
            }
        } else {
            McpToolPlan.Empty
        }
        coEvery { mcpRunner.plan(any(), any(), any(), any(), any()) } returns plan
        coEvery { mcpRunner.run(any(), any(), any(), any(), any(), any(), any(), any(), any(), any()) } coAnswers {
            mcpTransports += arg<TransportInput>(4)
            callOriginal()
        }

        val saved: MutableList<ai.oriveo.community.core.model.ChatMessage> = Collections.synchronizedList(mutableListOf())
        val conversations = mockk<ConversationRepository>(relaxed = true).also {
            coEvery { it.updateMessage(any(), capture(saved)) } returns Unit
        }
        val repository = ChatRepository(
            conversationRepository = conversations,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            mcpChatToolRunner = mcpRunner,
            contextCompaction = compaction,
        )
        val failure = runCatching {
            repository.sendMessage(
                conversation = CONVERSATION,
                text = "Find the plan",
                provider = PROVIDER,
                modelID = MODEL.id,
                existingMessages = existing,
                requestOptions = ChatRequestOptions(
                    activeModel = MODEL,
                    capabilityEvidenceIdentity = IDENTITY,
                    chatContext = ChatContextRequest(
                        ContextConversation(id = CONVERSATION.id, useMemory = false, instructions = INSTRUCTIONS),
                        attachmentGuide = attachmentGuide,
                    ),
                ),
                outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow(null),
                ),
            )
        }.exceptionOrNull()
        failure?.let { if (it is AssertionError) throw it }

        return bodies.toList().map { json.parseToJsonElement(it).jsonObject }
            .also { assertTrue("no tool loop leg was sent: $failure $paths ${saved.map { it.errorTitle to it.errorDetail }}", it.isNotEmpty()) }
    }

    private fun textOf(item: JsonObject): String = when (val content = item["content"]) {
        is JsonPrimitive -> content.content
        is JsonArray -> content.map { it.jsonObject }
            .filter { it["type"]?.jsonPrimitive?.content == "text" }
            .joinToString("") { it["text"]?.jsonPrimitive?.content.orEmpty() }
        else -> ""
    }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> ""
    }

    private companion object {
        const val INSTRUCTIONS = "Answer in one paragraph."
        const val GUIDE = "Attachment guide for this turn."
        val TEXT_LEG = """
            data: {"choices":[{"delta":{"content":"Answer"}}]}

            data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}

            data: [DONE]
        """.trimIndent() + "\n\n"
        val MODEL = AIModel(id = "relay-model", name = "Relay Model", toolCall = true, contextLength = 64_000)
        val PROVIDER = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            apiKey = "local-relay-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            models = listOf(MODEL),
            catalogModels = listOf(MODEL),
        )
        val IDENTITY = CapabilityEvidenceIdentity(
            partitionId = "test-partition",
            connectionInstanceId = "relay-1",
            connectionGeneration = "1",
            credentialEpoch = "1",
            providerKind = ProviderKind.Relay.rawValue,
            authMode = ProviderAuthMode.ApiKey.rawValue,
            canonicalModelId = "relay-model",
        )
        val CONVERSATION = Conversation(
            id = "conversation-1",
            title = "Tools",
            providerID = "relay-1",
            providerKind = ProviderKind.Relay,
            modelID = MODEL.id,
            useMemory = false,
        )
    }
}
