package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.CapabilityExecutionCollector
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Criteria for web search being "confirmed": every case lets the production service parse raw
 * upstream frames, then hands the events it actually emitted to [CapabilityExecutionCollector].
 * No case hand-builds a StreamEvent: that would only prove the collector can count, not that the
 * parsing path really produces evidence.
 *
 * Signal definitions come from the shared result-definitions file and are bound to the recipes
 * through recipeBindings; the expected terminal states come from the shared
 * `provider_recipe_result_facts.v1.json`.
 */
class WebSearchEvidenceProducerTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry = TransportRegistry(json)
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        openClients.forEach { it.close() }
        openClients.clear()
    }

    // ── Moonshot ────────────────────────────────────────────────

    @Test
    fun `Moonshot recorded sample replay emits one tool_result and web is observed`() = runTest {
        applyWebRecipe("moonshot", "kimi-k2.6", "moonshot.chat.web.v1")
        val recorded = workspaceFile(
            "shared/test-fixtures/provider-toolcall/recorded/moonshot_web_search.leg1.sse",
        ).readText()

        val (events, collector) = runMoonshot(firstLeg = recorded)

        val results = events.filterIsInstance<StreamEvent.ToolResult>()
        assertEquals(1, results.size)
        assertEquals("\$web_search", results.single().tool)
        assertEquals("answer", (events.last() as StreamEvent.Done).result.text)
        assertSharedExpectation("moonshot", "moonshot.chat.web.v1", events, collector)
        assertEquals("observed", collector.webState())
    }

    @Test
    fun `Moonshot web_search arguments that are invalid JSON or lack a search_id emit nothing`() = runTest {
        applyWebRecipe("moonshot", "kimi-k2.6", "moonshot.chat.web.v1")
        val rejected = listOf(
            "{not json",
            "{}",
            """{\"search_result\":{}}""",
            """{\"search_result\":{\"search_id\":\"\"}}""",
            """{\"search_result\":{\"search_id\":42}}""",
            """{\"usage\":{\"total_tokens\":7610}}""",
        )
        for (arguments in rejected) {
            val (events, collector) = runMoonshot(firstLeg = builtinLeg(arguments))
            assertTrue(arguments, events.none { it is StreamEvent.ToolResult })
            assertEquals(arguments, "unconfirmed", collector.webState())
        }
    }

    @Test
    fun `Moonshot Formula fiber returning a non-empty result emits tool_result and web is observed`() = runTest {
        applyWebRecipe("moonshot", "kimi-k3", "moonshot.formula.web.v1")
        var chatLeg = 0
        val client = client(MockEngine { request ->
            val path = request.url.encodedPath
            when {
                request.method == HttpMethod.Get && path.endsWith("/tools") -> respond(
                    """{"tools":[{"type":"function","function":{"name":"search","parameters":{}}}]}""",
                    HttpStatusCode.OK,
                )
                path.endsWith("/fibers") -> respond(
                    """{"context":{"output":"three results"}}""",
                    HttpStatusCode.OK,
                )
                else -> {
                    chatLeg += 1
                    sse(
                        if (chatLeg == 1) {
                            """data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"search","arguments":"{}"}}]}}]}"""
                        } else {
                            """data: {"choices":[{"delta":{"content":"answer"}}]}"""
                        },
                    )
                }
            }
        })
        val collector = CapabilityExecutionCollector()
        val events = MoonshotService(client, json, transportRegistry).sendMessageStream(
            "sk", "kimi-k3", listOf(userMessage(ProviderKind.Moonshot, "kimi-k3")), null, false,
            ReasoningMode.Automatic, true, ChatRequestOptions(capabilityExecutionCollector = collector),
        ).toList()
        events.forEach(collector::observe)

        val results = events.filterIsInstance<StreamEvent.ToolResult>()
        assertEquals(1, results.size)
        assertEquals("search", results.single().tool)
        assertEquals("observed", collector.webState())
    }

    // -- Zhipu ----------------------------------------------------

    @Test
    fun `Zhipu top-level web_search with two entries yields two sources and web is observed`() = runTest {
        applyWebRecipe("zhipu", "glm-5", "zhipu.chat.web.v1")
        val (events, collector) = runZhipu(
            """data: {"choices":[{"delta":{"content":"answer"}}],"web_search":[{"title":"First","link":"https://a.example/1","content":"snippet one","media":"A","icon":"","refer":"ref_1","publish_date":"2026-10-01"},{"title":"Second","link":"https://b.example/2","content":"snippet two","media":"B","icon":"","refer":"ref_2","publish_date":""}]}""",
        )

        val citations = events.filterIsInstance<StreamEvent.Citations>().flatMap { it.citations }
        assertEquals(listOf("https://a.example/1", "https://b.example/2"), citations.map { it.url })
        assertEquals(listOf("First", "Second"), citations.map { it.title })
        assertEquals(listOf("snippet one", "snippet two"), citations.map { it.snippet })
        assertSharedExpectation("zhipu", "zhipu.chat.web.v1", events, collector)
        assertEquals("observed", collector.webState())
    }

    @Test
    fun `Zhipu legacy search_result path yields sources`() = runTest {
        applyWebRecipe("zhipu", "glm-5", "zhipu.chat.web.v1")
        val (events, collector) = runZhipu(
            """data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"ws-1","type":"web_search","web_search":{"search_result":[{"title":"Legacy","link":"https://c.example/3","content":"legacy snippet"}]}}]}}]}""",
            """data: {"choices":[{"delta":{"content":"answer"}}]}""",
        )

        val citations = events.filterIsInstance<StreamEvent.Citations>().flatMap { it.citations }
        assertEquals(listOf("https://c.example/3"), citations.map { it.url })
        assertEquals("Legacy", citations.single().title)
        assertEquals("legacy snippet", citations.single().snippet)
        assertEquals("observed", collector.webState())
    }

    @Test
    fun `Zhipu sources from both paths in one frame are merged and de-duplicated`() = runTest {
        applyWebRecipe("zhipu", "glm-5", "zhipu.chat.web.v1")
        val (events, _) = runZhipu(
            """data: {"choices":[{"delta":{"content":"answer","tool_calls":[{"index":0,"id":"ws-1","type":"web_search","web_search":{"search_result":[{"title":"Dup","link":"https://a.example/1","content":"old"},{"title":"Only legacy","link":"https://d.example/4","content":"legacy"}]}}]}}],"web_search":[{"title":"Dup","link":"https://a.example/1","content":"new"}]}""",
        )

        val frames = events.filterIsInstance<StreamEvent.Citations>()
        assertEquals(1, frames.size)
        assertEquals(listOf("https://a.example/1", "https://d.example/4"), frames.single().citations.map { it.url })
    }

    @Test
    fun `Zhipu plain answer without web_search emits nothing and stays unconfirmed`() = runTest {
        applyWebRecipe("zhipu", "glm-5", "zhipu.chat.web.v1")
        val (events, collector) = runZhipu(
            """data: {"choices":[{"delta":{"content":"plain answer"}}]}""",
            """data: {"choices":[{"delta":{}}],"web_search":[]}""",
            """data: {"choices":[{"delta":{}}],"web_search":[{"title":"No link","content":"dropped"}]}""",
        )

        assertTrue(events.none { it is StreamEvent.Citations || it is StreamEvent.ToolResult })
        assertEquals("plain answer", (events.last() as StreamEvent.Done).result.text)
        assertEquals("unconfirmed", collector.webState())
    }

    // -- Gemini Interactions --------------------------------------

    @Test
    fun `Gemini Interactions non-empty google_search_result emits tool_result and url_citation emits sources`() = runTest {
        applyWebRecipe("gemini", "gemini-3-flash", "gemini.interactions.web.v1", transport = "gemini_generate")
        val (events, collector) = runGeminiInteractions(
            """data: {"event_type":"step.delta","step":{"type":"google_search_result","delta":{"type":"google_search_result","result":[{"url":"https://g.example/1","title":"G1"}],"is_error":false}}}""",
            """data: {"event_type":"step.delta","step":{"type":"model_output","delta":{"type":"text","text":"answer"}}}""",
            """data: {"event_type":"step.delta","step":{"type":"model_output","delta":{"type":"text_annotation_delta","annotations":[{"type":"url_citation","url":"https://g.example/1","title":"G1","start_index":0,"end_index":6},{"type":"file_citation","url":"https://ignored.example"},{"type":"url_citation","url":""}]}}}""",
            """data: {"event_type":"interaction.completed","interaction":{"id":"int-1","status":"completed"}}""",
        )

        assertEquals(1, events.filterIsInstance<StreamEvent.ToolResult>().size)
        val citations = events.filterIsInstance<StreamEvent.Citations>().flatMap { it.citations }
        assertEquals(listOf("https://g.example/1"), citations.map { it.url })
        assertEquals("G1", citations.single().title)
        assertEquals("answer", (events.last() as StreamEvent.Done).result.text)
        assertEquals("observed", collector.webState())
    }

    @Test
    fun `Gemini Interactions events with the delta at the top level are parsed the same way`() = runTest {
        applyWebRecipe("gemini", "gemini-3-flash", "gemini.interactions.web.v1", transport = "gemini_generate")
        val (events, collector) = runGeminiInteractions(
            """data: {"event_type":"step.delta","index":0,"delta":{"type":"google_search_result","result":[{"url":"https://g.example/1"}]}}""",
            """data: {"event_type":"step.delta","index":1,"delta":{"type":"text_annotation_delta","annotations":[{"type":"url_citation","url":"https://g.example/2","title":"G2"}]}}""",
        )

        assertEquals(1, events.filterIsInstance<StreamEvent.ToolResult>().size)
        assertEquals(
            listOf("https://g.example/2"),
            events.filterIsInstance<StreamEvent.Citations>().flatMap { it.citations }.map { it.url },
        )
        assertEquals("observed", collector.webState())
    }

    @Test
    fun `Gemini Interactions search error or empty result emits nothing and stays unconfirmed`() = runTest {
        applyWebRecipe("gemini", "gemini-3-flash", "gemini.interactions.web.v1", transport = "gemini_generate")
        val (events, collector) = runGeminiInteractions(
            """data: {"event_type":"step.delta","step":{"type":"google_search_result","delta":{"type":"google_search_result","result":[{"url":"https://g.example/1"}],"is_error":true}}}""",
            """data: {"event_type":"step.delta","step":{"type":"google_search_result","delta":{"type":"google_search_result","result":[]}}}""",
            """data: {"event_type":"step.delta","step":{"type":"google_search_call","delta":{"type":"google_search_call","arguments":{"queries":["q"]}}}}""",
            """data: {"event_type":"step.delta","step":{"type":"model_output","delta":{"type":"text","text":"answer"}}}""",
        )

        assertTrue(events.none { it is StreamEvent.Citations || it is StreamEvent.ToolResult })
        assertEquals("unconfirmed", collector.webState())
    }

    // -- Qwen -----------------------------------------------------

    @Test
    fun `Qwen plain answer with web search on stays unconfirmed`() = runTest {
        applyWebRecipe("qwen", "qwen3.7-plus", "qwen.chat.web.v1")
        var requestBody = ""
        val client = client(MockEngine { request ->
            requestBody = (request.body as io.ktor.http.content.TextContent).text
            sse("""data: {"choices":[{"delta":{"content":"searched answer"}}]}""")
        })
        val collector = CapabilityExecutionCollector()
        val events = QwenService(client, json, transportRegistry).sendMessageStream(
            apiKey = "sk", modelID = "qwen3.7-plus",
            messages = listOf(userMessage(ProviderKind.Qwen, "qwen3.7-plus")), baseUrl = null,
            supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = true,
            requestOptions = ChatRequestOptions(capabilityExecutionCollector = collector),
        ).toList()
        events.forEach(collector::observe)

        // The web setting did go out; it stays unconfirmed because the official OpenAI-compatible
        // protocol returns no search sources, not because nothing was sent.
        assertTrue(requestBody, json.parseToJsonElement(requestBody).jsonObject["enable_search"]?.jsonPrimitive?.content == "true")
        assertEquals("searched answer", (events.last() as StreamEvent.Done).result.text)
        assertSharedExpectation("qwen", "qwen.chat.web.v1", events, collector)
        assertEquals("unconfirmed", collector.webState())
    }

    // -- Drivers --------------------------------------------------

    private suspend fun runMoonshot(firstLeg: String): Pair<List<StreamEvent>, CapabilityExecutionCollector> {
        var leg = 0
        val client = client(MockEngine {
            leg += 1
            if (leg == 1) {
                respond(firstLeg, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            } else {
                sse("""data: {"choices":[{"delta":{"content":"answer"}}]}""")
            }
        })
        val collector = CapabilityExecutionCollector()
        val events = MoonshotService(client, json, transportRegistry).sendMessageStream(
            apiKey = "sk", modelID = "kimi-k2.6",
            messages = listOf(userMessage(ProviderKind.Moonshot, "kimi-k2.6")), baseUrl = null,
            supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = true,
            requestOptions = ChatRequestOptions(capabilityExecutionCollector = collector),
        ).toList()
        events.forEach(collector::observe)
        return events to collector
    }

    private suspend fun runZhipu(vararg frames: String): Pair<List<StreamEvent>, CapabilityExecutionCollector> {
        val client = client(MockEngine { sse(*frames) })
        val collector = CapabilityExecutionCollector()
        val events = ZhipuService(client, json, transportRegistry).sendMessageStream(
            apiKey = "sk", modelID = "glm-5",
            messages = listOf(userMessage(ProviderKind.Zhipu, "glm-5")), baseUrl = null,
            supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = true,
            requestOptions = ChatRequestOptions(capabilityExecutionCollector = collector),
        ).toList()
        events.forEach(collector::observe)
        return events to collector
    }

    private suspend fun runGeminiInteractions(vararg frames: String): Pair<List<StreamEvent>, CapabilityExecutionCollector> {
        val client = client(MockEngine { request ->
            assertEquals("/v1/interactions", request.url.encodedPath)
            sse(*frames)
        })
        val collector = CapabilityExecutionCollector()
        val events = GeminiService(client, json, transportRegistry).sendMessageStream(
            "key", "gemini-3-flash", listOf(userMessage(ProviderKind.Gemini, "gemini-3-flash")), null, false,
            ReasoningMode.Automatic, true, ChatRequestOptions(capabilityExecutionCollector = collector),
        ).toList()
        events.forEach(collector::observe)
        return events to collector
    }

    private fun CapabilityExecutionCollector.webState(): String =
        successfulTerminalResults().single { it.owner == "web" }.state

    /**
     * The row of the shared facts table must hold through the production parsing path: the terminal
     * state is equal, and every declared producerEvent really appears, non-empty, among the events
     * the service emitted.
     */
    private fun assertSharedExpectation(
        providerKind: String,
        recipeRef: String,
        events: List<StreamEvent>,
        collector: CapabilityExecutionCollector,
    ) {
        val row = json.parseToJsonElement(
            workspaceFile("shared/model-contracts/provider_recipe_result_facts.v1.json").readText(),
        ).jsonObject["providerResultCoverage"]!!.jsonArray.map { it.jsonObject }
            .single { it["providerKind"]!!.jsonPrimitive.content == providerKind }
        assertEquals(recipeRef, row["recipeRef"]!!.jsonPrimitive.content)
        assertEquals(providerKind, row["expected"]!!.jsonPrimitive.content, collector.webState())
        val produced = events.mapNotNull { event ->
            when (event) {
                is StreamEvent.Citations -> "citations".takeIf { event.citations.any { it.url.isNotBlank() } }
                is StreamEvent.ToolResult -> "tool_result".takeIf { event.summary.isNotBlank() }
                is StreamEvent.Reasoning -> "reasoning".takeIf { event.text.isNotBlank() }
                else -> null
            }
        }.toSet()
        val declared = row["producerEvents"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertTrue("$providerKind declared=$declared produced=$produced", produced.containsAll(declared))
    }

    private fun builtinLeg(escapedArguments: String) = """
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"t-web_search-1","type":"builtin_function","function":{"name":"${'$'}web_search","arguments":"$escapedArguments"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls","usage":{"prompt_tokens":1,"completion_tokens":1}}]}

        data: [DONE]
    """.trimIndent()

    private fun io.ktor.client.engine.mock.MockRequestHandleScope.sse(vararg frames: String) = respond(
        (frames.toList() + "data: [DONE]").joinToString("\n\n", postfix = "\n\n"),
        HttpStatusCode.OK,
        headersOf(HttpHeaders.ContentType, "text/event-stream"),
    )

    private fun client(engine: MockEngine): HttpClient = HttpClient(engine).also { openClients.add(it) }

    private fun userMessage(kind: ProviderKind, model: String) = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = "What is in the news today?",
        providerKind = kind,
        providerName = kind.rawValue,
        modelName = model,
        state = ChatMessageState.Delivered,
    )

    /**
     * The envelope shape the catalog delivers: the registry itself plus the result definitions, with
     * recipes bound to evidence definitions through recipeBindings. No signal is spelled out here;
     * the collector judges exactly as the definitions file declares.
     */
    private fun applyWebRecipe(provider: String, modelId: String, recipeRef: String, transport: String = "openai_chat") {
        val directory = "shared/capabilityrecipe"
        val registry = json.parseToJsonElement(workspaceFile("$directory/capability_runtime.v1.json").readText()).jsonObject
        val definitions = json.parseToJsonElement(
            workspaceFile("$directory/capability_result_definitions.v1.json").readText(),
        ).jsonObject
        val bindings = definitions["recipeBindings"]!!.jsonObject
        val recipes = JsonObject(registry["recipes"]!!.jsonObject.mapValues { (ref, recipe) ->
            (bindings[ref] as? JsonObject)?.let { JsonObject(recipe.jsonObject + it) } ?: recipe
        })
        val runtime = JsonObject(
            registry + mapOf(
                "recipes" to recipes,
                "responseEvidenceDefinitions" to definitions["responseEvidenceDefinitions"]!!,
                "errorRecoveryDefinitions" to definitions["errorRecoveryDefinitions"]!!,
                "revision" to JsonPrimitive("sha256:web-evidence-test"),
                "generatedAt" to JsonPrimitive("2026-10-09T00:00:00Z"),
            ),
        )
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("providers", buildJsonObject {
                put(provider, buildJsonObject {
                    put("resolveMap", buildJsonObject { put(modelId, modelId) })
                    put("models", buildJsonObject {
                        put(modelId, buildJsonObject {
                            put("canonicalModelId", modelId)
                            put("transport", transport)
                            put("capabilityControls", buildJsonObject {
                                put("web", buildJsonObject {
                                    put("state", "auto_available")
                                    put("recipeRef", recipeRef)
                                })
                            })
                        })
                    })
                })
            })
        }.toString())
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("workspace file not found: $relative")
    }
}
