package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.testing.TestSharedPreferences
import ai.oriveo.community.core.capability.truth.ToolCallOrderEvidenceGolden
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Shared fixture `shared/test-fixtures/capability/tool-call-order.v1.json`: verdict order of tool_call for official / subscription connections
 * first-party > catalog > rejection memory (false only, revision at record time == current) > modelFacts (consulted only when the catalog misses) > local declaration of a hand-entered model
 * > memory true > unknown (allowed); empty / expired evidence in the catalog = unknown, never falling back to the top-level toolCall.
 * One `TOOL_CALL_ORDER_<id>` test per case: memory is recorded / queried through the production [ToolCallMemoryStore] (a revision mismatch voids it,
 * and after a declaration edit clearConnection is applied the way the repository does), then the production [CapabilityEvidenceProductionAdapter.toolCallVerdict] runs.
 *
 * The catalog takes the whole payload of the Server golden `tool-call-order-evidence.v1.json`, with the clock injected from the golden nowMs;
 * it writes no evidence view and does not rewrite candidate support / time windows. It is injected into a standalone MetadataClient through the production decode.
 */
class ToolCallOrderCapabilityContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val now = ToolCallOrderEvidenceGolden.nowMs
    private val official = Provider(id = "official-openAI", kind = ProviderKind.OpenAI)

    private val cases: Map<String, JsonObject> by lazy {
        readJson("shared/test-fixtures/capability/tool-call-order.v1.json").getValue("cases").jsonArray
            .associate { it.jsonObject["id"]!!.jsonPrimitive.content to it.jsonObject }
    }

    @Test
    fun `fixture ids are exactly the TOOL_CALL_ORDER tests`() {
        val tests = javaClass.declaredMethods.map { it.name }.filter { it.startsWith("TOOL_CALL_ORDER_") }
            .map { it.removePrefix("TOOL_CALL_ORDER_") }.toSet()
        assertEquals(cases.keys, tests)
    }

    @Test fun TOOL_CALL_ORDER_catalog_evidence_supported() = assertCase("catalog_evidence_supported")
    @Test fun TOOL_CALL_ORDER_catalog_evidence_unsupported() = assertCase("catalog_evidence_unsupported")
    @Test fun TOOL_CALL_ORDER_catalog_evidence_missing_no_top_level_fallback() = assertCase("catalog_evidence_missing_no_top_level_fallback")
    @Test fun TOOL_CALL_ORDER_hand_entered_model_facts_beat_local() = assertCase("hand_entered_model_facts_beat_local")
    @Test fun TOOL_CALL_ORDER_hand_entered_local_when_no_model_facts() = assertCase("hand_entered_local_when_no_model_facts")
    @Test fun TOOL_CALL_ORDER_hand_entered_memory_when_no_declaration() = assertCase("hand_entered_memory_when_no_declaration")
    @Test fun TOOL_CALL_ORDER_hand_entered_model_facts_beat_memory() = assertCase("hand_entered_model_facts_beat_memory")
    @Test fun TOOL_CALL_ORDER_hand_entered_nothing_fail_open() = assertCase("hand_entered_nothing_fail_open")
    @Test fun TOOL_CALL_ORDER_hand_entered_rejection_beats_model_facts() = assertCase("hand_entered_rejection_beats_model_facts")
    @Test fun TOOL_CALL_ORDER_hand_entered_rejection_beats_local_declaration() = assertCase("hand_entered_rejection_beats_local_declaration")
    @Test fun TOOL_CALL_ORDER_hand_entered_rejection_stale_facts_revision() = assertCase("hand_entered_rejection_stale_facts_revision")
    @Test fun TOOL_CALL_ORDER_hand_entered_rejection_void_after_declaration_edit() = assertCase("hand_entered_rejection_void_after_declaration_edit")
    @Test fun TOOL_CALL_ORDER_hand_entered_memory_true_does_not_beat_model_facts_false() = assertCase("hand_entered_memory_true_does_not_beat_model_facts_false")
    @Test fun TOOL_CALL_ORDER_catalog_evidence_beats_rejection() = assertCase("catalog_evidence_beats_rejection")
    @Test fun TOOL_CALL_ORDER_catalog_evidence_missing_rejection_applies() = assertCase("catalog_evidence_missing_rejection_applies")
    @Test fun TOOL_CALL_ORDER_subscription_rejection_beats_model_facts() = assertCase("subscription_rejection_beats_model_facts")

    /** Subscription route: /models has no tool field, so the first-party layer is always empty; model.toolCall is a server catalog bit, not first-party evidence. */
    private val subscription = Provider(
        id = "11111111-1111-4111-8111-111111111111",
        kind = ProviderKind.OpenAI,
        authMode = ai.oriveo.community.core.model.ProviderAuthMode.Subscription,
    )

    @Test
    fun `subscription catalog toolCall false does not beat modelFacts true`() {
        val model = AIModel(id = HAND_ENTERED_MODEL, name = HAND_ENTERED_MODEL, toolCall = false)
        val client = client(catalog = null, modelId = HAND_ENTERED_MODEL, modelFacts = true)
        assertEquals(true, client.modelFacts(subscription.kind, model.id)?.toolCall)
        assertEquals(
            true,
            CapabilityEvidenceProductionAdapter.toolCallVerdict(
                subscription, model, memoryVerdict = null, metadataClient = client, now = now,
            ),
        )
    }

    @Test
    fun `subscription without modelFacts falls to memory, ignoring catalog toolCall`() {
        val model = AIModel(id = HAND_ENTERED_MODEL, name = HAND_ENTERED_MODEL, toolCall = false)
        val client = client(catalog = null, modelId = HAND_ENTERED_MODEL, modelFacts = null)
        assertEquals(null, client.modelFacts(subscription.kind, model.id)?.toolCall)
        assertEquals(
            true,
            CapabilityEvidenceProductionAdapter.toolCallVerdict(
                subscription, model, memoryVerdict = true, metadataClient = client, now = now,
            ),
        )
    }

    @Test
    fun `subscription without modelFacts or memory is unknown even with catalog toolCall`() {
        val client = client(catalog = null, modelId = HAND_ENTERED_MODEL, modelFacts = null)
        listOf(true, false).forEach { catalogBit ->
            val model = AIModel(id = HAND_ENTERED_MODEL, name = HAND_ENTERED_MODEL, toolCall = catalogBit)
            assertEquals(
                "catalog toolCall=$catalogBit",
                null,
                CapabilityEvidenceProductionAdapter.toolCallVerdict(subscription, model, metadataClient = client, now = now),
            )
        }
    }

    @Test
    fun `library agent route omits tools for hand-entered rejection memory over modelFacts true`() {
        val model = AIModel(id = HAND_ENTERED_MODEL, name = HAND_ENTERED_MODEL, isManual = true)
        val previous = MetadataClient.instance
        MetadataClient.instance = client(catalog = null, modelId = HAND_ENTERED_MODEL, modelFacts = true)
        try {
            val rejected = CapabilityEvidenceProductionAdapter.toolCallProjection(official, model, memoryVerdict = false)
            assertEquals("unsupported", rejected.decision("tool_call")?.resolution?.support)
            assertEquals("connection_memory", rejected.decision("tool_call")?.resolution?.source)
            assertFalse(rejected.permitsOutbound("tool_call"))
            val noMemory = CapabilityEvidenceProductionAdapter.toolCallProjection(official, model, memoryVerdict = null)
            assertEquals("supported", noMemory.decision("tool_call")?.resolution?.support)
        } finally {
            MetadataClient.instance = previous
        }
    }

    @Test
    fun `editing a hand-entered declaration through ProviderRepository voids the rejection memory`() = runBlocking {
        val account = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
        val model = AIModel(id = HAND_ENTERED_MODEL, name = HAND_ENTERED_MODEL, toolCall = true, isManual = true)
        val initial = official.copy(id = "33333333-3333-4333-8333-333333333333", models = listOf(model))
        var stored: ai.oriveo.community.core.data.entity.ProviderEntity? =
            with(ai.oriveo.community.core.data.mapper.ProviderMapper) { initial.toEntity(account) }
        val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>(relaxed = true)
        coEvery { dao.getById(any(), any()) } coAnswers {
            stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
        }
        coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
        coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
        val memory = ToolCallMemoryStore({ TestSharedPreferences() }, json, factsRevision = { "r1" })
        val repository = ai.oriveo.community.core.data.repository.ProviderRepository(
            dao = dao,
            secureKeyStore = mockk(relaxed = true),
            openRouterService = mockk(relaxed = true),
            openAIService = mockk(relaxed = true),
            deepSeekService = mockk(relaxed = true),
            grokService = mockk(relaxed = true),
            anthropicService = mockk(relaxed = true),
            geminiService = mockk(relaxed = true),
            groqService = mockk(relaxed = true),
            togetherService = mockk(relaxed = true),
            fireworksService = mockk(relaxed = true),
            miniMaxService = mockk(relaxed = true),
            zhipuService = mockk(relaxed = true),
            qwenService = mockk(relaxed = true),
            moonshotService = mockk(relaxed = true),
            mistralService = mockk(relaxed = true),
            siliconFlowService = mockk(relaxed = true),
            relayService = mockk(relaxed = true),
            metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
            httpClient = mockk(relaxed = true),
            toolCallMemoryStore = memory,
        )
        assertTrue(memory.record(account, initial, model, false, "tools_rejected_4xx"))

        // Re-saving the same declaration (a cosmetic change) does not clear the memory.
        repository.updateProvider(initial.copy(customName = "Renamed"))
        assertEquals(false, memory.lookup(account, initial, model))

        val edited = model.copy(toolCall = false)
        repository.updateProvider(initial.copy(models = listOf(edited)))
        assertNull(memory.lookup(account, initial, edited))
    }

    // ── helpers ──

    private fun assertCase(id: String) {
        val case = cases.getValue(id)
        val catalog = case["catalog"]?.takeUnless { it is JsonNull }?.jsonObject
        val modelId = if (catalog != null) CATALOG_MODEL else HAND_ENTERED_MODEL
        val provider = if ((case["form"] as? JsonPrimitive)?.content == "subscription") subscription else official
        val model = AIModel(
            id = modelId,
            name = modelId,
            toolCall = case.bool("localDeclaration"),
            // Only a hand-entered id on an official connection (which may happen to share an id with the catalog) records memory; the subscription route is eligible by itself.
            isManual = provider === official,
        )
        val client = client(catalog, modelId, case.bool("modelFacts"))
        if (catalog == null) {
            assertEquals(id, null, client.currentCapabilityEvidenceModel(modelId, provider.kind))
        }
        val verdict = CapabilityEvidenceProductionAdapter.toolCallVerdict(
            provider, model, memoryVerdict = memoryVerdict(case, provider, model), metadataClient = client, now = now,
        )
        val expect = case.getValue("expect").jsonObject
        assertEquals(id, expect.bool("verdict"), verdict)
        // Allow rule: tools are withheld only when false is confirmed.
        assertEquals(id, expect.bool("sendsTools"), verdict != false)
    }

    /** Fixture memory goes through the production memory store: record with the revision at record time, lookup with the current revision; after a declaration edit the repository clears the connection. */
    private fun memoryVerdict(case: JsonObject, provider: Provider, model: AIModel): Boolean? {
        val memory = case["memory"]?.takeUnless { it is JsonNull }?.jsonObject ?: return null
        var revision: String? = (memory["factsRevision"] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content
        val store = ToolCallMemoryStore({ TestSharedPreferences() }, json, factsRevision = { revision })
        store.record(PARTITION, provider, model, memory.bool("value")!!, "fixture")
        if (memory.bool("declarationEditedAfterRecord") == true) store.clearConnection(PARTITION, provider.id)
        revision = (case["factsRevision"] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content
        return store.lookup(PARTITION, provider, model)
    }

    private fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull

    /**
     * The catalog takes the whole Server golden payload ([ToolCallOrderEvidenceGolden]): with a non-empty catalog it picks
     * supported / unsupported / missing by evidence and only rewrites the top-level toolCall to the fixture value; with an empty catalog the golden supported
     * payload is sent as-is (the hand-entered model id is not in the catalog). modelFacts is written under [modelId].
     */
    private fun client(catalog: JsonObject?, modelId: String, modelFacts: Boolean?): MetadataClient {
        val variant = if (catalog == null) {
            "supported"
        } else {
            (catalog["evidence"] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content ?: "missing"
        }
        return ToolCallOrderEvidenceGolden.client(
            variant = variant,
            topLevelToolCall = catalog?.get("topLevelToolCall"),
            modelFacts = modelFacts?.let { mapOf(modelId to it) }.orEmpty(),
            etag = "\"tool-call-order\"",
        )
    }

    private fun repoRoot(): File = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

    private fun readJson(relativePath: String): JsonObject =
        json.parseToJsonElement(File(repoRoot(), relativePath).readText()).jsonObject

    private companion object {
        val CATALOG_MODEL = ToolCallOrderEvidenceGolden.modelId
        const val HAND_ENTERED_MODEL = "my-hand-typed-model"
        const val PARTITION = "account-tool-call-order"
    }
}
