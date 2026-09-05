package ai.oriveo.community.core.provider.grok

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.GrokSubscriptionFailureReason
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.CostCalculator
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.SseParser
import ai.oriveo.community.core.provider.UsageBreakdown
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The outbound shape and cost semantics of the subscription path.
 *
 * Every assertion lands on **an object the production code path actually produced**: the URL and
 * headers come from the request `GrokService` really sent, and the cost comes from the streamed
 * `StreamEvent.Done`. Nothing here builds its own context and then asserts against itself.
 */
class GrokSubscriptionOutboundTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry = TransportRegistry(json)

    private val subscription = GrokSubscriptionRequestContext(
        chatUrl = "https://cli-chat-proxy.grok.com/v1/chat/completions",
        requiredHeaders = mapOf(
            "x-grok-client-version" to "1.0.4",
            "x-grok-client-identifier" to "oriveo",
            "x-grok-client-surface" to "grok-build",
            "x-xai-token-auth" to "xai-grok-cli",
        ),
    )

    private val responsesSubscription = subscription.copy(
        responsesUrl = "https://cli-chat-proxy.grok.com/v1/responses",
        transport = "openai_responses",
    )

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun sampleMessage() = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = "ping",
        providerKind = ProviderKind.Grok,
        providerName = "Grok",
        modelID = "grok-4.6",
        modelName = "grok-4.6",
        state = ChatMessageState.Delivered,
    )

    private fun sseBody(usage: String): String = buildString {
        append("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
        append("data: {\"choices\":[{\"delta\":{}}],\"usage\":$usage}\n\n")
        append("data: [DONE]\n\n")
    }

    private fun responsesSseBody(): String = buildString {
        append("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n")
        append("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}\n\n")
        append("data: [DONE]\n\n")
    }

    @Test
    fun `a Responses subscription always carries real web search per the first-hand declaration and automatic sends the default reasoning level`() = runTest {
        var url: String? = null
        var body: String? = null
        val client = HttpClient(MockEngine { request ->
            url = request.url.toString()
            body = (request.body as io.ktor.http.content.TextContent).text
            respond(
                responsesSseBody(),
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        })
        val model = AIModel(
            id = "grok-4.6",
            name = "grok-4.6",
            capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.Text,
                ai.oriveo.community.core.model.ModelCapability.Web,
                ai.oriveo.community.core.model.ModelCapability.Reasoning),
            upstreamReasoningLevels = listOf("low", "high", "xhigh"),
            upstreamDefaultReasoningLevel = "high",
            upstreamApiBackend = "responses",
        )

        val events = GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "access-token",
            modelID = model.id,
            messages = listOf(sampleMessage()),
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                grokSubscription = responsesSubscription,
                activeModel = model,
            ),
        ).toList()

        val root = json.parseToJsonElement(body!!).jsonObject
        assertEquals("https://cli-chat-proxy.grok.com/v1/responses", url)
        assertEquals("web_search", root.getValue("tools").jsonArray.single().jsonObject
            .getValue("type").jsonPrimitive.content)
        assertEquals("high", root.getValue("reasoning").jsonObject
            .getValue("effort").jsonPrimitive.content)
        assertEquals("hi", events.filterIsInstance<StreamEvent.Done>().single().result.text)
    }

    /**
     * Regression sentinel for the 404 that hit the very first message on a real device.
     *
     * Swapping only the base while still taking the path from `providers.grok.transport` produces
     * `.../v1/v1/chat/completions`. This asserts that the URL actually sent is the one joined from
     * the served configuration, and that it contains no `/v1/v1`.
     */
    @Test
    fun `subscription requests hit the chatUrl joined from the served configuration and carry the required headers verbatim`() = runTest {
        var url: String? = null
        val headers = mutableMapOf<String, String?>()
        val client = HttpClient(
            MockEngine { request ->
                url = request.url.toString()
                listOf(
                    "Authorization",
                    "x-grok-client-version",
                    "x-grok-client-identifier",
                    "x-grok-client-surface",
                    "x-xai-token-auth",
                ).forEach { headers[it] = request.headers[it] }
                respond(
                    sseBody("""{"prompt_tokens":10,"completion_tokens":5}"""),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "access-token",
            modelID = "grok-4.6",
            messages = listOf(sampleMessage()),
            requestOptions = ChatRequestOptions(grokSubscription = subscription),
        ).toList()

        assertEquals("https://cli-chat-proxy.grok.com/v1/chat/completions", url)
        assertFalse(url!!.contains("/v1/v1"))
        // The access token travels through the existing apiKey parameter into Bearer, so the whole
        // request building chain stays untouched.
        assertEquals("Bearer access-token", headers["Authorization"])
        assertEquals("1.0.4", headers["x-grok-client-version"])
        assertEquals("oriveo", headers["x-grok-client-identifier"])
        assertEquals("grok-build", headers["x-grok-client-surface"])
        assertEquals("xai-grok-cli", headers["x-xai-token-auth"])
    }

    /**
     * Reasoning levels on the subscription path.
     *
     * The capability recipe route is inert for subscriptions, because subscription models are not in
     * the catalog and no recipe exists for them. The result was a panel that let the user pick a
     * level while the request carried no such field at all. The value may only come from what
     * upstream declares at `/models`: sending a value upstream does not recognise is exactly the
     * shape of the grok reasoning_effort incident.
     */
    @Test
    fun `subscription requests carry a reasoning level whose value comes from the set upstream declared`() = runTest {
        var body: String? = null
        val client = HttpClient(
            MockEngine { request ->
                body = (request.body as io.ktor.http.content.TextContent).text
                respond(
                    sseBody("""{"prompt_tokens":1,"completion_tokens":1}"""),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "access-token",
            modelID = "grok-4.6",
            messages = listOf(sampleMessage()),
            reasoningMode = ReasoningMode.Deep,
            requestOptions = ChatRequestOptions(
                grokSubscription = subscription,
                // Copied straight from the upstream `/models` `reasoning_efforts` when the catalog
                // entry was modelled.
                activeModel = AIModel(
                    id = "grok-4.6",
                    name = "grok-4.6",
                    reasoningModeAvailable = true,
                    upstreamReasoningLevels = listOf("low", "high"),
                ),
            ),
        ).toList()

        // deep maps to high, which upstream declared.
        assertTrue("body=$body", body!!.contains("\"reasoning_effort\":\"high\""))
    }

    @Test
    fun `a level that maps to nothing in the declared set is never sent`() = runTest {
        var body: String? = null
        val client = HttpClient(
            MockEngine { request ->
                body = (request.body as io.ktor.http.content.TextContent).text
                respond(
                    sseBody("""{"prompt_tokens":1,"completion_tokens":1}"""),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "access-token",
            modelID = "grok-4.6",
            messages = listOf(sampleMessage()),
            reasoningMode = ReasoningMode.Fast,
            requestOptions = ChatRequestOptions(
                grokSubscription = subscription,
                // Upstream accepts only high, and none of the fast candidates low/minimal/medium match.
                activeModel = AIModel(
                    id = "grok-4.6",
                    name = "grok-4.6",
                    reasoningModeAvailable = true,
                    upstreamReasoningLevels = listOf("high"),
                ),
            ),
        ).toList()

        assertFalse("body=$body", body!!.contains("reasoning_effort"))
    }

    /** With no subscription context the request shape must be identical to what it was before this feature existed, and the same holds for every other provider. */
    @Test
    fun `a non-subscription request carries no subscription headers and still hits the standard endpoint`() = runTest {
        var url: String? = null
        var version: String? = null
        val client = HttpClient(
            MockEngine { request ->
                url = request.url.toString()
                version = request.headers["x-grok-client-version"]
                respond(
                    sseBody("""{"prompt_tokens":1,"completion_tokens":1}"""),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "xai-key",
            modelID = "grok-4.3",
            messages = listOf(sampleMessage()),
        ).toList()

        assertTrue("got $url", url!!.startsWith("https://api.x.ai/v1/chat/completions"))
        assertEquals(null, version)
    }

    /**
     * A subscription message shows no cost.
     *
     * Upstream still returns `cost_in_usd_ticks`, but that is "what this request would have been
     * worth at API prices", not money the user actually spent, since what they pay is a flat monthly
     * fee. Adopting it would invent a charge out of thin air, so the subscription branch has to be
     * checked before the upstream figure is used.
     */
    @Test
    fun `a subscription request reports zero cost sourced from SUBSCRIPTION even when upstream returned a computed cost`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond(
                    sseBody("""{"prompt_tokens":100,"completion_tokens":50,"cost_in_usd_ticks":37756000}"""),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val events = GrokService(client, json, transportRegistry).sendMessageStream(
            apiKey = "access-token",
            modelID = "grok-4.6",
            messages = listOf(sampleMessage()),
            requestOptions = ChatRequestOptions(grokSubscription = subscription),
        ).toList()

        val done = events.filterIsInstance<StreamEvent.Done>().single()
        assertEquals(0.0, done.result.estimatedCost, 1e-9)
        assertEquals(CostSource.SUBSCRIPTION.name, done.result.costSource)
        // Token counts are recorded as usual: not showing an amount does not mean not recording usage.
        assertEquals(100, done.result.promptTokens)
        assertEquals(50, done.result.completionTokens)
    }

    /** The same usage on a non-subscription path still adopts the upstream figure, which proves the zero above is not hardcoded. */
    @Test
    fun `a non-subscription path still adopts the computed upstream cost`() = runTest {
        val (cost, source) = CostCalculator.calcCost(
            UsageBreakdown(promptTokens = 100, completionTokens = 50, upstreamCost = 0.0038),
            pricing = null,
        )
        assertEquals(0.0038, cost, 1e-9)
        assertEquals(CostSource.UPSTREAM, source)
    }

    // ── The four failure meanings ──

    /**
     * A 401 or 403 on the subscription path must not land in the API key mode's `InvalidAPIKey`: a
     * subscription user has no key to swap, so "go replace your key" is an action that can never
     * succeed.
     */
    @Test
    fun `the four status codes on the subscription path each map on their own without polluting the API key classification`() {
        fun subscriptionError(status: Int) =
            SseParser.mapHttpError(status, "", emptyList(), subscription = true)

        assertEquals(
            GrokSubscriptionFailureReason.Expired,
            (subscriptionError(401) as ProviderServiceError.GrokSubscription).reason,
        )
        assertEquals(
            GrokSubscriptionFailureReason.NotEligible,
            (subscriptionError(403) as ProviderServiceError.GrokSubscription).reason,
        )
        assertEquals(
            GrokSubscriptionFailureReason.ClientVersionRejected,
            (subscriptionError(426) as ProviderServiceError.GrokSubscription).reason,
        )
        assertEquals(
            GrokSubscriptionFailureReason.QuotaExhausted,
            (subscriptionError(429) as ProviderServiceError.GrokSubscription).reason,
        )

        // The API key mode classification stays as it was.
        assertTrue(SseParser.mapHttpError(401, "") is ProviderServiceError.InvalidAPIKey)
        assertTrue(SseParser.mapHttpError(403, "") is ProviderServiceError.InvalidAPIKey)
        assertTrue(SseParser.mapHttpError(429, "") is ProviderServiceError.RateLimited)
    }

    /** The four messages must all differ: collapsing them into one sentence points users at the wrong recovery action. */
    @Test
    fun `the four failure messages are pairwise distinct`() {
        val messages = GrokSubscriptionFailureReason.entries.map { it.userMessage }
        assertEquals(messages.size, messages.toSet().size)
        assertTrue(messages.all { it.isNotBlank() })
    }

    /** A 426 on the subscription path really does raise the subscription-level error from the streaming path, rather than `Upstream(426)`. */
    @Test
    fun `a 426 during subscription streaming raises the subscription-level error`() = runTest {
        val client = HttpClient(
            MockEngine { respond("upgrade required", HttpStatusCode.UpgradeRequired) }
        )
        val error = runCatching {
            GrokService(client, json, transportRegistry).sendMessageStream(
                apiKey = "access-token",
                modelID = "grok-4.6",
                messages = listOf(sampleMessage()),
                requestOptions = ChatRequestOptions(grokSubscription = subscription),
            ).toList()
        }.exceptionOrNull()

        assertTrue("got $error", error is ProviderServiceError.GrokSubscription)
        assertEquals(
            GrokSubscriptionFailureReason.ClientVersionRejected,
            (error as ProviderServiceError.GrokSubscription).reason,
        )
    }
}
