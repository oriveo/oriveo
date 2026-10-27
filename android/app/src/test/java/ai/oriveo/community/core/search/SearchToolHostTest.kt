package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.Mismatches
import ai.oriveo.community.core.search.SearchContractFixtures.cases
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.serialization.json.jsonObject
import org.junit.Test

/** Tool host table for regular chat (contract section 7): each case compared with the expect in tool-host.v1.json. */
class SearchToolHostTest {
    private val doc = SearchContractFixtures.load("search-contracts/tool-host.v1.json")

    @Test
    fun SRCH_HOST_01() {
        val all = cases(doc, "cases")
        val m = Mismatches()
        for (c in all) {
            val actual = resolveSearchToolHost(SearchTurnJson.hostInput(c.getValue("input").jsonObject))
            m.check(str(c["caseId"])!!, c.getValue("expect").jsonObject, SearchTurnJson.toolHost(actual))
        }
        m.assertNone(all.size)
    }
}
