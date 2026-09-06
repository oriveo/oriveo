package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OpenAICompatibleTransportDispatchTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        UnsupportedParamCache.resetForTest()
    }

    @Test
    fun `grok model transport openai_responses streams through responses endpoint`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Grok,
                defaultModelId = "grok-4.20-multi-agent-0309",
                resolveMap = mapOf("grok-4.20-multi-agent-0309" to "grok-4.20-multi-agent-0309"),
                transportBaseUrl = "https://api.x.ai",
                transportChatPath = "/v1/chat/completions",
                transportResponsesPath = "/v1/responses",
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "grok-4.20-multi-agent-0309",
                        displayName = "Grok Multi-Agent",
                        transport = "openai_responses",
                    )
                ),
            )
        )

        val requestedUrls = mutableListOf<String>()
        val bodies = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                requestedUrls += request.url.toString()
                bodies += (request.body as TextContent).text
                respond(
                    content = """
                        event: response.output_text.delta
                        data: {"delta":"hi"}

                        event: response.completed
                        data: {"response":{"usage":{"input_tokens":2,"output_tokens":1}}}

                        data: [DONE]
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            },
        )

        val events = GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "xai-test",
            modelID = "grok-4.20-multi-agent-0309",
            messages = listOf(
                ProviderTestFixtures.userMessage(
                    text = "hello",
                    providerKind = ProviderKind.Grok,
                    modelName = "grok-4.20-multi-agent-0309",
                )
            ),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(listOf("https://api.x.ai/v1/responses"), requestedUrls)
        assertTrue(bodies.single().contains("\"input\""))
        assertFalse(bodies.single().contains("\"messages\""))
        assertFalse(bodies.single().contains("\"reasoning\""))
        assertFalse(bodies.single().contains("\"reasoning_effort\""))
        assertTrue(events.any { it is StreamEvent.Delta && it.text == "hi" })
    }

    @Test
    fun `grok openai_chat uses metadata chat endpoint`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Grok,
                defaultModelId = "grok-3-mini",
                resolveMap = mapOf("grok-3-mini" to "grok-3-mini"),
                transportBaseUrl = "https://api.x.ai",
                transportChatPath = "/v1/chat/completions",
                transportResponsesPath = "/v1/responses",
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "grok-3-mini",
                        displayName = "Grok 3 Mini",
                        transport = "openai_chat",
                    )
                ),
            )
        )

        val requestedUrls = mutableListOf<String>()
        val bodies = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                requestedUrls += request.url.toString()
                bodies += (request.body as TextContent).text
                respond(
                    content = """
                        data: {"choices":[{"delta":{"content":"hi"}}],"usage":{"prompt_tokens":2,"completion_tokens":1}}
                        data: [DONE]
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            },
        )

        val events = GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "xai-test",
            modelID = "grok-3-mini",
            messages = listOf(
                ProviderTestFixtures.userMessage(
                    text = "hello",
                    providerKind = ProviderKind.Grok,
                    modelName = "grok-3-mini",
                )
            ),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(listOf("https://api.x.ai/v1/chat/completions"), requestedUrls)
        assertTrue(bodies.single().contains("\"messages\""))
        assertFalse(bodies.single().contains("\"input\""))
        assertFalse(bodies.single().contains("\"reasoning_effort\""))
        assertTrue(events.any { it is StreamEvent.Delta && it.text == "hi" })
    }

    private fun applyGrokResponsesFixture(recipeRef: String) {
        val controls = MetadataTestFixtures.capabilityControlsJson(
            MetadataTestFixtures.ControlSpec(
                capability = "reasoning",
                recipeRef = recipeRef,
                availableIntents = listOf("low", "balanced", "deep", "max"),
            ),
        )
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "capabilityRuntime": ${MetadataTestFixtures.capabilityRuntimeJson()},
              "providers": {
                "grok": {
                  "defaultModelId": "grok-4.20-multi-agent-0309",
                  "resolveMap": {
                    "grok-4.20-multi-agent-0309": "grok-4.20-multi-agent-0309"
                  },
                  "transport": {
                    "baseUrl": "https://api.x.ai",
                    "endpoints": {
                      "chat": "/v1/chat/completions",
                      "responses": "/v1/responses"
                    }
                  },
                  "models": {
                    "grok-4.20-multi-agent-0309": {
                      "canonicalModelId": "grok-4.20-multi-agent-0309",
                      "displayName": "Grok Multi-Agent",
                      "transport": "openai_responses",
                      "capabilityControls": $controls
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
    }

    @Test
    fun `grok responses reasoning uses the exact server recipe shape`() = runTest {
        applyGrokResponsesFixture("grok.responses.reasoning.v1")

        val bodies = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                bodies += (request.body as TextContent).text
                respond(
                    content = """
                        data: {"type":"response.output_text.delta","delta":"hi"}
                        data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":1}}}
                        data: [DONE]
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            },
        )

        GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "xai-test",
            modelID = "grok-4.20-multi-agent-0309",
            messages = listOf(
                ProviderTestFixtures.userMessage(
                    text = "hello",
                    providerKind = ProviderKind.Grok,
                    modelName = "grok-4.20-multi-agent-0309",
                )
            ),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(1, bodies.size)
        assertTrue(bodies.single().contains("\"reasoning\":{\"effort\":\"high\"}"))
    }

    @Test
    fun `grok responses dispatches exactly one leg and never rewrites the server reasoning object`() = runTest {
        applyGrokResponsesFixture("grok.responses.reasoning.v1")

        val bodies = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                bodies += (request.body as TextContent).text
                respond(
                    content = """
                        data: {"type":"response.output_text.delta","delta":"hi"}
                        data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":1}}}
                        data: [DONE]
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            },
        )

        GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "xai-test",
            modelID = "grok-4.20-multi-agent-0309",
            messages = listOf(
                ProviderTestFixtures.userMessage(
                    text = "hello",
                    providerKind = ProviderKind.Grok,
                    modelName = "grok-4.20-multi-agent-0309",
                )
            ),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(1, bodies.size)
        assertTrue(bodies.single().contains("\"reasoning\":{\"effort\":\"high\"}"))
    }

    @Test
    fun `grok responses never borrows a chat recipe nor invents a local reasoning shape`() = runTest {
        applyGrokResponsesFixture("grok.chat.reasoning.v1")

        val bodies = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                bodies += (request.body as TextContent).text
                respond(
                    content = """
                        data: {"type":"response.output_text.delta","delta":"hi"}
                        data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":1}}}
                        data: [DONE]
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            },
        )

        GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "xai-test",
            modelID = "grok-4.20-multi-agent-0309",
            messages = listOf(
                ProviderTestFixtures.userMessage(
                    text = "hello",
                    providerKind = ProviderKind.Grok,
                    modelName = "grok-4.20-multi-agent-0309",
                )
            ),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Max,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        val body = bodies.single()
        assertFalse(body.contains("reasoning_effort"))
        assertFalse(body.contains(""""reasoning""""))
        assertFalse(body.contains(""""summary":"auto""""))
    }
}
