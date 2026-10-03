package ai.oriveo.community.core.data.repository

import androidx.room.Room
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.mcp.InMemoryPrefs
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpConnectionState
import ai.oriveo.community.core.mcp.McpConnectionStatus
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.core.mcp.McpServerAddition
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.core.mcp.McpToolSnapshot
import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
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
import io.mockk.every
import io.mockk.mockk
import java.util.Collections
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
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
 * When the outbound request body must **not** contain MCP tools.
 *
 * The assertions look at the request body the production path actually sends: the real
 * `ChatRepository.sendMessage` -> the real `McpChatToolRunner` (a real Room database holding one enabled server
 * with one tool) -> the real leg runner or provider service -> the bytes received by the Ktor MockEngine.
 * A control case first proves that this setup does emit `mcp_` when it should; without it the
 * "contains no `mcp_`" cases below would prove nothing.
 */
@RunWith(RobolectricTestRunner::class)
class ChatRepositoryMcpOutboundTest {

    private lateinit var db: OriveoDatabase
    private lateinit var store: McpServerStore
    private lateinit var runner: McpChatToolRunner
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val requests: MutableList<Pair<String, String>> = Collections.synchronizedList(mutableListOf())
    private val providerRepository = mockk<ProviderRepository>(relaxed = true)

    private val client = HttpClient(
        MockEngine { request ->
            val path = request.url.encodedPath
            requests += path to bodyText(request)
            when {
                path.endsWith("/images/generations") -> respond(
                    """{"created":1,"data":[{"b64_json":"aGk="}]}""",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
                else -> respond(
                    ProviderTestFixtures.openAiStream(
                        ProviderTestFixtures.openAiChunk(delta = "hello", model = "m"),
                        ProviderTestFixtures.openAiChunk(promptTokens = 5, completionTokens = 2, model = "m"),
                    ),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        },
    )

    private fun bodyText(request: HttpRequestData): String = when (val body = request.body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().toString(Charsets.UTF_8)
        else -> ""
    }

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        val credentials = McpCredentialStore(InMemoryPrefs())
        store = McpServerStore(db.mcpServerDao(), credentials)
        runner = McpChatToolRunner(
            httpClient = client,
            json = json,
            store = store,
            credentialStore = credentials,
            mcpTransport = { McpScriptedTransport() },
        )
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { providerRepository.currentCapabilityPartitionId() } returns LOCAL_PARTITION_ID
        runBlocking {
            store.addServer(
                McpServerAddition(
                    id = SERVER, name = "Linear", url = "https://linear.example.com/mcp", authKind = McpAuthKind.Auto,
                    localOnly = false, iconURL = null, createdAt = 1L,
                    snapshots = listOf(
                        McpToolSnapshot(
                            serverId = SERVER, toolName = "search", title = "Search", description = "Search issues",
                            inputSchema = buildJsonObject { put("type", "object") },
                            annotations = buildJsonObject { put("readOnlyHint", true) },
                            contentHash = mcpSha256Hex("search"), readOnly = true, updatedAt = 1L,
                        ),
                    ),
                    permissions = mapOf("search" to McpToolPermission.Auto),
                    connectionState = McpConnectionState(SERVER, McpConnectionStatus.Connected),
                ),
                maxServers = 20,
            )
            // This conversation has the server switched on: whenever the connection allows it, the request carries `mcp_linear_search`.
            store.setServerEnabled(true, CONVERSATION, SERVER)
        }
    }

    @After
    fun tearDown() {
        db.close()
    }

    private fun repository() = ChatRepository(
        conversationRepository = mockk(relaxed = true),
        providerRepository = providerRepository,
        attachmentStore = mockk<AttachmentStore>(relaxed = true),
        mcpChatToolRunner = runner,
    )

    private suspend fun send(provider: Provider, modelId: String, conversationId: String = CONVERSATION) {
        repository().sendMessage(
            conversation = Conversation(id = conversationId, title = "MCP", providerID = provider.id, providerKind = provider.kind, modelID = modelId),
            text = "Find the open bugs",
            provider = provider,
            modelID = modelId,
            existingMessages = emptyList(),
            // Relay tool-call decisions are scoped by connection identity: production gets it from the chat screen, here it is fixed.
            requestOptions = ChatRequestOptions(
                capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
                    partitionId = LOCAL_PARTITION_ID, connectionInstanceId = "relay-1", connectionGeneration = "g1", credentialEpoch = "c1",
                    providerKind = ProviderKind.Relay.rawValue, metadataRevision = "m1", generationRevision = "g1",
                ),
            ),
            outputs = ConversationStreamingOutputs(streamingText = MutableStateFlow(""), streamingMessageId = MutableStateFlow(null)),
        )
    }

    private fun relay(model: AIModel) = Provider(
        id = "relay-1", kind = ProviderKind.Relay, status = ProviderConnectionState.Connected, apiKey = "local-key",
        baseUrlText = "https://relay.test/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions), models = listOf(model),
    ).also { every { providerRepository.serviceFor(it) } returns RelayService(client, json, TransportRegistry(json)) }

    private fun bodies(pathSuffix: String) = requests.toList().filter { it.first.endsWith(pathSuffix) }.map { it.second }

    private fun assertNoMcp(label: String) {
        assertTrue("$label - at least one request was sent", requests.isNotEmpty())
        for ((path, body) in requests.toList()) {
            assertFalse("$label - the request body for $path contains an MCP tool - $body", body.contains("mcp_"))
        }
    }

    /** Control: own connection, a model that supports tool calls, a server switched on -> the request body really carries the MCP tool. */
    @Test
    fun `control - a connection that may carry tools sends the mcp tool in the request body`() = runBlocking {
        send(relay(AIModel(id = "relay-model", name = "Relay Model", toolCall = true)), "relay-model")

        val chat = bodies("/chat/completions")
        assertTrue("a chat request was sent - $requests", chat.isNotEmpty())
        assertTrue("carries mcp_linear_search - ${chat.first()}", chat.first().contains("\"mcp_linear_search\""))
    }

    @Test
    fun `a conversation with no server switched on sends no mcp tool`() = runBlocking {
        send(relay(AIModel(id = "relay-model", name = "Relay Model", toolCall = true)), "relay-model", conversationId = "another-conversation")

        assertTrue(bodies("/chat/completions").isNotEmpty())
        assertNoMcp("a conversation with no server switched on")
    }

    @Test
    fun `image generation does not go through the tool loop and carries no mcp tool`() = runBlocking {
        val model = AIModel(
            id = "gpt-image-1", name = "Image", toolCall = true, capabilities = listOf(ModelCapability.ImageGen),
        )

        send(relay(model), model.id)

        assertEquals("went to the image endpoint - $requests", 1, bodies("/images/generations").size)
        assertTrue("did not go through the chat tool loop", bodies("/chat/completions").isEmpty())
        assertNoMcp("image generation")
    }

    private companion object {
        const val SERVER = "aaaaaaaa-0000-4000-8000-000000000001"
        const val CONVERSATION = "conversation-1"
    }
}
