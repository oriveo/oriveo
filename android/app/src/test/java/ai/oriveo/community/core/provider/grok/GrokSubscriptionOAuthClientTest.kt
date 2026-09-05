package ai.oriveo.community.core.provider.grok

import ai.oriveo.community.feature.providers.grok.GrokSubscriptionAuthorizationModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.respondError
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.http.HttpHeaders
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The device code state machine and the shape of its outbound requests.
 *
 * MockEngine rather than real network: what needs pinning is "upstream said X, so we do Y", not
 * whether those two xAI endpoints happen to be reachable right now.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class GrokSubscriptionOAuthClientTest {

    private val config = GrokSubscriptionAuthConfig(
        clientId = "client-id",
        scopes = "openid profile",
        deviceAuthorizationEndpoint = "https://auth.x.ai/oauth2/device/code",
        tokenEndpoint = "https://auth.x.ai/oauth2/token",
        revocationEndpoint = "https://auth.x.ai/oauth2/revoke",
        trustedVerificationHosts = listOf("accounts.x.ai", "x.ai"),
        resourceBaseUrl = "https://cli-chat-proxy.grok.com/v1",
        requiredHeaders = mapOf(
            "x-grok-client-version" to "1.0.4",
            "x-grok-client-identifier" to "oriveo",
        ),
        modelsUrl = "https://cli-chat-proxy.grok.com/v1/models",
        chatUrl = "https://cli-chat-proxy.grok.com/v1/chat/completions",
        pollIntervalSeconds = 5,
        pollTimeoutSeconds = 1800,
    )

    // ── Requesting a device code ──

    @Test
    fun `the device code request carries client_id and scope, and resolves the authorization page URL`() = runTest {
        var body: String? = null
        val client = HttpClient(
            MockEngine { request ->
                body = (request.body as io.ktor.http.content.TextContent).text
                respond(
                    """
                    {"device_code":"dc","user_code":"AAAA-BBBB",
                     "verification_uri":"https://accounts.x.ai/device",
                     "verification_uri_complete":"https://accounts.x.ai/device?user_code=AAAA-BBBB",
                     "expires_in":900,"interval":5}
                    """.trimIndent(),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        )
        val authorization = GrokSubscriptionOAuthClient(client).requestDeviceAuthorization(config)

        assertTrue(body!!.contains("client_id=client-id"))
        assertTrue(body!!.contains("scope=openid+profile") || body!!.contains("scope=openid%20profile"))
        assertEquals("dc", authorization.deviceCode)
        assertEquals("AAAA-BBBB", authorization.userCode)
        // When the short code is already spliced into the URL, prefer it so the user does not have to
        // copy eight characters by hand.
        assertEquals("https://accounts.x.ai/device?user_code=AAAA-BBBB", authorization.verificationUrl)
    }

    /** An authorization page outside the trusted hosts: better to do nothing than to send the user to a domain of unknown origin. */
    @Test
    fun `an authorization page URL outside the allow-list is treated as an unusable configuration`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond(
                    """{"device_code":"dc","user_code":"X","verification_uri_complete":"https://evil.com/device"}""",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        )
        val error = runCatching {
            GrokSubscriptionOAuthClient(client).requestDeviceAuthorization(config)
        }.exceptionOrNull() as GrokSubscriptionException
        assertEquals(GrokSubscriptionError.ConfigurationUnavailable, error.error)
    }

    // ── Fetching the model catalog ──

    @Test
    fun `the catalog request hits the fully joined modelsUrl and carries the served required headers verbatim`() = runTest {
        var url: String? = null
        var version: String? = null
        var identifier: String? = null
        var authorization: String? = null
        val client = HttpClient(
            MockEngine { request ->
                url = request.url.toString()
                version = request.headers["x-grok-client-version"]
                identifier = request.headers["x-grok-client-identifier"]
                authorization = request.headers["Authorization"]
                respond(
                    """{"data":[{"id":"grok-4.6"},{"id":"grok-4.5"},{"id":""}]}""",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        )
        val models = GrokSubscriptionOAuthClient(client).fetchModels(config, "token-123")

        assertEquals("https://cli-chat-proxy.grok.com/v1/models", url)
        // The 404 regression sentinel: joining happens once, at config resolution, and the outbound
        // side must never join another /v1 on top.
        assertTrue(!url!!.contains("/v1/v1"))
        assertEquals("1.0.4", version)
        assertEquals("oriveo", identifier)
        assertEquals("Bearer token-123", authorization)
        // When upstream gives only an id, degrade to "no declared capabilities", matching how the
        // earlier id-only implementation behaved.
        assertEquals(listOf("grok-4.6", "grok-4.5"), models.map { it.id })
        assertTrue(models.none { it.supportsWebSearch || it.supportsReasoning })
    }

    @Test
    fun `the catalog follows the capabilities upstream declares, degrades when it says nothing, and hardcodes nothing on the client`() = runTest {
        // Capabilities have to follow the API, otherwise every new model needs someone to write code.
        // The field names come from the catalog cache the grok CLI writes to disk, whose origin is
        // cli-chat-proxy.grok.com/v1/models.
        val client = HttpClient(
            MockEngine {
                respond(
                    """
                    {"data":[
                      {"id":"grok-4.6","name":"Grok 4.6","supports_backend_search":true,
                       "supports_reasoning_effort":true,"context_window":500000,"api_backend":"responses",
                       "reasoning_efforts":[{"value":"xhigh","default":false},
                                            {"value":"high","default":true}],
                       "hidden":false,"supported_in_api":true},
                      {"id":"grok-legacy","supports_backend_search":false,"supports_reasoning_effort":false},
                      {"id":"grok-internal","hidden":true},
                      {"id":"grok-plain"}
                    ]}
                    """.trimIndent(),
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        )
        val models = GrokSubscriptionOAuthClient(client).fetchModels(config, "t")

        // Hidden entries are filtered out, while an entry declaring nothing at all must be **kept**.
        // The loose filter is deliberate: emptying the whole catalog the moment a field goes missing
        // is a far worse regression than losing a capability.
        assertEquals(listOf("grok-4.6", "grok-legacy", "grok-plain"), models.map { it.id })

        val flagship = models.first()
        assertEquals("Grok 4.6", flagship.displayName)
        assertTrue(flagship.supportsWebSearch)
        assertTrue(flagship.supportsReasoning)
        assertEquals(listOf("xhigh", "high"), flagship.reasoningEfforts)
        assertEquals("high", flagship.defaultReasoningEffort)
        assertEquals(500000, flagship.contextWindow)
        assertEquals("responses", flagship.apiBackend)

        // Explicitly unsupported means unsupported; saying nothing also means unsupported, because a
        // capability is never guessed from an id.
        assertTrue(models.drop(1).none { it.supportsWebSearch || it.supportsReasoning })
    }

    @Test
    fun `a 426 from the catalog translates to a rejected client version`() = runTest {
        val client = HttpClient(MockEngine { respondError(HttpStatusCode.UpgradeRequired) })
        val error = runCatching {
            GrokSubscriptionOAuthClient(client).fetchModels(config, "t")
        }.exceptionOrNull() as GrokSubscriptionException
        assertEquals(GrokSubscriptionError.ClientVersionRejected, error.error)
    }

    // ── Renewal ──

    /**
     * xAI **rotates the refresh_token** on every refresh. Writing back only the access token leaves
     * the next renewal holding an already invalidated refresh token, which shows up to the user as
     * "it worked all day and then suddenly asked me to sign in again".
     */
    @Test
    fun `a new refresh token returned by a renewal must be carried through in full`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond(
                    """{"access_token":"new-access","refresh_token":"rotated","expires_in":21600}""",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        )
        val tokens = GrokSubscriptionOAuthClient(client).refreshTokens(config, "old-refresh")
        assertEquals("new-access", tokens.accessToken)
        assertEquals("rotated", tokens.refreshToken)
        assertTrue(tokens.expiresAt!! > System.currentTimeMillis())
    }

    /** When upstream returns no refresh_token, keep the old one, otherwise the ability to renew is thrown away. */
    @Test
    fun `a renewal that returns no refresh token keeps the previous value`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond(
                    """{"access_token":"new-access","expires_in":600}""",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        )
        val tokens = GrokSubscriptionOAuthClient(client).refreshTokens(config, "old-refresh")
        assertEquals("old-refresh", tokens.refreshToken)
    }

    @Test
    fun `with no revocation endpoint, disconnecting sends no request and raises no error`() = runTest {
        var calls = 0
        val client = HttpClient(MockEngine { calls += 1; respond("", HttpStatusCode.OK) })
        GrokSubscriptionOAuthClient(client).revoke(config.copy(revocationEndpoint = null), "t")
        assertEquals(0, calls)
    }

    // ── State machine ──

    /**
     * `authorization_pending` means keep waiting, `slow_down` adds five seconds to the interval, and
     * the last poll succeeds with a 200.
     *
     * The intervals are recorded through an injected fake sleep rather than actually waited out;
     * waiting for real would make this case take fifteen seconds.
     */
    @Test
    fun `polling absorbs pending and slow_down and then receives the token`() = runTest {
        var poll = 0
        val client = HttpClient(
            MockEngine { request ->
                if (request.url.encodedPath.endsWith("/device/code")) {
                    respond(
                        """{"device_code":"dc","user_code":"AA","verification_uri_complete":"https://accounts.x.ai/d","expires_in":900,"interval":5}""",
                        HttpStatusCode.OK,
                        headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                } else {
                    poll += 1
                    when (poll) {
                        1 -> respond(
                            """{"error":"authorization_pending"}""",
                            HttpStatusCode.BadRequest,
                            headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                        2 -> respond(
                            """{"error":"slow_down"}""",
                            HttpStatusCode.BadRequest,
                            headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                        else -> respond(
                            """{"access_token":"granted","refresh_token":"r","expires_in":21600}""",
                            HttpStatusCode.OK,
                            headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                    }
                }
            }
        )
        val slept = mutableListOf<Long>()
        val model = GrokSubscriptionAuthorizationModel(
            client = GrokSubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { millis -> slept += millis },
        )

        model.start(config)
        model.awaitCompletionForTest()

        val phase = model.phase
        assertTrue("got $phase", phase is GrokSubscriptionAuthorizationModel.Phase.Succeeded)
        assertEquals("granted", (phase as GrokSubscriptionAuthorizationModel.Phase.Succeeded).tokens.accessToken)
        // RFC 8628: after a slow_down the interval goes up by 5, and jumping the queue only earns
        // more slow_down responses.
        assertEquals(listOf(5_000L, 5_000L, 10_000L), slept)
    }

    @Test
    fun `a user who declines authorization moves to the failed state and polling stops`() = runTest {
        var poll = 0
        val client = HttpClient(
            MockEngine { request ->
                if (request.url.encodedPath.endsWith("/device/code")) {
                    respond(
                        """{"device_code":"dc","user_code":"AA","verification_uri_complete":"https://accounts.x.ai/d","expires_in":900,"interval":1}""",
                        HttpStatusCode.OK,
                        headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                } else {
                    poll += 1
                    respond(
                        """{"error":"access_denied"}""",
                        HttpStatusCode.BadRequest,
                        headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        )
        val model = GrokSubscriptionAuthorizationModel(
            client = GrokSubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )
        model.start(config)
        model.awaitCompletionForTest()

        assertEquals(
            GrokSubscriptionAuthorizationModel.Phase.Failed(GrokSubscriptionError.AccessDenied),
            model.phase,
        )
        assertEquals(1, poll)
    }

    /** Polling past the short code's expiry achieves nothing and only generates useless upstream traffic. */
    @Test
    fun `polling stops once expires_in has passed and reports the short code as expired`() = runTest {
        var poll = 0
        var clock = 0L
        val client = HttpClient(
            MockEngine { request ->
                if (request.url.encodedPath.endsWith("/device/code")) {
                    respond(
                        """{"device_code":"dc","user_code":"AA","verification_uri_complete":"https://accounts.x.ai/d","expires_in":10,"interval":5}""",
                        HttpStatusCode.OK,
                        headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                } else {
                    poll += 1
                    respond(
                        """{"error":"authorization_pending"}""",
                        HttpStatusCode.BadRequest,
                        headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            }
        )
        val model = GrokSubscriptionAuthorizationModel(
            client = GrokSubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { clock },
            sleep = { millis -> clock += millis },
        )
        model.start(config)
        model.awaitCompletionForTest()

        assertEquals(
            GrokSubscriptionAuthorizationModel.Phase.Failed(GrokSubscriptionError.CodeExpired),
            model.phase,
        )
        // deadline 10s against a 5s interval: two polls, then the next one would cross the line and it
        // stops rather than hammering forever.
        assertEquals(2, poll)
    }

    @Test
    fun `cancelling returns to idle and clears the flag that the authorization page was opened`() = runTest {
        val client = HttpClient(
            MockEngine {
                respond(
                    """{"device_code":"dc","user_code":"AA","verification_uri_complete":"https://accounts.x.ai/d","expires_in":900,"interval":5}""",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        )
        val model = GrokSubscriptionAuthorizationModel(
            client = GrokSubscriptionOAuthClient(client),
            scope = this,
            nowMillis = { 0L },
            sleep = { },
        )
        model.start(config)
        model.awaitCompletionForTest()
        model.markVerificationPageOpened()
        model.cancel()

        assertEquals(GrokSubscriptionAuthorizationModel.Phase.Idle, model.phase)
        assertEquals(false, model.didOpenVerificationPage)
        assertNull(model.deviceAuthorization)
    }
}
