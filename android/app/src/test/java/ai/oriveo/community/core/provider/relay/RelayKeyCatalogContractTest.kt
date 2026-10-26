package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.util.Collections
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * Driven by the fixture `shared/test-fixtures/relay/key-binding.v1.json` catalogCases / shellCases:
 * the merge pure function per caseId; the shell via the production refresh decoder; per-key catalog fetches and key changes via the production ProviderRepository (upstream MockEngine,
 * persisted objects encoded/decoded by the production ProviderMapper).
 */
class RelayKeyCatalogContractTest {

    // Catalog decoding fills in groups / names from the global MetadataClient.instance (current production behavior), which changes the merge order;
    // this class asserts the order under empty metadata, so each case swaps in a fresh instance and restores the old one afterwards, ignoring global snapshots left by other tests.
    private lateinit var previousMetadata: MetadataClient

    @Before
    fun isolateMetadata() {
        previousMetadata = MetadataClient.instance
        MetadataClient.instance = MetadataClient()
    }

    @After
    fun restoreMetadata() {
        MetadataClient.instance = previousMetadata
    }

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/key-binding.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private fun cases(section: String): List<JsonObject> =
        fixture.getValue(section).jsonObject.getValue("cases").jsonArray.map { it.jsonObject }

    private fun case(section: String, id: String): JsonObject =
        cases(section).single { it.getValue("caseId").jsonPrimitive.content == id }

    private fun JsonElement.strings(): List<String> = jsonArray.map { it.jsonPrimitive.content }

    private fun model(id: String, listedBy: List<String>? = null) = AIModel(id = id, name = id, relayListedByKeyIDs = listedBy)

    private fun assertCatalog(id: String) {
        val c = case("catalogCases", id)
        val keys = c.getValue("keys").strings()
        val previous = c.getValue("previous").jsonArray.map { it.jsonObject }.map { entry ->
            model(entry.getValue("id").jsonPrimitive.content, entry["relayListedByKeyIDs"]?.strings())
        }
        val results = c.getValue("results").jsonObject.mapValues { (_, raw) ->
            when {
                raw is JsonPrimitive && raw.content == "skipped" -> RelayKeyBinding.CatalogFetch.Skipped
                "ok" in raw.jsonObject -> RelayKeyBinding.CatalogFetch.Ok(raw.jsonObject.getValue("ok").strings().map { model(it) })
                else -> {
                    val status = raw.jsonObject.getValue("status").takeUnless { it is JsonNull }?.jsonPrimitive?.intOrNull
                    val body = raw.jsonObject.getValue("body").jsonPrimitive.content
                    RelayKeyBinding.CatalogFetch.Failed(status, status?.let { RelayKeyAccess.classify(it, body) } ?: ai.oriveo.community.core.model.RelayKeyAccessOutcome.None)
                }
            }
        }
        val merged = RelayKeyBinding.mergeCatalog(keys, previous, results)
        val expect = c.getValue("expect").jsonObject
        val expectedCatalog = expect.getValue("catalog").jsonArray.map { it.jsonObject }
        assertEquals(id, expectedCatalog.map { it.getValue("id").jsonPrimitive.content }, merged.catalog.map { it.id })
        assertEquals(
            id,
            expectedCatalog.map { it.getValue("relayListedByKeyIDs").strings() },
            merged.catalog.map { it.relayListedByKeyIDs },
        )
        assertEquals(
            id,
            expect.getValue("statuses").jsonObject.mapValues { it.value.jsonPrimitive.content },
            merged.statuses.mapValues { it.value.state },
        )
    }

    @Test
    fun `KEY-CATALOG-union_in_key_order`() = assertCatalog("union_in_key_order")

    @Test
    fun `KEY-CATALOG-failed_key_keeps_previous_listing`() = assertCatalog("failed_key_keeps_previous_listing")

    @Test
    fun `KEY-CATALOG-all_failed_keeps_everything`() = assertCatalog("all_failed_keeps_everything")

    @Test
    fun `KEY-CATALOG-dropped_by_its_only_key_leaves`() = assertCatalog("dropped_by_its_only_key_leaves")

    @Test
    fun `KEY-CATALOG-skipped_key_keeps_listing_and_status`() = assertCatalog("skipped_key_keeps_listing_and_status")

    @Test
    fun `KEY-CATALOG-status_mapping_403_quota_and_plain`() = assertCatalog("status_mapping_403_quota_and_plain")

    private suspend fun assertShell(id: String) {
        val c = case("shellCases", id)
        val body = c.getValue("body").jsonPrimitive.content
        val json = Json { ignoreUnknownKeys = true }
        val coordinator = RelayTransportCoordinator(
            client = HttpClient(
                MockEngine { respond(body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString())) },
            ),
            json = json,
            transportRegistry = TransportRegistry(json),
        )
        // Production decoding before sorting: fixture id order.
        assertEquals(id, c.getValue("expect").strings(), coordinator.decodeRelayCatalogIDs(body))
        // The whole production refresh (sorted by group / name after decoding; single-key output unchanged): only the id set is asserted.
        val synced = coordinator.syncProvider("sk-a", null, "https://relay.example.com/v1", RelayRequestedConfig())
        assertEquals(id, c.getValue("expect").strings().toSet(), synced.models.map { it.id }.toSet())
    }

    @Test
    fun `KEY-SHELL-openai_list`() = runTest { assertShell("openai_list") }

    @Test
    fun `KEY-SHELL-new_api_success`() = runTest { assertShell("new_api_success") }

    @Test
    fun `KEY-SHELL-anthropic_page`() = runTest { assertShell("anthropic_page") }

    @Test
    fun `number of fixture cases matches this class coverage`() {
        assertEquals(6, cases("catalogCases").size)
        assertEquals(3, cases("shellCases").size)
    }

    // ── production refresh / key change ──

    /** Two keys: the production refresh sends two catalog requests, each with its own Authorization; the merged result equals union_in_key_order. */
    @Test
    fun `KEY-CATALOG production refresh fetches each key with its own secret`() = runTest {
        val c = case("catalogCases", "union_in_key_order")
        val harness = RepositoryHarness(
            initial = relayProvider(
                keys = listOf(RelayKey("initial"), RelayKey("k-claude", apiKey = "sk-b")),
                catalog = emptyList(),
            ),
            catalogs = mapOf("sk-a" to listOf("gpt-4o", "gpt-4.1"), "sk-b" to listOf("claude-sonnet-4-5", "gpt-4o")),
        )
        assertTrue(harness.repository.refreshRelayCatalogOnly(PROVIDER_ID).catalogSucceeded)

        assertEquals(listOf("Bearer sk-a", "Bearer sk-b"), harness.catalogAuthorizations)
        val stored = harness.current()
        val expected = c.getValue("expect").jsonObject.getValue("catalog").jsonArray.map { it.jsonObject }
        // Each key's entries are sorted by the existing decoder and then merged, so listers are compared by id, not by overall order.
        assertEquals(
            expected.associate { it.getValue("id").jsonPrimitive.content to it.getValue("relayListedByKeyIDs").strings() },
            stored.catalogModels.associate { it.id to it.relayListedByKeyIDs },
        )
        assertEquals(expected.size, stored.catalogModels.size)
        // After merging, the single-key path's sorting is applied again, so both paths produce the same order.
        assertEquals(
            stored.catalogModels.sortedWith(RelayTransportCoordinator.CATALOG_ORDER).map { it.id },
            stored.catalogModels.map { it.id },
        )
        assertEquals(listOf("ok", "ok"), stored.relayKeys!!.map { it.status?.state })
    }

    /** Changing the Key of a single-key connection: the catalog is kept, the unverified flag and re-verification are unchanged; on verification failure the catalog stays as is and no catalog request is sent. */
    @Test
    fun `KEY-REPLACE-single_key_keeps_catalog`() = runTest {
        val catalog = listOf(model("gpt-4o"), model("gpt-4.1"))
        val harness = RepositoryHarness(
            initial = relayProvider(keys = null, catalog = catalog, enabled = listOf(model("gpt-4o"))),
            catalogs = emptyMap(),
            pingStatus = HttpStatusCode.Unauthorized,
        )
        val thrown = runCatching { harness.repository.updateApiKey(PROVIDER_ID, "sk-new") }.exceptionOrNull()

        assertTrue("a verification failure is handed back to the caller as before", thrown != null)
        assertEquals(1, harness.pingAuthorizations.size)
        assertEquals("Bearer sk-new", harness.pingAuthorizations.single())
        assertTrue(harness.catalogAuthorizations.isEmpty())
        val stored = harness.current()
        assertEquals("sk-new", harness.apiKey)
        assertEquals(listOf("gpt-4o", "gpt-4.1"), stored.catalogModels.map { it.id })
        assertEquals(listOf("gpt-4o"), stored.models.map { it.id })
        assertTrue(stored.status is ProviderConnectionState.Issue)
        assertNull(stored.lastCheckedAt)
        // A verification 401 is written into the primary key's state: the list holds only that entry, with no other key fields.
        assertEquals(listOf("initial" to "invalid"), stored.relayKeys?.map { it.id to it.status?.state })
        assertTrue("listers are not written", stored.catalogModels.all { it.relayListedByKeyIDs == null })
    }

    /** Changing the value of one key in a multi-key connection: only one catalog request is sent with the new value; the entries and states of the other keys are untouched. */
    @Test
    fun `KEY-REPLACE-multi_refetches_only_that_key`() = runTest {
        val initialStatus = RelayKeyStatus("ok", checkedAt = 1_000L)
        val harness = RepositoryHarness(
            initial = relayProvider(
                keys = listOf(
                    RelayKey("initial", status = initialStatus),
                    RelayKey("k-b", apiKey = "sk-b", status = RelayKeyStatus("invalid", 401, 1_000L)),
                ),
                catalog = listOf(model("gpt-4o", listOf("initial")), model("claude-opus-4", listOf("k-b"))),
                enabled = listOf(AIModel(id = "claude-opus-4", name = "claude-opus-4", relayKeyID = "k-b", relayDeniedKeyID = "k-b")),
            ),
            catalogs = mapOf("sk-b2" to listOf("claude-opus-4", "claude-sonnet-4-5")),
        )
        harness.repository.replaceRelayKeySecret(PROVIDER_ID, "k-b", "sk-b2")

        assertEquals(listOf("Bearer sk-b2"), harness.catalogAuthorizations)
        val stored = harness.current()
        assertEquals("sk-b2", harness.secrets["k-b"])
        assertEquals(listOf("gpt-4o", "claude-opus-4", "claude-sonnet-4-5"), stored.catalogModels.map { it.id })
        assertEquals(listOf(listOf("initial"), listOf("k-b"), listOf("k-b")), stored.catalogModels.map { it.relayListedByKeyIDs })
        assertEquals(initialStatus, stored.relayKeys!!.first().status)
        assertEquals("ok", stored.relayKeys!![1].status?.state)
        assertNull(stored.models.single().relayDeniedKeyID)
        assertEquals("k-b", stored.models.single().relayKeyID)
    }

    /** The key's value was changed while in flight: this result is treated as skipped, and the previous entries and listers are kept. */
    @Test
    fun `KEY-CATALOG secret changed in flight is skipped`() = runTest {
        lateinit var harness: RepositoryHarness
        harness = RepositoryHarness(
            initial = relayProvider(
                keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b")),
                catalog = listOf(model("gpt-4o", listOf("initial")), model("claude-opus-4", listOf("k-b"))),
            ),
            catalogs = mapOf("sk-a" to listOf("gpt-4o"), "sk-b" to listOf("claude-sonnet-4-5")),
            onCatalog = { auth -> if (auth == "Bearer sk-b") harness.secrets["k-b"] = "sk-b-rotated" },
        )
        assertTrue(harness.repository.refreshRelayCatalogOnly(PROVIDER_ID).catalogSucceeded)
        val stored = harness.current()
        assertEquals(
            mapOf("gpt-4o" to listOf("initial"), "claude-opus-4" to listOf("k-b")),
            stored.catalogModels.associate { it.id to it.relayListedByKeyIDs },
        )
        assertEquals("ok", stored.relayKeys!!.first().status?.state)
        assertNull(stored.relayKeys!![1].status)
    }

    /** Both keys fail to fetch: the catalog is untouched, each key's state is written, and failure is returned following the single-key failure semantics. */
    @Test
    fun `KEY-CATALOG all keys failing keeps the catalog writes statuses and fails`() = runTest {
        val catalog = listOf(model("gpt-4o"), model("claude-opus-4", listOf("k-b")))
        val harness = RepositoryHarness(
            initial = relayProvider(keys = listOf(RelayKey("initial"), RelayKey("k-b", apiKey = "sk-b")), catalog = catalog),
            catalogs = emptyMap(),
        )
        val outcome = harness.repository.refreshRelayCatalogOnly(PROVIDER_ID)
        assertTrue(!outcome.catalogSucceeded && outcome.error != null)
        val stored = harness.current()
        assertEquals(catalog.map { it.id to it.relayListedByKeyIDs }, stored.catalogModels.map { it.id to it.relayListedByKeyIDs })
        assertEquals(listOf("invalid", "invalid"), stored.relayKeys!!.map { it.status?.state })
        assertEquals(listOf(401, 401), stored.relayKeys!!.map { it.status?.httpStatus })
        assertEquals(ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE, stored.lastError)
    }

    private fun relayProvider(keys: List<RelayKey>?, catalog: List<AIModel>, enabled: List<AIModel> = emptyList()) = Provider(
        id = PROVIDER_ID,
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        baseUrlText = "https://relay.example.com/v1",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            resolvedAPIBaseURL = "https://relay.example.com/v1",
        ),
        relayKeys = keys,
        models = enabled,
        catalogModels = catalog,
    )

    /** Production ProviderRepository + production RelayService; the MockEngine upstream returns each key's catalog according to Authorization. */
    private inner class RepositoryHarness(
        initial: Provider,
        catalogs: Map<String, List<String>>,
        pingStatus: HttpStatusCode = HttpStatusCode.OK,
        onCatalog: (String?) -> Unit = {},
    ) {
        var apiKey = "sk-a"
        val secrets: MutableMap<String, String> = initial.relayKeys.orEmpty().drop(1).associate { it.id to it.apiKey }.toMutableMap()
        var stored: ProviderEntity? = with(ProviderMapper) { initial.toEntity(ACCOUNT) }
        val catalogAuthorizations: MutableList<String?> = Collections.synchronizedList(mutableListOf())
        val pingAuthorizations: MutableList<String?> = Collections.synchronizedList(mutableListOf())
        private val json = Json { ignoreUnknownKeys = true }

        private val engine = MockEngine { request ->
            val auth = request.headers[HttpHeaders.Authorization]
            if (request.method == HttpMethod.Get) {
                catalogAuthorizations += auth
                onCatalog(auth)
                val ids = catalogs[auth?.removePrefix("Bearer ")]
                    ?: return@MockEngine respond("{\"error\":\"Invalid API key\"}", HttpStatusCode.Unauthorized)
                respond(
                    "{\"data\":[" + ids.joinToString(",") { "{\"id\":\"$it\"}" } + "]}",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            } else {
                pingAuthorizations += auth
                respond(
                    if (pingStatus == HttpStatusCode.OK) "{\"id\":\"x\",\"choices\":[{\"message\":{\"content\":\"p\"}}]}" else "{\"error\":\"Invalid API key\"}",
                    pingStatus,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            }
        }

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } answers { apiKey }
            every { keys.saveApiKey(any(), any(), any()) } answers { apiKey = thirdArg() }
            every { keys.getRelayKeySecret(any(), any(), any()) } answers { secrets[thirdArg()] }
            every { keys.saveRelayKeySecrets(any(), any(), any()) } answers {
                thirdArg<List<RelayKey>?>().orEmpty().drop(1).filter { it.apiKey.isNotEmpty() }.forEach { secrets[it.id] = it.apiKey }
            }
            ProviderRepository(
                dao = dao,
                secureKeyStore = keys,
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
                relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json)),
                metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
                relayModelFamily = { null },
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) { secrets[it] } }
    }

    private companion object {
        const val ACCOUNT = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
        const val PROVIDER_ID = "33333333-3333-4333-8333-333333333333"
    }
}
