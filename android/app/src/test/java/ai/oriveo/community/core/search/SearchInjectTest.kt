package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.Mismatches
import ai.oriveo.community.core.search.SearchContractFixtures.bool
import ai.oriveo.community.core.search.SearchContractFixtures.cases
import ai.oriveo.community.core.search.SearchContractFixtures.int
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Test

/** Injection budget, envelope, unified numbering, message facts (contract sections 12 / 13 / 14): each case compared with the shared fixture's expect, envelope compared byte for byte. */
class SearchInjectTest {
    private val budgetDoc = SearchContractFixtures.load("search-contracts/injection-budget.v1.json")
    private val citeDoc = SearchContractFixtures.load("search-contracts/citation-allocator.v1.json")
    private val factsDoc = SearchContractFixtures.load("search-contracts/result-facts.v1.json")

    private fun caseId(c: JsonObject) = str(c["caseId"])!!

    private fun input(c: JsonObject) = c.getValue("input").jsonObject

    @Test
    fun SRCH_INJ_01() {
        val all = cases(budgetDoc, "budgetCases")
        val m = Mismatches()
        for (c in all) {
            val actual = searchInjectionBudget(int(input(c)["B"]))
            m.check(caseId(c), c.getValue("expect"), SearchTurnJson.budget(actual))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_INJ_02() {
        val all = cases(budgetDoc, "nextCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = budgetForNextSearch(int(i["B"]), int(i["usedTokens"])!!)
            m.check(caseId(c), c.getValue("expect"), buildJsonObject { put("budgetTokens", JsonPrimitive(actual)) })
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_INJ_03() {
        val all = cases(budgetDoc, "fitCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = fitWebResults(
                WebFitInput(
                    provider = str(i["provider"])!!,
                    query = str(i["query"])!!,
                    retrievedAt = str(i["retrievedAt"])!!,
                    results = SearchTurnJson.results(i["results"]),
                    firstId = int(i["firstId"])!!,
                    budgetTokens = int(i["budgetTokens"])!!,
                    rhoHi = (i.getValue("rhoHi") as JsonPrimitive).content.toDouble(),
                ),
            )
            val expect = c.getValue("expect").jsonObject
            // Envelope compared byte for byte: compare the raw string first, then the whole result
            m.check("${caseId(c)} envelope", str(expect["envelope"]), actual.envelope)
            m.check(caseId(c), expect, SearchTurnJson.fit(actual))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CITE_01() {
        val all = cases(citeDoc, "cases")
        val m = Mismatches()
        for (c in all) {
            val actual = allocateCitations(SearchTurnJson.batches(input(c)["batches"]))
            val json = JsonArray(
                actual.map { n ->
                    buildJsonObject {
                        put("source", JsonPrimitive(n.source))
                        put("numbers", JsonArray(n.numbers.map { JsonPrimitive(it) }))
                    }
                },
            )
            m.check(caseId(c), c.getValue("expect"), json)
        }
        m.assertNone(all.size)
    }

    private fun fact(e: JsonElement?): SearchCallFact? =
        (e as? JsonObject)?.let { SearchCallFact(str(it["outcome"])!!, int(it["delivered"])) }

    @Test
    fun SRCH_FACT_01() {
        val all = cases(factsDoc, "cases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = summarizeSearchFacts(
                path = str(i["path"])!!,
                webOn = bool(i["webOn"]) == true,
                calls = (i["calls"] as? JsonArray).orEmpty().map { fact(it)!! },
                presearch = fact(i["presearch"]?.takeIf { it != JsonNull }),
                serviceName = str(i["serviceName"]),
            )
            m.check(caseId(c), c.getValue("expect"), SearchTurnJson.facts(actual))
        }
        m.assertNone(all.size)
    }
}
