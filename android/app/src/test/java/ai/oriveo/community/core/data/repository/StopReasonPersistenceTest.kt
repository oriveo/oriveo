package ai.oriveo.community.core.data.repository

import androidx.room.Room
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.ContextMemoryItem
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.data.entity.MessageEntity
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
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.streaming.StreamRequest
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Persistence contract: the assistant message gets its stopReason when it is finalized.
 *
 * Everything goes through the production finalization path: the real [ChatRepository.sendMessage] (or the startup sanitize)
 * -> the real [ConversationRepository] -> a real Room; the assertions read back the column from [ai.oriveo.community.core.data.dao.MessageDao].
 * In the relay / MCP cases the stream is the raw wire text given by MockEngine, parsed by the real service.
 */
@RunWith(RobolectricTestRunner::class)
class StopReasonPersistenceTest {

    private lateinit var db: OriveoDatabase
    private lateinit var conversations: ConversationRepository
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val providerRepository = mockk<ProviderRepository>(relaxed = true)
    private val sseHeaders = headersOf(HttpHeaders.ContentType, "text/event-stream")
    private val jsonHeaders = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString())

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        conversations = ConversationRepository(
            conversationDao = db.conversationDao(),
            messageDao = db.messageDao(),
        )
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { providerRepository.currentCapabilityPartitionId() } returns UID
    }

    @After
    fun tearDown() {
        db.close()
    }

    private fun repository(mcpRunner: McpChatToolRunner? = null) = ChatRepository(
        conversationRepository = conversations,
        providerRepository = providerRepository,
        attachmentStore = mockk<AttachmentStore>(relaxed = true),
        mcpChatToolRunner = mcpRunner,
    )

    private suspend fun seedConversation(provider: Provider, modelId: String): Conversation {
        val conversation = Conversation(
            id = CONVERSATION, title = "Stop reason", providerID = provider.id, providerKind = provider.kind, modelID = modelId,
        )
        db.conversationDao().upsert(conversation.toEntity(UID))
        return conversation
    }

    private fun outputs() = ConversationStreamingOutputs(
        streamingText = MutableStateFlow(""),
        streamingMessageId = MutableStateFlow<String?>(null),
    )

    /** Sends one message through the real ChatRepository and returns the assistant row read back from the DAO after it is stored. */
    private suspend fun send(
        provider: Provider,
        modelId: String,
        repository: ChatRepository = repository(),
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
    ): MessageEntity {
        val conversation = seedConversation(provider, modelId)
        runCatching {
            repository.sendMessage(
                conversation = conversation,
                text = "hi",
                provider = provider,
                modelID = modelId,
                existingMessages = emptyList(),
                requestOptions = requestOptions,
                outputs = outputs(),
            )
        }
        return assistantRow()
    }

    private suspend fun assistantRow(): MessageEntity =
        db.messageDao().getByConversation(UID, CONVERSATION).maxBy { it.sortOrder }

    private fun assertStopReason(expected: StopReason, row: MessageEntity) {
        assertEquals("stopReason column for ${row.state} '${row.text}'", expected.wire, row.stopReason)
    }

    // ---------- Generic BYOK: a stub service emits events / throws directly ----------

    private fun scriptedProvider(stream: kotlinx.coroutines.flow.Flow<StreamEvent>): Provider {
        val provider = Provider(
            id = "openai-1", kind = ProviderKind.OpenAI, status = ProviderConnectionState.Connected, apiKey = "sk-test",
            models = listOf(AIModel(id = "gpt-test", name = "GPT Test")),
        )
        val service = mockk<ProviderService>(relaxed = true)
        every { service.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), any()) } returns stream
        every { providerRepository.serviceFor(provider, any()) } returns service
        return provider
    }

    @Test
    fun delivered_length() = runBlocking {
        val provider = relayProvider(
            sse(
                ProviderTestFixtures.openAiStream(
                    """data: {"choices":[{"delta":{"content":"Cut off at the token li"}}]}""",
                    """data: {"choices":[{"delta":{},"finish_reason":"length"}]}""",
                ),
            ),
        )

        val row = send(provider, RELAY_MODEL, requestOptions = relayOptions())

        assertEquals(ChatMessageState.Delivered.name, row.state)
        assertStopReason(StopReason.LENGTH, row)
    }

    @Test
    fun user_stop_interrupted() = runBlocking {
        val delivered = CompletableDeferred<Unit>()
        val provider = scriptedProvider(
            flow {
                emit(StreamEvent.Delta("Half an answer\n"))
                delivered.complete(Unit)
                awaitCancellation()
            },
        )
        val conversation = seedConversation(provider, "gpt-test")
        val job = async(Dispatchers.Default, start = CoroutineStart.DEFAULT) {
            repository().sendMessage(
                conversation = conversation,
                text = "hi",
                provider = provider,
                modelID = "gpt-test",
                existingMessages = emptyList(),
                outputs = outputs(),
            )
        }
        withTimeout(10_000) { delivered.await() }
        // ChatStreamingManager.stopStream simply cancels the send coroutine
        job.cancel()
        runCatching { job.await() }

        val row = assistantRow()
        assertEquals(ChatMessageState.Interrupted.name, row.state)
        assertStopReason(StopReason.INTERRUPTED, row)
    }

    /** Shutdown goes through [ChatStreamingManager.stopAllStreamsAndJoin]: a system interruption is recorded as a transport error, not as interrupted. */
    private suspend fun systemInterrupt(stream: kotlinx.coroutines.flow.Flow<StreamEvent>, ready: CompletableDeferred<Unit>): MessageEntity {
        val provider = scriptedProvider(stream)
        val conversation = seedConversation(provider, "gpt-test")
        val manager = ChatStreamingManager(chatRepository = repository())
        manager.startStream(
            StreamRequest(conversation = conversation, text = "hi", provider = provider, modelID = "gpt-test", existingMessages = emptyList()),
        )
        withTimeout(10_000) { ready.await() }
        manager.stopAllStreamsAndJoin()
        return assistantRow()
    }

    @Test
    fun system_interrupt_logout_incomplete() = runBlocking {
        val withText = CompletableDeferred<Unit>()
        val row = systemInterrupt(
            flow {
                emit(StreamEvent.Delta("Half an answer\n"))
                withText.complete(Unit)
                awaitCancellation()
            },
            withText,
        )
        assertEquals("Half an answer", row.text)
        assertStopReason(StopReason.INCOMPLETE, row)

        db.messageDao().deleteByConversation(UID, CONVERSATION)
        val noText = CompletableDeferred<Unit>()
        val empty = systemInterrupt(
            flow {
                noText.complete(Unit)
                awaitCancellation()
            },
            noText,
        )
        assertStopReason(StopReason.ERROR, empty)
    }

    @Test
    fun transport_error_after_text() = runBlocking {
        val provider = scriptedProvider(
            flow {
                emit(StreamEvent.Delta("Partial body"))
                throw ProviderServiceError.Network("connection reset")
            },
        )

        val row = send(provider, "gpt-test")

        assertEquals(ChatMessageState.Failed.name, row.state)
        assertStopReason(StopReason.INCOMPLETE, row)
    }

    @Test
    fun transport_error_before_text() = runBlocking {
        val provider = scriptedProvider(flow { throw ProviderServiceError.Network("connection reset") })

        val row = send(provider, "gpt-test")

        assertEquals(ChatMessageState.Failed.name, row.state)
        assertStopReason(StopReason.ERROR, row)
    }

    // ---------- Relay (OpenAI-compatible stream parsed by the real service) ----------

    private fun sse(body: String) = body

    private fun relayProvider(streamBody: String): Provider {
        val client = HttpClient(
            MockEngine { respond(streamBody, HttpStatusCode.OK, sseHeaders) },
        )
        val provider = Provider(
            id = "relay-stream", kind = ProviderKind.Relay, status = ProviderConnectionState.Connected, apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            models = listOf(AIModel(id = RELAY_MODEL, name = "Relay")),
        )
        every { providerRepository.serviceFor(provider, any()) } returns RelayService(client, json, TransportRegistry(json))
        return provider
    }

    private fun relayOptions() = ChatRequestOptions(
        capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
            partitionId = UID, connectionInstanceId = "relay-stream", connectionGeneration = "g1", credentialEpoch = "c1",
            providerKind = ProviderKind.Relay.rawValue, metadataRevision = "m1", generationRevision = "g1",
            authMode = ProviderAuthMode.ApiKey.rawValue,
        ),
    )

    @Test
    fun relay_eof_without_done() = runBlocking {
        // A missing terminator means incomplete, not the error of a frame error. (The community edition has no Free provider, whose
        // empty-body EOF is recorded as incomplete by its own error type; a relay stream with no answer text is an empty response.)
        val provider = relayProvider(
            buildString {
                appendLine("""data: {"choices":[{"delta":{"content":"Half an answer"}}]}""")
            },
        )

        val row = send(provider, RELAY_MODEL, requestOptions = relayOptions())

        assertStopReason(StopReason.INCOMPLETE, row)
    }

    // ---------- MCP tool loop ----------

    @Test
    fun mcp_send_delivered_records_stop_reason() = runBlocking {
        val client = HttpClient(
            MockEngine {
                respond(
                    ProviderTestFixtures.openAiStream(
                        ProviderTestFixtures.openAiChunk(delta = "hello", model = "m"),
                        // The last round (and the only one) is cut off by length
                        """data: {"model":"m","choices":[{"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}""",
                    ),
                    HttpStatusCode.OK,
                    sseHeaders,
                )
            },
        )
        val credentials = McpCredentialStore(InMemoryPrefs())
        val store = McpServerStore(db.mcpServerDao(), credentials)
        val runner = McpChatToolRunner(
            httpClient = client, json = json, store = store, credentialStore = credentials,
            mcpTransport = { McpScriptedTransport() },
        )
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
        store.setServerEnabled(true, CONVERSATION, SERVER)
        val model = AIModel(id = "relay-model", name = "Relay Model", toolCall = true)
        val provider = Provider(
            id = "relay-1", kind = ProviderKind.Relay, status = ProviderConnectionState.Connected, apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions), models = listOf(model),
        )
        every { providerRepository.serviceFor(provider, any()) } returns RelayService(client, json, TransportRegistry(json))

        val row = send(
            provider,
            model.id,
            repository = repository(runner),
            requestOptions = ChatRequestOptions(
                capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
                    partitionId = UID, connectionInstanceId = "relay-1", connectionGeneration = "g1", credentialEpoch = "c1",
                    providerKind = ProviderKind.Relay.rawValue, metadataRevision = "m1", generationRevision = "g1",
                    authMode = ProviderAuthMode.ApiKey.rawValue,
                ),
            ),
        )

        assertEquals(ChatMessageState.Delivered.name, row.state)
        assertEquals("hello", row.text)
        // The tool loop stores the finish info of the last round
        assertStopReason(StopReason.LENGTH, row)
    }

    // ---------- Ids of the memory items injected into this answer (stored locally only) ----------

    private fun memoryContext(useMemory: Boolean, vararg items: Pair<String, String>) = ChatRequestOptions(
        chatContext = ChatContextRequest(
            conversation = ContextConversation(id = CONVERSATION, useMemory = useMemory),
            memoryItems = items.map { (id, kind) -> ContextMemoryItem(id = id, kind = kind, content = "Item $id.") },
        ),
    )

    @Test
    fun memory_item_ids_round_trip() = runBlocking {
        val provider = scriptedProvider(flow { emit(StreamEvent.Delta("Answer")); emit(StreamEvent.Done(ProviderChatResult(text = "Answer"))) })

        // Delivered: stored in the JSON column in plan injection order (standing first) and read back as the same list.
        val row = send(provider, "gpt-test", requestOptions = memoryContext(true, "f-1" to "fact", "i-1" to "instruction"))
        assertEquals(ChatMessageState.Delivered.name, row.state)
        assertEquals("""["i-1","f-1"]""", row.memoryItemIds)
        val delivered = conversations.getWithMessages(CONVERSATION)!!.messages.single { it.id == row.id }
        assertEquals(listOf("i-1", "f-1"), delivered.memoryItemIds)

        // A continue that injected no items keeps the ids the original message already has.
        continueAnswer(provider, delivered, memoryContext(false, "x-1" to "fact"))
        assertEquals(ChatMessageState.Delivered.name, messageRow(row.id).state)
        assertEquals("""["i-1","f-1"]""", messageRow(row.id).memoryItemIds)
        // A continue that injected new items overwrites them.
        continueAnswer(provider, delivered, memoryContext(true, "x-1" to "fact"))
        assertEquals("""["x-1"]""", messageRow(row.id).memoryItemIds)

        // No items injected: an empty list is stored as NULL.
        assertNull(send(provider, "gpt-test", requestOptions = memoryContext(false, "f-1" to "fact")).memoryItemIds)

        // A failed message whose stream errored does not record them.
        val failing = scriptedProvider(flow { emit(StreamEvent.Delta("Partial")); throw ProviderServiceError.Network("reset") })
        val failed = send(failing, "gpt-test", requestOptions = memoryContext(true, "f-1" to "fact"))
        assertEquals(ChatMessageState.Failed.name, failed.state)
        assertNull(failed.memoryItemIds)
    }

    @Test
    fun memory_item_ids_not_in_backup_payload() {
        val message = ChatMessage(
            id = ASSISTANT_ID, role = ChatRole.Assistant, text = "Answer", providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI", modelName = "gpt-test", state = ChatMessageState.Delivered,
            stopReason = StopReason.STOP, memoryItemIds = listOf("i-1", "f-1"),
        )

        // A backup export (ChatMessage serialization) does not carry them.
        val backup = json.encodeToString(ChatMessage.serializer(), message)
        assertFalse(backup.contains("memoryItemIds"))
        assertFalse(backup.contains("i-1"))
    }

    private suspend fun messageRow(id: String): MessageEntity =
        db.messageDao().getByConversation(UID, CONVERSATION).single { it.id == id }

    private suspend fun continueAnswer(provider: Provider, target: ChatMessage, requestOptions: ChatRequestOptions) {
        val conversation = conversations.getWithMessages(CONVERSATION)!!
        repository().sendMessage(
            conversation = conversation,
            text = ai.oriveo.community.core.context.ContextAssembler.CONTINUE_PROMPT,
            provider = provider,
            modelID = "gpt-test",
            existingMessages = conversation.messages,
            requestOptions = requestOptions,
            outputs = outputs(),
            persistUserMessage = false,
            userMessageAlreadyInHistory = false,
            appendToAssistant = target,
            attemptKind = ai.oriveo.community.feature.chat.ContextConfirmAttempt.CONTINUE,
        )
    }

    // ---------- Cold start ----------

    @Test
    fun cold_start_sanitize_records_incomplete_or_error() = runBlocking {
        val provider = Provider(
            id = "openai-1", kind = ProviderKind.OpenAI, status = ProviderConnectionState.Connected, apiKey = "sk-test",
        )
        seedConversation(provider, "gpt-test")
        listOf(ASSISTANT_ID to "Half written", EMPTY_ASSISTANT_ID to "").forEachIndexed { index, (id, text) ->
            db.messageDao().upsert(
                ChatMessage(
                    id = id, role = ChatRole.Assistant, text = text, reasoningText = "thought",
                    providerKind = ProviderKind.OpenAI, providerName = "OpenAI", modelName = "gpt-test",
                    state = ChatMessageState.Generating,
                ).toEntity(UID, CONVERSATION, index),
            )
        }

        conversations.sanitizeStaleGenerating()

        val rows = db.messageDao().getByConversation(UID, CONVERSATION).associateBy { it.id }
        assertEquals(ChatMessageState.Interrupted.name, rows.getValue(ASSISTANT_ID).state)
        assertStopReason(StopReason.INCOMPLETE, rows.getValue(ASSISTANT_ID))
        // Reasoning only, no answer text -> error
        assertStopReason(StopReason.ERROR, rows.getValue(EMPTY_ASSISTANT_ID))
    }

    private companion object {
        const val UID = LOCAL_PARTITION_ID
        const val CONVERSATION = "AAAAAAAA-0000-4000-8000-0000000000C1"
        const val ASSISTANT_ID = "AAAAAAAA-0000-4000-8000-0000000000A1"
        const val EMPTY_ASSISTANT_ID = "AAAAAAAA-0000-4000-8000-0000000000A2"
        const val SERVER = "aaaaaaaa-0000-4000-8000-000000000001"
        const val RELAY_MODEL = "relay-model"
    }
}
