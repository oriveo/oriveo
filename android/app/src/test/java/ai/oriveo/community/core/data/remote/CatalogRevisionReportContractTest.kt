package ai.oriveo.community.core.data.remote

import android.content.Context
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Shared fixture catalog-revision-report.v1.json: per-provider catalog revision criteria and report counts.
 * Runs the production initialize / refresh path and asserts the catalog actually left in the Room rows and the reports the failureReporter received.
 *
 * The fixture's integer revision lands in two places: the catalog's schema 2 envelope metadataRevision (the forward-only criterion), and
 * the catalogRevision string registered by the index / self-reported by the catalog (derived from the same integer). Cache revision 0 counts as the bundled snapshot:
 * its catalogRevision never equals any index registration, so it is always fetched.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(Parameterized::class)
class CatalogRevisionReportContractTest(private val id: String, private val case: JsonObject) {

    @Test
    fun `case matches shared expectation`() = runTest {
        val cached = case.getValue("cachedCatalogRevision").jsonPrimitive.int
        val announces = case.getValue("indexAnnounces").jsonPrimitive.int
        // null: the index matches the cache, no catalog request is sent, so there is no response revision.
        val response = case.getValue("responseRevision").jsonPrimitive.intOrNull
        val afterRefetch = case.getValue("indexAfterRefetch").jsonPrimitive.intOrNull
        val expect = case.getValue("expect").jsonObject
        val outcome = expect.getValue("outcome").jsonPrimitive.content
        val report = expect["report"]?.jsonPrimitive?.takeIf { it.isString }?.content
        val cachedLabel = if (cached == 0) BUNDLED else cached.toString()

        val server = ScriptedServer(corpus(), cachedLabel, cached, announces, response, afterRefetch)
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = client(server, dao, reports)
        client.initialize(context())
        val seeded = catalogRow(dao)
        assertEquals(cached.toLong(), seeded.getValue("payloadRevision").jsonPrimitive.content.toLong())
        assertEquals(SEED_ETAG, seeded.getValue("eTag").jsonPrimitive.content)

        server.seeding = false
        reports.clear()
        client.refresh()
        val after = catalogRow(dao)
        val afterRevision = after.getValue("payloadRevision").jsonPrimitive.content.toLong()
        val afterCatalogRevision = after.getValue("data").jsonObject.getValue("catalogRevision").jsonPrimitive.content
        val afterETag = after.getValue("eTag").jsonPrimitive.content

        expect["requestSent"]?.jsonPrimitive?.booleanOrNull?.let { sent ->
            assertEquals("whether a catalog request was sent", sent, server.catalogCalls > 0)
        }
        if (response == null) {
            assertEquals("no catalog request should be sent without a response revision", 0, server.catalogCalls)
            assertEquals(SEED_ETAG, afterETag)
        }
        if (expect["etag"]?.jsonPrimitive?.content == "unchanged") assertEquals(SEED_ETAG, afterETag)
        if (outcome == "accept") {
            assertEquals(requireNotNull(response).toLong(), afterRevision)
            assertEquals(catalogRevisionOf(response.toString()), afterCatalogRevision)
            assertEquals(server.responseETag, afterETag)
        } else {
            // reject / unchanged: the catalog in hand is kept as is.
            assertEquals(cached.toLong(), afterRevision)
            assertEquals(catalogRevisionOf(cachedLabel), afterCatalogRevision)
            if (outcome == "reject") assertEquals(SEED_ETAG, afterETag)
            if (expect["etag"]?.jsonPrimitive?.content == "refreshed") {
                // The new ETag from a 200 with an equal revision is persisted first; when the index matches the cache there are zero catalog requests, so there is no new ETag to refresh.
                assertEquals("no catalog request when the index matches the cache", announces != cached, server.catalogCalls > 0)
                assertEquals(if (server.catalogCalls > 0) server.responseETag else SEED_ETAG, afterETag)
            }
        }
        assertNotNull(client.resolveCatalogModel(MODEL_ID, ProviderKind.OpenAI))

        val codes = reports.filter { it["provider_kind"] == "openai" }.map { it["reason"] }
        assertFalse(reports.any { it["phase"] == "catalog_revision" || it["reason"] == "catalog_revision" })
        val expected = if (report == null) emptyList() else {
            List(expect["reports"]?.jsonPrimitive?.int ?: 1) { report }
        }
        assertEquals(expected, codes)
        assertEquals("unrelated reports: $reports", expected.size, reports.size)
    }

    @Test
    fun `case ids are the locked set`() {
        assertEquals(LOCKED_IDS, cases().map { it[0] as String }.toSet())
    }

    /** Server double: the seed phase serves the cached copy; in the refresh phase the first index reports indexAnnounces, then indexAfterRefetch. */
    private class ScriptedServer(
        root: JsonObject,
        private val cachedLabel: String,
        private val cachedRevision: Int,
        private val announces: Int,
        private val response: Int?,
        private val afterRefetch: Int?,
    ) : MetadataSplitTransport {
        private val index = root.getValue("indexResponse").jsonObject
        private val catalog = root.getValue("catalogResponses").jsonObject
            .getValue(KIND).jsonObject.getValue("data").jsonObject
        var seeding = true
        var indexCalls = 0
        var catalogCalls = 0
        val responseETag = "\"catalog-$response\""

        override suspend fun fetchIndex(ifNoneMatch: String?, cacheBust: String?): MetadataTransportResponse {
            val label = if (seeding) cachedLabel else {
                indexCalls += 1
                (if (indexCalls > 1 && afterRefetch != null) afterRefetch else announces).toString()
            }
            val eTag = "\"index-$label\""
            if (ifNoneMatch == eTag) return MetadataTransportResponse(304, eTag, null, 0)
            val data = index.getValue("data").jsonObject
            val providers = data.getValue("providers").jsonObject
            val entry = JsonObject(
                providers.getValue(KIND).jsonObject + ("catalogRevision" to JsonPrimitive(catalogRevisionOf(label))),
            )
            val body = JsonObject(index + ("data" to JsonObject(data + ("providers" to JsonObject(providers + (KIND to entry)))))).toString()
            return MetadataTransportResponse(200, eTag, body, body.length.toLong())
        }

        override suspend fun fetchCatalog(provider: String, ifNoneMatch: String?, revision: String?): MetadataTransportResponse {
            if (provider != KIND) error("unexpected catalog request $provider")
            val (label, revision, eTag) = if (seeding) {
                Triple(cachedLabel, cachedRevision, SEED_ETAG)
            } else {
                catalogCalls += 1
                val revision = response ?: error("the catalog must not be requested when the index matches the cache")
                Triple(revision.toString(), revision, responseETag)
            }
            if (ifNoneMatch == eTag) return MetadataTransportResponse(304, eTag, null, 0)
            val data = JsonObject(
                catalog + mapOf(
                    "catalogRevision" to JsonPrimitive(catalogRevisionOf(label)),
                    "metadataSchema" to JsonPrimitive(2),
                    "metadataRevision" to JsonPrimitive(revision),
                    "generatedAt" to JsonPrimitive("2026-10-19T00:00:00Z"),
                ),
            )
            val body = JsonObject(mapOf("code" to JsonPrimitive(0), "data" to data, "message" to JsonPrimitive("ok"))).toString()
            return MetadataTransportResponse(200, eTag, body, body.length.toLong())
        }
    }

    private fun TestScope.client(
        server: ScriptedServer,
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

    private fun catalogRow(dao: FakeRowDao): JsonObject =
        Json.parseToJsonElement(dao.rows.getValue(MetadataCacheEntity.CATALOG_KEY_PREFIX + KIND).payload).jsonObject

    private fun context(): Context {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), Context.MODE_PRIVATE) } returns TestSharedPreferences()
        return context
    }

    /** Multi-row Room double (modeled on MetadataClientRevisionTest.FakeRowDao). */
    private class FakeRowDao : MetadataCacheDao {
        val rows = linkedMapOf<String, MetadataCacheEntity>()

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

    companion object {
        private const val KIND = "openAI"
        private const val BUNDLED = "bundled"
        private const val SEED_ETAG = "\"catalog-seed\""
        /** A model from the corpus openAI catalog. */
        private const val MODEL_ID = "chat-latest"
        private val LOCKED_IDS = setOf(
            "catalog_zero_then_zero_accepts",
            "catalog_regressed_refused",
            "catalog_equal_matches_index_unchanged",
            "catalog_equal_index_newer_then_settles",
            "catalog_equal_index_still_newer_reports_once",
            "catalog_newer_accepts",
        )

        /** The catalogRevision string derived from the same integer revision; the bundled snapshot gets a separate value that no index registers. */
        private fun catalogRevisionOf(label: String): String {
            val seed = if (label == BUNDLED) "b" else label.toInt().toString(16)
            return "sha256:" + seed.padStart(64, '0')
        }

        private fun corpus(): JsonObject =
            Json.parseToJsonElement(workspaceFile("shared/model-contracts/metadata_catalog_contract.v1.json").readText())
                .jsonObject

        /** Walks up from the working directory to find a path relative to the repository root (modeled on MetadataClientRevisionTest.workspaceFile). */
        private fun workspaceFile(relative: String): File {
            var dir: File? = File("").absoluteFile
            while (dir != null) {
                val candidate = File(dir, relative)
                if (candidate.exists()) return candidate
                dir = dir.parentFile
            }
            throw IllegalStateException("$relative not found")
        }

        @JvmStatic
        @Parameterized.Parameters(name = "CATALOG_REVISION_REPORT_{0}")
        fun cases(): List<Array<Any>> =
            Json.parseToJsonElement(workspaceFile("shared/test-fixtures/provider-catalog/catalog-revision-report.v1.json").readText())
                .jsonObject.getValue("cases").jsonArray
                .map { raw -> raw.jsonObject.let { arrayOf<Any>(it.getValue("id").jsonPrimitive.content, it) } }
    }
}
