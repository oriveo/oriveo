package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class OpenAICompatibleSelfHealTest {

    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() {
        UnsupportedParamCache.resetForTest()
        MetadataTestFixtures.clear()
    }

    private fun relayService(client: HttpClient): OpenAICompatibleService =
        OpenAICompatibleService(
            client = client,
            json = json,
            defaultBaseUrl = "https://relay.example/v1",
            providerName = "Relay",
            providerKind = ProviderKind.Relay,
        )

    private fun userMessage(text: String) = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.Relay,
        providerName = "Relay",
        modelName = "test-model",
        state = ChatMessageState.Delivered,
    )

    @Test
    fun `400 unsupported-param is surfaced after one unchanged production attempt`() = runTest {
        val bodies = mutableListOf<String>()
        var call = 0
        val client = HttpClient(
            MockEngine { request ->
                bodies += (request.body as TextContent).text
                call += 1
                if (call == 1) {
                    respond(
                        content = """{"code":"invalid-argument","error":"Model m does not support parameter reasoning_effort."}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                } else {
                    respond(
                        content = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                }
            },
        )

        val failure = runCatching {
            relayService(client).sendMessageStream(
                apiKey = "sk-test",
                modelID = "m",
                messages = listOf(userMessage("Hi")),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }.exceptionOrNull()

        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, bodies.size)
        assertTrue("the only attempt must preserve the param", bodies.single().contains("reasoning_effort"))
    }

    @Test
    fun `a 400 on the standard compatible path surfaces without a second attempt`() = runTest {
        // A complete snapshot: the model has a reasoning profile, so the production body really does
        // carry reasoning_effort and the old stripping heuristic would have something to strip, and it
        // also declares a protocol transport.
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "reasoning": {
                  "oai_chat": {
                    "transport": "chat_completions",
                    "levels": ["fast", "balanced", "deep"],
                    "params": { "deep": { "reasoning_effort": "high" } }
                  }
                }
              },
              "providers": {
                "grok": {
                  "resolveMap": { "grok-4": "grok-4" },
                  "models": {
                    "grok-4": {
                      "canonicalModelId": "grok-4",
                      "transport": "openai_chat",
                      "profiles": { "reasoning": "oai_chat" }
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )
        var call = 0
        val client = HttpClient(
            MockEngine { _ ->
                call += 1
                if (call == 1) {
                    respond(
                        content = """{"code":"invalid-argument","error":"Model grok-4 does not support parameter reasoning_effort."}""",
                        status = HttpStatusCode.BadRequest,
                        headers = headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                } else {
                    respond(
                        content = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n",
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                }
            },
        )

        val failure = runCatching {
            OpenAICompatibleService(
                client = client,
                json = json,
                defaultBaseUrl = "https://api.x.ai/v1",
                providerName = "Grok",
                providerKind = ProviderKind.Grok,
            ).sendMessageStream(
                apiKey = "xai-test",
                modelID = "grok-4",
                messages = listOf(
                    ChatMessage(
                        id = "msg-1",
                        role = ChatRole.User,
                        text = "Hi",
                        providerKind = ProviderKind.Grok,
                        providerName = "Grok",
                        modelName = "grok-4",
                        state = ChatMessageState.Delivered,
                    ),
                ),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }.exceptionOrNull()
        assertTrue(failure is ProviderServiceError.Upstream)
        assertEquals(1, call)
    }

    @Test
    fun `plain 400 (not a param rejection) is passed through without retry`() = runTest {
        var call = 0
        val client = HttpClient(
            MockEngine { _ ->
                call += 1
                respond(
                    content = """{"error":"Each message must have at least one content element"}""",
                    status = HttpStatusCode.BadRequest,
                    headers = headersOf(HttpHeaders.ContentType, "application/json"),
                )
            },
        )

        try {
            relayService(client).sendMessageStream(
                apiKey = "sk-test",
                modelID = "m",
                messages = listOf(userMessage("Hi")),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
            fail("expected ProviderServiceError.Upstream to be thrown")
        } catch (e: ProviderServiceError.Upstream) {
            assertEquals(400, e.statusCode)
        }

        assertEquals(1, call)
    }

    @Test
    fun `P5 runtime presence closes the legacy unsupported parameter retry in the production service`() = runTest {
        // The P5 envelope intentionally has no reviewed locator yet. Presence of its definitions
        // must surface the 400 rather than revive the old error-text stripping heuristic.
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{},"capabilityRuntime":{"responseEvidenceDefinitions":{},"errorRecoveryDefinitions":{}}}""",
        )
        var calls = 0
        val client = HttpClient(MockEngine {
            calls += 1
            respond(
                content = """{"error":"Model m does not support parameter reasoning_effort."}""",
                status = HttpStatusCode.BadRequest,
                headers = headersOf(HttpHeaders.ContentType, "application/json"),
            )
        })

        val failure = runCatching {
            relayService(client).sendMessageStream(
                apiKey = "sk-test", modelID = "m", messages = listOf(userMessage("Hi")),
                baseUrl = null, supportsImageGen = false, reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = false, requestOptions = ChatRequestOptions(),
            ).toList()
        }.exceptionOrNull()

        assertTrue("P5 runtime 400 must surface", failure is ProviderServiceError)
        assertEquals("P5 runtime must not make a second wire attempt", 1, calls)
    }

    @Test
    fun `custom request fields and non optional statuses never receive a silent production retry`() = runTest {
        // Relay only authorises custom fields against the generation profile currently selected on
        // this device. Without one the request is refused as InvalidConfiguration before a socket is
        // even opened, and then this case could not verify anything about the attempt that was
        // actually sent.
        val options = ChatRequestOptions(
            activeModel = AIModel(
                id = "m",
                name = "m",
                generationProfile = GenerationProfileRef(
                    template = "openai_chat_completions",
                    parameters = listOf(GenerationParameterRef(id = "seed", support = "supported")),
                    wire = mapOf("seed" to "seed"),
                    transport = "openai_chat_completions",
                ),
            ),
            localCustomFragments = mapOf("generation" to """{"seed":7}"""),
        )
        // 400 is the only status the old self-heal net would have stripped a parameter and retried on,
        // so a locally owned custom field has to close that door too; 401/403/429/500 must reach the
        // user directly. Both kinds are allowed exactly one outbound request.
        val statuses = listOf(
            HttpStatusCode.BadRequest,
            HttpStatusCode.Unauthorized,
            HttpStatusCode.Forbidden,
            HttpStatusCode.TooManyRequests,
            HttpStatusCode.InternalServerError,
        )
        statuses.forEach { status ->
            val bodies = mutableListOf<String>()
            val client = HttpClient(MockEngine { request ->
                bodies += (request.body as TextContent).text
                respond(
                    content = """{"error":"Model m does not support parameter reasoning_effort."}""",
                    status = status,
                    headers = headersOf(HttpHeaders.ContentType, "application/json"),
                )
            })
            val failure = runCatching {
                relayService(client).sendMessageStream(
                    apiKey = "sk-test", modelID = "m", messages = listOf(userMessage("Hi")),
                    baseUrl = null, supportsImageGen = false, reasoningMode = ReasoningMode.Deep,
                    webSearchEnabled = false,
                    requestOptions = options,
                ).toList()
            }.exceptionOrNull()
            assertTrue("$status must surface", failure is ProviderServiceError)
            assertEquals("$status must have one production request", 1, bodies.size)
            // This one outbound request really does carry both the local custom field and the exact
            // parameter upstream complains about. Otherwise "there was no second attempt" might only
            // mean there was nothing to strip, and the assertion would stay green even if the old
            // self-heal net were reopened.
            assertTrue("$status custom field must reach the wire: ${bodies.first()}", bodies.first().contains("\"seed\":7"))
            assertTrue("$status rejected param must be on the wire: ${bodies.first()}", bodies.first().contains("reasoning_effort"))
        }
    }
}
