package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A slim set of MistralService tests. The metadata-only behaviour of sync is covered by the
 * [OfficialProviderMetadataOnlySyncTest] matrix and the request shape is pinned by [RequestShapeContractTest], so what
 * is left here is that the vendor endpoint is hit, and that a real Magistral streaming chunk shape (captured directly
 * from api.mistral.ai) splits reasoning from body text and carries usage on the finish chunk.
 */
class MistralServiceTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `sendMessageStream hits official endpoint and parses magistral thinking stream`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Mistral,
                defaultModelId = "magistral-medium-latest",
                resolveMap = mapOf("magistral-medium-latest" to "magistral-medium-latest"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        "magistral-medium-latest",
                        displayName = "Magistral Medium",
                    )
                ),
            )
        )

        // The frame order as observed: an empty string delta first, then an array of thinking blocks, then an empty thinking
        // array closing that phase, then the body falling back to a plain string, and finally a finish chunk carrying usage.
        // The SSE frames also carry a non-standard "p" field, which has to be ignored harmlessly.
        val payload = """
            data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}],"p":"abcdef"}

            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"thinkA"}]}]}}],"p":"gh"}

            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"thinkB"}]}]}}]}

            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[]}]}}]}

            data: {"choices":[{"delta":{"content":"body"}}]}

            data: {"choices":[{"delta":{"content":"-more"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_tokens_details":{"cached_tokens":3}},"p":"pad"}

            data: [DONE]
        """.trimIndent()

        val requestedUrls = mutableListOf<String>()
        val authHeaders = mutableListOf<String?>()
        val service = MistralService(
            client = HttpClient(
                MockEngine { request ->
                    requestedUrls += request.url.toString()
                    authHeaders += request.headers[HttpHeaders.Authorization]
                    respond(
                        content = payload,
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                }
            ),
            json = json,
            transportRegistry = transportRegistry,
        )

        val events = service.sendMessageStream(
            apiKey = "mistral-test-key",
            modelID = "magistral-medium-latest",
            messages = listOf(
                ProviderTestFixtures.userMessage(
                    text = "hi",
                    providerKind = ProviderKind.Mistral,
                    modelName = "magistral-medium-latest",
                )
            ),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(listOf("https://api.mistral.ai/v1/chat/completions"), requestedUrls)
        assertEquals(listOf<String?>("Bearer mistral-test-key"), authHeaders)

        val reasoning = events.filterIsInstance<StreamEvent.Reasoning>().joinToString("") { it.text }
        val deltas = events.filterIsInstance<StreamEvent.Delta>().joinToString("") { it.text }
        assertEquals("thinkAthinkB", reasoning)
        assertEquals("body-more", deltas)

        val done = events.last() as StreamEvent.Done
        assertEquals("body-more", done.result.text)
        assertEquals("thinkAthinkB", done.result.reasoningText)
        // OpenAI template: the promptTokens shown = (prompt - cached) + cached = 10, with cached listed separately
        assertEquals(10, done.result.promptTokens)
        assertEquals(5, done.result.completionTokens)
        assertEquals(3, done.result.cachedInputTokens)
    }

    @Test
    fun `mistral parser state round trips ordered content and tool calls into next request`() = runTest {
        applyMistralContinuationRuntime()
        val firstPayload = """
            data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"thought-A"}]}]}}]}

            data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"thought-B"}],"closed":true},{"type":"text","text":"first"}],"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"lookup","arguments":"{\"q\""}}]}}]}

            data: {"choices":[{"delta":{"content":" answer","tool_calls":[{"index":0,"function":{"arguments":":\"news\"}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]
        """.trimIndent()
        val secondPayload = """
            data: {"choices":[{"delta":{"content":"continued"},"finish_reason":"stop"}]}

            data: [DONE]
        """.trimIndent()
        val requestBodies = mutableListOf<JsonObject>()
        var leg = 0
        val client = HttpClient(MockEngine { request ->
            requestBodies += request.jsonBody()
            respond(
                content = if (leg++ == 0) firstPayload else secondPayload,
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        })
        val service = MistralService(client, json, transportRegistry)
        val firstEvents = service.sendMessageStream(
            apiKey = "key", modelID = "mistral-medium-3-5",
            messages = listOf(ProviderTestFixtures.userMessage(
                text = "question", providerKind = ProviderKind.Mistral, modelName = "mistral-medium-3-5",
            )),
            reasoningMode = ReasoningMode.Deep,
        ).toList()
        val continuation = firstEvents.filterIsInstance<StreamEvent.RecipeContinuation>().single()
        val expectedContent = Json.parseToJsonElement(
            """[{"type":"thinking","thinking":[{"type":"text","text":"thought-A"},{"type":"text","text":"thought-B"}],"closed":true},{"type":"text","text":"first answer"}]""",
        )
        val assistant = continuation.state["assistantMessages"]!!.jsonArray.single().jsonObject
        assertEquals(expectedContent, assistant["content"])
        assertEquals("{\"q\":\"news\"}", assistant["tool_calls"]!!.jsonArray.single().jsonObject["function"]!!.jsonObject["arguments"]!!.jsonPrimitive.content)

        service.sendMessageStream(
            apiKey = "key", modelID = "mistral-medium-3-5",
            messages = listOf(ProviderTestFixtures.userMessage(
                text = "continue", providerKind = ProviderKind.Mistral, modelName = "mistral-medium-3-5",
            )),
            reasoningMode = ReasoningMode.Deep,
            requestOptions = ChatRequestOptions(
                localContinuationState = continuation.state,
                localContinuationExplicit = true,
            ),
        ).toList()
        val replayMessages = requestBodies.last()["messages"]!!.jsonArray
        assertEquals(listOf("assistant", "user"), replayMessages.map { it.jsonObject["role"]!!.jsonPrimitive.content })
        assertEquals(expectedContent, replayMessages.first().jsonObject["content"])
        assertEquals(assistant["tool_calls"], replayMessages.first().jsonObject["tool_calls"])
        client.close()
    }

    private fun applyMistralContinuationRuntime() {
        val runtime = Json.parseToJsonElement(MetadataTestFixtures.capabilityRuntimeJson()).jsonObject
        val recipes = runtime["recipes"]!!.jsonObject
        val recipeID = "mistral.chat.reasoning.v1"
        val recipe = recipes[recipeID]!!.jsonObject
        val patchedRuntime = JsonObject(runtime + mapOf(
            "recipes" to JsonObject(recipes + mapOf(
                recipeID to JsonObject(recipe + mapOf("continuationKind" to JsonPrimitive("replay_reasoning"))),
            )),
        ))
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", patchedRuntime)
            put("providers", buildJsonObject { put("mistral", buildJsonObject {
                put("resolveMap", buildJsonObject { put("mistral-medium-3-5", "mistral-medium-3-5") })
                put("models", buildJsonObject { put("mistral-medium-3-5", buildJsonObject {
                    put("transport", "openai_chat")
                    put("capabilityControls", buildJsonObject { put("reasoning", buildJsonObject {
                        put("state", "auto_available")
                        put("recipeRef", recipeID)
                        put("availableIntents", JsonArray(listOf(JsonPrimitive("off"), JsonPrimitive("deep"))))
                    }) })
                }) })
            }) })
        }.toString())
    }

    private fun HttpRequestData.jsonBody(): JsonObject =
        json.parseToJsonElement((body as TextContent).text).jsonObject
}
