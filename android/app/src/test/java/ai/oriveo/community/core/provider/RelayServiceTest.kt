package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayImageConfig
import ai.oriveo.community.core.model.RelayImageMode
import ai.oriveo.community.core.model.RelayWebSearchToolName
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.ktor.http.withCharset
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayServiceTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    private fun relayIdentity(modelId: String) = CapabilityEvidenceIdentity(
        partitionId = "test-partition",
        connectionInstanceId = "relay-test",
        connectionGeneration = "1",
        credentialEpoch = "1",
        providerKind = ProviderKind.Relay.rawValue,
        canonicalModelId = modelId,
    )

    private fun relayModel(
        modelId: String,
        reasoning: Boolean = false,
        web: Boolean = false,
    ) = AIModel(
        id = modelId,
        name = modelId,
        capabilities = if (web) listOf(ModelCapability.Web) else emptyList(),
        reasoningModeAvailable = reasoning,
        reasoningProfile = if (reasoning) "relay_reasoning" else null,
        webSearchProfile = if (web) "relay_web" else null,
    )

    @After
    fun tearDown() {
        UnsupportedParamCache.resetForTest()
    }

    @Test
    fun `persisted http relay is rejected before the network engine runs`() = runTest {
        var requestCount = 0
        val client = HttpClient(
            MockEngine {
                requestCount += 1
                respond("{}", HttpStatusCode.OK)
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        try {
            service.syncProvider(
                apiKey = "sk-relay",
                preferredModelID = "local-model",
                baseUrl = "http://10.0.0.5:8080/v1",
            )
            throw AssertionError("Expected InvalidConfiguration")
        } catch (error: ProviderServiceError.InvalidConfiguration) {
            assertEquals(RelayEndpointPolicy.HTTPS_REQUIRED_MESSAGE, error.detail)
        }

        assertEquals(0, requestCount)
    }

    // A local inference engine needs no authentication and must be sent no credentials at
    // all. Catalog sync therefore cannot be stopped up front by the empty-key gate, and it has
    // to use the API root that probing actually found together with the LAN security mode --
    // otherwise the request never leaves the gate. Both halves were regressions found against
    // a real engine.
    @Test
    fun `local engine catalog sync passes the empty key gate and uses the probed api root`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = ByteReadChannel("""{"data":[{"id":"qwen/qwen3-0.6b"}]}"""),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val result = service.syncProvider(
            apiKey = "",
            preferredModelID = "qwen/qwen3-0.6b",
            baseUrl = "http://192.168.31.250:1234",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.None,
                securityMode = RelayConnectionSecurityMode.LocalHttp,
                resolvedAPIBaseURL = "http://192.168.31.250:1234/v1",
                engineProfile = "lmstudio",
            ),
        )

        assertEquals(1, seenRequests.size)
        // The probed root (which already includes /v1) plus /models, not the raw baseUrlText.
        assertEquals("http://192.168.31.250:1234/v1/models", seenRequests[0].url.toString())
        // With authMode = None an empty key must not be assembled into an
        // `Authorization: Bearer ` header, which would additionally trip the cleartext
        // sensitive-material check.
        assertFalse(
            seenRequests[0].headers.names().any { it.equals(HttpHeaders.Authorization, ignoreCase = true) },
        )
        assertEquals(listOf("qwen/qwen3-0.6b"), result.models.map { it.id })
    }

    @Test
    fun `ordinary local relay catalog sync preserves local security and no auth`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = ByteReadChannel("""{"data":[{"id":"local-relay-model"}]}"""),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val productionRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.None,
            securityMode = RelayConnectionSecurityMode.LocalHttp,
            resolvedAPIBaseURL = "http://192.168.31.251:8080/v1",
            engineProfile = null,
        )
        val result = service.syncProvider(
            apiKey = "",
            preferredModelID = "local-relay-model",
            baseUrl = "http://192.168.31.251:8080",
            relayRequested = productionRequested,
        )

        val request = seenRequests.single()
        assertEquals("http://192.168.31.251:8080/v1/models", request.url.toString())
        assertFalse(request.headers.names().any { it.equals(HttpHeaders.Authorization, ignoreCase = true) })
        assertEquals(listOf("local-relay-model"), result.models.map { it.id })
    }

    // The counterweight to the exemption above: a cloud relay has no engineProfile, so an
    // empty key must still fail immediately with InvalidAPIKey and send nothing. The local
    // engine exemption must not loosen the gate for relays that do need credentials.
    @Test
    fun `cloud relay catalog sync still rejects an empty key without sending a request`() = runTest {
        var requestCount = 0
        val client = HttpClient(
            MockEngine {
                requestCount += 1
                respond("{}", HttpStatusCode.OK)
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        try {
            service.syncProvider(
                apiKey = "",
                preferredModelID = null,
                baseUrl = "https://relay.example.com/v1",
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIChatCompletions,
                    authMode = RelayAuthMode.Bearer,
                ),
            )
            throw AssertionError("Expected InvalidAPIKey")
        } catch (_: ProviderServiceError.InvalidAPIKey) {
            // expected
        }

        assertEquals(0, requestCount)
    }

    @Test
    fun `responses relay uses explicit transport image tool and output item fallback`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val stream = """
            event: response.output_text.delta
            data: {"delta":"hello"}

            event: response.output_item.done
            data: {"item":{"id":"img-1","type":"image_generation_call","result":"AQID"}}

            event: response.completed
            data: {"response":{"usage":{"input_tokens":9,"output_tokens":4}}}
        """.trimIndent()

        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = ByteReadChannel(stream),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val events = service.sendMessageStream(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                    modelID = "gpt-5.4",
                    reasoningEffort = RelayReasoningEffort.XHigh,
                    serviceTier = "fast",
                    stream = true,
                    disableResponseStorage = true,
                ),
                activeModel = relayModel("gpt-5.4", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("gpt-5.4"),
                relayImage = RelayImageConfig(
                    enabled = true,
                    mode = RelayImageMode.ToolModel,
                    toolModelID = "gpt-image-2",
                ),
            ),
        ).toList()

        val request = seenRequests.single()
        val body = (request.body as TextContent).text
        assertTrue(request.url.toString().endsWith("/responses"))
        assertEquals("Bearer sk-relay", request.headers[HttpHeaders.Authorization])
        assertTrue(body.contains("\"service_tier\":\"fast\""))
        assertTrue(body.contains("\"store\":false"))
        assertTrue(body.contains("\"effort\":\"xhigh\""))
        assertTrue(body.contains("\"model\":\"gpt-image-2\""))

        assertEquals("hello", (events[0] as StreamEvent.Delta).text)
        assertEquals("AQID", (events[1] as StreamEvent.ImagePart).attachment.base64Data)
        val done = events.last() as StreamEvent.Done
        assertEquals("hello", done.result.text)
        assertEquals(9, done.result.promptTokens)
        assertEquals(4, done.result.completionTokens)
    }

    @Test
    fun `chat completions relay forwards service tier on non stream requests`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val done = service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIChatCompletions,
                    authMode = RelayAuthMode.Bearer,
                    serviceTier = "priority",
                ),
            ),
        )

        val request = seenRequests.single()
        val body = (request.body as TextContent).text
        assertTrue(request.url.toString().endsWith("/chat/completions"))
        assertTrue(body.contains("\"service_tier\":\"priority\""))
        assertEquals("hello", done.result.text)
    }

    @Test
    fun `responses relay injects codex identity headers and custom user agent can override ua`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                    codexCompatIdentity = true,
                    customUserAgent = "Custom UA",
                ),
            ),
        )

        val request = seenRequests.single()
        assertEquals("Custom UA", request.headers[HttpHeaders.UserAgent])
        assertEquals("codex_cli_rs", request.headers["Originator"])
        assertTrue(request.headers["session_id"].orEmpty().contains("-"))
        assertEquals("responses=experimental", request.headers["OpenAI-Beta"])
    }

    @Test
    fun `responses relay does not inject codex identity when disabled`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                    codexCompatIdentity = false,
                ),
            ),
        )

        val request = seenRequests.single()
        assertEquals(null, request.headers["Originator"])
        assertEquals(null, request.headers["session_id"])
        assertEquals(null, request.headers["OpenAI-Beta"])
    }

    @Test
    fun `ping relay uses responses route for codex style`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"output_text":"pong"}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.pingRelay(
            apiKey = "sk-relay",
            baseUrl = "https://relay.example.com/v1",
            modelID = "gpt-5.4",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIResponses,
                authMode = RelayAuthMode.Bearer,
                disableResponseStorage = true,
                codexCompatIdentity = true,
            ),
            relayKind = ai.oriveo.community.core.model.RelayKind.CodexStyle,
        )

        val request = seenRequests.single()
        val body = (request.body as TextContent).text
        assertTrue(request.url.toString().endsWith("/responses"))
        assertTrue(body.contains("\"max_output_tokens\":1"))
        assertTrue(body.contains("\"store\":false"))
        assertEquals("codex_cli_rs", request.headers["Originator"])
    }

    @Test
    fun `generation verification sends a real one token chat request`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"choices":[{"message":{"content":"pong"}}]}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.verifyGeneration(
            apiKey = "sk-relay",
            baseUrl = "https://relay.example.com/v1",
            modelID = "gpt-5.4",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.Bearer,
            ),
        )

        val request = seenRequests.single()
        val body = (request.body as TextContent).text
        assertTrue(request.url.toString().endsWith("/chat/completions"))
        assertEquals("Bearer sk-relay", request.headers[HttpHeaders.Authorization])
        assertTrue(body.contains("\"model\":\"gpt-5.4\""))
        assertTrue(body.contains("\"stream\":false"))
        assertTrue(body.contains("\"max_tokens\":1"))
        assertTrue(body.contains("\"role\":\"user\""))
        assertTrue(body.contains("\"content\":\"ping\""))
    }

    @Test
    fun `ping relay rejects a 2xx HTML fallback page`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond(
                    content = "<!doctype html><html>relay console</html>",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.Html.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        try {
            service.pingRelay(
                apiKey = "sk-relay",
                baseUrl = "https://relay.example.com/v1",
                modelID = "gpt-5.4",
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIChatCompletions,
                    authMode = RelayAuthMode.Bearer,
                ),
            )
            throw AssertionError("Expected HTML response to fail validation")
        } catch (error: ProviderServiceError.RelayUpstream) {
            assertEquals(HttpStatusCode.OK.value, error.statusCode)
            assertTrue(error.detail.contains("HTML"))
        }
    }

    @Test
    fun `ping relay falls back to models route when OpenAI compatible model is blank`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"data":[{"id":"gpt-5.4","object":"model"}]}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.pingRelay(
            apiKey = "sk-relay",
            baseUrl = "https://relay.example.com/v1",
            modelID = " ",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.Auto,
                authMode = RelayAuthMode.Bearer,
            ),
        )

        val request = seenRequests.single()
        assertTrue(request.url.toString().endsWith("/models"))
        assertEquals("Bearer sk-relay", request.headers[HttpHeaders.Authorization])
    }

    @Test
    fun `responses relay surfaces xhigh 4xx after one unchanged attempt`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                if (seenRequests.size == 1) {
                    respond(
                        content = """{"error":{"message":"unsupported reasoning_effort xhigh"}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(
                        content = """{"output_text":"hello","usage":{"input_tokens":6,"output_tokens":4}}""",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                }
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val failure = runCatching { service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Max,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                ),
                activeModel = relayModel("gpt-5.4", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("gpt-5.4"),
            ),
        ) }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, seenRequests.size)
        val body = (seenRequests.single().body as TextContent).text
        assertTrue(body.contains("\"effort\":\"xhigh\""))
    }

    @Test
    fun `chat completions relay surfaces xhigh 4xx after one unchanged attempt`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                if (seenRequests.size == 1) {
                    respond(
                        content = """{"error":{"message":"unsupported reasoning_effort xhigh"}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(
                        content = """{"choices":[{"message":{"content":"hello"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}""",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                }
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val failure = runCatching { service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Max,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIChatCompletions,
                    authMode = RelayAuthMode.Bearer,
                ),
                activeModel = relayModel("gpt-5.4", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("gpt-5.4"),
            ),
        ) }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, seenRequests.size)
        val body = (seenRequests.single().body as TextContent).text
        assertTrue(body.contains("\"reasoning_effort\":\"xhigh\""))
    }

    @Test
    fun `anthropic relay uses x api key and messages endpoint`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val stream = ProviderTestFixtures.anthropicStream(
            ProviderTestFixtures.anthropicEvent("message_start", "{\"message\":{\"usage\":{\"input_tokens\":5}}}"),
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}"),
            ProviderTestFixtures.anthropicEvent("message_delta", "{\"usage\":{\"output_tokens\":3}}"),
        )
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = ByteReadChannel(stream),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val events = service.sendMessageStream(
            apiKey = "anth-key",
            modelID = "claude-sonnet-4-5",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "claude-sonnet-4-5")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.AnthropicMessages,
                    authMode = RelayAuthMode.XApiKey,
                ),
                activeModel = relayModel("claude-sonnet-4-5", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("claude-sonnet-4-5"),
            ),
        ).toList()

        val request = seenRequests.single()
        assertTrue(request.url.toString().endsWith("/messages"))
        assertEquals("anth-key", request.headers["x-api-key"])
        assertEquals("2023-06-01", request.headers["anthropic-version"])
        assertEquals("hello", (events[0] as StreamEvent.Delta).text)
        assertEquals("hello", (events.last() as StreamEvent.Done).result.text)
    }

    @Test
    fun `anthropic relay adds v1 prefix when base url omits version`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """
                        {
                          "content":[{"type":"text","text":"hello"}],
                          "usage":{"input_tokens":5,"output_tokens":3}
                        }
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.sendMessage(
            apiKey = "anth-key",
            modelID = "claude-sonnet-4-5",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "claude-sonnet-4-5")),
            baseUrl = "https://relay.example.com",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.AnthropicMessages,
                    authMode = RelayAuthMode.XApiKey,
                ),
                activeModel = relayModel("claude-sonnet-4-5", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("claude-sonnet-4-5"),
            ),
        )

        assertEquals("https://relay.example.com/v1/messages", seenRequests.single().url.toString())
    }

    @Test
    fun `anthropic relay sendMessage uses non stream request when stream is disabled`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """
                        {
                          "content":[{"type":"text","text":"hello"}],
                          "usage":{"input_tokens":5,"output_tokens":3}
                        }
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val done = service.sendMessage(
            apiKey = "anth-key",
            modelID = "claude-sonnet-4-5",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "claude-sonnet-4-5")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.AnthropicMessages,
                    authMode = RelayAuthMode.XApiKey,
                ),
                activeModel = relayModel("claude-sonnet-4-5", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("claude-sonnet-4-5"),
            ),
        )

        val request = seenRequests.single()
        val body = (request.body as TextContent).text
        assertTrue(request.url.toString().endsWith("/messages"))
        assertTrue(body.contains("\"stream\":false"))
        assertFalse(body.contains("\"stream\":true"))
        assertEquals("hello", done.result.text)
    }

    @Test
    fun `anthropic relay non stream surfaces unsupported thinking without retry`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                if (seenRequests.size == 1) {
                    respond(
                        content = """{"error":{"message":"unexpected field: thinking"}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(
                        content = """
                            {
                              "content":[{"type":"text","text":"hello"}],
                              "usage":{"input_tokens":5,"output_tokens":3}
                            }
                        """.trimIndent(),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                }
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val failure = runCatching { service.sendMessage(
            apiKey = "anth-key",
            modelID = "claude-sonnet-4-5",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "claude-sonnet-4-5")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.AnthropicMessages,
                    authMode = RelayAuthMode.XApiKey,
                ),
                activeModel = relayModel("claude-sonnet-4-5", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("claude-sonnet-4-5"),
            ),
        ) }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, seenRequests.size)
        val body = (seenRequests.single().body as TextContent).text
        assertTrue("the only attempt should include thinking: $body", body.contains("\"thinking\""))
    }

    @Test
    fun `anthropic relay stream surfaces unsupported thinking without retry`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val stream = ProviderTestFixtures.anthropicStream(
            ProviderTestFixtures.anthropicEvent("message_start", "{\"message\":{\"usage\":{\"input_tokens\":5}}}"),
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}"),
            ProviderTestFixtures.anthropicEvent("message_delta", "{\"usage\":{\"output_tokens\":3}}"),
        )
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                if (seenRequests.size == 1) {
                    respond(
                        content = """{"error":{"message":"unexpected field: thinking"}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(
                        content = ByteReadChannel(stream),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                    )
                }
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val failure = runCatching { service.sendMessageStream(
            apiKey = "anth-key",
            modelID = "claude-sonnet-4-5",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "claude-sonnet-4-5")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.AnthropicMessages,
                    authMode = RelayAuthMode.XApiKey,
                ),
                activeModel = relayModel("claude-sonnet-4-5", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("claude-sonnet-4-5"),
            ),
        ).toList() }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, seenRequests.size)
        val body = (seenRequests.single().body as TextContent).text
        assertTrue("the only attempt should include thinking: $body", body.contains("\"thinking\""))
    }

    @Test
    fun `gemini relay auto auth uses x goog api key header and inline image output`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val stream = buildString {
            appendLine(ProviderTestFixtures.geminiChunk(text = "hello", promptTokens = 7, completionTokens = 11))
            appendLine(ProviderTestFixtures.geminiChunk(text = "", inlineData = "AQID", promptTokens = 7, completionTokens = 11))
        }
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = ByteReadChannel(stream),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.withCharset(Charsets.UTF_8).toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val events = service.sendMessageStream(
            apiKey = "goog-key",
            modelID = "gemini-2.5-pro",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gemini-2.5-pro")),
            baseUrl = "https://relay.example.com/v1beta",
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.GeminiGenerateContent,
                    authMode = RelayAuthMode.Auto,
                ),
            ),
        ).toList()

        val request = seenRequests.single()
        assertTrue(request.url.toString().contains(":streamGenerateContent"))
        assertEquals("goog-key", request.headers["x-goog-api-key"])
        assertEquals("hello", (events[0] as StreamEvent.Delta).text)
        val done = events.last() as StreamEvent.Done
        assertEquals(1, done.result.attachments?.size)
        assertEquals("AQID", done.result.attachments?.first()?.base64Data)
    }

    @Test
    fun `gemini relay non stream surfaces unsupported thinkingConfig without retry`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                if (seenRequests.size == 1) {
                    respond(
                        content = """{"error":{"message":"Unknown name \"thinkingConfig\": Cannot find field."}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(
                        content = """
                            {
                              "candidates":[{"content":{"parts":[{"text":"hello"}]}}],
                              "usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":5,"totalTokenCount":9}
                            }
                        """.trimIndent(),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                }
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val failure = runCatching { service.sendMessage(
            apiKey = "goog-key",
            modelID = "gemini-2.5-pro",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gemini-2.5-pro")),
            baseUrl = "https://relay.example.com/v1beta",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.GeminiGenerateContent,
                    authMode = RelayAuthMode.XGoogApiKey,
                    stream = false,
                ),
                activeModel = relayModel("gemini-2.5-pro", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("gemini-2.5-pro"),
            ),
        ) }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, seenRequests.size)
        val body = (seenRequests.single().body as TextContent).text
        assertTrue("the only attempt should include thinkingConfig: $body", body.contains("thinkingConfig"))
    }

    @Test
    fun `gemini relay stream surfaces unsupported thinkingConfig without retry`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val stream = ProviderTestFixtures.geminiChunk(text = "hello", promptTokens = 4, completionTokens = 5) + "\n"
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                if (seenRequests.size == 1) {
                    respond(
                        content = """{"error":{"message":"Unknown name \"thinkingConfig\": Cannot find field."}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(
                        content = ByteReadChannel(stream),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.withCharset(Charsets.UTF_8).toString()),
                    )
                }
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val failure = runCatching { service.sendMessageStream(
            apiKey = "goog-key",
            modelID = "gemini-2.5-pro",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gemini-2.5-pro")),
            baseUrl = "https://relay.example.com/v1beta",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.GeminiGenerateContent,
                    authMode = RelayAuthMode.XGoogApiKey,
                    stream = true,
                ),
                activeModel = relayModel("gemini-2.5-pro", reasoning = true),
                capabilityEvidenceIdentity = relayIdentity("gemini-2.5-pro"),
            ),
        ).toList() }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, seenRequests.size)
        val body = (seenRequests.single().body as TextContent).text
        assertTrue("the only attempt should include thinkingConfig: $body", body.contains("thinkingConfig"))
    }

    @Test
    fun `gemini relay adds v1beta prefix when base url omits version`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """
                        {
                          "candidates":[{"content":{"parts":[{"text":"hello"}]}}],
                          "usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":5,"totalTokenCount":9}
                        }
                    """.trimIndent(),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.sendMessage(
            apiKey = "goog-key",
            modelID = "gemini-2.5-pro",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gemini-2.5-pro")),
            baseUrl = "https://relay.example.com",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.GeminiGenerateContent,
                    authMode = RelayAuthMode.XGoogApiKey,
                    stream = false,
                ),
            ),
        )

        assertEquals("https://relay.example.com/v1beta/models/gemini-2.5-pro:generateContent", seenRequests.single().url.toString())
    }

    @Test
    fun `responses relay emits image_generation and default web_search tools together`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                    hasWebSearch = true,
                    webSearchProfile = "relay_web",
                ),
                activeModel = relayModel("gpt-5.4", web = true),
                capabilityEvidenceIdentity = relayIdentity("gpt-5.4"),
                relayImage = RelayImageConfig(
                    enabled = true,
                    mode = RelayImageMode.ToolModel,
                    toolModelID = "gpt-image-2",
                ),
            ),
        )

        val request = seenRequests.single()
        val body = (request.body as TextContent).text
        // The default protocol name is web_search, which is what upstream recommends and what
        // the common relays accept; image_generation has to coexist with it.
        assertTrue("tools should contain image_generation: $body", body.contains("\"type\":\"image_generation\""))
        assertTrue("tools should contain web_search (no _preview): $body", body.contains("\"type\":\"web_search\""))
        assertFalse("tools should NOT contain legacy web_search_preview by default: $body", body.contains("\"type\":\"web_search_preview\""))
        // Structurally confirm they are in one tools array rather than two tools fields.
        val toolsStart = body.indexOf("\"tools\":[")
        assertTrue("tools field missing: $body", toolsStart >= 0)
        val toolsEnd = body.indexOf(']', toolsStart)
        val toolsSlice = body.substring(toolsStart, toolsEnd + 1)
        assertTrue("image_generation inside tools: $toolsSlice", toolsSlice.contains("image_generation"))
        assertTrue("web_search inside tools: $toolsSlice", toolsSlice.contains("web_search"))
    }

    @Test
    fun `responses relay uses legacy web_search_preview when webSearchToolName=WebSearchPreview`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://legacy.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                    webSearchToolName = RelayWebSearchToolName.WebSearchPreview,
                    hasWebSearch = true,
                    webSearchProfile = "relay_web",
                ),
                activeModel = relayModel("gpt-5.4", web = true),
                capabilityEvidenceIdentity = relayIdentity("gpt-5.4"),
            ),
        )

        val body = (seenRequests.single().body as TextContent).text
        assertTrue("legacy web_search_preview should be used: $body", body.contains("\"type\":\"web_search_preview\""))
        assertFalse("new web_search should NOT appear: $body", body.contains("\"type\":\"web_search\","))
    }

    @Test
    fun `responses relay omits web_search tool when webSearchToolName=Disabled`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true, // enabled here on purpose
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                    webSearchToolName = RelayWebSearchToolName.Disabled,
                ),
            ),
        )

        val body = (seenRequests.single().body as TextContent).text
        assertFalse("web_search should NOT appear when disabled: $body", body.contains("\"type\":\"web_search\""))
        assertFalse("web_search_preview should NOT appear when disabled: $body", body.contains("\"type\":\"web_search_preview\""))
        assertTrue("image_generation should still be present: $body", body.contains("\"type\":\"image_generation\""))
    }

    // MARK: - legacy tool rejection signals never auto-resend

    @Test
    fun `responses relay surfaces image generation 4xx after one unchanged attempt`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                if (seenRequests.size == 1) {
                    respond(
                        content = """{"error":{"code":"unknown_parameter","message":"Unknown parameter: tools[0].type (image_generation)","param":"tools[0].type"}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(
                        content = """{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}""",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                }
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val failure = runCatching { service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.4",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                ),
            ),
        ) }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, seenRequests.size)
        val body = (seenRequests.single().body as TextContent).text
        assertTrue("the only attempt should preserve tools: $body", body.contains("\"tools\":["))
    }

    @Test
    fun `responses relay surfaces an image-model mismatch after one unchanged attempt`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                if (seenRequests.size == 1) {
                    respond(
                        content = """{"error":{"message":"unsupported model: gpt-5.5 (only gpt-image-2 is supported on this endpoint)"}}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond(
                        content = """{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}""",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                }
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val failure = runCatching { service.sendMessage(
            apiKey = "sk-relay",
            modelID = "gpt-5.5",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.5")),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIResponses,
                    authMode = RelayAuthMode.Bearer,
                ),
            ),
        ) }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, seenRequests.size)
    }

    @Test
    fun `responses relay does NOT retry on unrelated 4xx (model_not_found) - prevent misfire`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"error":{"code":"model_not_found","message":"Model gpt-9 does not exist"}}""",
                    status = HttpStatusCode.NotFound,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        try {
            service.sendMessage(
                apiKey = "sk-relay",
                modelID = "gpt-9",
                messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-9")),
                baseUrl = "https://relay.example.com/v1",
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    relayRequested = RelayRequestedConfig(
                        transport = RelayTransport.OpenAIResponses,
                        authMode = RelayAuthMode.Bearer,
                    ),
                ),
            )
        } catch (_: Exception) {
            // The throw is expected.
        }

        // The point of the test: no retry was triggered, only one request went out.
        assertEquals(1, seenRequests.size)
    }

    @Test
    fun `responses relay does NOT retry xhigh on non-xhigh 4xx (rate limit) - signal must match`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = """{"error":{"code":"rate_limited","message":"Too many requests"}}""",
                    status = HttpStatusCode.TooManyRequests, // 429
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        try {
            service.sendMessage(
                apiKey = "sk-relay",
                modelID = "gpt-5.4",
                messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
                baseUrl = "https://relay.example.com/v1",
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Max, // xhigh
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    relayRequested = RelayRequestedConfig(
                        transport = RelayTransport.OpenAIResponses,
                        authMode = RelayAuthMode.Bearer,
                    ),
                ),
            )
        } catch (_: Exception) {
            // The throw is expected.
        }

        // The point of the test: a 429 is not an xhigh signal, so it must not trigger a
        // blind downgrade retry.
        assertEquals(1, seenRequests.size)
    }

    @Test
    fun `responses relay does NOT retry on stream image_generation error after first content (token tear protection)`() = runTest {
        val seenRequests = mutableListOf<HttpRequestData>()
        val streamWithDeltaThenError = """
            event: response.output_text.delta
            data: {"delta":"partial"}

            event: response.failed
            data: {"type":"response.failed","response":{"error":{"code":"unknown_parameter","message":"image_generation","param":"tools[0]"}}}

            data: [DONE]
        """.trimIndent()

        val client = HttpClient(
            MockEngine { request ->
                seenRequests += request
                respond(
                    content = ByteReadChannel(streamWithDeltaThenError),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            },
        )
        val service = RelayService(client = client, json = json, transportRegistry = transportRegistry)

        val events = mutableListOf<StreamEvent>()
        try {
            service.sendMessageStream(
                apiKey = "sk-relay",
                modelID = "gpt-5.4",
                messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gpt-5.4")),
                baseUrl = "https://relay.example.com/v1",
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    relayRequested = RelayRequestedConfig(
                        transport = RelayTransport.OpenAIResponses,
                        authMode = RelayAuthMode.Bearer,
                    ),
                ),
            ).collect { events += it }
        } catch (_: Exception) {
            // The stream throws its error here, as expected; the events already emitted are
            // still in the list.
        }

        // First half of the point: exactly one request. Once a token has been emitted the
        // retry is locked out, so the visible answer cannot tear.
        assertEquals(1, seenRequests.size)
        // Second half: the "partial" delta did go out before the stream terminated.
        assertTrue("expected partial delta in $events",
            events.any { it is StreamEvent.Delta && it.text == "partial" })
    }
}
