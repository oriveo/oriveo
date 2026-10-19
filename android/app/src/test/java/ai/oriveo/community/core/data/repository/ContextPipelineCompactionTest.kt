package ai.oriveo.community.core.data.repository

import android.content.Context
import androidx.room.Room
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.ContextReject
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
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
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * A plan refusal (no request, no message created, input kept) and the deterministic pre-send fallback for compaction=required.
 *
 * Production path: the real ChatRepository.sendMessage (with chatContext) -> the real AnthropicService, with MockEngine only capturing the request body.
 * Model W=16000 / output 8192 -> R=8000, U=B=8000, sendCompactAt=7200, rho=rho0=0.5.
 * Before sending, the stored row is read and anything over 0.90*B is compacted and stored through the coordinator (real Room database + real coordinator).
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class ContextPipelineCompactionTest {
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
    fun reject_instructions_too_long_no_request() = runTest {
        // A 17000-byte skill is about 8504 tokens > U=8000.
        val harness = Harness(this)
        harness.send("Hello", skillPrompt = "s".repeat(17_000))

        assertTrue("no request leaves the device: ${harness.bodies}", harness.bodies.isEmpty())
        coVerify(exactly = 0) { harness.conversationRepository.addMessage(any(), any()) }
        val rejection = harness.rejections.single()
        assertEquals(ContextReject.INSTRUCTIONS_TOO_LONG, rejection.reject)
        assertEquals(CONVERSATION_ID, rejection.conversationId)
        assertEquals("Hello", rejection.text)
        assertTrue("composer gets the text back", rejection.restoresComposer)
    }

    @Test
    fun reject_message_too_long_no_request() = runTest {
        val harness = Harness(this)
        val longText = "m".repeat(17_000)
        harness.send(longText)

        assertTrue("no request leaves the device: ${harness.bodies}", harness.bodies.isEmpty())
        coVerify(exactly = 0) { harness.conversationRepository.addMessage(any(), any()) }
        val rejection = harness.rejections.single()
        assertEquals(ContextReject.MESSAGE_TOO_LONG, rejection.reject)
        assertEquals(longText, rejection.text)
        assertTrue(rejection.restoresComposer)
    }

    @Test
    fun compaction_required_sends_checkpoint_first() = runTest {
        // 10 rounds of 1600 bytes (804 tokens) each -> estimate about 16k >= 0.90*B.
        val history = (0 until 10).flatMap { i ->
            listOf(
                message("u$i", ChatRole.User, "user-$i " + "a".repeat(1_592)),
                message("a$i", ChatRole.Assistant, "assistant-$i " + "b".repeat(1_587)),
            )
        }
        val harness = Harness(this)
        harness.send("Next question", existing = history)

        val body = harness.bodies.single()
        val turns = turnsOf(body)
        assertTrue("history was shortened: ${turns.size}", turns.size < history.size + 1)
        val (firstRole, firstText) = turns.first()
        assertEquals("user", firstRole)
        assertTrue("checkpoint leads the first user message: ${firstText.take(120)}", firstText.startsWith("<oriveo-context-checkpoint v=\"1\" covers=\"u0.."))
        val checkpointEnd = "</oriveo-context-checkpoint>\n\n"
        assertTrue("blank line separates checkpoint and the tail user text", checkpointEnd in firstText)
        val tailFirstUser = firstText.substringAfter(checkpointEnd)
        assertTrue("tail starts at a real user message: ${tailFirstUser.take(40)}", tailFirstUser.startsWith("user-"))
        assertEquals("user" to "Next question", turns.last())
        assertTrue("checkpoint fits B/2 after re-assembly: ${body.toString().length}", body.toString().length < 8_000 * 2)
        // The checkpoint does not go into the messages table but into the checkpoint table: one fallback row whose text is the segment in the request.
        coVerify(exactly = 0) { harness.conversationRepository.addMessage(any(), match { "<oriveo-context-checkpoint" in it.text }) }
        val row = store.list(ACCOUNT, CONVERSATION_ID).single()
        assertEquals(ContextCheckpointKind.FALLBACK, row.kind)
        assertTrue("request carries the stored row text", firstText.startsWith(row.text + "\n\n"))
        assertTrue(harness.rejections.isEmpty())
    }

    @Test
    fun checkpoint_stays_outside_unanswered_after_failed_reply() = runTest {
        // The database has a checkpoint row, a failed answer follows the first user message of the tail, and then a new message is sent.
        val history = longHistory(bytes = 1_600)
        val harness = Harness(this)
        harness.send("Next question", existing = history)
        val row = store.list(ACCOUNT, CONVERSATION_ID).single()
        val coversIndex = history.indexOfFirst { it.id == row.coversTo }
        assertTrue("stored row covers a history message: ${row.coversTo}", coversIndex >= 0)
        val failed = message("a10", ChatRole.Assistant, "partial").copy(state = ChatMessageState.Failed)
        val next = history.take(coversIndex + 1) + message("u10", ChatRole.User, "Previous question") + failed
        harness.send("Follow up", existing = next)

        assertEquals(2, harness.bodies.size)
        val firstUser = turnsOf(harness.bodies[1]).first { it.first == "user" }.second
        assertTrue("first user leads with the stored checkpoint: ${turnsOf(harness.bodies[1]).map { it.first to it.second.take(160) }}", firstUser.startsWith(row.text + "\n\n"))
        assertFalse("checkpoint is not escaped into <oriveo-unanswered>", "&lt;oriveo-context-checkpoint" in firstUser)
        assertTrue("failed turn's user is still carried: ${firstUser.takeLast(200)}", "Previous question" in firstUser)
    }

    @Test
    fun fallback_without_tail_start_keeps_unanswered_merge() = runTest {
        // The plan history has no user message (the unanswered user message is already merged into the current one) -> the fallback cannot give a tail start; the envelope is still there after the rebuild.
        val history = listOf(
            message("a0", ChatRole.Assistant, "assistant-0 " + "b".repeat(16_000)),
            message("u1", ChatRole.User, "Earlier question"),
            message("a1", ChatRole.Assistant, "partial").copy(state = ChatMessageState.Failed),
        )
        // The coordinator cannot get the account -> nothing is stored and the send path uses the in-memory fallback (checkpointed).
        val harness = Harness(this, accountFails = true)
        harness.send("Next question", existing = history)

        val turns = turnsOf(harness.bodies.last())
        val (lastRole, lastText) = turns.last()
        assertEquals("user", lastRole)
        assertTrue("current keeps the unanswered envelope: ${turns.map { it.first to it.second.take(160) }}", "<oriveo-unanswered>" in lastText)
        assertTrue("envelope carries the earlier user text: ${lastText.take(400)}", "Earlier question" in lastText)
        assertTrue("current text is still last: ${lastText.takeLast(80)}", lastText.endsWith("Next question"))
        assertTrue("fallback did cut a checkpoint: ${lastText.take(160)}", turns.any { it.first == "user" && it.second.startsWith("<oriveo-context-checkpoint") })
        assertTrue("memory fallback, nothing stored", store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
    }

    @Test
    fun presend_fallback_persists_and_next_send_reuses() = runTest {
        val history = longHistory(bytes = 1_600)
        val harness = Harness(this)
        harness.send("Next question", existing = history)
        val next = history + message("u10", ChatRole.User, "Next question") + message("a10", ChatRole.Assistant, "Answer")
        harness.send("Follow up", existing = next)

        assertEquals("AI off: one chat request per send, no summary request", 2, harness.bodies.size)
        assertFalse(harness.bodies.any { "CONTEXT CHECKPOINT" in it.toString() })
        val checkpointEnd = "</oriveo-context-checkpoint>"
        val firstPrefixes = harness.bodies.map { body ->
            val firstUser = turnsOf(body).first { it.first == "user" }.second
            assertTrue("first user leads with the checkpoint: ${firstUser.take(80)}", firstUser.startsWith("<oriveo-context-checkpoint"))
            firstUser.substringBefore(checkpointEnd)
        }
        assertEquals("second send reuses the stored checkpoint verbatim", firstPrefixes[0], firstPrefixes[1])
        val row = store.list(ACCOUNT, CONVERSATION_ID).single()
        assertEquals(ContextCheckpointKind.FALLBACK, row.kind)
        assertEquals(firstPrefixes[1], row.text.substringBefore(checkpointEnd))
        assertEquals("user" to "Follow up", turnsOf(harness.bodies[1]).last())
    }

    @Test
    fun presend_ai_summary_sends_compaction_request_then_chat() = runTest {
        // 10 messages x 1500 bytes (about 754 tokens) is about 7.5k >= 0.90*B and the span fits in U -> an appended summary request.
        val history = longHistory(bytes = 1_500)
        val harness = Harness(this, aiSummary = true)
        harness.send("Next question", existing = history)

        assertEquals("summary request then chat request: ${harness.bodies.map { it.toString().take(80) }}", 2, harness.bodies.size)
        val summary = harness.bodies[0]
        assertFalse("summary request carries no tools", "tools" in summary)
        val (lastRole, lastText) = turnsOf(summary).last()
        assertEquals("user", lastRole)
        assertTrue("summary prompt closes the last user: ${lastText.takeLast(200)}", "CONTEXT CHECKPOINT" in lastText)

        val chat = harness.bodies[1]
        val firstUser = turnsOf(chat).first { it.first == "user" }.second
        assertTrue("chat leads with the checkpoint: ${firstUser.take(80)}", firstUser.startsWith("<oriveo-context-checkpoint"))
        assertTrue("summary checkpoint embeds the summary", "<summary>" in firstUser)
        assertEquals("user" to "Next question", turnsOf(chat).last())
        val row = store.list(ACCOUNT, CONVERSATION_ID).single()
        assertEquals(ContextCheckpointKind.SUMMARY, row.kind)
        assertEquals(VALID_SUMMARY, row.summary)
        assertTrue(firstUser.startsWith(row.text + "\n\n"))
    }

    @Test
    fun presend_compaction_failure_still_sends() = runTest {
        // The coordinator throws when getting the account: compaction falls back to the in-memory fallback as a noop, sends as usual and stores no row.
        val history = longHistory(bytes = 1_600)
        val harness = Harness(this, accountFails = true)
        harness.send("Next question", existing = history)

        val chat = harness.bodies.single()
        val firstUser = turnsOf(chat).first { it.first == "user" }.second
        assertTrue("in-memory checkpoint leads: ${firstUser.take(80)}", firstUser.startsWith("<oriveo-context-checkpoint"))
        assertEquals("user" to "Next question", turnsOf(chat).last())
        assertTrue(store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
        assertTrue("user message persisted", harness.added.any { it.role == ChatRole.User && it.text == "Next question" })
    }

    @Test
    fun user_message_persisted_before_compaction() = runTest {
        val history = longHistory(bytes = 1_500)
        val harness = Harness(this, aiSummary = true)
        harness.send("Next question", existing = history)

        assertEquals("summary request then chat request", 2, harness.bodies.size)
        val atSummary = harness.addedAtSummary
        assertTrue("summary request was observed", atSummary != null)
        assertTrue(
            "user message is persisted before the summary call: ${atSummary?.map { it.role }}",
            atSummary!!.any { it.role == ChatRole.User && it.text == "Next question" },
        )
        assertTrue(
            "assistant placeholder is persisted before the summary call",
            atSummary.any { it.role == ChatRole.Assistant && it.state == ChatMessageState.Generating },
        )
    }

    @Test
    fun compaction_none_sends_full_history() = runTest {
        val history = listOf(
            message("u0", ChatRole.User, "First question"),
            message("a0", ChatRole.Assistant, "First answer"),
            message("u1", ChatRole.User, "Second question"),
            message("a1", ChatRole.Assistant, "Second answer"),
        )
        val harness = Harness(this)
        harness.send("Third question", existing = history)

        val body = harness.bodies.single()
        assertEquals(
            listOf(
                "user" to "First question",
                "assistant" to "First answer",
                "user" to "Second question",
                "assistant" to "Second answer",
                "user" to "Third question",
            ),
            turnsOf(body),
        )
        assertFalse("<oriveo-context-checkpoint" in body.toString())
    }

    // ── harness ──

    private fun longHistory(bytes: Int): List<ChatMessage> = (0 until 5).flatMap { i ->
        listOf(
            message("u$i", ChatRole.User, "user-$i " + "a".repeat(bytes - 8)),
            message("a$i", ChatRole.Assistant, "assistant-$i " + "b".repeat(bytes - 13)),
        )
    }

    private inner class Harness(scope: TestScope, aiSummary: Boolean = false, accountFails: Boolean = false) {
        val bodies = mutableListOf<JsonObject>()
        val added = mutableListOf<ChatMessage>()
        var addedAtSummary: List<ChatMessage>? = null
        val summaryOptions = mutableListOf<ChatRequestOptions>()
        val rejections = mutableListOf<ChatContextRejection>()
        private val channel = ChatContextRejections()
        private val client = HttpClient(MockEngine { request ->
            val body = json.parseToJsonElement(bodyText(request.body)).jsonObject
            bodies += body
            if (body["stream"]?.jsonPrimitive?.content == "false") {
                addedAtSummary = added.toList()
                // One-off summary call: non-streaming JSON.
                val reply = buildJsonObject {
                    put("content", buildJsonArray { add(buildJsonObject { put("type", "text"); put("text", "  $VALID_SUMMARY\n") }) })
                    put("usage", buildJsonObject { put("input_tokens", 10); put("output_tokens", 10) })
                }
                respond(reply.toString(), HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            } else {
                respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            }
        }).also { openClients += it }
        private val coordinator = ContextCompactionCoordinator(
            store = store,
            accountId = { if (accountFails) error("account unavailable") else ACCOUNT },
            aiSummaryEnabled = { aiSummary },
            remoteCompactionEnabled = { true },
            upload = { _, _, _ -> },
        )
        val conversationRepository = mockk<ConversationRepository>(relaxed = true).also {
            coEvery { it.addMessage(any(), any()) } answers { added += secondArg<ChatMessage>() }
        }
        private val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            // The one-off summary call goes through sendMessage: record the request options it carries, then send as the original implementation does.
            val real = AnthropicService(client, json, TransportRegistry(json))
            val service = object : ai.oriveo.community.core.provider.ProviderService by real {
                override suspend fun sendMessage(
                    apiKey: String,
                    modelID: String,
                    messages: List<ChatMessage>,
                    baseUrl: String?,
                    supportsImageGen: Boolean,
                    reasoningMode: ai.oriveo.community.core.model.ReasoningMode,
                    webSearchEnabled: Boolean,
                    requestOptions: ChatRequestOptions,
                ): ai.oriveo.community.core.model.StreamEvent.Done {
                    summaryOptions += requestOptions
                    return real.sendMessage(apiKey, modelID, messages, baseUrl, supportsImageGen, reasoningMode, webSearchEnabled, requestOptions)
                }
            }
            every { it.serviceFor(any<Provider>(), any()) } returns service
            coEvery { it.getById(PROVIDER.id) } returns PROVIDER
        }
        private val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextRejections = channel,
            contextCompaction = coordinator,
        )

        init {
            scope.backgroundScope.launch(UnconfinedTestDispatcher(scope.testScheduler)) {
                channel.events.collect { rejections += it }
            }
        }

        suspend fun send(
            text: String,
            existing: List<ChatMessage> = emptyList(),
            skillPrompt: String? = null,
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
                        chatContext = ChatContextRequest(
                            ContextConversation(id = CONVERSATION_ID, useMemory = false, skillPrompt = skillPrompt),
                        ),
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

    /** The compaction history only runs the detector when isDirective is read; most sends do not compact, so the detector must not run needlessly for every user message. */
    @Test
    fun directive_detect_is_lazy() {
        val raw = listOf(
            message("u0", ChatRole.User, "Always answer in English from now on."),
            message("a0", ChatRole.Assistant, "OK."),
            message("u1", ChatRole.User, "Next question"),
        )
        val expected = ai.oriveo.community.core.context.DirectiveDetector.detect(raw[0].text).isDirective
        io.mockk.mockkObject(ai.oriveo.community.core.context.DirectiveDetector)
        try {
            val history = ChatContextProjector.compactionHistory(raw, ai.oriveo.community.core.context.ContextBudget.RHO0)
            assertEquals(listOf("u0", "a0"), history.map { it.id })
            io.mockk.verify(exactly = 0) { ai.oriveo.community.core.context.DirectiveDetector.detect(any()) }

            assertEquals(listOf(expected, false), history.map { it.isDirective })
            // Only user messages run the detector, and reading twice computes once.
            assertEquals(expected, history[0].isDirective)
            io.mockk.verify(exactly = 1) { ai.oriveo.community.core.context.DirectiveDetector.detect(raw[0].text) }
            io.mockk.verify(exactly = 1) { ai.oriveo.community.core.context.DirectiveDetector.detect(any()) }
        } finally {
            io.mockk.unmockkObject(ai.oriveo.community.core.context.DirectiveDetector)
        }
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
        val VALID_SUMMARY = ai.oriveo.community.core.context.ContextCheckpoint.HEADINGS.joinToString("\n") { "## $it\n(none)" }
        val MODEL = AIModel(id = "claude-window-16k", name = "Claude 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val PROVIDER = Provider(id = "anthropic-1", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(MODEL))
        val CONVERSATION = Conversation(
            id = CONVERSATION_ID,
            title = "Compaction",
            providerID = PROVIDER.id,
            providerKind = PROVIDER.kind,
            modelID = MODEL.id,
            useMemory = false,
        )
    }
}
