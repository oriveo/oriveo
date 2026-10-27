package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.Mismatches
import ai.oriveo.community.core.search.SearchContractFixtures.cases
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Test

/** Execution-side combined entry point (contract section 5a): calls production functions in the order of search-turn.v1.json and compares output with expect by JSON semantics. */
class SearchTurnTest {
    private val doc = SearchContractFixtures.load("search-contracts/search-turn.v1.json")

    private fun caseId(c: JsonObject) = str(c["caseId"])!!

    @Test
    fun SRCH_TURN_01() {
        val all = cases(doc, "planCases")
        val m = Mismatches()
        for (c in all) {
            val expect = c.getValue("expect").jsonObject
            val input = SearchTurnJson.planInput(c.getValue("input").jsonObject)
            val error = str(expect["error"])
            if (error != null) {
                val thrown = runCatching { planSearchTurn(input) }.exceptionOrNull()
                m.check(caseId(c), error, thrown?.message)
                continue
            }
            m.check(caseId(c), expect, SearchTurnJson.plan(planSearchTurn(input)))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_TURN_02() {
        val all = cases(doc, "replyCases")
        val m = Mismatches()
        for (c in all) {
            val input = c.getValue("input").jsonObject
            val expect = c.getValue("expect").jsonObject
            var state = startSearchReply(SearchTurnJson.replyStart(input.getValue("start").jsonObject))
            val effects = input.getValue("events").jsonArray.map { e ->
                val step = applySearchEvent(state, SearchTurnJson.event(e.jsonObject))
                state = step.state
                SearchTurnJson.effect(step.effect)
            }
            m.check("${caseId(c)} effects", expect.getValue("effects"), JsonArray(effects))
            m.check("${caseId(c)} finish", expect.getValue("finish"), SearchTurnJson.finish(finishSearchReply(state)))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_TURN_03() {
        val all = cases(doc, "recordCases")
        val m = Mismatches()
        for (c in all) {
            val input = c.getValue("input").jsonObject
            val citations = (input["citations"] as? JsonArray)?.map { SearchTurnJson.citation(it.jsonObject) }
            val line = searchedRecordLine(citations)
            m.check(caseId(c), c.getValue("expect").jsonObject["line"], line?.let { JsonPrimitive(it) } ?: JsonNull)
        }
        m.assertNone(all.size)
    }
}
