package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.Mismatches
import ai.oriveo.community.core.search.SearchContractFixtures.bool
import ai.oriveo.community.core.search.SearchContractFixtures.cases
import ai.oriveo.community.core.search.SearchContractFixtures.catalogEntry
import ai.oriveo.community.core.search.SearchContractFixtures.int
import ai.oriveo.community.core.search.SearchContractFixtures.obj
import ai.oriveo.community.core.search.SearchContractFixtures.str
import ai.oriveo.community.core.search.SearchContractFixtures.withRegion
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Catalog normalization / signature / adoption / sites / host checks / site links, each case checked against the shared fixtures. */
class SearchCatalogContractTest {
    private val doc = SearchContractFixtures.load("search-contracts/search_catalog_contract.v1.json")
    private val catalog = doc.getValue("catalog").jsonObject
    private val testKeys: Map<String, String> = doc.getValue("testKeys").jsonObject.let {
        mapOf(str(it["keyId"])!! to str(it["publicKeyB64"])!!)
    }

    @Test
    fun SRCH_CAT_01() {
        val all = cases(doc, "canonicalCases")
        val m = Mismatches()
        for (c in all) {
            val id = str(c["caseId"])!!
            val expect = c.getValue("expect").jsonObject
            val actual = runCatching { SearchCatalog.canonicalCatalogJson(c.getValue("input")) }
            val expectedError = str(expect["error"])
            if (expectedError != null) {
                m.check(id, expectedError, (actual.exceptionOrNull() as? CanonicalJsonException)?.code)
            } else {
                m.check(id, str(expect["output"]), actual.getOrNull())
            }
        }
        m.assertNone(all.size)
    }

    private fun stateOf(c: JsonObject): CatalogAdoptionState {
        val s = c.getValue("state").jsonObject
        val current = obj(s["current"])?.let { snapshotOf(it) }
        return CatalogAdoptionState(s.getValue("maxSeenRevision").let { (it as JsonPrimitive).content.toLong() }, current)
    }

    private fun snapshotOf(o: JsonObject) = CatalogSnapshot(
        revision = (o.getValue("revision") as JsonPrimitive).content.toLong(),
        services = o.getValue("services").jsonArray.map { e ->
            val s = e.jsonObject
            CatalogServiceState(
                id = str(s["id"])!!,
                status = str(s["status"])!!,
                limits = obj(s["limits"])?.let { CatalogLimits(int(it["timeoutSec"])!!, int(it["maxCount"])!!) },
            )
        },
    )

    @Test
    fun SRCH_CAT_02() {
        val all = cases(doc, "acceptCases")
        val m = Mismatches()
        for (c in all) {
            val id = str(c["caseId"])!!
            val expect = c.getValue("expect").jsonObject
            val state = stateOf(c)
            val r = SearchCatalog.acceptSearchCatalog(state, c["incoming"], str(c["source"])!!, testKeys)
            m.check("$id accepted", bool(expect["accepted"]), r.accepted)
            m.check("$id reason", str(expect["reason"]), r.reason)
            m.check("$id maxSeenRevision", (expect.getValue("maxSeenRevision") as JsonPrimitive).content.toLong(), r.maxSeenRevision)
            if (expect.containsKey("current")) {
                m.check("$id current", obj(expect["current"])?.let(::snapshotOf), r.current)
            }
            if (expect.containsKey("skipped")) {
                val skipped = expect.getValue("skipped").jsonArray.map {
                    CatalogSkippedEntry(str(it.jsonObject["id"]), str(it.jsonObject["reason"])!!)
                }
                m.check("$id skipped", skipped, r.skipped)
            }
            if (!r.accepted) m.check("$id keeps previous", state.current, r.current)
            if (r.accepted) m.check("$id source", str(c["source"]), r.source)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CAT_03() {
        val all = cases(doc, "regionCases")
        val m = Mismatches()
        for (c in all) {
            val entry = catalogEntry(catalog, str(c["serviceId"])!!)
            val actual = SearchCatalog.regionForConnection(entry, str(c["connectionBaseUrl"]))
            m.check(str(c["caseId"])!!, str(c.getValue("expect").jsonObject["region"]), actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CAT_04() {
        val all = cases(doc, "hostCases")
        val m = Mismatches()
        for (c in all) {
            val regionId = str(c["regionId"])!!
            var entry = catalogEntry(catalog, str(c["serviceId"])!!)
            str(c["catalogHostOverride"])?.let { host ->
                entry = withRegion(entry, regionId) { JsonObject(it + ("host" to JsonPrimitive(host))) }
            }
            val actual = SearchCatalog.presetHostCheck(str(c["boundHost"]), entry, regionId, bool(c["withdrawn"]) == true)
            m.check(str(c["caseId"])!!, str(c.getValue("expect").jsonObject["verdict"]), actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CAT_05() {
        val all = cases(doc, "linkCases")
        val m = Mismatches()
        for (c in all) {
            val regionId = str(c["regionId"])!!
            var entry = catalogEntry(catalog, str(c["serviceId"])!!)
            if (c.containsKey("regionUrlsOverride")) {
                val override = c.getValue("regionUrlsOverride")
                entry = withRegion(entry, regionId) {
                    if (override == JsonNull) JsonObject(it - "urls") else JsonObject(it + ("urls" to override))
                }
            }
            val links = c.getValue("expect").jsonObject.getValue("links").jsonObject
            val expected = CatalogRegionLinks(
                homepage = str(links["homepage"]),
                docs = str(links["docs"]),
                terms = str(links["terms"]),
                keyHelp = str(links["keyHelp"]),
                pricing = str(links["pricing"]),
            )
            m.check(str(c["caseId"])!!, expected, SearchCatalog.regionLinks(entry, regionId))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CAT_06() {
        val all = cases(doc, "fetchCases")
        val m = Mismatches()
        for (c in all) {
            val input = c.getValue("input").jsonObject
            m.check(
                str(c["caseId"])!!,
                str(c.getValue("expect").jsonObject["action"]),
                SearchCatalog.catalogFetchAction(status = int(input["status"]), transportFailure = str(input["transportFailure"])),
            )
        }
        m.assertNone(all.size)
    }

    @Test
    fun `fixture catalog verifies with test key and every entry passes validation`() {
        assertEquals(CatalogSignatureCheck(true, null), SearchCatalog.verifyCatalogSignature(catalog, testKeys))
        assertEquals(
            CatalogSignatureCheck(false, "signature_unknown_key"),
            SearchCatalog.verifyCatalogSignature(catalog, SearchCatalogKeys.production),
        )
        val services = catalog.getValue("services").jsonArray
        assertEquals(7, services.size)
        services.forEach { assertNull(str(it.jsonObject["id"]), SearchCatalog.validateCatalogEntry(it)) }
    }

    @Test
    fun `hard limits and static param whitelist match fixture constants`() {
        val constants = doc.getValue("constants").jsonObject
        assertEquals(str(constants["schema"]), SearchCatalog.CATALOG_SCHEMA)
        assertEquals(str(constants["transport"]), SearchTransport.TRANSPORT_KIND)
        val limits = constants.getValue("hardLimits").jsonObject.mapValues { int(it.value) }
        assertEquals(
            mapOf(
                "maxCount" to SearchHardLimits.MAX_COUNT,
                "defaultCount" to SearchHardLimits.DEFAULT_COUNT,
                "maxTimeoutSec" to SearchHardLimits.MAX_TIMEOUT_SEC,
                "maxResponseBytes" to SearchHardLimits.MAX_RESPONSE_BYTES,
                "titleMaxChars" to SearchHardLimits.TITLE_MAX_CHARS,
                "snippetMaxChars" to SearchHardLimits.SNIPPET_MAX_CHARS,
                "siteMaxChars" to SearchHardLimits.SITE_MAX_CHARS,
                "dateMaxChars" to SearchHardLimits.DATE_MAX_CHARS,
                "maxQueryChars" to SearchHardLimits.MAX_QUERY_CHARS,
            ),
            limits,
        )
        val whitelist = constants.getValue("staticParamWhitelist").jsonObject.mapValues { (_, v) ->
            val rule = v.jsonObject
            (rule["enum"] as? JsonArray)?.map { it as JsonPrimitive } to
                (rule["int"] as? JsonArray)?.map { (it as JsonPrimitive).content.toLong() }
        }
        assertEquals(whitelist, SearchTransport.staticParamWhitelistShape)
        assertTrue(doc.getValue("productionKeys").jsonObject.mapValues { str(it.value) } == SearchCatalogKeys.production)
    }
}
