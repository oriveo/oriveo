package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.repository.localFieldsRetryOwner
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.grok.GrokSubscriptionRequestContext
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionRequestContext
import ai.oriveo.community.core.provider.transport.TransportRegistry
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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Subscription connections (Codex / Grok Responses) build the request body on their own, and the additional request body must still be merged in as the last step.
 * Every assertion reads the request body that the production service really sent, as captured by MockEngine.
 */
class SubscriptionAdditionalRequestBodyTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val registry = TransportRegistry(json)
    // `store` is a field outside the skeleton the subscription builder writes: on a name clash the additional request body wins.
    private val additional = """{"top_k": 40, "store": true, "text": {"verbosity": "low"}}"""

    private val codex = OpenAISubscriptionRequestContext(
        responsesUrl = "https://chatgpt.com/backend-api/codex/responses",
        accountId = "acct-123",
        requiredHeaders = mapOf("originator" to "codex_cli_rs"),
    )
    private val grok = GrokSubscriptionRequestContext(
        chatUrl = "https://cli-chat-proxy.grok.com/v1/chat/completions",
        requiredHeaders = mapOf("x-grok-client-version" to "1.0.4"),
        responsesUrl = "https://cli-chat-proxy.grok.com/v1/responses",
        transport = "openai_responses",
    )
    private val grokModel = AIModel(
        id = "grok-4.6",
        name = "grok-4.6",
        capabilities = listOf(ModelCapability.Text, ModelCapability.Reasoning),
        upstreamApiBackend = "responses",
    )

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test
    fun `codex subscription merges the additional body last`() = runTest {
        val bodies = mutableListOf<String>()
        sendCodex(bodies, ChatRequestOptions(openAISubscription = codex, additionalRequestBody = additional))
        assertMerged(json.parseToJsonElement(bodies.single()).jsonObject)
    }

    @Test
    fun `grok subscription responses merges the additional body on stream and non stream`() = runTest {
        val bodies = mutableListOf<String>()
        val options = ChatRequestOptions(grokSubscription = grok, activeModel = grokModel, additionalRequestBody = additional)
        GrokService(client(bodies, sse()), json, registry).sendMessageStream(
            apiKey = "access-token", modelID = grokModel.id, messages = listOf(message()),
            reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false, requestOptions = options,
        ).toList()
        GrokService(client(bodies, """{"output_text":"hi"}""", json = true), json, registry).sendMessage(
            apiKey = "access-token", modelID = grokModel.id, messages = listOf(message()), baseUrl = null,
            supportsImageGen = false, reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
            requestOptions = options,
        )
        assertEquals(2, bodies.size)
        bodies.forEach { assertMerged(json.parseToJsonElement(it).jsonObject) }
    }

    @Test
    fun `protected field is rejected on device for both subscriptions and nothing is sent`() = runTest {
        val protected = """{"input": [], "top_k": 1}"""
        val bodies = mutableListOf<String>()
        expectRejected { sendCodex(bodies, ChatRequestOptions(openAISubscription = codex, additionalRequestBody = protected)) }
        expectRejected {
            GrokService(client(bodies, sse()), json, registry).sendMessageStream(
                apiKey = "access-token", modelID = grokModel.id, messages = listOf(message()),
                reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = ChatRequestOptions(grokSubscription = grok, activeModel = grokModel, additionalRequestBody = protected),
            ).toList()
        }
        assertTrue("request must not be sent: $bodies", bodies.isEmpty())
    }

    @Test
    fun `subscription 400 before any event with an additional body offers the retry`() = runTest {
        val bodies = mutableListOf<String>()
        val events = mutableListOf<StreamEvent>()
        val error = runCatching {
            sendCodex(
                bodies,
                ChatRequestOptions(openAISubscription = codex, additionalRequestBody = additional),
                status = HttpStatusCode.BadRequest,
                payload = """{"detail":"Invalid request body"}""",
            ).forEach { events += it }
        }.exceptionOrNull()
        assertNotNull(error)
        assertTrue("events=$events", events.isEmpty())
        assertEquals(
            "error=$error",
            AdditionalRequestBody.OWNER,
            localFieldsRetryOwner(error!!, additional, receivedUpstreamEvent = false, hadToolSideEffects = false),
        )
    }

    private suspend fun sendCodex(
        bodies: MutableList<String>,
        options: ChatRequestOptions,
        status: HttpStatusCode = HttpStatusCode.OK,
        payload: String = sse(),
    ): List<StreamEvent> = OpenAIService(client(bodies, payload, status = status), json, registry).sendMessageStream(
        apiKey = "codex-access-token", modelID = "gpt-5.6-sol", messages = listOf(message()),
        baseUrl = "https://api.openai.com/v1", supportsImageGen = false,
        reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false, requestOptions = options,
    ).toList()

    private suspend fun expectRejected(block: suspend () -> Unit) {
        try {
            block()
            fail("a protected field must be rejected on device")
        } catch (error: ProviderServiceError.LocalRequestRejected) {
            assertEquals("protected_field", error.reason)
            assertEquals("input", error.fieldName)
        }
    }

    private fun assertMerged(body: JsonObject) {
        assertEquals("40", body["top_k"]!!.jsonPrimitive.content)
        assertEquals("true", body["store"]!!.jsonPrimitive.content)
        assertEquals("low", body["text"]!!.jsonObject["verbosity"]!!.jsonPrimitive.content)
        assertNotNull("builder skeleton stays: $body", body["input"])
    }

    private fun client(
        bodies: MutableList<String>,
        payload: String,
        json: Boolean = false,
        status: HttpStatusCode = HttpStatusCode.OK,
    ) = HttpClient(MockEngine { request ->
        bodies += (request.body as TextContent).text
        respond(
            payload,
            status,
            headersOf(HttpHeaders.ContentType, if (json || status != HttpStatusCode.OK) "application/json" else "text/event-stream"),
        )
    })

    private fun sse() = buildString {
        append("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n")
        append("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}\n\n")
        append("data: [DONE]\n\n")
    }

    private fun message() = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = "hello",
        providerKind = ProviderKind.Grok,
        providerName = "Grok",
        modelID = "grok-4.6",
        modelName = "grok-4.6",
        state = ChatMessageState.Delivered,
    )
}
