package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OpenAIServiceTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    private fun requestBodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    @org.junit.After
    fun tearDown() {
        MetadataTestFixtures.clear()
        UnsupportedParamCache.resetForTest()
    }

    @Test
    fun `official openai_chat unknown runtime stays plain despite legacy reasoning profile`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "reasoning": {
                  "oai_chat_future": {
                    "levels": ["deep"],
                    "params": { "deep": { "reasoning_effort": "server-high" } }
                  }
                }
              },
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-chat",
                  "resolveMap": { "gpt-chat": "gpt-chat" },
                  "models": {
                    "gpt-chat": {
                      "canonicalModelId": "gpt-chat",
                      "transport": "openai_chat",
                      "profiles": { "reasoning": "oai_chat_future" }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        var requestUrl = ""
        var requestBody = ""
        val client = HttpClient(
            MockEngine { request ->
                requestUrl = request.url.toString()
                requestBody = requestBodyText(request.body)
                respond(
                    content = ProviderTestFixtures.openAiStream(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        OpenAIService(client = client, json = json, transportRegistry = transportRegistry).sendMessageStream(
            apiKey = "sk-test",
            modelID = "gpt-chat",
            messages = listOf(userMessage("Hi")),
            baseUrl = "https://api.openai.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals("https://api.openai.com/v1/chat/completions", requestUrl)
        assertFalse(requestBody.contains("reasoning_effort"))
        assertFalse(requestBody.contains("\"input\""))
    }

    @Test
    fun `sendMessageStream keeps final responses usage when EOF has no trailing newline`() = runTest {
        val payload = """
            event: response.output_text.delta
            data: {"delta":"hello"}

            event: response.completed
            data: {"response":{"usage":{"input_tokens":123,"output_tokens":45}}}
        """.trimIndent()
        assertFalse(payload.endsWith("\n"))

        val client = HttpClient(
            MockEngine {
                respond(
                    content = payload,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = OpenAIService(client = client, json = json, transportRegistry = transportRegistry)

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "gpt-4o",
            messages = listOf(userMessage("Hi")),
            baseUrl = "https://api.openai.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(2, events.size)
        assertTrue(events[0] is StreamEvent.Delta)
        assertEquals("hello", (events[0] as StreamEvent.Delta).text)

        val done = events[1] as StreamEvent.Done
        assertEquals("hello", done.result.text)
        assertEquals(123, done.result.promptTokens)
        assertEquals(45, done.result.completionTokens)
    }

    @Test
    fun `sendMessageStream throws on responses error event and never emits done`() = runTest {
        // Besides response.failed, a fatal in-stream error on OpenAI Responses can also arrive under
        // the event name `error`. Missing it delivers the partial text accumulated so far as a Done,
        // so the user sees a truncated reply with no error at all.
        val payload = """
            event: response.output_text.delta
            data: {"delta":"partial"}

            event: error
            data: {"type":"error","code":"server_error","message":"The model run failed.","param":null}
        """.trimIndent()

        val client = HttpClient(
            MockEngine {
                respond(
                    content = payload,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = OpenAIService(client = client, json = json, transportRegistry = transportRegistry)

        val events = mutableListOf<StreamEvent>()
        var thrown: ProviderServiceError? = null
        try {
            service.sendMessageStream(
                apiKey = "sk-test",
                modelID = "gpt-4o",
                messages = listOf(userMessage("Hi")),
                baseUrl = "https://api.openai.com/v1",
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).collect { events.add(it) }
        } catch (e: ProviderServiceError) {
            thrown = e
        }

        val upstream = thrown as? ProviderServiceError.Upstream
            ?: throw AssertionError("expected Upstream, got ${thrown?.let { it::class.simpleName } ?: "no error at all"}")
        assertEquals(200, upstream.statusCode)
        assertTrue(upstream.detail.contains("The model run failed."))
        // Partial text emitted before the throw is kept, since the failure path above renders it, but
        // a Done that claims normal completion is never allowed.
        assertTrue(events.any { it is StreamEvent.Delta })
        assertTrue(events.none { it is StreamEvent.Done })
    }

    @Test
    fun `official openai_chat legacy profile is not injected or retried when runtime is unknown`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "reasoning": {
                  "oai_chat_future": {
                    "levels": ["deep"],
                    "params": { "deep": { "reasoning_effort": "server-high" } }
                  }
                }
              },
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-chat",
                  "resolveMap": { "gpt-chat": "gpt-chat" },
                  "models": {
                    "gpt-chat": {
                      "canonicalModelId": "gpt-chat",
                      "transport": "openai_chat",
                      "profiles": { "reasoning": "oai_chat_future" }
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
                if (requestBodies.size == 1) {
                    respond(
                        content = """{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                } else {
                    respond(
                        content = """{"choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}""",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        )

        val failure = runCatching {
            OpenAIService(client = client, json = json, transportRegistry = transportRegistry).sendMessage(
                apiKey = "sk-test",
                modelID = "gpt-chat",
                messages = listOf(userMessage("Hi")),
                baseUrl = "https://api.openai.com/v1",
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            )
        }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, requestBodies.size)
        assertFalse("unknown runtime must not inject legacy reasoning: ${requestBodies[0]}", requestBodies[0].contains("reasoning_effort"))
    }

    /**
     * Regression: the whole Codex subscription outbound path once went missing.
     *
     * `OpenAIService` does not extend `OpenAICompatibleService`, while the subscription context is
     * only set when `kind == OpenAI`, and `kind == OpenAI` happens to dispatch to `OpenAIService`.
     * So the codex branch written in the base class was never executed. What users saw: sign-in and
     * the model catalog both worked, because those go through the separate
     * `OpenAISubscriptionOAuthClient` path, but sending a message took the subscription access token
     * to `api.openai.com/v1/responses`, upstream answered "Missing scopes: api.responses.write", and
     * that was then classified as "Invalid API Key".
     *
     * So the assertions pin **the actual outbound shape** (URL, headers, the hard constraints on the
     * body) rather than whether some function was called.
     */
    @Test
    fun `codex subscription streams to the codex endpoint with account and required headers`() = runTest {
        // Subscription models are not in the model catalog, so resolveMap is deliberately left empty,
        // matching what happens in production.
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(providerKind = ProviderKind.OpenAI)
        )

        var requestUrl = ""
        var requestBody = ""
        var accountHeader: String? = null
        var originatorHeader: String? = null
        var versionHeader: String? = null
        var authorizationHeader: String? = null
        val client = HttpClient(
            MockEngine { request ->
                requestUrl = request.url.toString()
                requestBody = requestBodyText(request.body)
                accountHeader = request.headers["chatgpt-account-id"]
                originatorHeader = request.headers["originator"]
                versionHeader = request.headers["version"]
                authorizationHeader = request.headers[HttpHeaders.Authorization]
                respond(
                    content = """
                        event: response.output_text.delta
                        data: {"type":"response.output_text.delta","delta":"hi"}

                        event: response.completed
                        data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":1}}}

                        data: [DONE]
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            },
        )

        val events = OpenAIService(client, json, transportRegistry).sendMessageStream(
            apiKey = "codex-access-token",
            modelID = "gpt-5.6-sol",
            messages = listOf(userMessage("hi")),
            // A subscription connection's base URL text is the standard OpenAI base, so
            // `usesOfficialOpenAIApi` is always true for it. Before the fix that was the value that
            // sent the request to the standard API. The split has to happen before any baseUrl check.
            baseUrl = "https://api.openai.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                openAISubscription = ai.oriveo.community.core.provider.openai.OpenAISubscriptionRequestContext(
                    responsesUrl = "https://chatgpt.com/backend-api/codex/responses",
                    accountId = "acct-123",
                    requiredHeaders = mapOf("originator" to "codex_cli_rs", "version" to "0.104.0"),
                ),
            ),
        ).toList()

        assertEquals("https://chatgpt.com/backend-api/codex/responses", requestUrl)
        assertEquals("acct-123", accountHeader)
        assertEquals("codex_cli_rs", originatorHeader)
        assertEquals("0.104.0", versionHeader)
        assertEquals("Bearer codex-access-token", authorizationHeader)
        // store:false and encrypted reasoning are hard constraints of this path, and the standard
        // body builder never produces them, which makes them the evidence that the subscription
        // builder really ran.
        assertTrue(requestBody.contains("\"store\":false"))
        assertTrue(requestBody.contains("reasoning.encrypted_content"))
        assertTrue(events.any { it is StreamEvent.Delta && it.text == "hi" })
    }

    /**
     * The non-streaming path is not implemented for subscriptions, so it must refuse outright rather
     * than falling back to the standard branch.
     *
     * The Codex catalog does not currently declare image generation, so dispatch never reaches here.
     * What this locks down is that if it ever does, it will not silently take a subscription token to
     * api.openai.com, which is exactly the shape of the failure above.
     */
    @Test
    fun `codex subscription is refused on the non-streaming path`() = runTest {
        val client = HttpClient(MockEngine { error("no upstream request expected") })

        val failure = runCatching {
            OpenAIService(client, json, transportRegistry).sendMessage(
                apiKey = "codex-access-token",
                modelID = "gpt-5.6-sol",
                messages = listOf(userMessage("hi")),
                baseUrl = "https://api.openai.com/v1",
                supportsImageGen = true,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    openAISubscription = ai.oriveo.community.core.provider.openai.OpenAISubscriptionRequestContext(
                        responsesUrl = "https://chatgpt.com/backend-api/codex/responses",
                        accountId = "acct-123",
                        requiredHeaders = mapOf("originator" to "codex_cli_rs"),
                    ),
                ),
            )
        }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.InvalidConfiguration)
    }

    private fun userMessage(text: String) = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "gpt-4o",
        state = ChatMessageState.Delivered,
    )
}
