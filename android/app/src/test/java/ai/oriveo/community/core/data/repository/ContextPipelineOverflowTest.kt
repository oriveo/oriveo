package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextBasis
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.dao.ContextCheckpointDao
import ai.oriveo.community.core.data.dao.ContextLedgerDao
import ai.oriveo.community.core.data.entity.ContextCheckpointEntity
import ai.oriveo.community.core.data.entity.ContextManifestEntity
import ai.oriveo.community.core.data.entity.ContextRhoCalibrationEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.RelayErrorMapper
import ai.oriveo.community.core.provider.SseParser
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Overflow recovery (one resend after the fallback), rho write-back, the manifest of every request, and HTTP errors carrying the status / raw body.
 *
 * Production path: the real ChatRepository.sendMessage (with chatContext) -> the real AnthropicService, with MockEngine replaying responses in order and capturing request bodies.
 * Model W=16000 / output 8192 -> R=8000, U=B=8000, sendCompactAt=7200, tail=4000, rho=rho0=0.5.
 * History of 8 messages x 1600 bytes (804 tokens) is about 6.4k: the fallback is not triggered before sending, and the fallback after an overflow can cut a checkpoint.
 */
class ContextPipelineOverflowTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun overflow_recovers_once_with_checkpoint() = runTest {
        val harness = Harness(listOf(overflow400(), success(inputTokens = 3_000)))
        harness.send("Next question", existing = history())

        assertEquals("one automatic resend: ${harness.bodies.size}", 2, harness.bodies.size)
        val first = turnsOf(harness.bodies[0])
        val second = turnsOf(harness.bodies[1])
        assertFalse("first request is the full history", first.first().second.startsWith(CHECKPOINT_OPEN))
        assertTrue("resend is shorter: ${second.size} < ${first.size}", second.size < first.size)
        assertTrue("checkpoint leads the resend: ${second.first().second.take(80)}", second.first().second.startsWith(CHECKPOINT_OPEN))
        assertEquals("user" to "Next question", second.last())
        // Only one user message and one assistant placeholder are stored; the finish writes back to the same assistant message.
        coVerify(exactly = 1) { harness.conversationRepository.addMessage(any(), match { it.role == ChatRole.User }) }
        coVerify(exactly = 1) { harness.conversationRepository.addMessage(any(), match { it.role == ChatRole.Assistant }) }
        val final = harness.lastAssistantUpdate()
        assertEquals(harness.assistantId(), final.id)
        assertEquals(ChatMessageState.Delivered, final.state)
        assertEquals("Answer", final.text)
        assertEquals(StopReason.STOP, final.stopReason)
        val manifests = harness.dao.manifestsOf(CONVERSATION_ID)
        assertEquals(2, manifests.size)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, manifests[0].stopReason)
        assertEquals(StopReason.STOP, manifests[1].stopReason)
        assertNotNull("resend records where the tail starts", manifests[1].tailFrom)
        // In the default mode an overflow is compacted by the coordinator's fallback, storing one fallback row that the resend reads.
        val row = harness.store.list(ACCOUNT, CONVERSATION_ID).single()
        assertEquals(ContextCheckpointKind.FALLBACK, row.kind)
        assertTrue("resend leads with the stored row", second.first().second.startsWith(row.text + "\n\n"))
    }

    @Test
    fun overflow_ai_summary_compacts_then_retries_once() = runTest {
        val harness = Harness(listOf(overflow400(), summaryReply(), success(inputTokens = 3_000)), aiSummary = true)
        harness.send("Next question", existing = history())

        assertEquals("overflow, summary, resend: ${harness.bodies.map { it.toString().take(80) }}", 3, harness.bodies.size)
        val (summaryRole, summaryText) = turnsOf(harness.bodies[1]).last()
        assertEquals("user", summaryRole)
        assertTrue("summary prompt closes the last user: ${summaryText.takeLast(200)}", "CONTEXT CHECKPOINT" in summaryText)
        val resend = turnsOf(harness.bodies[2])
        val (firstRole, firstText) = resend.first()
        assertEquals("user", firstRole)
        assertTrue("resend leads with the summary checkpoint: ${firstText.take(120)}", "<summary>" in firstText)
        assertEquals("user" to "Next question", resend.last())
        val row = harness.store.list(ACCOUNT, CONVERSATION_ID).single()
        assertEquals(ContextCheckpointKind.SUMMARY, row.kind)
        assertTrue(firstText.startsWith(row.text + "\n\n"))
        coVerify(exactly = 1) { harness.conversationRepository.addMessage(any(), match { it.role == ChatRole.Assistant }) }
        val final = harness.lastAssistantUpdate()
        assertEquals(harness.assistantId(), final.id)
        assertEquals(ChatMessageState.Delivered, final.state)
        assertEquals("Answer", final.text)
    }

    @Test
    fun new_stop_families_map_to_overflow_families() {
        // The two newly added families must not crash OverflowFamily.fromWire; Interactions belongs to gemini and native llama.cpp to openai_compatible
        assertEquals(
            ai.oriveo.community.core.context.OverflowFamily.GEMINI,
            overflowFamilyOf(ai.oriveo.community.core.context.StopFamily.GEMINI_INTERACTIONS),
        )
        assertEquals(
            ai.oriveo.community.core.context.OverflowFamily.OPENAI_COMPATIBLE,
            overflowFamilyOf(ai.oriveo.community.core.context.StopFamily.LLAMA_CPP),
        )
        ai.oriveo.community.core.context.StopFamily.entries.forEach { overflowFamilyOf(it) }
        assertEquals(
            ai.oriveo.community.core.context.StopFamily.LLAMA_CPP,
            chatStopFamily(Provider(id = "relay", kind = ProviderKind.Relay), ai.oriveo.community.core.model.RelayTransport.LlamaCppNative),
        )
    }

    @Test
    fun overflow_compaction_failure_falls_back_to_p2() = runTest {
        // The coordinator throws when getting the account: the overflow compaction falls back to the in-memory fallback as a noop and still resends automatically only once.
        val harness = Harness(listOf(overflow400(), success(inputTokens = 3_000)), accountFails = true)
        harness.send("Next question", existing = history())

        assertEquals("one automatic resend: ${harness.bodies.size}", 2, harness.bodies.size)
        val second = turnsOf(harness.bodies[1])
        assertTrue("in-memory checkpoint leads the resend: ${second.first().second.take(80)}", second.first().second.startsWith(CHECKPOINT_OPEN))
        assertEquals("user" to "Next question", second.last())
        assertTrue(harness.store.list(ACCOUNT, CONVERSATION_ID).isEmpty())
        val final = harness.lastAssistantUpdate()
        assertEquals(harness.assistantId(), final.id)
        assertEquals(ChatMessageState.Delivered, final.state)
    }

    @Test
    fun overflow_fallback_keeps_latest_checkpoint_summary() = runTest {
        // Overflow after the first send applied a stored row (with a summary), and storing the compaction fails so it falls back to the in-memory fallback; the fallback checkpoint carries the stored row's old summary.
        val harness = Harness(listOf(overflow400(), success(inputTokens = 3_000)))
        val existing = history()
        val seeded = seededRow(existing, coversTo = "a1", summary = "## Goal\nKeep <tags> & go")
        harness.store.save(ACCOUNT, seeded)
        harness.checkpointDao.failUpsert = true
        harness.send("Next question", existing = existing)

        assertEquals("one automatic resend: ${harness.bodies.size}", 2, harness.bodies.size)
        val first = turnsOf(harness.bodies[0]).first().second
        assertTrue("first request leads with the stored row: ${first.take(80)}", first.startsWith(seeded.text + "\n\n"))
        val resend = turnsOf(harness.bodies[1]).first().second
        assertTrue("in-memory checkpoint leads the resend: ${resend.take(80)}", resend.startsWith(CHECKPOINT_OPEN))
        assertTrue("old summary carried, XML-escaped: $resend", "<summary>## Goal\nKeep &lt;tags&gt; &amp; go</summary>" in resend)
        assertEquals(listOf(seeded), harness.store.list(ACCOUNT, CONVERSATION_ID))
        assertEquals(ChatMessageState.Delivered, harness.lastAssistantUpdate().state)
    }

    @Test
    fun anthropic_in_stream_overflow_recovers_once() = runTest {
        // An in-stream model_context_window_exceeded with no body yet -> the same recovery as an HTTP overflow, resending only once.
        val harness = Harness(listOf(windowExceededWithoutContent(), success(inputTokens = 3_000)))
        harness.send("Next question", existing = history())

        assertEquals("one automatic resend: ${harness.bodies.size}", 2, harness.bodies.size)
        assertTrue(turnsOf(harness.bodies[1]).first().second.startsWith(CHECKPOINT_OPEN))
        coVerify(exactly = 1) { harness.conversationRepository.addMessage(any(), match { it.role == ChatRole.Assistant }) }
        val final = harness.lastAssistantUpdate()
        assertEquals(harness.assistantId(), final.id)
        assertEquals(ChatMessageState.Delivered, final.state)
        assertEquals("Answer", final.text)
        val manifests = harness.dao.manifestsOf(CONVERSATION_ID)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, manifests.first().stopReason)
        assertEquals(StopReason.STOP, manifests.last().stopReason)

        // The resend again exceeds the limit in-stream: no further resend, and the failed message records context_window_exceeded.
        val twice = Harness(listOf(windowExceededWithoutContent(), windowExceededWithoutContent()))
        twice.send("Next question", existing = history())
        assertEquals("only one resend: ${twice.bodies.size}", 2, twice.bodies.size)
        val failed = twice.lastAssistantUpdate()
        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, failed.stopReason)
    }

    @Test
    fun anthropic_in_stream_overflow_after_content_no_retry() = runTest {
        // Body already produced: finish as usual without a resend, and stopReason records context_window_exceeded.
        val harness = Harness(listOf(contentThenWindowExceeded(), success(inputTokens = 3_000)))
        harness.send("Next question", existing = history())

        assertEquals(1, harness.bodies.size)
        val final = harness.lastAssistantUpdate()
        assertEquals("Partial", final.text)
        assertEquals(ChatMessageState.Delivered, final.state)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, final.stopReason)
    }

    @Test
    fun overflow_twice_records_context_window_exceeded() = runTest {
        val harness = Harness(listOf(overflow400(), overflow400()))
        harness.send("Next question", existing = history())

        assertEquals("only one resend: ${harness.bodies.size}", 2, harness.bodies.size)
        assertTrue(turnsOf(harness.bodies[1]).first().second.startsWith(CHECKPOINT_OPEN))
        coVerify(exactly = 1) { harness.conversationRepository.addMessage(any(), match { it.role == ChatRole.Assistant }) }
        val final = harness.lastAssistantUpdate()
        assertEquals(harness.assistantId(), final.id)
        assertEquals(ChatMessageState.Failed, final.state)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, final.stopReason)
        assertNotNull("failure card stays as before", final.errorTitle)
    }

    @Test
    fun overflow_after_content_no_retry() = runTest {
        val harness = Harness(listOf(contentThenWindowExceeded()))
        harness.send("Next question", existing = history())

        assertEquals(1, harness.bodies.size)
        val final = harness.lastAssistantUpdate()
        assertEquals("Partial", final.text)
        assertEquals(StopReason.CONTEXT_WINDOW_EXCEEDED, final.stopReason)
    }

    @Test
    fun rate_limit_429_not_recovered() = runTest {
        val body = """{"type":"error","error":{"type":"rate_limit_error","message":"prompt is too long for the current rate limit"}}"""
        val harness = Harness(listOf(Reply(HttpStatusCode.TooManyRequests, body, JSON_TYPE)))
        harness.send("Next question", existing = history())

        assertEquals(1, harness.bodies.size)
        val final = harness.lastAssistantUpdate()
        assertEquals(ChatMessageState.Failed, final.state)
        assertEquals(StopReason.ERROR, final.stopReason)
        assertEquals("no overflow miss on 429", ContextBudget.RHO0, harness.dao.rho[KEY]?.rho ?: ContextBudget.RHO0, 1e-9)
    }

    @Test
    fun usage_writes_rho_sample() = runTest {
        val harness = Harness(listOf(success(inputTokens = 1_234)))
        harness.send("Hello there")

        val body = harness.bodies.single()
        val entity = assertNotNullAnd(harness.dao.rho[KEY]) { "rho row under (${PROVIDER.id}, ${MODEL.id})" }
        assertEquals(1, entity.n)
        val textBytes = textBytesOf(body)
        assertEquals(1_234.0 / textBytes, entity.calibration.seeds.single(), 1e-9)
    }

    @Test
    fun overflow_miss_raises_rho() = runTest {
        val harness = Harness(listOf(overflow400(), success(inputTokens = null)))
        harness.send("Next question", existing = history())

        val entity = assertNotNullAnd(harness.dao.rho[KEY]) { "overflow miss writes the rho row" }
        assertEquals(ContextBudget.RHO0 * ContextBudget.OVERFLOW_MISS_FACTOR, entity.rho, 1e-9)
    }

    @Test
    fun manifest_appended_per_request() = runTest {
        val harness = Harness(listOf(success(inputTokens = 900)))
        harness.send("Hello there")

        val manifest = harness.dao.manifestsOf(CONVERSATION_ID).single()
        assertEquals(RequestPurpose.CHAT, manifest.purpose)
        assertEquals(ai.oriveo.community.core.context.StopFamily.ANTHROPIC.wire, manifest.transport)
        assertEquals(MODEL.id, manifest.model)
        assertEquals(16_000, manifest.W)
        // O is the O computed from the window (model output 8192), not oWire (8000).
        assertEquals(8_192, manifest.O)
        assertEquals(8_000, manifest.B)
        assertEquals(ContextBasis.OBSERVED, manifest.basis)
        assertTrue(manifest.estimatedInput > 0)
        assertEquals(900, manifest.observedInput)
        assertEquals(StopReason.STOP, manifest.stopReason)
        assertNull(manifest.tailFrom)
        assertFalse(manifest.reminder)
        assertEquals(0, manifest.unansweredMerged)
    }

    @Test
    fun http_error_carries_status_and_raw_body() {
        val body = """{"error":{"type":"rate_limit_error","message":"slow down"}}"""
        val official = SseParser.mapHttpError(429, body)
        assertTrue(official is ProviderServiceError.RateLimited)
        assertEquals(429, official.httpStatus)
        assertEquals(body, official.rawBody)

        val relay = RelayErrorMapper.mapOrDefault(401, """{"error":{"message":"bad key"}}""")
        assertTrue(relay is ProviderServiceError.InvalidAPIKey)
        assertEquals(401, relay.httpStatus)
        assertEquals("""{"error":{"message":"bad key"}}""", relay.rawBody)

        // The raw body keeps only the first 32 KB of UTF-8, without cutting a multi-byte character.
        val long = "{\"error\":{\"message\":\"" + "\u6ea2".repeat(20_000) + "\"}}"
        val truncated = SseParser.mapHttpError(400, long).rawBody.orEmpty()
        assertTrue(truncated.toByteArray(Charsets.UTF_8).size <= 32 * 1024)
        assertTrue(truncated.toByteArray(Charsets.UTF_8).size > 32 * 1024 - 3)
        assertTrue(long.startsWith(truncated))
    }

    // ── harness ──

    private class Reply(val status: HttpStatusCode, val body: String, val contentType: String)

    private class FakeLedgerDao : ContextLedgerDao {
        val rho = linkedMapOf<Pair<String, String>, ContextRhoCalibrationEntity>()
        val manifests = mutableListOf<ContextManifestEntity>()

        override suspend fun upsertRho(entity: ContextRhoCalibrationEntity) {
            rho[entity.transportInstanceId to entity.modelId] = entity
        }

        override suspend fun rho(transportInstanceId: String, modelId: String) = rho[transportInstanceId to modelId]

        override suspend fun allRho() = rho.values.toList()

        override suspend fun insertManifest(entity: ContextManifestEntity) {
            manifests += entity
        }

        override suspend fun trimManifests(conversationId: String, keep: Int) = Unit

        override suspend fun manifests(conversationId: String) = manifests.filter { it.conversationId == conversationId }

        fun manifestsOf(conversationId: String) = manifests.filter { it.conversationId == conversationId }.map { it.manifest }
    }

    /** In-memory checkpoint table: overwrites by accountId + conversationId + checkpointId, and trim keeps the latest keep rows. */
    private class FakeCheckpointDao : ContextCheckpointDao {
        private val rows = mutableListOf<ContextCheckpointEntity>()
        /** true = storing throws (the coordinator swallows it and the compaction falls back to the in-memory fallback as a noop). */
        var failUpsert = false

        override suspend fun upsert(entity: ContextCheckpointEntity) {
            if (failUpsert) error("upsert failed")
            rows.removeAll { it.accountId == entity.accountId && it.conversationId == entity.conversationId && it.checkpointId == entity.checkpointId }
            rows += entity
        }

        override suspend fun trim(accountId: String, conversationId: String, keep: Int) {
            val mine = rows.filter { it.accountId == accountId && it.conversationId == conversationId }
            rows.removeAll(mine.sortedByDescending { it.createdAt }.drop(keep).toSet())
        }

        override suspend fun list(accountId: String, conversationId: String) =
            rows.filter { it.accountId == accountId && it.conversationId == conversationId }.sortedBy { it.createdAt }

        override suspend fun delete(accountId: String, conversationId: String, checkpointIds: Collection<String>) {
            rows.removeAll { it.accountId == accountId && it.conversationId == conversationId && it.checkpointId in checkpointIds }
        }
    }

    private inner class Harness(replies: List<Reply>, aiSummary: Boolean = false, accountFails: Boolean = false) {
        val bodies = mutableListOf<JsonObject>()
        val dao = FakeLedgerDao()
        val checkpointDao = FakeCheckpointDao()
        val store = ContextCompactionStore(checkpointDao)
        private val coordinator = ContextCompactionCoordinator(
            store = store,
            accountId = { if (accountFails) error("account unavailable") else ACCOUNT },
            aiSummaryEnabled = { aiSummary },
            remoteCompactionEnabled = { true },
            upload = { _, _, _ -> },
        )
        private val queue = ArrayDeque(replies)
        private val client = HttpClient(MockEngine { request ->
            bodies += json.parseToJsonElement(bodyText(request.body)).jsonObject
            val reply = queue.removeFirst()
            respond(reply.body, reply.status, headersOf(HttpHeaders.ContentType, reply.contentType))
        }).also { openClients += it }
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        private val added = mutableListOf<ChatMessage>()
        private val updated = mutableListOf<ChatMessage>()
        private val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
            coEvery { it.getById(PROVIDER.id) } returns PROVIDER
        }
        private val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextLedgerDao = dao,
            contextCompaction = coordinator,
        )

        init {
            coEvery { conversationRepository.addMessage(any(), any()) } answers { added += secondArg<ChatMessage>() }
            coEvery { conversationRepository.updateMessage(any(), any()) } answers { updated += secondArg<ChatMessage>() }
        }

        fun assistantId(): String = added.single { it.role == ChatRole.Assistant }.id

        fun lastAssistantUpdate(): ChatMessage = updated.last { it.role == ChatRole.Assistant }

        suspend fun send(text: String, existing: List<ChatMessage> = emptyList()) {
            runCatching {
                repository.sendMessage(
                    conversation = CONVERSATION,
                    text = text,
                    provider = PROVIDER,
                    modelID = MODEL.id,
                    existingMessages = existing,
                    requestOptions = ChatRequestOptions(
                        activeModel = MODEL,
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

    private fun overflow400() = Reply(
        HttpStatusCode.BadRequest,
        """{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 20412 tokens > 16000 maximum"}}""",
        JSON_TYPE,
    )

    /** The non-streaming reply of the one-off summary call: a compliant summary (five English level-2 headings). */
    private fun summaryReply() = Reply(
        HttpStatusCode.OK,
        buildJsonObject {
            put("content", buildJsonArray { add(buildJsonObject { put("type", "text"); put("text", VALID_SUMMARY) }) })
            put("usage", buildJsonObject { put("input_tokens", 10); put("output_tokens", 10) })
        }.toString(),
        JSON_TYPE,
    )

    private fun success(inputTokens: Int?): Reply {
        val usage = inputTokens?.let { ""","usage":{"input_tokens":$it,"output_tokens":1}""" }.orEmpty()
        return Reply(
            HttpStatusCode.OK,
            """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","content":[]$usage}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Answer"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

            event: message_stop
            data: {"type":"message_stop"}

            """.trimIndent() + "\n\n",
            SSE_TYPE,
        )
    }

    private fun contentThenWindowExceeded() = Reply(
        HttpStatusCode.OK,
        """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","content":[]}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partial"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded"},"usage":{"output_tokens":2}}

        event: message_stop
        data: {"type":"message_stop"}

        """.trimIndent() + "\n\n",
        SSE_TYPE,
    )

    /** The window is exceeded in-stream and no body was produced. */
    private fun windowExceededWithoutContent() = Reply(
        HttpStatusCode.OK,
        """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","content":[]}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded"},"usage":{"output_tokens":0}}

        event: message_stop
        data: {"type":"message_stop"}

        """.trimIndent() + "\n\n",
        SSE_TYPE,
    )

    /** A valid stored row covering up to [coversTo] (the digest is computed from the original history text). */
    private fun seededRow(existing: List<ChatMessage>, coversTo: String, summary: String): ContextCheckpointRecord {
        val covered = existing.take(existing.indexOfFirst { it.id == coversTo } + 1)
        return ContextCheckpointRecord(
            conversationId = CONVERSATION_ID,
            checkpointId = ai.oriveo.community.core.context.ContextCheckpoint.checkpointId(CONVERSATION_ID, coversTo),
            kind = ContextCheckpointKind.SUMMARY,
            coversFrom = covered.first().id,
            coversTo = coversTo,
            coversDigest = ai.oriveo.community.core.context.ContextCheckpoint.coversDigest(
                covered.map { ai.oriveo.community.core.context.CheckpointCoveredMessage(it.id, it.text) },
            ),
            messagesCovered = covered.size,
            userMessageIds = covered.filter { it.role == ChatRole.User }.map { it.id },
            text = "<oriveo-context-checkpoint v=\"1\" seeded/>",
            summary = summary,
            language = null,
            model = MODEL.id,
            packerVersion = ai.oriveo.community.core.context.ContextCheckpoint.PACKER_VERSION,
            createdAt = 1,
            cost = null,
        )
    }

    private fun history(): List<ChatMessage> = (0 until 4).flatMap { i ->
        listOf(
            message("u$i", ChatRole.User, "user-$i " + "a".repeat(1_592)),
            message("a$i", ChatRole.Assistant, "assistant-$i " + "b".repeat(1_587)),
        )
    }

    private fun <T : Any> assertNotNullAnd(value: T?, message: () -> String): T {
        assertNotNull(message(), value)
        return value!!
    }

    /** The sum of the UTF-8 byte counts of the system text and each message text in the request body (the denominator of the rho sample). */
    private fun textBytesOf(body: JsonObject): Int {
        val system = when (val s = body["system"]) {
            is JsonPrimitive -> s.content
            is JsonArray -> s.joinToString("") { it.jsonObject["text"]?.jsonPrimitive?.content.orEmpty() }
            else -> ""
        }
        val messages = body["messages"]?.jsonArray.orEmpty().map { textOf(it.jsonObject) }
        return (listOf(system) + messages).sumOf { it.toByteArray(Charsets.UTF_8).size }
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
        val VALID_SUMMARY = ai.oriveo.community.core.context.ContextCheckpoint.HEADINGS.joinToString("\n") { "## $it\n(none)" }
        const val CHECKPOINT_OPEN = "<oriveo-context-checkpoint v=\"1\""
        const val JSON_TYPE = "application/json"
        const val SSE_TYPE = "text/event-stream"
        val MODEL = AIModel(id = "claude-window-16k", name = "Claude 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val PROVIDER = Provider(id = "anthropic-1", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(MODEL))
        val KEY = PROVIDER.id to MODEL.id
        val CONVERSATION = Conversation(
            id = CONVERSATION_ID,
            title = "Overflow",
            providerID = PROVIDER.id,
            providerKind = PROVIDER.kind,
            modelID = MODEL.id,
            useMemory = false,
        )
    }
}
