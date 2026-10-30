package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.core.search.SavedSearchService
import ai.oriveo.community.core.search.SearchCallOutcome
import ai.oriveo.community.core.search.SearchCatalogRepository
import ai.oriveo.community.core.search.SearchExecution
import ai.oriveo.community.core.search.SearchExecutor
import ai.oriveo.community.core.search.SearchReplyStart
import ai.oriveo.community.core.search.SearchRowState
import ai.oriveo.community.core.search.SearchServiceStore
import ai.oriveo.community.core.search.SearchTurnPlanInput
import ai.oriveo.community.core.search.SearchReplyRunner
import ai.oriveo.community.core.search.planSearchTurn
import ai.oriveo.community.core.search.startSearchReply
import ai.oriveo.community.feature.settings.websearch.WebSearchServiceItem
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A preset service whose key cannot be read locally (or whose reused connection was deleted) sends no request and finishes as key invalid (primary button "Update Key");
 * a custom service's key is optional and the request is sent as usual. Goes through production [StoreModelControlsWebSearch.searchBinding].
 */
class ConversationWebSearchBindingTest {
    private val executor = mockk<SearchExecutor>()
    private val store = SearchServiceStore(TestSharedPreferences())

    private fun webSearch() = StoreModelControlsWebSearch(
        store,
        SearchCatalogRepository(TestSharedPreferences(), { error("no fetch") }, { null }, emptyMap()),
        { emptyList() },
        { _, _ -> null },
        executor = executor,
        // Reused model connection deleted: key cannot be obtained
        connectionKey = { null },
    )

    private fun snapshot(saved: SavedSearchService, entry: JsonObject? = JsonObject(emptyMap())) = WebSearchPanelSnapshot(
        listOf(WebSearchServiceItem(saved, saved.name ?: "DeepSeek", SearchRowState("ready", saved.kind, saved.keySource, null), true, false, null, entry)),
        saved.id, null, null, null, "unknown",
    )

    @Test
    fun `preset whose reused connection is gone fails as auth_invalid without sending`() = runTest {
        val saved = SavedSearchService(
            id = "s1", kind = SavedSearchService.KIND_PRESET, serviceId = "deepseek", regionId = "cn", boundHost = "api.deepseek.com",
            keySource = SavedSearchService.KEY_SOURCE_CONNECTION, connectionRef = "conn-deleted", name = "DeepSeek",
        )
        val binding = webSearch().searchBinding(snapshot(saved), "s1")!!
        val outcome = binding.execute("q", 5) as SearchCallOutcome.Failed
        assertEquals("auth_invalid", outcome.errorClass)
        assertFalse(outcome.retryOnce)
        assertFalse(outcome.sent)
        coVerify(exactly = 0) { executor.executePreset(any(), any(), any(), any(), any(), any(), any(), any()) }

        // Finish: error card primary button "Update Key", no request was sent
        val plan = planSearchTurn(SearchTurnPlanInput(path = "external_presearch", service = binding.service, userText = "q", b = 64_000, today = "2026-10-27"))
        val runner = SearchReplyRunner(
            startSearchReply(SearchReplyStart(plan.replyPlan, binding.service, b = 64_000, rhoHi = 1.0, retrievedAt = "2026-10-27T00:00:00Z")),
            binding,
            track = {},
        )
        runner.search("q", 5)
        val card = runner.finish().errorCard!!
        assertEquals("key_rejected", card.headline)
        assertEquals("update_key", card.primaryAction)
        assertEquals(0, runner.state.requestsSent)
    }

    @Test
    fun `preset with no stored own key does not send`() = runTest {
        val saved = SavedSearchService(id = "s2", kind = SavedSearchService.KIND_PRESET, serviceId = "deepseek", regionId = "cn", boundHost = "api.deepseek.com", name = "DeepSeek")
        val outcome = webSearch().searchBinding(snapshot(saved), "s2")!!.execute("q", 5) as SearchCallOutcome.Failed
        assertEquals("auth_invalid", outcome.errorClass)
        assertFalse(outcome.sent)
        coVerify(exactly = 0) { executor.executePreset(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `custom service without a key still sends`() = runTest {
        coEvery { executor.executeCustom(any(), any(), any(), any(), any(), any(), any()) } returns SearchExecution.Empty
        val saved = SavedSearchService(id = "s3", kind = SavedSearchService.KIND_CUSTOM, protocol = "searxng", address = "https://search.example.com", keySource = "none", name = "Mine")
        val outcome = webSearch().searchBinding(snapshot(saved, entry = null), "s3")!!.execute("q", 5)
        assertTrue(outcome is SearchCallOutcome.Empty)
        coVerify(exactly = 1) { executor.executeCustom("searxng", "https://search.example.com", null, null, "q", 5, 0) }
    }
}
