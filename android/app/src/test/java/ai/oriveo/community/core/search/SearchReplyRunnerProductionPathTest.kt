package ai.oriveo.community.core.search

import ai.oriveo.community.core.context.ContextAssembleInput
import ai.oriveo.community.core.context.ContextAssembler
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.ContextDynamicInput
import ai.oriveo.community.core.context.ContextLibraryEntry
import ai.oriveo.community.core.context.ContextMaxOutput
import ai.oriveo.community.core.context.ContextWindowInput
import ai.oriveo.community.core.context.ContextWindowKind
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.search.SearchContractFixtures.catalogEntry
import ai.oriveo.community.core.search.SearchContractFixtures.str
import ai.oriveo.community.core.tools.ToolExecutionContext
import ai.oriveo.community.core.tools.ToolLoopToolCall
import ai.oriveo.community.core.tools.ToolLoopToolCallFunction
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * DeepSeek golden response replaces HTTP, running this app's real executor -> web_search entry / pre-search -> [D] -> persisted at finish.
 * Ids start after the sources already numbered in the library; numbers on the message match the envelope, and message facts are observed.
 */
class SearchReplyRunnerProductionPathTest {
    private val golden = SearchContractFixtures.load("search-contracts/transport-golden.v1.json")
    private val catalog: JsonObject = run {
        val ref = str(golden["catalogRef"])!!
        SearchContractFixtures.load("search-contracts/" + ref.substringBefore('#')).getValue(ref.substringAfter('#')).jsonObject
    }
    private val normal = golden.getValue("cases").jsonArray.map { it.jsonObject }.first { str(it["caseId"]) == "deepseek.normal" }
    private val expectedCount = normal.getValue("expect").jsonObject.getValue("results").jsonArray.size
    private val requests = mutableListOf<String>()

    /** HTTP is replaced by golden responses; DNS is replaced by a public address (the https safety check still runs as usual). */
    private val executor = SearchExecutor(
        OkHttpClient.Builder().addInterceptor(
            Interceptor { chain ->
                requests += chain.request().url.toString()
                Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(200)
                    .message("OK")
                    .body(Json.encodeToString(JsonObject.serializer(), normal.getValue("body").jsonObject).toResponseBody("application/json".toMediaType()))
                    .build()
            },
        ).build(),
        { listOf("104.16.0.1") },
    )

    private fun binding(): ExternalSearchBinding {
        val entry = catalogEntry(catalog, "deepseek")
        val region = SearchJson.string(entry.getValue("regions").jsonArray.first().jsonObject["id"])!!
        val host = SearchCatalog.presetTarget(entry, region)!!.host
        return ExternalSearchBinding(
            service = SearchTurnService(id = "local-service-1", name = "DeepSeek", protocol = "catalog"),
            otherServices = emptyList(),
            defaultCount = 5,
            execute = { query, count ->
                executor.executePreset(entry, region, host, withdrawn = false, key = "sk-test-0000", query = query, count = count).toOutcome(5)
            },
            telemetryService = "deepseek",
        )
    }

    private fun runner(path: String, tracked: MutableList<SearchTelemetryEvent>): SearchReplyRunner {
        val b = binding()
        val plan = planSearchTurn(
            SearchTurnPlanInput(
                path = path,
                service = b.service,
                toolCall = "supported",
                host = SearchToolHostInput(continuationKind = "tool_loop"),
                userText = "Oriveo 联网搜索",
                b = 64_000,
                today = "2026-10-27",
            ),
        )
        // Two already-numbered library sources take ids 1 and 2 first
        val prior = listOf(CitationBatch("library", listOf(CitationItem(libraryKey = "doc-a"), CitationItem(libraryKey = "doc-b"))))
        return SearchReplyRunner(
            startSearchReply(SearchReplyStart(plan.replyPlan, b.service, b = 64_000, rhoHi = 1.0, retrievedAt = "2026-10-27T00:00:00Z", priorBatches = prior)),
            b,
            track = { tracked += it },
        )
    }

    private fun fact(f: SearchReplyFinish) = f.facts

    @Test
    fun `web_search tool result is an oriveo-web envelope numbered after library sources`() = runBlocking {
        val tracked = mutableListOf<SearchTelemetryEvent>()
        val runner = runner("external_tool", tracked)
        val entry = WebSearchToolEntry(WEB_SEARCH_TOOL, runner)
        val outcome = entry.execute(
            ToolLoopToolCall("call_1", function = ToolLoopToolCallFunction("web_search", """{"query":"Oriveo 联网搜索"}""")),
            ToolExecutionContext(callId = "call_1", stepNumber = 1, legIndex = 0),
        )
        assertEquals(1, requests.size)
        assertTrue(outcome.content.startsWith("<oriveo-web "))
        assertTrue(outcome.content.contains("id=\"3\""))
        assertTrue(!outcome.content.contains("id=\"1\"") && !outcome.content.contains("id=\"2\""))

        val finish = runner.finish()
        val citations = finish.citations.map { it.toCitation() }
        assertEquals(expectedCount, citations.size)
        assertEquals((3 until 3 + expectedCount).toList(), citations.map { it.index })
        citations.forEach { c ->
            assertTrue(outcome.content.contains("id=\"${c.index}\""))
            assertEquals("external_search", c.source)
            assertEquals("local-service-1", c.serviceId)
            assertEquals("Oriveo 联网搜索", c.query)
        }
        assertEquals("observed", fact(finish).state)
        assertEquals("external_search", fact(finish).source)
        // Analytics reports the catalog id as service, not the local record id
        assertEquals("deepseek", tracked.single { it.event == "search_executed" }.props["service"])
        // The compact history record is derived from the persisted sources
        assertTrue(searchedRecordLineFor(citations)!!.contains("\"Oriveo 联网搜索\""))
    }

    @Test
    fun `presearch delivery goes into D right after the library envelope`() = runBlocking {
        val runner = runner("external_presearch", mutableListOf())
        val delivered = runner.search("Oriveo 联网搜索", 5).content
        val plan = ContextAssembler.assemble(
            ContextAssembleInput(
                purpose = RequestPurpose.CHAT,
                window = ContextWindowInput(W = 128_000, windowKind = ContextWindowKind.TOTAL, maxOutput = ContextMaxOutput(model = 8_000)),
                conversation = ContextConversation(id = "c1", useMemory = false),
                history = emptyList(),
                current = "Oriveo 联网搜索",
                dynamic = ContextDynamicInput(library = listOf(ContextLibraryEntry(citation = 1, title = "A", text = "alpha")), web = delivered),
            ),
        )
        val d = plan.messages!!.last().blocks.last().text
        val library = d.indexOf("<oriveo-library")
        val web = d.indexOf("<oriveo-web ")
        assertTrue(library >= 0 && web > library)
        assertTrue(d.contains("id=\"3\""))
        assertEquals((3 until 3 + expectedCount).toList(), runner.finish().citations.map { it.toCitation().index })
        assertEquals("observed", runner.finish().facts.state)
    }
}
