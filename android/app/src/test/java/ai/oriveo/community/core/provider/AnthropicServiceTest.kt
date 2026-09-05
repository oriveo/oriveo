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
import io.ktor.http.content.OutgoingContent
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

class AnthropicServiceTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    private fun requestBodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `syncProvider validates key and returns empty models`() = runTest {
        // The service only validates the key and drives the transport; the model list itself is assembled by ProviderRepository from the catalog metadata.
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Anthropic,
                defaultModelId = "claude-3",
                resolveMap = mapOf("claude-3" to "claude-3"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec("claude-3", displayName = "Claude 3"),
                ),
            )
        )

        val client = HttpClient(MockEngine { respond("{}", HttpStatusCode.OK) })
        val service = AnthropicService(client, json, transportRegistry)

        val result = service.syncProvider(apiKey = "sk-test", preferredModelID = " claude-4 ", baseUrl = null)

        assertTrue(result.models.isEmpty())
    }

    @Test
    fun `sendMessageStream parses anthropic SSE and cost`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Anthropic,
                defaultModelId = "claude-3",
                resolveMap = mapOf("claude-3" to "claude-3"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "claude-3",
                        promptPerToken = 0.001,
                        completionPerToken = 0.002,
                    ),
                ),
            )
        )

        val stream = ProviderTestFixtures.anthropicStream(
            ProviderTestFixtures.anthropicEvent("message_start", "{\"message\":{\"usage\":{\"input_tokens\":5}}}"),
            // content_block_delta is dispatched on delta.type, so the type field has to be spelled out explicitly.
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}"),
            ProviderTestFixtures.anthropicEvent("message_delta", "{\"usage\":{\"output_tokens\":3}}"),
        )

        val client = HttpClient(
            MockEngine {
                respond(
                    content = stream,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val service = AnthropicService(client, json, transportRegistry)
        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "claude-3",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Anthropic, "claude-3")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(2, events.size)
        assertEquals("hello", (events[0] as StreamEvent.Delta).text)
        val done = events.last() as StreamEvent.Done
        assertEquals("hello", done.result.text)
        assertEquals(5, done.result.promptTokens)
        assertEquals(3, done.result.completionTokens)
        assertEquals(0.001 * 5 + 0.002 * 3, done.result.estimatedCost, 1e-9)
    }

    @Test
    fun `legacy Anthropic profile does not inject thinking or max_tokens without exact runtime`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "reasoning": {
                  "ant_budget_future": {
                    "levels": ["deep"],
                    "params": {
                      "deep": {
                        "thinking": { "type": "enabled", "budget_tokens": 7777 },
                        "max_tokens": 8888
                      }
                    }
                  }
                }
              },
              "providers": {
                "anthropic": {
                  "defaultModelId": "claude-sonnet-test",
                  "resolveMap": { "claude-sonnet-test": "claude-sonnet-test" },
                  "models": {
                    "claude-sonnet-test": {
                      "canonicalModelId": "claude-sonnet-test",
                      "profiles": { "reasoning": "ant_budget_future" }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        var requestBody = ""
        val client = HttpClient(
            MockEngine { request ->
                requestBody = requestBodyText(request.body)
                respond(
                    content = ProviderTestFixtures.anthropicStream(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        AnthropicService(client, json, transportRegistry).sendMessageStream(
            apiKey = "sk-test",
            modelID = "claude-sonnet-test",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Anthropic, "claude-sonnet-test")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertFalse(requestBody.contains(""""budget_tokens":7777"""))
        assertFalse(requestBody.contains(""""max_tokens":8888"""))
        assertFalse(requestBody.contains(""""budget_tokens":16384"""))
        assertFalse(requestBody.contains(""""max_tokens":20480"""))
    }

    // Dispatch coverage for thinking_delta vs text_delta: Anthropic ships both of them inside content_block_delta,
    // and delta.type is the only thing that decides whether a chunk becomes a Reasoning event or a Delta event.

    @Test
    fun `sendMessageStream emits Reasoning for thinking_delta and Delta for text_delta`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Anthropic,
                defaultModelId = "claude-3",
                resolveMap = mapOf("claude-3" to "claude-3"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "claude-3")),
            )
        )

        val stream = ProviderTestFixtures.anthropicStream(
            ProviderTestFixtures.anthropicEvent("message_start", "{\"message\":{\"usage\":{\"input_tokens\":2}}}"),
            // thinking_delta arrives first (reasoning tokens)
            ProviderTestFixtures.anthropicEvent(
                "content_block_delta",
                "{\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"let me think...\"}}",
            ),
            // then the visible answer as text_delta
            ProviderTestFixtures.anthropicEvent(
                "content_block_delta",
                "{\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}",
            ),
            ProviderTestFixtures.anthropicEvent("message_delta", "{\"usage\":{\"output_tokens\":1}}"),
        )

        val client = HttpClient(
            MockEngine {
                respond(
                    content = stream,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val service = AnthropicService(client, json, transportRegistry)
        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "claude-3",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Anthropic, "claude-3")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        // Expected: Reasoning("let me think...") + Delta("hi") + Done
        assertEquals(3, events.size)
        assertTrue("first event must be Reasoning", events[0] is StreamEvent.Reasoning)
        assertEquals("let me think...", (events[0] as StreamEvent.Reasoning).text)
        assertTrue("second event must be Delta", events[1] is StreamEvent.Delta)
        assertEquals("hi", (events[1] as StreamEvent.Delta).text)
        assertTrue("last event must be Done", events[2] is StreamEvent.Done)
        // Done.result.text accumulates the visible answer only, never the reasoning text
        assertEquals("hi", (events[2] as StreamEvent.Done).result.text)
    }

    @Test
    fun `sendMessageStream ignores unknown delta types (signature_delta etc)`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Anthropic,
                defaultModelId = "claude-3",
                resolveMap = mapOf("claude-3" to "claude-3"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "claude-3")),
            )
        )

        // Unknown delta types such as signature_delta must not be accumulated as reasoning or as text
        val stream = ProviderTestFixtures.anthropicStream(
            ProviderTestFixtures.anthropicEvent(
                "content_block_delta",
                "{\"delta\":{\"type\":\"signature_delta\",\"signature\":\"abc\"}}",
            ),
            ProviderTestFixtures.anthropicEvent(
                "content_block_delta",
                "{\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}",
            ),
        )

        val client = HttpClient(
            MockEngine {
                respond(
                    content = stream,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val service = AnthropicService(client, json, transportRegistry)
        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "claude-3",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Anthropic, "claude-3")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        // signature_delta is dropped silently, leaving just Delta + Done
        assertEquals(2, events.size)
        assertTrue("first event must be Delta", events[0] is StreamEvent.Delta)
        assertEquals("done", (events[0] as StreamEvent.Delta).text)
        assertTrue("last event must be Done", events[1] is StreamEvent.Done)
        assertFalse("no Reasoning event expected", events.any { it is StreamEvent.Reasoning })
    }
}
