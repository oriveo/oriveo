package ai.oriveo.community.core.data.remote

import android.content.Context
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.every
import io.mockk.mockk
import java.io.File
import java.net.URLDecoder
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Shared fixture catalog-request-shape.v1.json: per-view requests are addressed by revision (contract section 5.9).
 * A catalog request carries the rev announced by the index; only the index refetch after a mismatch carries fresh.
 * Assertions use the URLs the production HttpUrlConnectionMetadataSplitTransport actually builds (get replaced by a recording double),
 * driven through the production MetadataClient.initialize / refresh; Room and reporting follow CatalogRevisionReportContractTest.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(Parameterized::class)
class CatalogRequestShapeContractTest(private val id: String, private val case: JsonObject) {

    @Test
    fun `case matches shared expectation`() = runTest {
        val expect = case.getValue("expect").jsonObject
        val announced = case["indexAnnounces"]?.jsonObject?.get(KIND)?.jsonPrimitive?.contentOrNull
        if (case["indexAnnounces"] != null && announced == null) {
            // The index does not announce this provider's revision: the client sends no catalog request for a provider without a registered revision, so take the URL the production transport builds with null.
            val urls = mutableListOf<String>()
            val transport = HttpUrlConnectionMetadataSplitTransport { path, _, _ ->
                urls += path
                MetadataTransportResponse(304, null, null, 0)
            }
            transport.fetchCatalog(KIND, null, announced)
            assertCatalogRequest(expect.getValue("catalogRequest").jsonObject, urls.single())
            return@runTest
        }

        val first = announced ?: REV_DEFAULT
        val firstResponse = case["firstCatalogResponseRevision"]?.jsonPrimitive?.contentOrNull
        val afterRefetch = case["indexAfterRefetch"]?.jsonObject?.get(KIND)?.jsonPrimitive?.contentOrNull
        val server = ScriptedServer(corpus(), first, firstResponse, afterRefetch)
        val dao = FakeRowDao()
        val reports = mutableListOf<Map<String, String>>()
        val client = client(server.transport, dao, reports)
        client.initialize(context())
        assertEquals(SEED_REV, catalogRevisionInRow(dao))

        server.seeding = false
        server.urls.clear()
        reports.clear()
        client.refresh()

        val indexUrls = server.urls.filter { it.contains("view=index") }
        val catalogUrls = server.urls.filter { it.contains("view=catalog") }
        expect["catalogRequest"]?.jsonObject?.let { assertCatalogRequest(it, catalogUrls.first()) }
        expect["indexRequest"]?.jsonObject?.let { shape ->
            assertTrue("a regular index fetch is expected", indexUrls.isNotEmpty())
            indexUrls.forEach { url -> assertEquals(url, shape.nullableString("fresh"), param(url, "fresh")) }
        }
        expect["firstCatalogRequest"]?.jsonObject?.let { assertCatalogRequest(it, catalogUrls.first()) }
        expect["indexRefetch"]?.jsonObject?.let { shape ->
            assertEquals("one regular fetch plus one refetch after the mismatch: $indexUrls", 2, indexUrls.size)
            assertNull("a regular index fetch carries no fresh", param(indexUrls[0], "fresh"))
            if (shape.nullableString("fresh") == "non-empty") {
                assertFalse("the refetch after a mismatch must carry a non-empty fresh", param(indexUrls[1], "fresh").isNullOrEmpty())
            }
        }
        expect["secondCatalogRequest"]?.jsonObject?.let { shape ->
            assertEquals(2, catalogUrls.size)
            assertCatalogRequest(shape, catalogUrls[1])
        }
        if (expect["outcome"]?.jsonPrimitive?.contentOrNull == "accept") {
            assertEquals(afterRefetch ?: first, catalogRevisionInRow(dao))
        }
        if (expect.containsKey("report")) {
            assertEquals(expect.nullableString("report"), reports.firstOrNull()?.get("reason"))
            if (expect.nullableString("report") == null) assertEquals("unrelated reports: $reports", 0, reports.size)
        }
    }

    @Test
    fun `case ids are the locked set`() {
        assertEquals(LOCKED_IDS, cases().map { it[0] as String }.toSet())
    }

    private fun assertCatalogRequest(shape: JsonObject, url: String) {
        assertEquals(url, shape.getValue("provider").jsonPrimitive.content, param(url, "provider"))
        assertEquals(url, shape.nullableString("rev"), param(url, "rev"))
        if (shape.containsKey("fresh")) assertEquals(url, shape.nullableString("fresh"), param(url, "fresh"))
    }

    /**
     * Server double: in the seed phase index / catalog are both [SEED_REV]; in the refresh phase the index first announces [announced],
     * and from the second time on (refetch after a mismatch) announces [afterRefetch]. The catalog first answers [firstResponse] (stale edge cache), then the revision the index currently announces.
     */
    private class ScriptedServer(
        root: JsonObject,
        private val announced: String,
        private val firstResponse: String?,
        private val afterRefetch: String?,
    ) {
        private val index = root.getValue("indexResponse").jsonObject
        private val catalog = root.getValue("catalogResponses").jsonObject
            .getValue(KIND).jsonObject.getValue("data").jsonObject
        private val order = listOfNotNull(SEED_REV, announced, firstResponse, afterRefetch).distinct()
        var seeding = true
        val urls = mutableListOf<String>()
        private var indexCalls = 0
        private var catalogCalls = 0
        private var current = SEED_REV

        val transport = HttpUrlConnectionMetadataSplitTransport { path, _, ifNoneMatch ->
            urls += path
            if (path.contains("view=index")) index(ifNoneMatch) else catalog(path, ifNoneMatch)
        }

        private fun index(ifNoneMatch: String?): MetadataTransportResponse {
            current = if (seeding) SEED_REV else {
                indexCalls += 1
                if (indexCalls > 1 && afterRefetch != null) afterRefetch else announced
            }
            val eTag = "\"index-$current\""
            if (ifNoneMatch == eTag) return MetadataTransportResponse(304, eTag, null, 0)
            val data = index.getValue("data").jsonObject
            val providers = data.getValue("providers").jsonObject
            val entry = JsonObject(providers.getValue(KIND).jsonObject + ("catalogRevision" to JsonPrimitive(current)))
            val body = JsonObject(index + ("data" to JsonObject(data + ("providers" to JsonObject(providers + (KIND to entry)))))).toString()
            return MetadataTransportResponse(200, eTag, body, body.length.toLong())
        }

        private fun catalog(path: String, ifNoneMatch: String?): MetadataTransportResponse {
            if (param(path, "provider") != KIND) error("unexpected catalog request $path")
            val revision = if (seeding) SEED_REV else {
                catalogCalls += 1
                if (catalogCalls == 1 && firstResponse != null) firstResponse else current
            }
            val eTag = "\"catalog-$revision\""
            if (ifNoneMatch == eTag) return MetadataTransportResponse(304, eTag, null, 0)
            val data = JsonObject(
                catalog + mapOf(
                    "catalogRevision" to JsonPrimitive(revision),
                    "metadataSchema" to JsonPrimitive(2),
                    "metadataRevision" to JsonPrimitive(order.indexOf(revision) + 1),
                    "generatedAt" to JsonPrimitive("2026-10-21T00:00:00Z"),
                ),
            )
            val body = JsonObject(mapOf("code" to JsonPrimitive(0), "data" to data, "message" to JsonPrimitive("ok"))).toString()
            return MetadataTransportResponse(200, eTag, body, body.length.toLong())
        }
    }

    private fun TestScope.client(
        transport: MetadataSplitTransport,
        dao: FakeRowDao,
        reports: MutableList<Map<String, String>>,
    ): MetadataClient = MetadataClient(
        backgroundScope = this,
        ioDispatcher = StandardTestDispatcher(testScheduler),
        metadataCacheDao = dao,
        metadataTransport = MetadataTransport { error("lean must not be requested") },
        metadataSplitTransport = transport,
        nowMillis = { 1_000L },
        failureReporter = { tags -> reports.add(tags) },
        metadataPayloadSchemaText = workspaceFile("shared/model-contracts/metadata_payload.v2.schema.json").readText(),
    ).also { client ->
        client.catalogDemandSupplier = { MetadataClient.CatalogDemand(setOf(ProviderKind.OpenAI), hasRelay = false) }
    }

    private fun catalogRevisionInRow(dao: FakeRowDao): String =
        Json.parseToJsonElement(dao.rows.getValue(MetadataCacheEntity.CATALOG_KEY_PREFIX + KIND).payload).jsonObject
            .getValue("data").jsonObject.getValue("catalogRevision").jsonPrimitive.content

    private fun context(): Context {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), Context.MODE_PRIVATE) } returns TestSharedPreferences()
        return context
    }

    /** Multi-row Room double (modeled on CatalogRevisionReportContractTest.FakeRowDao). */
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
        private val SEED_REV = "sha256:" + "0".repeat(64)
        /** For a fixture case without indexAnnounces (only the index request shape is measured): the index announces a revision different from the seed. */
        private val REV_DEFAULT = "sha256:" + "a".repeat(64)
        private val LOCKED_IDS = setOf(
            "catalog_request_carries_index_revision",
            "catalog_request_without_announced_revision_omits_rev",
            "regular_index_fetch_has_no_cache_bust",
            "mismatch_refetch_bypasses_edge_then_catalog_uses_new_revision",
        )

        private fun JsonObject.nullableString(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull

        /** The decoded value of a URL query parameter; null when the parameter is absent. */
        private fun param(url: String, name: String): String? =
            url.substringAfter('?', "").split('&')
                .firstOrNull { it.substringBefore('=') == name }
                ?.let { URLDecoder.decode(it.substringAfter('=', ""), "UTF-8") }

        private fun corpus(): JsonObject =
            Json.parseToJsonElement(workspaceFile("shared/model-contracts/metadata_catalog_contract.v1.json").readText())
                .jsonObject

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
        @Parameterized.Parameters(name = "CATALOG_REQUEST_SHAPE_{0}")
        fun cases(): List<Array<Any>> =
            Json.parseToJsonElement(workspaceFile("shared/test-fixtures/provider-catalog/catalog-request-shape.v1.json").readText())
                .jsonObject.getValue("cases").jsonArray
                .map { raw -> raw.jsonObject.let { arrayOf<Any>(it.getValue("id").jsonPrimitive.content, it) } }
    }
}
