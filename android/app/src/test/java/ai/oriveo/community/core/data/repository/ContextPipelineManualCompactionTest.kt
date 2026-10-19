package ai.oriveo.community.core.data.repository

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.CompactOutcome
import ai.oriveo.community.core.context.ContextCompactionBreaker
import ai.oriveo.community.core.context.ContextCompactionMode
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
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
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The manual compaction entry ChatRepository.compactConversationNow.
 *
 * Production path: the real ChatRepository -> the real coordinator (real Room database) -> the real AnthropicService, with MockEngine only capturing the request body.
 * Model W=16000 / output 8192 -> U=B=8000; the last message of the conversation is the current message and the rest is history.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class ContextPipelineManualCompactionTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()
    private lateinit var db: OriveoDatabase
    private lateinit var store: ContextCompactionStore

    @Before
    fun setUp() {
        val context: Context = RuntimeEnvironment.getApplication()
        db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        db.openHelper.writableDatabase.execSQL(
            "INSERT INTO conversations (id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                "accountId) " +
                "VALUES ('$CONVERSATION_ID', 'c', 0, 'p1', 'Anthropic', 'm1', 0, '', 0.0, 0, '', 0, 0, '$ACCOUNT')",
        )
        store = ContextCompactionStore(db.contextCheckpointDao())
    }

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
        db.close()
    }

    @Test
    fun manual_compaction_request_body_from_production() = runTest {
        // Preference off and the breaker already tripped: a manual run still uses the AI summary.
        val harness = Harness(aiSummary = false)
        harness.tripBreaker()
        assertEquals(ContextCompactionMode.FALLBACK_ONLY, harness.coordinator.breaker(CONVERSATION_ID).mode)
        val conversation = CONVERSATION.copy(useMemory = true, messages = longHistory(bytes = 1_500))
        harness.storedConversation = conversation
        // A context request on the same terms as a chat send (memory switch on, memory present).
        val chatContext = ChatContextRequest(
            ContextConversation(id = CONVERSATION_ID, useMemory = true),
            memoryItems = ChatContextRequest.memoryItems(
                useMemory = true,
                items = listOf(
                    ai.oriveo.community.core.context.MemoryItem(
                        id = "memory-1", kind = ai.oriveo.community.core.context.MemoryKind.FACT, content = MEMORY_TEXT,
                        mutationId = "mutation-1", deviceId = "device-1",
                    ),
                ),
                conversationId = CONVERSATION_ID,
                folderId = null,
                now = java.time.Instant.now(),
            ),
        )

        val result = harness.repository.compactConversationNow(CONVERSATION_ID, chatContext)

        val summary = harness.bodies.single()
        assertTrue("summary system carries the conversation memory: ${summary["system"]}", MEMORY_TEXT in summary["system"].toString())
        assertEquals("one-shot summary call, no chat request", "false", summary["stream"]?.jsonPrimitive?.content)
        assertFalse("summary request carries no tools", "tools" in summary)
        val (lastRole, lastText) = turnsOf(summary).last()
        assertEquals("user", lastRole)
        assertTrue("summary prompt closes the last user: ${lastText.takeLast(200)}", "CONTEXT CHECKPOINT" in lastText)
        val row = store.list(ACCOUNT, CONVERSATION_ID).single()
        assertEquals(ContextCheckpointKind.SUMMARY, row.kind)
        assertEquals(VALID_SUMMARY, row.summary)
        assertEquals(CompactOutcome.SUMMARY, result.outcome)
        assertEquals(row, result.row)
    }

    @Test
    fun manual_compaction_flag_off_uses_fallback() = runTest {
        val harness = Harness(aiSummary = true, remoteFlag = false)
        harness.storedConversation = CONVERSATION.copy(messages = longHistory(bytes = 1_600))

        val result = harness.repository.compactConversationNow(CONVERSATION_ID)

        assertTrue("remote flag off: no request leaves the device: ${harness.bodies}", harness.bodies.isEmpty())
        val row = store.list(ACCOUNT, CONVERSATION_ID).single()
        assertEquals(ContextCheckpointKind.FALLBACK, row.kind)
        assertEquals(CompactOutcome.FALLBACK, result.outcome)
        assertEquals(row, result.row)
    }

    @Test
    fun manual_compaction_without_conversation_is_noop() = runTest {
        val harness = Harness(aiSummary = true)

        harness.storedConversation = null
        val missing = harness.repository.compactConversationNow(CONVERSATION_ID)
        assertEquals(CompactOutcome.NOOP, missing.outcome)
        assertNull(missing.row)

        harness.storedConversation = CONVERSATION
        val empty = harness.repository.compactConversationNow(CONVERSATION_ID)
        assertEquals(CompactOutcome.NOOP, empty.outcome)
        assertNull(empty.row)

        harness.storedConversation = CONVERSATION.copy(providerID = "missing-provider", messages = longHistory(bytes = 1_500))
        val noModel = harness.repository.compactConversationNow(CONVERSATION_ID)
        assertEquals(CompactOutcome.NOOP, noModel.outcome)

        assertTrue("noop sends nothing: ${harness.bodies}", harness.bodies.isEmpty())
        assertTrue(store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
    }

    @Test
    fun manual_compaction_budget_matches_send() = runTest {
        // With the panel's max output at 2048, B is larger than with the model's default output (8192); when manual compaction and sending use the same terms, the cut point is the same.
        val options = ChatRequestOptions(
            activeModel = MODEL,
            generationParameters = GenerationParameterOverrides(
                mapOf("max_output_tokens" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(2_048))),
            ),
        )
        val history = (0 until 10).flatMap { i ->
            listOf(
                message("u$i", ChatRole.User, "user-$i " + "a".repeat(2_992)),
                message("a$i", ChatRole.Assistant, "assistant-$i " + "b".repeat(2_987)),
            )
        }
        val sender = Harness(aiSummary = false)
        sender.send("Next question", existing = history, generationParameters = options.generationParameters)
        val sent = store.list(ACCOUNT, CONVERSATION_ID).single()
        db.openHelper.writableDatabase.execSQL("DELETE FROM context_checkpoint")

        val manual = Harness(aiSummary = false, remoteFlag = false)
        manual.storedConversation = CONVERSATION.copy(
            messages = history + message("u-next", ChatRole.User, "Next question"),
        )
        val result = manual.repository.compactConversationNow(CONVERSATION_ID, requestOptions = options)

        assertEquals(CompactOutcome.FALLBACK, result.outcome)
        val row = store.list(ACCOUNT, CONVERSATION_ID).single()
        assertEquals(sent.coversTo, row.coversTo)
        assertEquals(sent.checkpointId, row.checkpointId)
        assertEquals(sent.text, row.text)
    }

    // ── harness ──

    private fun longHistory(bytes: Int): List<ChatMessage> = (0 until 5).flatMap { i ->
        listOf(
            message("u$i", ChatRole.User, "user-$i " + "a".repeat(bytes - 8)),
            message("a$i", ChatRole.Assistant, "assistant-$i " + "b".repeat(bytes - 13)),
        )
    }

    private inner class Harness(aiSummary: Boolean, remoteFlag: Boolean = true) {
        val bodies = mutableListOf<JsonObject>()
        var storedConversation: Conversation? = null
        private val client = HttpClient(MockEngine { request ->
            val body = json.parseToJsonElement(bodyText(request.body)).jsonObject
            bodies += body
            if (body["stream"]?.jsonPrimitive?.content == "false") {
                val reply = buildJsonObject {
                    put("content", buildJsonArray { add(buildJsonObject { put("type", "text"); put("text", "  $VALID_SUMMARY\n") }) })
                    put("usage", buildJsonObject { put("input_tokens", 10); put("output_tokens", 10) })
                }
                respond(reply.toString(), HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            } else {
                respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            }
        }).also { openClients += it }
        val coordinator = ContextCompactionCoordinator(
            store = store,
            accountId = { ACCOUNT },
            aiSummaryEnabled = { aiSummary },
            remoteCompactionEnabled = { remoteFlag },
            upload = { _, _, _ -> },
        )
        val conversationRepository = mockk<ConversationRepository>(relaxed = true).also {
            coEvery { it.getWithMessages(CONVERSATION_ID) } answers { storedConversation }
        }
        private val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
            coEvery { it.getById(any()) } returns null
            coEvery { it.getById(PROVIDER.id) } returns PROVIDER
        }
        val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextRejections = ChatContextRejections(),
            contextCompaction = coordinator,
        )

        /** The breaker is kept in memory per conversation with no public write entry: put a tripped state in directly. */
        @Suppress("UNCHECKED_CAST")
        fun tripBreaker() {
            val field = ContextCompactionCoordinator::class.java.getDeclaredField("breakers").apply { isAccessible = true }
            val breakers = field.get(coordinator) as java.util.concurrent.ConcurrentHashMap<String, ContextCompactionBreaker>
            breakers[CONVERSATION_ID] = ContextCompactionBreaker(turnsLeft = ContextCompactionBreaker.FALLBACK_TURNS)
        }

        suspend fun send(
            text: String,
            existing: List<ChatMessage>,
            generationParameters: GenerationParameterOverrides? = null,
        ) {
            runCatching {
                repository.sendMessage(
                    conversation = CONVERSATION,
                    text = text,
                    provider = PROVIDER,
                    modelID = MODEL.id,
                    existingMessages = existing,
                    requestOptions = ChatRequestOptions(
                        activeModel = MODEL,
                        generationParameters = generationParameters,
                        chatContext = ChatContextRequest(ContextConversation(id = CONVERSATION_ID, useMemory = false)),
                    ),
                    outputs = ConversationStreamingOutputs(
                        streamingText = MutableStateFlow(""),
                        streamingMessageId = MutableStateFlow(null),
                    ),
                )
            }
        }
    }

    private fun turnsOf(body: JsonObject): List<Pair<String, String>> =
        body["messages"]?.jsonArray.orEmpty()
            .map { it.jsonObject }
            .filter { it["role"]?.jsonPrimitive?.content in setOf("user", "assistant") }
            .map { it.getValue("role").jsonPrimitive.content to textOf(it) }

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
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun message(id: String, role: ChatRole, text: String) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = PROVIDER.id,
        providerKind = PROVIDER.kind,
        providerName = PROVIDER.displayName,
        modelID = MODEL.id,
        modelName = MODEL.name,
        state = ChatMessageState.Delivered,
    )

    private companion object {
        const val CONVERSATION_ID = "conversation-1"
        const val ACCOUNT = "acct-1"
        const val MEMORY_TEXT = "The user prefers metric units."
        val VALID_SUMMARY = ai.oriveo.community.core.context.ContextCheckpoint.HEADINGS.joinToString("\n") { "## $it\n(none)" }
        val MODEL = AIModel(id = "claude-window-16k", name = "Claude 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val PROVIDER = Provider(id = "anthropic-1", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(MODEL))
        val CONVERSATION = Conversation(
            id = CONVERSATION_ID,
            title = "Manual compaction",
            providerID = PROVIDER.id,
            providerKind = PROVIDER.kind,
            modelID = MODEL.id,
            useMemory = false,
        )
    }
}
