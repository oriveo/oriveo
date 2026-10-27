package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.Mismatches
import ai.oriveo.community.core.search.SearchContractFixtures.bool
import ai.oriveo.community.core.search.SearchContractFixtures.cases
import ai.oriveo.community.core.search.SearchContractFixtures.catalogEntry
import ai.oriveo.community.core.search.SearchContractFixtures.int
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** Search error mapping: general rules plus entry / protocol specific rules (serviceId refers to a catalog fixture entry, protocol=searxng refers to the built-in protocol). */
class SearchErrorMappingContractTest {
    private val doc = SearchContractFixtures.load("search-contracts/error-mapping.v1.json")
    private val catalog = SearchContractFixtures.load("search-contracts/search_catalog_contract.v1.json")
        .getValue("catalog").jsonObject

    @Test
    fun SRCH_ERR_01() {
        val all = cases(doc, "cases")
        val m = Mismatches()
        for (c in all) {
            val input = c.getValue("input").jsonObject
            val rules: JsonArray? = when {
                str(input["serviceId"]) != null ->
                    catalogEntry(catalog, str(input["serviceId"])!!).getValue("transport").jsonObject["errors"] as? JsonArray
                str(input["protocol"]) == "searxng" -> SearchCustomService.SEARXNG_SPEC["errors"] as? JsonArray
                else -> null
            }
            val actual = SearchTransport.classifySearchError(
                SearchErrorInput(
                    status = int(input["status"]),
                    transportFailure = str(input["transportFailure"]),
                    preflight = str(input["preflight"]),
                    parse = str(input["parse"]),
                    body = input["body"],
                    rules = rules,
                    custom = bool(input["custom"]) == true,
                    otherServices = int(input["otherServices"]) ?: 0,
                ),
            )
            m.check(str(c["caseId"])!!, SearchContractFixtures.errorOutcomeOf(c.getValue("expect").jsonObject), actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun `error classes, tool messages and retryable statuses match fixture constants`() {
        val constants = doc.getValue("constants").jsonObject
        val classes = constants.getValue("classes").jsonObject.mapValues { (_, v) ->
            val o = v.jsonObject
            val card = o.getValue("card").jsonObject
            SearchErrorClassDef(bool(o["retryOnce"])!!, str(o["toolMessage"])!!, str(card["headline"])!!, str(card["primaryAction"])!!)
        }
        assertEquals(classes, SearchTransport.ERROR_CLASSES)
        assertEquals(constants.getValue("toolMessages").jsonObject.mapValues { str(it.value) }, SearchTransport.TOOL_MESSAGES)
        val retryable = constants.getValue("retryableStatuses").jsonArray.map { int(it)!! }.toSet()
        val retriedByStatus = (400..599).filter {
            SearchTransport.classifySearchError(SearchErrorInput(status = it)).retryOnce
        }.toSet()
        assertEquals(retryable, retriedByStatus)
    }
}
