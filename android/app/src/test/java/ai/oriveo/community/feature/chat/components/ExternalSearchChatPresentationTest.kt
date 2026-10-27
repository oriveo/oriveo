package ai.oriveo.community.feature.chat.components

import ai.oriveo.community.R
import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.model.SearchMessageErrorCard
import ai.oriveo.community.core.model.SearchMessageSourcesLine
import ai.oriveo.community.core.model.SearchMessageSwitchTarget
import ai.oriveo.community.core.search.SearchActivity
import ai.oriveo.community.core.search.SearchCallOutcome
import ai.oriveo.community.core.search.SearchOtherService
import ai.oriveo.community.core.search.SearchReplyStart
import ai.oriveo.community.core.search.SearchTransport
import ai.oriveo.community.core.search.SearchTurnPlanInput
import ai.oriveo.community.core.search.SearchTurnService
import ai.oriveo.community.core.search.applySearchEvent
import ai.oriveo.community.core.search.SearchEvent
import ai.oriveo.community.core.search.finishSearchReply
import ai.oriveo.community.core.search.nextExternalSearchActivity
import ai.oriveo.community.core.search.planSearchTurn
import ai.oriveo.community.core.search.searchQueryChipText
import ai.oriveo.community.core.search.startSearchReply
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Presentation mapping: headline -> copy, primaryAction -> button and behavior, sourcesLine -> three segments, switchTo visibility, regenerate-type actions only on the last message. */
class ExternalSearchChatPresentationTest {
    private val p = ExternalSearchChatPresentation

    @Test
    fun `every headline the error table produces maps to a chatError string`() {
        val headlines = SearchTransport.ERROR_CLASSES.values.map { it.headline }.toSet()
        headlines.forEach { assertTrue("headline $it", p.headlineRes(it) != null) }
        assertEquals(R.string.web_search_chat_error_key_rejected, p.headlineRes("key_rejected"))
        assertEquals(R.string.web_search_chat_error_searxng_json_disabled, p.headlineRes("searxng_json_disabled"))
        assertNull(p.headlineRes("unknown_headline"))
    }

    @Test
    fun `every primary action maps to its button and behaviour`() {
        val primaries = SearchTransport.ERROR_CLASSES.keys.flatMap { cls ->
            listOf(SearchTransport.searchErrorCard(cls).primaryAction, SearchTransport.searchErrorCard(cls, custom = true).primaryAction)
        }.toSet()
        primaries.forEach { assertTrue("primary $it", p.primaryButton(it) != null) }
        assertEquals(SearchCardButton(SearchCardAction.UpdateKey, R.string.web_search_action_update_key), p.primaryButton("update_key"))
        assertEquals(SearchCardButton(SearchCardAction.TopUp, R.string.web_search_action_top_up, external = true), p.primaryButton("top_up"))
        assertEquals(SearchCardAction.Retry, p.primaryButton("retry")!!.action)
        assertEquals(SearchCardAction.Retry, p.primaryButton("retry_later")!!.action)
        assertTrue(p.primaryButton("retry")!!.regenerates)
        assertEquals(R.string.web_search_action_switch_service, p.primaryButton("switch_service")!!.titleRes)
        assertEquals(SearchCardAction.CheckSettings, p.primaryButton("check_settings")!!.action)
        assertTrue(p.primaryButton("view_setup_guide")!!.external)
        assertEquals(SearchCardAction.Reconfirm, p.primaryButton("reconfirm")!!.action)
    }

    /** The error card comes from production finishSearchReply: for non-network failures with another service available, it offers "Answer again with X". */
    private fun producedCard(cls: String): SearchMessageErrorCard {
        val service = SearchTurnService(id = "s1", name = "DeepSeek", protocol = "catalog")
        val plan = planSearchTurn(SearchTurnPlanInput(path = "external_presearch", service = service, userText = "q", b = 64_000, today = "2026-10-27"))
        var state = startSearchReply(
            SearchReplyStart(plan.replyPlan, service, listOf(SearchOtherService("s2", "Brave", false)), b = 64_000, rhoHi = 1.0, retrievedAt = "t"),
        )
        state = applySearchEvent(state, SearchEvent.Call("q", 5)).state
        state = applySearchEvent(state, SearchEvent.Result(SearchCallOutcome.Failed(cls, retryOnce = false, sent = true))).state
        val card = finishSearchReply(state).errorCard!!
        return SearchMessageErrorCard(
            errorClass = card.errorClass, headline = card.headline, primaryAction = card.primaryAction,
            secondaryAction = card.secondaryAction, serviceName = card.serviceName, serviceId = "s1",
            switchTo = card.switchTo?.let { SearchMessageSwitchTarget(it.id, it.name) },
        )
    }

    @Test
    fun `regenerating buttons only show on the last answer and switchTo follows the card`() {
        val timeout = producedCard("timeout")
        val last = p.errorCard(timeout, isLastMessage = true, switchToAvailable = true)
        assertEquals(R.string.web_search_chat_error_no_response, last.headlineRes)
        assertEquals("DeepSeek", last.serviceName)
        assertEquals(SearchCardAction.Retry, last.primary!!.action)
        assertEquals(SearchMessageSwitchTarget("s2", "Brave"), last.answerWith)
        val old = p.errorCard(timeout, isLastMessage = false, switchToAvailable = true)
        assertNull("retry regenerates: hidden on an older answer", old.primary)
        assertNull(old.answerWith)
        // "Answer again with X" depends only on switchTo; it is hidden if X is no longer on this device
        assertNull(p.errorCard(timeout, isLastMessage = true, switchToAvailable = false).answerWith)
        val noSecondaryKey = timeout.copy(secondaryAction = null)
        assertEquals(SearchMessageSwitchTarget("s2", "Brave"), p.errorCard(noSecondaryKey, isLastMessage = true, switchToAvailable = true).answerWith)

        // Navigation-type buttons are kept on older messages too
        val auth = p.errorCard(producedCard("auth_invalid"), isLastMessage = false, switchToAvailable = true)
        assertEquals(SearchCardAction.UpdateKey, auth.primary!!.action)
        assertEquals("s1", auth.serviceId)

        // A local network failure does not offer "switch to"
        assertNull(p.errorCard(producedCard("network"), isLastMessage = true, switchToAvailable = true).answerWith)
    }

    @Test
    fun `sources header has three parts and no chevron at zero sources`() {
        val searched = p.sourcesHeader(SearchMessageSourcesLine(searchCount = 2, serviceName = "DeepSeek", sourceCount = 5))
        assertFalse(searched.reused)
        assertEquals(2, searched.searchCount)
        assertEquals("DeepSeek", searched.serviceName)
        assertTrue(searched.expandable)
        val reusedCustom = p.sourcesHeader(SearchMessageSourcesLine(1, "My SearXNG", 0, reused = true, custom = true))
        assertTrue(reusedCustom.reused)
        assertTrue(reusedCustom.custom)
        assertFalse(reusedCustom.expandable)
    }

    @Test
    fun `web sources split from library sources and drive the regenerate-with-search item`() {
        val web = Citation(url = "https://b.example.com/x", title = "B", index = 3, source = "external_search")
        val web2 = Citation(url = "https://a.example.com/y", title = "A", index = 2, source = "external_search")
        val lib = Citation(url = "https://www.notion.so/doc", title = "Doc", index = 1, source = "notion", docId = "d")
        assertEquals(listOf(web2, web), p.webSources(listOf(lib, web, web2)))
        assertEquals(listOf(lib), p.otherSources(listOf(lib, web, web2)))
        assertTrue(p.offersRegenerateWithSearch(listOf(lib, web)))
        assertFalse(p.offersRegenerateWithSearch(listOf(lib)))
        assertEquals("b.example.com", p.host("https://www.b.example.com/x"))
    }

    @Test
    fun `activity chips append per call, retries do not, and deliver keeps them until the first character`() {
        var s = nextExternalSearchActivity(null, SearchActivity("external_search", "DeepSeek", "first query"), retry = false)!!
        assertTrue(s.searching)
        s = nextExternalSearchActivity(s, SearchActivity("external_search", "DeepSeek", "first query"), retry = true)!!
        assertEquals(listOf("first query"), s.chips)
        s = nextExternalSearchActivity(s, null, retry = false)!!
        assertFalse(s.searching)
        listOf("two", "three", "four").forEach { q ->
            s = nextExternalSearchActivity(s, SearchActivity("external_search", "DeepSeek", q), retry = false)!!
            s = nextExternalSearchActivity(s, null, retry = false)!!
        }
        assertEquals(listOf("two", "three", "four"), s.chips)
        assertEquals("a".repeat(40) + "…", searchQueryChipText("a".repeat(41) + "\nsecond line"))
        assertEquals("line one", searchQueryChipText("  line one  \nline two"))
        assertEquals("first non-blank line", "q", searchQueryChipText("\n  \nq"))
        // Truncate by grapheme: 40 emoji (2 UTF-16 code units each) are not cut; 41 are cut to 40 plus "…"
        val emoji = "\uD83D\uDE00"
        assertEquals(emoji.repeat(40), searchQueryChipText(emoji.repeat(40)))
        assertEquals(emoji.repeat(40) + "…", searchQueryChipText(emoji.repeat(41)))
        assertEquals("\u4E2D".repeat(40) + "…", searchQueryChipText("\u4E2D".repeat(41)))
    }

    @Test
    fun `an unknown primary action renders no button but keeps the card`() {
        // A primaryAction outside the fixture renders no button; the card still shows title and subtitle
        assertNull(p.primaryButton("something_new"))
        val card = SearchMessageErrorCard("x", "no_response", "something_new", null, "DeepSeek")
        assertNull(p.errorCard(card, isLastMessage = true, switchToAvailable = true).primary)
        // Unknown headline: the whole card is still shown, with the title falling back to "Returned an error"
        assertEquals(
            R.string.web_search_chat_error_service_error,
            p.errorCard(card.copy(headline = "from_the_future"), isLastMessage = true, switchToAvailable = true).headlineRes,
        )
    }
}
