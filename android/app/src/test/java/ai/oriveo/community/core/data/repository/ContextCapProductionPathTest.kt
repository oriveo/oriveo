package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.CompactOutcome
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.backup.BackupService
import ai.oriveo.community.core.data.dao.ContextLedgerDao
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.NoteDao
import ai.oriveo.community.core.data.dao.NoteFolderDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.dao.SkillDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.mapper.ConversationMapper
import ai.oriveo.community.core.data.entity.ContextManifestEntity
import ai.oriveo.community.core.data.entity.ContextRhoCalibrationEntity
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ImportMode
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.slot
import io.mockk.unmockkStatic
import java.util.Date
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The price line T is decoded by the production metadata decoder and enters B through the window factory.
 *
 * Data: xAI grok-4.7, W = 2000000, pricing.longContext.thresholdTokens = 200000.
 * T only enters through [MetadataTestFixtures.applyRaw] (the production decode / publish boundary); AIModel carries no price-line field.
 */
class ContextCapProductionPathTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun grok_auto_price_line_caps_budget() = runTest {
        MetadataTestFixtures.applyRaw(metadata(LONG_CONTEXT))
        val harness = Harness(GROK_PROVIDER)
        harness.send("Hello there")

        // The conversation follows global and global is auto: B is the one the production send path wrote into the ledger.
        val manifest = harness.dao.manifests.single { it.conversationId == CONVERSATION_ID }.manifest
        assertEquals(2_000_000, manifest.W)
        assertEquals(200_000, manifest.B)
    }

    @Test
    fun relay_ignores_price_line() {
        // Removing the Relay check from window would not turn this red: Relay has no official catalog, so resolveCatalogModel(id, Relay) is always null
        // and T cannot be found structurally; this case guards that a same-named model in an official catalog is not borrowed.
        MetadataTestFixtures.applyRaw(metadata(LONG_CONTEXT))
        val provider = Provider(id = "relay-1", kind = ProviderKind.Relay, apiKey = "relay-key", models = listOf(MODEL))

        val window = ChatContextProjector.window(provider, MODEL, ChatRequestOptions())
        assertNull(window.priceLineTokens)
        val budget = assertNotNullAnd(planBudget(window)) { "relay plan has a window budget" }
        assertEquals(256_000, budget.B)
    }

    @Test
    fun metadata_decodes_long_context() {
        MetadataTestFixtures.applyRaw(metadata(LONG_CONTEXT))
        val resolved = assertNotNullAnd(MetadataClient.resolveCatalogModel(MODEL_ID, ProviderKind.Grok)) { "grok-4.7 resolves" }
        val longContext = assertNotNullAnd(resolved.longContext) { "longContext decoded" }
        assertEquals(200_000, longContext.thresholdTokens)
        assertEquals(4.0, longContext.promptPerMToken, 1e-9)
        assertEquals(12.0, longContext.completionPerMToken, 1e-9)
        assertEquals(1.0, longContext.cacheReadPerMToken!!, 1e-9)
        assertEquals(2_000_000, resolved.contextLength)

        // A malformed shape only drops longContext and the other fields are kept; a non-positive-integer thresholdTokens means no T.
        val malformed = listOf(
            "\"oops\"",
            "[200000]",
            """{"thresholdTokens":"200k","promptPerMToken":4,"completionPerMToken":12}""",
            """{"thresholdTokens":0,"promptPerMToken":4,"completionPerMToken":12}""",
            """{"thresholdTokens":-5,"promptPerMToken":4,"completionPerMToken":12}""",
            """{"thresholdTokens":200000.5,"promptPerMToken":4,"completionPerMToken":12}""",
            """{"thresholdTokens":200000,"completionPerMToken":12}""",
            """{"thresholdTokens":200000,"promptPerMToken":-1,"completionPerMToken":12}""",
            """{"thresholdTokens":2147483648,"promptPerMToken":4,"completionPerMToken":12}""",
        )
        malformed.forEach { shape ->
            MetadataTestFixtures.applyRaw(metadata(shape))
            val degraded = assertNotNullAnd(MetadataClient.resolveCatalogModel(MODEL_ID, ProviderKind.Grok)) { "model survives $shape" }
            assertNull("longContext dropped for $shape", degraded.longContext)
            assertEquals(2_000_000, degraded.contextLength)
            assertEquals(2.0 / 1_000_000, degraded.promptPerToken!!, 1e-15)
            assertEquals(6.0 / 1_000_000, degraded.completionPerToken!!, 1e-15)
        }

        // A thresholdTokens written as a decimal with an integral value (200000.0) is accepted and converted to an integer exactly.
        MetadataTestFixtures.applyRaw(metadata("""{"thresholdTokens":200000.0,"promptPerMToken":4,"completionPerMToken":12}"""))
        val integral = assertNotNullAnd(MetadataClient.resolveCatalogModel(MODEL_ID, ProviderKind.Grok)) { "model survives 200000.0" }
        assertEquals(200_000, assertNotNullAnd(integral.longContext) { "200000.0 decodes" }.thresholdTokens)
    }

    @Test
    fun backup_restored_cap_drives_budget() = runTest {
        MetadataTestFixtures.applyRaw(metadata(LONG_CONTEXT))
        // 190000 is exported by the production BackupService and imported onto a device without that conversation; the stored row is read back through the production mapper.
        val restoredRow = BackupHarness().roundTrip(backupEntity(contextCap = "190000"))
        val restored = ConversationMapper.run { restoredRow.toDomain() }
        assertEquals(ContextBudgetCap.Custom(190_000), restored.contextCap)

        val harness = Harness(GROK_PROVIDER)
        harness.send("Hello there", grokConversation(restored))
        assertEquals(190_000, harness.sentB(restored.id))
    }

    @Test
    fun global_custom_cap_applies_when_following() = runTest {
        MetadataTestFixtures.applyRaw(metadata(LONG_CONTEXT))
        // The conversation follows (contextCap = null) and global is 300000: the custom tier overrides the price line.
        val harness = Harness(GROK_PROVIDER, defaultCap = ContextBudgetCap.Custom(300_000))
        harness.send("Hello there", capConversation(cap = null))
        assertEquals(300_000, harness.sentB(CONVERSATION_ID))
    }

    @Test
    fun conversation_unlimited_overrides_global() = runTest {
        MetadataTestFixtures.applyRaw(metadata(LONG_CONTEXT))
        val harness = Harness(GROK_PROVIDER, defaultCap = ContextBudgetCap.Custom(64_000))
        harness.send("Hello there", capConversation(cap = ContextBudgetCap.Unlimited))

        // U does not depend on the tier: it is the U computed by the production window plus the production projection.
        val usable = assertNotNullAnd(planBudget(ChatContextProjector.window(GROK_PROVIDER, MODEL, ChatRequestOptions()))?.U) {
            "grok window has U"
        }
        val sent = harness.sentB(CONVERSATION_ID)
        assertEquals(usable, sent)
        assertNotEquals(64_000, sent)
    }

    @Test
    fun compaction_uses_conversation_cap() = runTest {
        MetadataTestFixtures.applyRaw(metadata(LONG_CONTEXT))
        val coordinator = mockk<ContextCompactionCoordinator>(relaxed = true)
        val context = slot<ContextCompactionContext>()
        coEvery { coordinator.latestValid(any(), any()) } returns null
        coEvery { coordinator.compact(any(), any(), capture(context), any(), any()) } returns
            ContextCompactionResult(CompactOutcome.NOOP, null, emptyList())
        val stored = capConversation(cap = ContextBudgetCap.Custom(64_000))
            .copy(messages = listOf(message("u1", ChatRole.User, "Hello there")))
        // Global 300000: compaction also goes by the conversation tier.
        val harness = Harness(GROK_PROVIDER, defaultCap = ContextBudgetCap.Custom(300_000), compaction = coordinator, stored = stored)

        harness.repository.compactConversationNow(CONVERSATION_ID)

        assertTrue("manual compaction reached the coordinator", context.isCaptured)
        assertEquals(64_000, context.captured.B)
    }

    // ── helpers ──

    private fun capConversation(cap: ContextBudgetCap?) = Conversation(
        id = CONVERSATION_ID,
        title = "Cap",
        providerID = GROK_PROVIDER.id,
        providerKind = GROK_PROVIDER.kind,
        modelID = MODEL_ID,
        useMemory = false,
        contextCap = cap,
    )

    /** Attaches a conversation read back by production to this test's grok connection; contextCap is kept as-is. */
    private fun grokConversation(conversation: Conversation) = conversation.copy(
        providerID = GROK_PROVIDER.id,
        providerKind = GROK_PROVIDER.kind,
        modelID = MODEL_ID,
        useMemory = false,
    )

    private fun backupEntity(contextCap: String?) = ConversationEntity(
        id = "conversation-backup",
        title = "Backup",
        hasCustomTitle = false,
        providerID = "existing-provider",
        providerKind = ProviderKind.OpenAI.name,
        modelID = "gpt-4o",
        useMemory = true,
        previewText = "Hello",
        estimatedCost = 0.0,
        isDraft = false,
        draftText = "",
        createdAt = 10L,
        updatedAt = 10L,
        accountId = LOCAL_PARTITION_ID,
        contextCap = contextCap,
    )

    /** The plan budget computed by the production window plus the production projection (the same project as the send path). */
    private fun planBudget(window: ai.oriveo.community.core.context.ContextWindowInput) =
        ChatContextProjector.project(
            request = ChatContextRequest(ContextConversation(id = CONVERSATION_ID, useMemory = false)),
            rawMessages = listOf(message("u1", ChatRole.User, "Hello there")),
            window = window,
            rhoHi = ContextBudget.RHO0,
        )?.windowBudget

    private fun <T : Any> assertNotNullAnd(value: T?, message: () -> String): T {
        assertNotNull(message(), value)
        return value!!
    }

    private class FakeLedgerDao : ContextLedgerDao {
        val manifests = mutableListOf<ContextManifestEntity>()
        private val rho = linkedMapOf<Pair<String, String>, ContextRhoCalibrationEntity>()

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
    }

    private inner class Harness(
        private val provider: Provider,
        defaultCap: ContextBudgetCap = ContextBudgetCap.Auto,
        compaction: ContextCompactionCoordinator? = null,
        stored: Conversation? = null,
    ) {
        val dao = FakeLedgerDao()
        private val client = HttpClient(MockEngine {
            respond(SUCCESS_SSE, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also { openClients += it }
        private val conversationRepository = mockk<ConversationRepository>(relaxed = true).also {
            coEvery { it.getWithMessages(any()) } returns stored
        }
        private val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
            coEvery { it.getById(provider.id) } returns provider
        }
        val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            contextLedgerDao = dao,
            contextCompaction = compaction,
            contextDefaultCap = { defaultCap },
        )

        /** The B of this conversation's manifest that the production send path wrote into the ledger. */
        fun sentB(conversationId: String): Int? =
            dao.manifests.single { it.conversationId == conversationId }.manifest.B

        suspend fun send(text: String, conversation: Conversation = capConversation(cap = null)) {
            runCatching {
                repository.sendMessage(
                    conversation = conversation,
                    text = text,
                    provider = provider,
                    modelID = MODEL_ID,
                    existingMessages = emptyList(),
                    requestOptions = ChatRequestOptions(
                        activeModel = MODEL,
                        chatContext = ChatContextRequest(ContextConversation(id = conversation.id, useMemory = false)),
                    ),
                    outputs = ConversationStreamingOutputs(
                        streamingText = MutableStateFlow(""),
                        streamingMessageId = MutableStateFlow(null),
                    ),
                )
            }
        }
    }

    /** Wired like ConversationContextCapBackupTest: the production BackupService exports one conversation, imports it with ImportNewOnly, and returns the stored row. */
    private class BackupHarness {
        private val conversationDao = mockk<ConversationDao>()
        private val upserted = mutableListOf<ConversationEntity>()
        private val providerDao = mockk<ProviderDao>()
        private val messageDao = mockk<MessageDao>()
        private val folderDao = mockk<FolderDao>()
        private val skillDao = mockk<SkillDao>()
        private val noteDao = mockk<NoteDao>(relaxed = true)
        private val noteFolderDao = mockk<NoteFolderDao>(relaxed = true)
        private val secureKeyStore = mockk<SecureKeyStore>()
        private val attachmentStore = mockk<AttachmentStore>()
        private val preferenceDao = mockk<PreferenceDao>()

        suspend fun roundTrip(entity: ConversationEntity): ConversationEntity {
            mockkStatic(android.util.Log::class)
            try {
                every { android.util.Log.w(any<String>(), any<String>(), any<Throwable>()) } returns 0
                every { android.util.Log.w(any<String>(), any<String>()) } returns 0
                every { secureKeyStore.getApiKey(any(), any()) } returns null
                every { secureKeyStore.deleteApiKey(any(), any()) } just Runs
                every { secureKeyStore.saveApiKey(any(), any(), any()) } just Runs
                coEvery { attachmentStore.clearAll() } returns Unit
                every { attachmentStore.delete(any()) } just Runs
                every { attachmentStore.loadImageBytes(any()) } returns null
                every { attachmentStore.loadThumbnailBytes(any()) } returns null
                coEvery { preferenceDao.get(any()) } returns null
                coEvery { preferenceDao.set(any()) } returns Unit
                coEvery { preferenceDao.delete(any()) } returns Unit
                coEvery { providerDao.upsert(any()) } returns Unit
                coEvery { providerDao.getAll(any()) } returns listOf(
                    Provider(id = "existing-provider", kind = ProviderKind.OpenAI, apiKey = "")
                        .toEntity(LOCAL_PARTITION_ID),
                )
                coEvery { providerDao.getById(any(), any()) } returns null
                coEvery { providerDao.deleteByAccount(any()) } returns Unit
                coEvery { conversationDao.upsert(capture(upserted)) } returns Unit
                coEvery { conversationDao.getById(any(), any()) } returns null
                coEvery { conversationDao.deleteByAccount(any()) } returns Unit
                coEvery { messageDao.getByConversation(any(), any()) } returns emptyList()
                coEvery { messageDao.deleteRowsByConversation(any(), any()) } returns Unit
                coEvery { messageDao.upsert(any()) } returns Unit
                coEvery { folderDao.getAll(any()) } returns emptyList()
                coEvery { folderDao.countByAccount(any()) } returns 0
                coEvery { folderDao.upsert(any()) } returns Unit
                coEvery { folderDao.getById(any(), any()) } returns null
                coEvery { folderDao.deleteByAccount(any()) } returns Unit
                coEvery { skillDao.getBySource(any(), any()) } returns emptyList()
                coEvery { skillDao.getById(any()) } returns null
                coEvery { skillDao.upsert(any()) } returns Unit
                coEvery { skillDao.deleteBySource(any(), any()) } returns Unit
                coEvery { noteDao.getAll(any()) } returns emptyList()
                coEvery { noteDao.getById(any(), any()) } returns null
                coEvery { noteFolderDao.getAll(any()) } returns emptyList()
                coEvery { noteFolderDao.getById(any(), any()) } returns null
                val service = BackupService(
                    providerDao = providerDao,
                    conversationDao = conversationDao,
                    messageDao = messageDao,
                    folderDao = folderDao,
                    skillDao = skillDao,
                    noteDao = noteDao,
                    noteFolderDao = noteFolderDao,
                    json = Json { ignoreUnknownKeys = true; encodeDefaults = true },
                    secureKeyStore = secureKeyStore,
                    attachmentStore = attachmentStore,
                    preferenceDao = preferenceDao,
                    metadataRefresh = {},
                    runInTransaction = { block -> block() },
                )
                coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns listOf(entity)
                val exported = service.exportBackup()
                // Imported onto a device that does not have this conversation yet
                coEvery { conversationDao.getAll(LOCAL_PARTITION_ID) } returns emptyList()
                service.executeImport(mode = ImportMode.ImportNewOnly, bytes = exported)
                return upserted.single { it.id == entity.id }
            } finally {
                unmockkStatic(android.util.Log::class)
            }
        }
    }

    private fun message(id: String, role: ChatRole, text: String) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = GROK_PROVIDER.id,
        providerKind = GROK_PROVIDER.kind,
        providerName = GROK_PROVIDER.displayName,
        modelID = MODEL_ID,
        modelName = MODEL.name,
        state = ChatMessageState.Delivered,
    )

    private companion object {
        const val CONVERSATION_ID = "conversation-cap"
        const val MODEL_ID = "grok-4.7"
        const val LONG_CONTEXT =
            """{"thresholdTokens":200000,"promptPerMToken":4,"completionPerMToken":12,"cacheReadPerMToken":1}"""

        /** AIModel carries only W and no price-line field (T is never written into AIModel). */
        val MODEL = AIModel(id = MODEL_ID, name = "Grok 4.7", contextLength = 2_000_000)
        val GROK_PROVIDER = Provider(id = "grok-1", kind = ProviderKind.Grok, apiKey = "byok-key", models = listOf(MODEL))

        /** The model entry hangs under the grok catalog, with longContext embedded into pricing as-is. */
        fun metadata(longContext: String): String {
            val model = """
                "$MODEL_ID": {
                  "canonicalModelId": "$MODEL_ID",
                  "displayName": "Grok 4.7",
                  "contextLength": 2000000,
                  "pricingStatus": "paid",
                  "pricing": {"promptPerMToken": 2, "completionPerMToken": 6, "longContext": $longContext}
                }
            """.trimIndent()
            fun provider(name: String) = """
                "$name": {"displayName": "$name", "resolveMap": {"$MODEL_ID": "$MODEL_ID"}, "models": {$model}}
            """.trimIndent()
            return """{"version": 1, "contractVersion": 1, "providers": {${provider("grok")}}}"""
        }

        val SUCCESS_SSE = """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":900,"output_tokens":1}}}

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

        """.trimIndent() + "\n\n"
    }
}
