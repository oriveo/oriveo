package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.Mismatches
import ai.oriveo.community.core.search.SearchContractFixtures.cases
import ai.oriveo.community.core.search.SearchContractFixtures.catalogEntry
import ai.oriveo.community.core.search.SearchContractFixtures.int
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** json_http/v1 request construction and response mapping goldens: entries come from the catalog that transport-golden's catalogRef points to. */
class SearchTransportGoldenContractTest {
    private val golden = SearchContractFixtures.load("search-contracts/transport-golden.v1.json")

    private val catalog: JsonObject = run {
        val ref = str(golden["catalogRef"])!!
        assertEquals("search_catalog_contract.v1.json#catalog", ref)
        SearchContractFixtures.load("search-contracts/" + ref.substringBefore('#')).getValue(ref.substringAfter('#')).jsonObject
    }

    @Test
    fun SRCH_TRN_01() {
        val all = cases(golden, "cases")
        val m = Mismatches()
        for (c in all) {
            val id = str(c["caseId"])!!
            val entry = catalogEntry(catalog, str(c["serviceId"])!!)
            val spec = entry.getValue("transport").jsonObject
            val expect = c.getValue("expect").jsonObject
            when (str(c["kind"])) {
                "request" -> {
                    val input = c.getValue("input").jsonObject
                    val target = SearchCatalog.presetTarget(entry, str(c["regionId"]))
                    if (target == null) {
                        m.fail(id, "no target")
                        continue
                    }
                    val actual = SearchTransport.buildSearchRequest(spec, target, str(input["query"])!!, int(input["count"]), str(input["key"]))
                    SearchContractFixtures.requestMismatch(expect, actual)?.let { m.fail(id, it) }
                }
                "response" -> m.check(
                    id,
                    SearchContractFixtures.parseResultOf(expect),
                    SearchTransport.parseSearchResponse(spec, c["body"], int(c["count"])),
                )
                "error" -> m.check(
                    id,
                    SearchContractFixtures.errorOutcomeOf(expect),
                    SearchTransport.classifySearchError(
                        SearchErrorInput(status = int(c["status"]), body = c["body"], rules = spec["errors"] as? JsonArray),
                    ),
                )
                else -> m.fail(id, "unknown kind ${c["kind"]}")
            }
        }
        m.assertNone(all.size)
    }
}
