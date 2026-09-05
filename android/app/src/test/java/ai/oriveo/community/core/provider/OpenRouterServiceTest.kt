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

class OpenRouterServiceTest {

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
    fun `sendMessageStream emits delta then done with usage tokens`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond(
                    content = ProviderTestFixtures.openAiStream(
                        ProviderTestFixtures.openAiChunk(delta = "hi", model = "openai/gpt-4o"),
                        ProviderTestFixtures.openAiChunk(promptTokens = 4, completionTokens = 2, model = "openai/gpt-4o"),
                    ),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val service = OpenRouterService(client, json, transportRegistry)
        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "openai/gpt-4o",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.OpenRouter, "openai/gpt-4o")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(2, events.size)
        assertEquals("hi", (events[0] as StreamEvent.Delta).text)
        val done = events.last() as StreamEvent.Done
        assertEquals("hi", done.result.text)
        assertEquals(4, done.result.promptTokens)
        assertEquals(2, done.result.completionTokens)
        
        assertEquals(0.0, done.result.estimatedCost, 1e-9)
        assertEquals("openai/gpt-4o", done.result.servedModelID)
    }

    @Test
    fun `sendMessageStream uses metadata maxOutputTokens for max_tokens`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "providers": {
                "openRouter": {
                  "defaultModelId": "minimax/minimax-m2.5:free",
                  "resolveMap": { "minimax/minimax-m2.5:free": "minimax/minimax-m2.5:free" },
                  "models": {
                    "minimax/minimax-m2.5:free": {
                      "canonicalModelId": "minimax/minimax-m2.5:free",
                      "maxOutputTokens": 1234
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
                    content = ProviderTestFixtures.openAiStream(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val service = OpenRouterService(client, json, transportRegistry)
        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "minimax/minimax-m2.5:free",
            messages = listOf(
                ProviderTestFixtures.userMessage("Hi", ProviderKind.OpenRouter, "MiniMax M2.5"),
            ),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertTrue(requestBody.contains("\"model\":\"minimax/minimax-m2.5:free\""))
        assertTrue(requestBody.contains("\"max_tokens\":1234"))
        assertFalse(requestBody.contains("\"max_tokens\":4096"))
    }

    @Test
    fun `legacy OpenRouter reasoning profile stays dormant without exact runtime`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "reasoning": {
                  "or_future": {
                    "levels": ["max"],
                    "params": {
                      "max": { "reasoning": { "effort": "server-x" } }
                    }
                  }
                }
              },
              "providers": {
                "openRouter": {
                  "defaultModelId": "future/reasoner",
                  "resolveMap": { "future/reasoner": "future/reasoner" },
                  "models": {
                    "future/reasoner": {
                      "canonicalModelId": "future/reasoner",
                      "profiles": { "reasoning": "or_future" }
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
                    content = ProviderTestFixtures.openAiStream(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        OpenRouterService(client, json, transportRegistry).sendMessageStream(
            apiKey = "sk-test",
            modelID = "future/reasoner",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.OpenRouter, "future/reasoner")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Max,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertFalse(requestBody.contains(""""effort":"server-x""""))
        assertFalse(requestBody.contains(""""effort":"xhigh""""))
    }

    @Test
    fun `legacy generation support cannot authorize temperature without exact runtime`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "generation": {
                  "parameters": { "temperature": { "valueSchema": "number" } },
                  "templates": {
                    "openai_chat_completions": {
                      "transport": "openai_chat", "wire": { "temperature": "temperature" }
                    }
                  }
                }
              },
              "providers": {
                "openRouter": {
                  "defaultModelId": "no-temp",
                  "resolveMap": {
                    "no-temp": "no-temp",
                    "unknown-temp": "unknown-temp"
                  },
                  "models": {
                    "no-temp": {
                      "canonicalModelId": "no-temp",
                      "transport": "openai_chat",
                      "supportsTemperature": false
                    },
                    "unknown-temp": {
                      "canonicalModelId": "unknown-temp",
                      "transport": "openai_chat"
                    },
                    "supported-temp": {
                      "canonicalModelId": "supported-temp",
                      "transport": "openai_chat",
                      "supportsTemperature": true,
                      "profiles": {
                        "generation": {
                          "template": "openai_chat_completions",
                          "parameters": [{"id":"temperature","support":"supported","source":"authoritative_metadata"}]
                        }
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        val requestBodies = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                requestBodies += requestBodyText(request.body)
                respond(
                    content = ProviderTestFixtures.openAiStream(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = OpenRouterService(client, json, transportRegistry)

        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "no-temp",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.OpenRouter, "no-temp")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(temperature = 0.3f),
        ).toList()
        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "unknown-temp",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.OpenRouter, "unknown-temp")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(temperature = 0.3f),
        ).toList()
        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "supported-temp",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.OpenRouter, "supported-temp")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(temperature = 0.3f),
        ).toList()

        //
        //
        assertFalse(requestBodies[0].contains("temperature"))
        //
        assertFalse(requestBodies[1].contains("temperature"))
        assertFalse(requestBodies[2].contains("temperature"))
    }

    @Test
    fun `legacy OpenRouter web profile stays dormant without exact runtime`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "webSearch": {
                  "or_web": {
                    "mergeParams": { "plugins": [{ "id": "web", "max_results": 5 }] },
                    "streamShape": {
                      "citationsArrayPath": "choices.0.delta.annotations",
                      "citationUrlField": "url_citation.url",
                      "citationTitleField": "url_citation.title",
                      "citationSnippetField": "url_citation.content"
                    }
                  }
                }
              },
              "providers": {
                "openRouter": {
                  "defaultModelId": "anthropic/claude-sonnet-4",
                  "resolveMap": { "anthropic/claude-sonnet-4": "anthropic/claude-sonnet-4" },
                  "models": {
                    "anthropic/claude-sonnet-4": {
                      "canonicalModelId": "anthropic/claude-sonnet-4",
                      "profiles": { "webSearch": "or_web" },
                      "capabilities": ["text", "web"]
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
                    content = ProviderTestFixtures.openAiStream(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val service = OpenRouterService(client, json, transportRegistry)
        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "anthropic/claude-sonnet-4",
            messages = listOf(
                ProviderTestFixtures.userMessage("Hi", ProviderKind.OpenRouter, "anthropic/claude-sonnet-4"),
            ),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertFalse(requestBody.contains("\"plugins\":[{\"id\":\"web\",\"max_results\":5}]"))
        assertFalse(requestBody.contains("openrouter:web_search"))
        assertFalse(requestBody.contains("web_search_options"))
    }

    @Test
    fun `sendMessageStream parses delta reasoning into Reasoning events and reasoningText`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond(
                    content = ProviderTestFixtures.openAiStream(
                        //
                        """data: {"choices":[{"delta":{"reasoning":"thinking..."}}]}""",
                        ProviderTestFixtures.openAiChunk(delta = "answer", model = "xiaomi/mimo-v2.5"),
                        ProviderTestFixtures.openAiChunk(promptTokens = 3, completionTokens = 2, model = "xiaomi/mimo-v2.5"),
                    ),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val service = OpenRouterService(client, json, transportRegistry)
        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "xiaomi/mimo-v2.5",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.OpenRouter, "xiaomi/mimo-v2.5")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        val reasoning = events.filterIsInstance<StreamEvent.Reasoning>()
        assertEquals(1, reasoning.size)
        assertEquals("thinking...", reasoning.first().text)
        assertEquals("answer", events.filterIsInstance<StreamEvent.Delta>().first().text)
        val done = events.last() as StreamEvent.Done
        assertEquals("answer", done.result.text)
        assertEquals("thinking...", done.result.reasoningText)
    }
}
