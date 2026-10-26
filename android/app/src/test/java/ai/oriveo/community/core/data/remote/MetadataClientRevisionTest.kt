package ai.oriveo.community.core.data.remote

import android.content.Context
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The request schema switch (index / catalog query + headers) and the Room round trip of the new schema 2 fields. */
@OptIn(ExperimentalCoroutinesApi::class)
class MetadataClientRevisionTest {

    private data class Call(val pathAndQuery: String, val headers: Map<String, String>, val ifNoneMatch: String?)

    private fun recordingTransport(requestSchema: Int, calls: MutableList<Call>) =
        HttpUrlConnectionMetadataSplitTransport(requestSchema) { path, headers, ifNoneMatch ->
            calls += Call(path, headers, ifNoneMatch)
            MetadataTransportResponse(304, null, null, 0)
        }

    @Test
    fun `production request schema is 3`() {
        assertEquals(3, MetadataClient.METADATA_REQUEST_SCHEMA)
    }

    @Test
    fun `production schema 3 adds query and header to index and catalog`() = runTest {
        val calls = mutableListOf<Call>()
        val transport = recordingTransport(requestSchema = MetadataClient.METADATA_REQUEST_SCHEMA, calls = calls)

        transport.fetchIndex("\"idx\"", null)
        transport.fetchCatalog("openAI", null, null)

        val header = mapOf("X-Oriveo-Metadata-Schema" to "3")
        assertEquals(
            listOf(
                Call("/api/metadata?view=index&schema=3", header, "\"idx\""),
                Call("/api/metadata?view=catalog&provider=openAI&schema=3", header, null),
            ),
            calls,
        )
    }

    @Test
    fun `schema 1 keeps historical URL and headers`() = runTest {
        val calls = mutableListOf<Call>()
        val transport = recordingTransport(requestSchema = 1, calls = calls)

        transport.fetchIndex(null, null)
        transport.fetchCatalog("open AI", "\"cat\"", null)

        assertEquals(
            listOf(
                Call("/api/metadata?view=index", emptyMap(), null),
                Call("/api/metadata?view=catalog&provider=open+AI", emptyMap(), "\"cat\""),
            ),
            calls,
        )
    }

    @Test
    fun `schema 2 lifecycle and parameterSupport survive Room cold start`() = runTest {
        val dao = FakeMetadataCacheDao()
        val writer = MetadataClient(
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport {
                MetadataTransportResponse(200, "\"etag-7\"", SCHEMA2_PAYLOAD, SCHEMA2_PAYLOAD.length.toLong())
            },
            nowMillis = { 1_000L },
            failureReporter = { error("unexpected failure: $it") },
        )
        writer.initialize(context())
        assertEquals(1, dao.upsertCount)

        // Cold start: the new instance reads back from Room only; background confirmation is always 304 and brings no new content.
        val reader = MetadataClient(
            backgroundScope = this,
            ioDispatcher = StandardTestDispatcher(testScheduler),
            metadataCacheDao = dao,
            metadataTransport = MetadataTransport { MetadataTransportResponse(304, "\"etag-7\"", null, 0) },
            nowMillis = { 2_000L },
            failureReporter = { error("unexpected failure: $it") },
        )
        reader.initialize(context())
        advanceUntilIdle()

        val data = Json.parseToJsonElement(requireNotNull(reader.encodedCachePayloadForTesting()))
            .jsonObject.getValue("data").jsonObject
        assertEquals(2, data.getValue("metadataSchema").jsonPrimitive.content.toInt())
        assertEquals(7L, data.getValue("metadataRevision").jsonPrimitive.content.toLong())
        assertEquals("2026-10-19T00:00:00Z", data.getValue("generatedAt").jsonPrimitive.content)
        assertEquals(6L, data.getValue("rollbackOf").jsonPrimitive.content.toLong())
        val model = data.getValue("providers").jsonObject.getValue("openAI").jsonObject
            .getValue("models").jsonObject.getValue("gpt-x").jsonObject
        assertEquals(
            Json.parseToJsonElement("""{"state":"deprecated","shutdownAt":"2026-12-01T00:00:00Z","signal":"upstream_shutdown_date"}"""),
            model.getValue("lifecycle"),
        )
        assertEquals(
            Json.parseToJsonElement("""{"temperature":{"state":"unsupported"}}"""),
            model.getValue("parameterSupport"),
        )
    }

    @Test
    fun `revision cases match shared expectations`() {
        val cases = Json.parseToJsonElement(workspaceFile("shared/model-contracts/metadata_payload.v2.cases.json").readText())
            .jsonObject.getValue("revisionCases").jsonArray
        assertTrue(cases.isNotEmpty())
        for (raw in cases) {
            val case = raw.jsonObject
            val cached = case.getValue("cached").takeUnless { it is JsonNull }?.jsonPrimitive?.longOrNull
            val incoming = case.getValue("incoming").jsonPrimitive.content.toLong()
            val expected = when (val expect = case.getValue("expect").jsonPrimitive.content) {
                "accept" -> MetadataRevisionVerdict.Accept
                "unchanged" -> MetadataRevisionVerdict.Unchanged
                "reject" -> MetadataRevisionVerdict.Reject
                else -> error("unknown expect $expect")
            }
            assertEquals(case.getValue("name").jsonPrimitive.content, expected, compareMetadataRevision(cached, incoming))
        }
    }

    @Test
    fun `older index revision is rejected and keeps the cached index`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editIndex { asSchemaV2(it, 5) }
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = splitClient(server, dao, reports)
        client.initialize(context())
        assertTrue(reports.isEmpty())
        val catalogCalls = server.catalogCalls.size

        // The revision 4 index also registers a new catalogRevision: if it were adopted the catalog would be fetched.
        server.editIndex { data -> withCatalogRevision(asSchemaV2(data, 4), "openAI", NEW_CATALOG_REVISION) }
        client.refresh()

        assertEquals(catalogCalls, server.catalogCalls.size)
        val row = indexRow(dao)
        assertEquals(5L, row.getValue("data").jsonObject.getValue("metadataRevision").jsonPrimitive.content.toLong())
        assertEquals(server.eTagAt(1), row.getValue("eTag").jsonPrimitive.content)
        val report = reports.single()
        assertEquals("revision_regressed", report["reason"])
        assertEquals("index", report["provider_kind"])
        assertEquals("index_decode", report["phase"])
        assertTrue(client.providerModelIds(ProviderKind.OpenAI).isNotEmpty())
    }

    @Test
    fun `equal index revision keeps data and refreshes ETag in one upsert`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editIndex { asSchemaV2(it, 5) }
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = splitClient(server, dao, reports)
        client.initialize(context())
        val catalogCalls = server.catalogCalls.size
        val indexUpserts = dao.upsertKeys.count { it == MetadataCacheEntity.INDEX_KEY }

        server.editIndex { data -> withCatalogRevision(data, "openAI", NEW_CATALOG_REVISION) }
        client.refresh()

        assertEquals(catalogCalls, server.catalogCalls.size)
        assertEquals(indexUpserts + 1, dao.upsertKeys.count { it == MetadataCacheEntity.INDEX_KEY })
        val row = indexRow(dao)
        assertEquals(server.eTagAt(2), row.getValue("eTag").jsonPrimitive.content)
        val openAI = row.getValue("data").jsonObject.getValue("providers").jsonObject.getValue("openAI").jsonObject
        assertTrue(openAI.getValue("catalogRevision").jsonPrimitive.content != NEW_CATALOG_REVISION)
        assertTrue(reports.isEmpty())

        // The next conditional request carries the refreshed ETag and the server answers 304.
        client.refresh()
        assertEquals(indexUpserts + 1, dao.upsertKeys.count { it == MetadataCacheEntity.INDEX_KEY })
        assertEquals(catalogCalls, server.catalogCalls.size)
        assertTrue(reports.isEmpty())
    }

    @Test
    fun `older catalog revision is rejected against that provider's cached row`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { asSchemaV2(it, 5) }
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = splitClient(server, dao, reports)
        client.initialize(context())
        val before = client.resolveCatalogModel(MODEL_ID, ProviderKind.OpenAI)?.displayName
        assertTrue(reports.isEmpty())

        server.editCatalog("openAI", NEW_CATALOG_REVISION) { data -> renamed(asSchemaV2(data, 4)) }
        client.refresh()

        assertEquals(before, client.resolveCatalogModel(MODEL_ID, ProviderKind.OpenAI)?.displayName)
        val row = catalogRow(dao, "openAI")
        assertEquals(5L, row.getValue("payloadRevision").jsonPrimitive.content.toLong())
        val regressed = reports.single { it["reason"] == "revision_regressed" }
        assertEquals("openai", regressed["provider_kind"])
        assertEquals("catalog_decode", regressed["phase"])
    }

    @Test
    fun `equal catalog revision keeps data and refreshes the row ETag`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { asSchemaV2(it, 5) }
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = splitClient(server, dao, reports)
        client.initialize(context())
        val before = client.resolveCatalogModel(MODEL_ID, ProviderKind.OpenAI)?.displayName
        val beforeRow = catalogRow(dao, "openAI")

        server.editCatalog("openAI", NEW_CATALOG_REVISION) { data -> renamed(data) }
        client.refresh()

        assertEquals(before, client.resolveCatalogModel(MODEL_ID, ProviderKind.OpenAI)?.displayName)
        val row = catalogRow(dao, "openAI")
        assertEquals(server.catalogETag("openAI"), row.getValue("eTag").jsonPrimitive.content)
        assertEquals(beforeRow.getValue("data"), row.getValue("data"))
        assertEquals(5L, row.getValue("payloadRevision").jsonPrimitive.content.toLong())
        assertNull(reports.firstOrNull { it["reason"] == "revision_regressed" })
    }

    @Test
    fun `rejected older index reports only the regression, not its bad providers`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editIndex { asSchemaV2(it, 5) }
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = splitClient(server, dao, reports)
        client.initialize(context())
        assertTrue(reports.isEmpty())

        server.editIndex { data -> withBrokenProvider(asSchemaV2(data, 4), "anthropic") }
        client.refresh()

        assertEquals("revision_regressed", reports.single()["reason"])

        // Control: the same bad provider does report an entry error under an adopted higher revision.
        reports.clear()
        server.editIndex { data -> asSchemaV2(data, 6) }
        client.refresh()
        assertEquals("anthropic", reports.single { it["reason"] == "model_entry_invalid" }["provider_kind"])
    }

    @Test
    fun `equal index revision does not report its bad providers`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editIndex { asSchemaV2(it, 5) }
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = splitClient(server, dao, reports)
        client.initialize(context())

        server.editIndex { data -> withBrokenProvider(data, "anthropic") }
        client.refresh()

        assertTrue(reports.isEmpty())
    }

    @Test
    fun `rejected or equal catalog revision does not report its bad models`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { asSchemaV2(it, 5) }
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = splitClient(server, dao, reports)
        client.initialize(context())
        assertTrue(reports.isEmpty())

        server.editCatalog("openAI", NEW_CATALOG_REVISION) { data -> withUnresolvedControls(asSchemaV2(data, 4)) }
        client.refresh()
        assertEquals("revision_regressed", reports.single()["reason"])

        reports.clear()
        server.editCatalog("openAI", "sha256:" + "c".repeat(64)) { data -> asSchemaV2(data, 5) }
        client.refresh()
        // An equal revision is treated like a 304 of a different generation (one revision_mismatch is reported against the index), but no entry error is reported.
        assertNull(reports.firstOrNull { it["reason"] == "model_entry_invalid" })

        // Control: the same bad model does report an entry error under an adopted higher revision.
        reports.clear()
        server.editCatalog("openAI", "sha256:" + "e".repeat(64)) { data -> asSchemaV2(data, 6) }
        client.refresh()
        assertEquals(MODEL_ID, reports.single { it["reason"] == "model_entry_invalid" }["model_id"])
    }

    @Test
    fun `unresolved parametersRef drops that model and reports it once`() = runTest {
        val server = FakeSplitServer(splitFixture())
        server.editCatalog("openAI") { data -> withUnresolvedParameters(asSchemaV2(data, 5), MODEL_ID) }
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = splitClient(server, dao, reports)
        client.initialize(context())
        client.refresh()

        assertNull(client.resolveCatalogModel(MODEL_ID, ProviderKind.OpenAI))
        assertTrue(client.providerModelIds(ProviderKind.OpenAI).isNotEmpty())
        val report = reports.single()
        assertEquals("model_entry_invalid", report["reason"])
        assertEquals("openai", report["provider_kind"])
        assertEquals(MODEL_ID, report["model_id"])
        assertEquals("unresolved_ref", report["keyword"])
        assertEquals("/parametersRef", report["instance_path"])
    }

    /** A provider's models in the index is not an object: schema 2 validation drops the whole provider. */
    private fun withBrokenProvider(index: JsonObject, key: String): JsonObject {
        val providers = index.getValue("providers").jsonObject
        val provider = JsonObject(providers.getValue(key).jsonObject + ("models" to JsonPrimitive("bad")))
        return JsonObject(index + ("providers" to JsonObject(providers + (key to provider))))
    }

    /** The capabilityControlsRef of [MODEL_ID] points at a missing table entry: schema 2 validation drops that model. */
    private fun withUnresolvedControls(data: JsonObject): JsonObject {
        val models = data.getValue("models").jsonObject
        val model = JsonObject(models.getValue(MODEL_ID).jsonObject + ("capabilityControlsRef" to JsonPrimitive("missing")))
        return JsonObject(data + ("models" to JsonObject(models + (MODEL_ID to model))))
    }

    /** Swaps in a profile for [modelId] whose generation.parametersRef cannot be found in generationParameters. */
    private fun withUnresolvedParameters(data: JsonObject, modelId: String): JsonObject {
        val tables = data.getValue("tables").jsonObject
        val profiles = tables.getValue("profiles").jsonObject
        val models = data.getValue("models").jsonObject
        val model = models.getValue(modelId).jsonObject
        val original = profiles.getValue(model.getValue("profilesRef").jsonPrimitive.content).jsonObject
        val generation = JsonObject(
            original.getValue("generation").jsonObject + ("parametersRef" to JsonPrimitive("sha256:" + "d".repeat(64))),
        )
        val broken = JsonObject(original + ("generation" to generation))
        val nextTables = JsonObject(tables + ("profiles" to JsonObject(profiles + ("broken" to broken))))
        val nextModel = JsonObject(model + ("profilesRef" to JsonPrimitive("broken")))
        return JsonObject(
            data + mapOf("tables" to nextTables, "models" to JsonObject(models + (modelId to nextModel))),
        )
    }

    private fun asSchemaV2(data: JsonObject, revision: Long): JsonObject = JsonObject(
        data + mapOf(
            "metadataSchema" to JsonPrimitive(2),
            "metadataRevision" to JsonPrimitive(revision),
            "generatedAt" to JsonPrimitive("2026-10-19T00:00:00Z"),
        ),
    )

    private fun withCatalogRevision(index: JsonObject, key: String, revision: String): JsonObject {
        val providers = index.getValue("providers").jsonObject
        val provider = JsonObject(providers.getValue(key).jsonObject + ("catalogRevision" to JsonPrimitive(revision)))
        return JsonObject(index + ("providers" to JsonObject(providers + (key to provider))))
    }

    private fun renamed(data: JsonObject): JsonObject {
        val models = data.getValue("models").jsonObject.mapValues { (_, raw) ->
            JsonObject(raw.jsonObject + ("displayName" to JsonPrimitive("Renamed")))
        }
        return JsonObject(data + ("models" to JsonObject(models)))
    }

    private fun indexRow(dao: FakeRowDao): JsonObject =
        Json.parseToJsonElement(dao.rows.getValue(MetadataCacheEntity.INDEX_KEY).payload).jsonObject

    private fun catalogRow(dao: FakeRowDao, key: String): JsonObject =
        Json.parseToJsonElement(dao.rows.getValue(MetadataCacheEntity.CATALOG_KEY_PREFIX + key).payload).jsonObject

    private fun TestScope.splitClient(
        server: FakeSplitServer,
        dao: FakeRowDao,
        reports: MutableList<Map<String, String>>,
    ): MetadataClient = MetadataClient(
        backgroundScope = this,
        ioDispatcher = StandardTestDispatcher(testScheduler),
        metadataCacheDao = dao,
        metadataTransport = MetadataTransport { error("lean must not be requested") },
        metadataSplitTransport = server,
        nowMillis = { 1_000L },
        failureReporter = { tags -> reports.add(tags) },
        metadataPayloadSchemaText = workspaceFile("shared/model-contracts/metadata_payload.v2.schema.json").readText(),
    ).also { client ->
        client.catalogDemandSupplier = { MetadataClient.CatalogDemand(setOf(ProviderKind.OpenAI), hasRelay = false) }
    }

    private fun splitFixture(): JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/metadata_catalog_contract.v1.json").readText())
            .jsonObject

    /** Server double (modeled on MetadataCatalogSplitTest.FakeSplitServer): index and catalog each carry an ETag and a match returns 304. */
    private class FakeSplitServer(root: JsonObject) : MetadataSplitTransport {
        private var index: JsonObject = root.getValue("indexResponse").jsonObject
        private val catalogs: MutableMap<String, JsonObject> = root.getValue("catalogResponses").jsonObject
            .mapValues { (_, value) -> value.jsonObject.getValue("data").jsonObject }
            .toMutableMap()
        private var indexGeneration = 0
        val catalogCalls = mutableListOf<Pair<String, String?>>()

        fun eTagAt(generation: Int) = "\"index-$generation\""
        private fun indexETag() = eTagAt(indexGeneration)
        fun catalogETag(key: String) = "\"catalog-$key-${revisionOf(catalogs.getValue(key))}\""
        private fun revisionOf(data: JsonObject) = (data.getValue("catalogRevision") as JsonPrimitive).content

        override suspend fun fetchIndex(ifNoneMatch: String?, cacheBust: String?): MetadataTransportResponse {
            if (ifNoneMatch == indexETag()) return MetadataTransportResponse(304, indexETag(), null, 0)
            val body = index.toString()
            return MetadataTransportResponse(200, indexETag(), body, body.length.toLong())
        }

        override suspend fun fetchCatalog(provider: String, ifNoneMatch: String?, revision: String?): MetadataTransportResponse {
            catalogCalls += provider to ifNoneMatch
            val data = catalogs[provider] ?: return MetadataTransportResponse(404, null, null, 0)
            val eTag = catalogETag(provider)
            if (ifNoneMatch == eTag) return MetadataTransportResponse(304, eTag, null, 0)
            val body = JsonObject(mapOf("code" to JsonPrimitive(0), "data" to data, "message" to JsonPrimitive("ok"))).toString()
            return MetadataTransportResponse(200, eTag, body, body.length.toLong())
        }

        /** Edits the catalog; when [newRevision] is given the catalog and the revision registered in the index change together (one snapshot generation change). */
        fun editCatalog(key: String, newRevision: String? = null, edit: (JsonObject) -> JsonObject) {
            var data = edit(catalogs.getValue(key))
            if (newRevision != null) {
                data = JsonObject(data + ("catalogRevision" to JsonPrimitive(newRevision)))
                editIndex { index ->
                    val providers = index.getValue("providers").jsonObject
                    val provider = providers.getValue(key).jsonObject
                    JsonObject(
                        index + ("providers" to JsonObject(providers + (key to JsonObject(provider + ("catalogRevision" to JsonPrimitive(newRevision)))))),
                    )
                }
            }
            catalogs[key] = data
        }

        fun editIndex(edit: (JsonObject) -> JsonObject) {
            val data = index.getValue("data").jsonObject
            index = JsonObject(index + ("data" to edit(data)))
            indexGeneration += 1
        }
    }

    /** Multi-row Room double (modeled on MetadataCatalogSplitTest.FakeRowDao) that also records the key of every upsert. */
    private class FakeRowDao : MetadataCacheDao {
        val rows = linkedMapOf<String, MetadataCacheEntity>()
        val upsertKeys = mutableListOf<String>()

        override suspend fun payloadLength(key: String): Int? =
            rows[key]?.payload?.let { it.codePointCount(0, it.length) }

        override suspend fun payloadChunk(start: Int, count: Int, key: String): String? {
            val payload = rows[key]?.payload ?: return null
            val total = payload.codePointCount(0, payload.length)
            val startIndex = (start - 1).coerceIn(0, total)
            val endIndex = (startIndex + count).coerceAtMost(total)
            return payload.substring(
                payload.offsetByCodePoints(0, startIndex),
                payload.offsetByCodePoints(0, endIndex),
            )
        }

        override suspend fun upsert(entity: MetadataCacheEntity) {
            upsertKeys += entity.key
            rows[entity.key] = entity
        }

        override suspend fun updatedAtMs(key: String): Long? = rows[key]?.updatedAtMs

        override suspend fun touch(key: String, updatedAtMs: Long): Int {
            val row = rows[key] ?: return 0
            rows[key] = row.copy(updatedAtMs = updatedAtMs)
            return 1
        }

        override suspend fun delete(key: String) {
            rows.remove(key)
        }

        override suspend fun deleteAllExcept(keep: String) {
            rows.keys.retainAll { it == keep }
        }

        override suspend fun clear() {
            rows.clear()
        }
    }

    /** Walks up from the working directory to find a path relative to the repository root (modeled on MetadataTestFixtures.workspaceFile). */
    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("$relative not found")
    }

    private fun context(): Context {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), Context.MODE_PRIVATE) } returns TestSharedPreferences()
        return context
    }

    /** Single-row Room double: chunked reads count by code point, the same way as the other metadata client cases. */
    private class FakeMetadataCacheDao(var entity: MetadataCacheEntity? = null) : MetadataCacheDao {
        var upsertCount = 0

        private fun payloadFor(key: String): String? = entity?.takeIf { it.key == key }?.payload

        override suspend fun payloadLength(key: String): Int? {
            val payload = payloadFor(key) ?: return null
            return payload.codePointCount(0, payload.length)
        }

        override suspend fun payloadChunk(start: Int, count: Int, key: String): String? {
            val payload = payloadFor(key) ?: return null
            val total = payload.codePointCount(0, payload.length)
            val startIndex = (start - 1).coerceIn(0, total)
            val endIndex = (startIndex + count).coerceAtMost(total)
            return payload.substring(
                payload.offsetByCodePoints(0, startIndex),
                payload.offsetByCodePoints(0, endIndex),
            )
        }

        override suspend fun upsert(entity: MetadataCacheEntity) {
            upsertCount += 1
            this.entity = entity
        }

        override suspend fun updatedAtMs(key: String): Long? = entity?.takeIf { it.key == key }?.updatedAtMs

        override suspend fun touch(key: String, updatedAtMs: Long): Int {
            val current = entity?.takeIf { it.key == key } ?: return 0
            entity = current.copy(updatedAtMs = updatedAtMs)
            return 1
        }

        override suspend fun delete(key: String) {
            if (entity?.key == key) entity = null
        }

        override suspend fun deleteAllExcept(keep: String) {
            if (entity?.key != keep) entity = null
        }

        override suspend fun clear() {
            entity = null
        }
    }

    private companion object {
        /** A model from the corpus openAI catalog. */
        const val MODEL_ID = "chat-latest"
        val NEW_CATALOG_REVISION = "sha256:" + "b".repeat(64)

        val SCHEMA2_PAYLOAD = """
            {
              "version": 7,
              "contractVersion": 1,
              "metadataSchema": 2,
              "metadataRevision": 7,
              "generatedAt": "2026-10-19T00:00:00Z",
              "rollbackOf": 6,
              "updatedAt": "2026-10-19T00:00:00Z",
              "profiles": {},
              "providers": {
                "openAI": {
                  "displayName": "OpenAI",
                  "models": {
                    "gpt-x": {
                      "displayName": "GPT X",
                      "lifecycle": {"state": "deprecated", "shutdownAt": "2026-12-01T00:00:00Z", "signal": "upstream_shutdown_date"},
                      "parameterSupport": {"temperature": {"state": "unsupported"}}
                    }
                  }
                }
              }
            }
        """.trimIndent()
    }
}
