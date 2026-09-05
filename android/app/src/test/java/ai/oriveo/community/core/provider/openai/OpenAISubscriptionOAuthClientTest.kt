package ai.oriveo.community.core.provider.openai

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.respondError
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * The outbound request shapes of the two-leg Codex device flow, and how upstream replies are
 * translated.
 *
 * MockEngine rather than real network: what needs pinning is "upstream said X, so we do Y", not
 * whether those OpenAI endpoints happen to be reachable right now. Reachability is a separate
 * fact, and only real traffic can establish it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class OpenAISubscriptionOAuthClientTest {

    private val config = OpenAISubscriptionAuthConfig(
        clientId = "app_EMoamEEZ73f0CkXaXp7hrann",
        deviceAuthorizationEndpoint = "https://auth.openai.com/api/accounts/deviceauth/usercode",
        deviceTokenEndpoint = "https://auth.openai.com/api/accounts/deviceauth/token",
        tokenEndpoint = "https://auth.openai.com/oauth/token",
        verificationUrl = "https://auth.openai.com/codex/device",
        redirectUri = "https://auth.openai.com/deviceauth/callback",
        trustedVerificationHosts = listOf("auth.openai.com"),
        resourceBaseUrl = "https://chatgpt.com/backend-api/codex",
        requiredHeaders = mapOf(
            "OpenAI-Beta" to "responses=experimental",
            "originator" to "oriveo",
            "version" to "0.148.0",
        ),
        modelsPath = "/models",
        chatPath = "/responses",
        modelsUrl = "https://chatgpt.com/backend-api/codex/models",
        responsesUrl = "https://chatgpt.com/backend-api/codex/responses",
        pollIntervalSeconds = 5,
        pollTimeoutSeconds = 900,
    )

    private val jsonHeaders = headersOf(HttpHeaders.ContentType, "application/json")

    /** Builds a base64url encoded JWT. Only the payload matters here; the signature is never decoded. */
    private fun jwt(payload: String): String {
        val encode = { value: String ->
            Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray(Charsets.UTF_8))
        }
        return "${encode("""{"alg":"RS256","typ":"JWT"}""")}.${encode(payload)}.signature"
    }

    private val accountId = "5c0d9a3e-1f2b-4c8d-9e7a-0b1c2d3e4f50"

    /** Same shape as a real id_token: the account details hang off a namespaced claim, not off the top level. */
    private val idToken = jwt(
        """{"sub":"user-1","https://api.openai.com/auth":{"chatgpt_account_id":"$accountId","chatgpt_plan_type":"pro"}}"""
    )

    /** The access token carries its own exp and **no** chatgpt_account_id, which is exactly the trap that has caught us before. */
    private val accessToken = jwt("""{"sub":"user-1","exp":1800000000}""")

    private fun bodyText(request: HttpRequestData): String = (request.body as TextContent).text

    private fun contentType(request: HttpRequestData): String? =
        request.body.contentType?.withoutParameters()?.toString()

    private fun clientOf(engine: MockEngine) = OpenAISubscriptionOAuthClient(HttpClient(engine))

    private fun parser() = clientOf(MockEngine { respond("", HttpStatusCode.OK) })

    // ── First leg: request a device code ──

    @Test
    fun `the usercode request posts JSON carrying only client_id, and the authorization page comes from the served value`() = runTest {
        var url: String? = null
        var type: String? = null
        var body: String? = null
        val client = clientOf(
            MockEngine { request ->
                url = request.url.toString()
                type = contentType(request)
                body = bodyText(request)
                respond(
                    """{"device_auth_id":"da_123","user_code":"ABCD-1234","expires_in":600,"interval":5}""",
                    HttpStatusCode.OK,
                    jsonHeaders,
                )
            }
        )
        val authorization = client.requestDeviceAuthorization(config)

        assertEquals("https://auth.openai.com/api/accounts/deviceauth/usercode", url)
        // The first leg is JSON, not a Grok style form: copying Grok here gets rejected outright.
        assertEquals("application/json", type)
        assertEquals("""{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann"}""", body)
        assertEquals("da_123", authorization.deviceAuthId)
        assertEquals("ABCD-1234", authorization.userCode)
        // Codex does not return verification_uri_complete, so the page address can only come from
        // the served value that already passed the allow-list.
        assertEquals("https://auth.openai.com/codex/device", authorization.verificationUrl)
        assertEquals(600, authorization.expiresIn)
        assertEquals(5, authorization.interval)
    }

    @Test
    fun `a missing expires_in falls back to the served poll timeout, and interval may arrive as a numeric string`() = runTest {
        val client = clientOf(
            MockEngine {
                respond(
                    """{"device_auth_id":"da_1","user_code":"AB","interval":"7"}""",
                    HttpStatusCode.OK,
                    jsonHeaders,
                )
            }
        )
        val authorization = client.requestDeviceAuthorization(config)
        assertEquals(900, authorization.expiresIn)
        assertEquals(7, authorization.interval)
    }

    @Test
    fun `a reply missing device_auth_id or the user code is an upstream failure, not something to carry forward`() = runTest {
        val client = clientOf(
            MockEngine { respond("""{"user_code":"ABCD"}""", HttpStatusCode.OK, jsonHeaders) }
        )
        val error = runCatching { client.requestDeviceAuthorization(config) }
            .exceptionOrNull() as OpenAISubscriptionException
        assertTrue("got ${error.error}", error.error is OpenAISubscriptionError.Upstream)
    }

    @Test
    fun `an authorization page URL outside the allow-list is treated as an unusable configuration`() = runTest {
        val client = clientOf(
            MockEngine {
                respond("""{"device_auth_id":"da_1","user_code":"AB"}""", HttpStatusCode.OK, jsonHeaders)
            }
        )
        // A caller hand-building a config to bypass parsing: better to do nothing than to send the
        // user off to a domain of unknown origin.
        val tampered = config.copy(verificationUrl = "https://evil.test/device")
        val error = runCatching { client.requestDeviceAuthorization(tampered) }
            .exceptionOrNull() as OpenAISubscriptionException
        assertEquals(OpenAISubscriptionError.ConfigurationUnavailable, error.error)
    }

    // ── Second leg: poll, then exchange with PKCE ──

    /**
     * Polling returns `authorization_code + code_verifier`, **not a token**: `tokenEndpoint` still
     * has to be called for the PKCE exchange. Skipping that leg shows up as "polling never
     * succeeds".
     */
    @Test
    fun `a 200 poll that carries the code triggers the form exchange immediately and resolves accountId`() = runTest {
        val urls = mutableListOf<String>()
        val types = mutableListOf<String?>()
        val bodies = mutableListOf<String>()
        val client = clientOf(
            MockEngine { request ->
                urls += request.url.toString()
                types += contentType(request)
                bodies += bodyText(request)
                if (request.url.encodedPath.contains("deviceauth")) {
                    respond(
                        """{"authorization_code":"ac_1","code_verifier":"cv_1"}""",
                        HttpStatusCode.OK,
                        jsonHeaders,
                    )
                } else {
                    respond(
                        """{"access_token":"$accessToken","refresh_token":"rt_1","id_token":"$idToken","expires_in":60}""",
                        HttpStatusCode.OK,
                        jsonHeaders,
                    )
                }
            }
        )
        val tokens = client.pollToken(config, "da_123", "ABCD-1234")

        assertEquals(2, urls.size)
        assertEquals("https://auth.openai.com/api/accounts/deviceauth/token", urls[0])
        assertEquals("application/json", types[0])
        assertTrue(bodies[0].contains(""""device_auth_id":"da_123""""))
        assertTrue(bodies[0].contains(""""user_code":"ABCD-1234""""))

        // The second leg must be form-urlencoded against tokenEndpoint, carrying both code_verifier
        // and redirect_uri.
        assertEquals("https://auth.openai.com/oauth/token", urls[1])
        assertEquals("application/x-www-form-urlencoded", types[1])
        assertTrue(bodies[1].contains("grant_type=authorization_code"))
        assertTrue(bodies[1].contains("code=ac_1"))
        assertTrue(bodies[1].contains("code_verifier=cv_1"))
        assertTrue(
            bodies[1].contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback")
        )
        assertTrue(bodies[1].contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))

        assertEquals(accessToken, tokens.accessToken)
        assertEquals("rt_1", tokens.refreshToken)
        assertEquals(idToken, tokens.idToken)
        // accountId hangs off a namespaced claim inside the id_token, not off the top level.
        assertEquals(accountId, tokens.accountId)
        assertEquals("pro", tokens.planType)
        // The exp inside the access token outranks expires_in: taking the 60 here would put
        // expiry moments away.
        assertEquals(1_800_000_000_000L, tokens.expiresAt)
    }

    @Test
    fun `a 200 poll with no code means the user has not authorized yet, so keep polling as pending`() = runTest {
        val client = clientOf(MockEngine { respond("{}", HttpStatusCode.OK, jsonHeaders) })
        val error = runCatching { client.pollToken(config, "da_1", "AB") }
            .exceptionOrNull() as OpenAISubscriptionException
        assertEquals(OpenAISubscriptionError.AuthorizationPending, error.error)
    }

    @Test
    fun `a 200 poll carrying only half the reply is also treated as pending`() = runTest {
        val client = clientOf(
            MockEngine { respond("""{"authorization_code":"ac_1"}""", HttpStatusCode.OK, jsonHeaders) }
        )
        val error = runCatching { client.pollToken(config, "da_1", "AB") }
            .exceptionOrNull() as OpenAISubscriptionException
        assertEquals(OpenAISubscriptionError.AuthorizationPending, error.error)
    }

    /**
     * **During polling, 403 and 404 mean "the user has not clicked approve in the browser yet"**,
     * which is the exact opposite of what those codes mean everywhere else. Getting this wrong
     * looks like: the user is handed a short code and immediately told their plan is not supported.
     */
    @Test
    fun `403 and 404 while polling mean not yet approved, not an unsupported plan`() = runTest {
        listOf(HttpStatusCode.Forbidden, HttpStatusCode.NotFound).forEach { status ->
            val client = clientOf(MockEngine { respond("", status) })
            val error = runCatching { client.pollToken(config, "da_1", "AB") }
                .exceptionOrNull() as OpenAISubscriptionException
            assertEquals("status=$status", OpenAISubscriptionError.AuthorizationPending, error.error)
        }
        // The same status code outside the polling path still means the plan is not supported.
        assertEquals(
            OpenAISubscriptionError.SubscriptionNotEligible,
            OpenAISubscriptionOAuthClient.mapFailure(403, ""),
        )
    }

    @Test
    fun `when upstream states an error code while polling that wins, it is not swallowed by the 403 fallback`() = runTest {
        val cases = listOf(
            Triple(HttpStatusCode.Forbidden, """{"error":"access_denied"}""", OpenAISubscriptionError.AccessDenied),
            Triple(
                HttpStatusCode.BadRequest,
                """{"error":"deviceauth_authorization_pending"}""",
                OpenAISubscriptionError.AuthorizationPending,
            ),
            Triple(HttpStatusCode.BadRequest, """{"error":"slow_down"}""", OpenAISubscriptionError.SlowDown),
            Triple(HttpStatusCode.BadRequest, """{"error":"expired_token"}""", OpenAISubscriptionError.CodeExpired),
            Triple(
                HttpStatusCode.NotFound,
                """{"error":{"code":"device_code_expired"}}""",
                OpenAISubscriptionError.CodeExpired,
            ),
        )
        cases.forEach { (status, body, expected) ->
            val client = clientOf(MockEngine { respond(body, status, jsonHeaders) })
            val error = runCatching { client.pollToken(config, "da_1", "AB") }
                .exceptionOrNull() as OpenAISubscriptionException
            assertEquals("body=$body", expected, error.error)
        }
    }

    @Test
    fun `other hard failures while polling go through the shared translation`() = runTest {
        val client = clientOf(MockEngine { respondError(HttpStatusCode.UpgradeRequired) })
        val error = runCatching { client.pollToken(config, "da_1", "AB") }
            .exceptionOrNull() as OpenAISubscriptionException
        assertEquals(OpenAISubscriptionError.ClientVersionRejected, error.error)
    }

    // ── Credentials ──

    /**
     * This is a failure we have actually shipped: resolving the claim from the access token instead
     * shows up as sign-in succeeding and then immediately reporting that the model list cannot be
     * fetched. It has to fail at the moment the credential is received, rather than storing a
     * credential whose outbound requests are guaranteed to be missing a header.
     */
    @Test
    fun `an access token with no chatgpt_account_id and no id_token is rejected as an unusable credential`() = runTest {
        val client = clientOf(
            MockEngine {
                respond("""{"access_token":"$accessToken","expires_in":60}""", HttpStatusCode.OK, jsonHeaders)
            }
        )
        val error = runCatching { client.exchangeAuthorizationCode(config, "ac", "cv") }
            .exceptionOrNull() as OpenAISubscriptionException
        val upstream = error.error as OpenAISubscriptionError.Upstream
        assertTrue(upstream.body.contains("chatgpt_account_id"))
    }

    @Test
    fun `with no id_token the namespaced claim on the access token is used instead`() = runTest {
        val selfDescribing = jwt(
            """{"exp":1800000000,"https://api.openai.com/auth":{"chatgpt_account_id":"$accountId"}}"""
        )
        val client = clientOf(
            MockEngine {
                respond("""{"access_token":"$selfDescribing"}""", HttpStatusCode.OK, jsonHeaders)
            }
        )
        val tokens = client.exchangeAuthorizationCode(config, "ac", "cv")
        assertEquals(accountId, tokens.accountId)
        assertNull(tokens.planType)
    }

    /**
     * An OpenAI refresh response usually returns neither a refresh_token nor an id_token. Failing to
     * carry the old values forward throws away the ability to renew and the account identity at the
     * same time; the latter shows up as outbound requests missing the `chatgpt-account-id` header
     * and being rejected upstream.
     */
    @Test
    fun `a refresh that returns no refresh token and no id token keeps the previous values`() = runTest {
        var type: String? = null
        var body: String? = null
        val client = clientOf(
            MockEngine { request ->
                type = contentType(request)
                body = bodyText(request)
                respond("""{"access_token":"$accessToken","expires_in":3600}""", HttpStatusCode.OK, jsonHeaders)
            }
        )
        val tokens = client.refreshTokens(config, "rt_old", previousAccountId = accountId, previousPlanType = "pro")

        assertEquals("application/x-www-form-urlencoded", type)
        assertTrue(body!!.contains("grant_type=refresh_token"))
        assertTrue(body!!.contains("refresh_token=rt_old"))
        assertTrue(body!!.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        assertEquals("rt_old", tokens.refreshToken)
        assertEquals(accountId, tokens.accountId)
        assertEquals("pro", tokens.planType)
    }

    @Test
    fun `a refresh that does return a new refresh token uses the new value`() = runTest {
        val client = clientOf(
            MockEngine {
                respond(
                    """{"access_token":"$accessToken","refresh_token":"rotated","id_token":"$idToken"}""",
                    HttpStatusCode.OK,
                    jsonHeaders,
                )
            }
        )
        val tokens = client.refreshTokens(config, "rt_old")
        assertEquals("rotated", tokens.refreshToken)
        assertEquals(accountId, tokens.accountId)
    }

    @Test
    fun `any reply without an access_token is a failure`() = runTest {
        val client = clientOf(
            MockEngine { respond("""{"refresh_token":"rt"}""", HttpStatusCode.OK, jsonHeaders) }
        )
        val error = runCatching { client.exchangeAuthorizationCode(config, "ac", "cv") }
            .exceptionOrNull() as OpenAISubscriptionException
        assertTrue(error.error is OpenAISubscriptionError.Upstream)
    }

    @Test
    fun `renewal starts 5 minutes before expiry, avoiding the random 401 where a token is valid at check time and expired on arrival`() {
        val tokens = OpenAISubscriptionTokens(accessToken = "a", accountId = "acct", expiresAt = 1_000_000L)
        assertTrue(tokens.needsRefresh(1_000_000L - 4 * 60 * 1000L))
        assertFalse(tokens.needsRefresh(1_000_000L - 6 * 60 * 1000L))
        // With no expiry from upstream, do not renew eagerly rather than refreshing on every request.
        assertFalse(
            OpenAISubscriptionTokens(accessToken = "a", accountId = "acct").needsRefresh(System.currentTimeMillis())
        )
    }

    @Test
    fun `an undecodable JWT always yields null and never throws`() {
        assertNull(OpenAIJwtClaims.string("not-a-jwt", "chatgpt_account_id"))
        assertNull(OpenAIJwtClaims.string("a.!!!.c", "chatgpt_account_id"))
        assertNull(OpenAIJwtClaims.expirationMillis("not-a-jwt"))
        assertNull(OpenAIJwtClaims.expirationMillis(idToken))
        assertEquals(1_800_000_000_000L, OpenAIJwtClaims.expirationMillis(accessToken))
    }

    // ── Model catalog ──

    @Test
    fun `the catalog request carries client_version and chatgpt-account-id, plus the served required headers verbatim`() = runTest {
        var url: String? = null
        val headers = mutableMapOf<String, String?>()
        val client = clientOf(
            MockEngine { request ->
                url = request.url.toString()
                listOf("Authorization", "chatgpt-account-id", "originator", "version", "OpenAI-Beta")
                    .forEach { headers[it] = request.headers[it] }
                respond("""{"models":[]}""", HttpStatusCode.OK, jsonHeaders)
            }
        )
        client.fetchModels(config, "token-123", accountId)

        // Without client_version upstream always answers 400 missing field client_version.
        assertEquals("https://chatgpt.com/backend-api/codex/models?client_version=0.148.0", url)
        assertEquals("Bearer token-123", headers["Authorization"])
        assertEquals(accountId, headers["chatgpt-account-id"])
        assertEquals("oriveo", headers["originator"])
        assertEquals("0.148.0", headers["version"])
        assertEquals("responses=experimental", headers["OpenAI-Beta"])
    }

    /**
     * Captured from the production path with a real pro account, **field for field, unsimplified**.
     *
     * An earlier version of this fixture claimed the same provenance while `supported_reasoning_levels`
     * had been hand-written as a flat array of strings. What upstream actually sends is an **array of
     * objects**, `[{effort, description}, ...]`. The tests went green and every subscription model in
     * production displayed "this model does not support reasoning".
     *
     * **A fake fixture is more dangerous than no test at all**: it freezes our assumption about
     * upstream into an assertion, and from then on nothing ever questions it. Build boundary cases in
     * a separate fixture and say plainly that it is synthetic; do not edit this one.
     */
    private val realModelsPayload = """
        {
          "models": [
            {"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true,
             "web_search_tool_type":"text_and_image","default_reasoning_level":"low",
             "supported_reasoning_levels":[
               {"effort":"low","description":"Fast responses with lighter reasoning"},
               {"effort":"medium","description":"Balances speed and reasoning depth"},
               {"effort":"high","description":"Greater reasoning depth"},
               {"effort":"xhigh","description":"Extra high reasoning depth"},
               {"effort":"max","description":"Maximum reasoning depth"},
               {"effort":"ultra","description":"Maximum reasoning with delegation"}],
             "input_modalities":["text","image"],"context_window":272000},
            {"slug":"gpt-5.6-terra","visibility":"list","supported_in_api":true,
             "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
             "supported_reasoning_levels":[
               {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
               {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"},
               {"effort":"max","description":"Max"},{"effort":"ultra","description":"Ultra"}],
             "input_modalities":["text","image"],"context_window":272000},
            {"slug":"gpt-5.6-luna","visibility":"list","supported_in_api":true,
             "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
             "supported_reasoning_levels":[
               {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
               {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"},
               {"effort":"max","description":"Max"}],
             "input_modalities":["text","image"],"context_window":272000},
            {"slug":"gpt-reserve","visibility":"hide","supported_in_api":true,
             "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
             "supported_reasoning_levels":[{"effort":"low","description":"Fast"}],
             "input_modalities":["text","image"],"context_window":272000},
            {"slug":"gpt-5.5","visibility":"list","supported_in_api":true,
             "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
             "supported_reasoning_levels":[
               {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
               {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"}],
             "input_modalities":["text","image"],"context_window":272000},
            {"slug":"gpt-5.4","visibility":"list","supported_in_api":true,
             "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
             "supported_reasoning_levels":[
               {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
               {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"}],
             "input_modalities":["text","image"],"context_window":272000},
            {"slug":"gpt-5.4-mini","visibility":"list","supported_in_api":true,
             "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
             "supported_reasoning_levels":[
               {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
               {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"}],
             "input_modalities":["text","image"],"context_window":272000},
            {"slug":"gpt-5.3-codex-spark","visibility":"list","supported_in_api":false,
             "web_search_tool_type":"text","default_reasoning_level":"high",
             "supported_reasoning_levels":[{"effort":"low","description":"Fast"}],
             "input_modalities":["text"],"context_window":128000},
            {"slug":"codex-auto-review","visibility":"hide","supported_in_api":true,
             "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
             "supported_reasoning_levels":[{"effort":"low","description":"Fast"}],
             "input_modalities":["text","image"],"context_window":272000}
          ]
        }
    """.trimIndent()

    /** A synthetic boundary case. This is **not** a real upstream response; it exists only to pin how a model with no declared capabilities degrades. */
    private val sparseModelsPayload = """
        {
          "models": [
            {"slug":"no-caps","visibility":"list","supported_in_api":true},
            {"slug":"empty-caps","visibility":"list","supported_in_api":true,
             "web_search_tool_type":"","supported_reasoning_levels":[],"input_modalities":["text"]}
          ]
        }
    """.trimIndent()

    @Test
    fun `parsing keys off the models slug and filters out hidden entries and entries not supported in the API`() {
        // The key regression: the Codex response is **not** the standard {"data":[{"id"}]} shape, and
        // copying that shape parses out an empty catalog.
        val descriptors = parser().parseModelDescriptors(realModelsPayload)
        assertEquals(
            listOf("gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini"),
            descriptors.map { it.slug },
        )
    }

    // The north star, established in production: upstream declares four to six reasoning levels per
    // model, we parsed them as an array of strings, every entry failed to parse, the level table was
    // permanently empty, and every subscription model displayed "this model does not support reasoning".
    @Test
    fun `every model that reaches the catalog in the real response resolves reasoning levels, none may be empty`() {
        val descriptors = parser().parseModelDescriptors(realModelsPayload)
        assertEquals(emptyList<String>(), descriptors.filter { it.supportedReasoningLevels.isEmpty() }.map { it.slug })

        val luna = descriptors.first { it.slug == "gpt-5.6-luna" }
        assertEquals(listOf("low", "medium", "high", "xhigh", "max"), luna.supportedReasoningLevels)
        assertEquals("medium", luna.defaultReasoningLevel)
        assertTrue(luna.supportsReasoning)
    }

    @Test
    fun `every model that reaches the catalog in the real response resolves web search support`() {
        val descriptors = parser().parseModelDescriptors(realModelsPayload)
        assertTrue(descriptors.all { it.supportsWebSearch })
        assertTrue(descriptors.all { it.supportsImageInput })
    }

    @Test
    fun `a flat array of strings is still accepted, so a switch back upstream cannot empty the table again`() {
        val descriptors = parser().parseModelDescriptors(
            """{"models":[{"slug":"flat","visibility":"list","supported_in_api":true,
               "supported_reasoning_levels":["low","high"]}]}""",
        )
        assertEquals(listOf("low", "high"), descriptors.first().supportedReasoningLevels)
    }

    @Test
    fun `a level entry that is neither a string nor carries effort is skipped rather than polluting the table`() {
        val descriptors = parser().parseModelDescriptors(
            """{"models":[{"slug":"mixed","visibility":"list","supported_in_api":true,
               "supported_reasoning_levels":[{"description":"no effort here"},{"effort":"high"},42]}]}""",
        )
        assertEquals(listOf("high"), descriptors.first().supportedReasoningLevels)
    }

    @Test
    fun `the standard data id shape parses to nothing, the two catalogs are not interchangeable`() {
        assertTrue(parser().parseModelDescriptors("""{"data":[{"id":"gpt-4o"}]}""").isEmpty())
    }

    @Test
    fun `capabilities are copied from what upstream declares, one field at a time`() {
        val sol = parser().parseModelDescriptors(realModelsPayload).first()
        assertEquals(
            CodexModelDescriptor(
                slug = "gpt-5.6-sol",
                displayName = null,
                supportsWebSearch = true,
                supportedReasoningLevels = listOf("low", "medium", "high", "xhigh", "max", "ultra"),
                defaultReasoningLevel = "low",
                supportsImageInput = true,
                contextWindow = 272000,
            ),
            sol,
        )
        assertTrue(sol.supportsReasoning)
    }

    @Test
    fun `an empty string or empty array means unsupported, never guess a capability from the slug`() {
        val empty = parser().parseModelDescriptors(sparseModelsPayload).first { it.slug == "empty-caps" }
        assertFalse(empty.supportsWebSearch)
        assertEquals(emptyList<String>(), empty.supportedReasoningLevels)
        assertFalse(empty.supportsReasoning)
        assertFalse(empty.supportsImageInput)
    }

    @Test
    fun `a model declaring no capability fields stays in the catalog, only degraded to no capabilities`() {
        // Treating "did not declare" as "filter it out" would empty the whole catalog the next time
        // upstream adjusts a field name, which is far worse than losing a capability.
        val bare = parser().parseModelDescriptors(sparseModelsPayload).firstOrNull { it.slug == "no-caps" }
        assertNotNull(bare)
        requireNotNull(bare)
        assertFalse(bare.supportsWebSearch)
        assertEquals(emptyList<String>(), bare.supportedReasoningLevels)
        assertNull(bare.contextWindow)
        assertNull(bare.displayName)
    }

    @Test
    fun `a 426 from the catalog translates to a rejected client version`() = runTest {
        val client = clientOf(MockEngine { respondError(HttpStatusCode.UpgradeRequired) })
        val error = runCatching { client.fetchModels(config, "t", accountId) }
            .exceptionOrNull() as OpenAISubscriptionException
        assertEquals(OpenAISubscriptionError.ClientVersionRejected, error.error)
        assertTrue(error.error.requiresConfigRefresh)
    }

    // ── Failure mapping ──

    @Test
    fun `the four hard failures each map to their own meaning and must not collapse into one generic error`() {
        assertEquals(
            OpenAISubscriptionError.ClientVersionRejected,
            OpenAISubscriptionOAuthClient.mapFailure(426, ""),
        )
        assertEquals(
            OpenAISubscriptionError.SubscriptionNotEligible,
            OpenAISubscriptionOAuthClient.mapFailure(403, ""),
        )
        assertEquals(OpenAISubscriptionError.Unauthorized, OpenAISubscriptionOAuthClient.mapFailure(401, ""))
        assertEquals(OpenAISubscriptionError.QuotaExhausted, OpenAISubscriptionOAuthClient.mapFailure(429, ""))
        assertEquals(
            OpenAISubscriptionError.Upstream(500, "boom"),
            OpenAISubscriptionOAuthClient.mapFailure(500, "boom"),
        )
    }

    @Test
    fun `Codex expresses quota and plan through an error code rather than the status code, in both error shapes`() {
        // String shape.
        assertEquals(
            OpenAISubscriptionError.QuotaExhausted,
            OpenAISubscriptionOAuthClient.mapFailure(400, """{"error":"usage_limit_reached"}"""),
        )
        // Object shape, which may carry either {code} or {type}.
        assertEquals(
            OpenAISubscriptionError.SubscriptionNotEligible,
            OpenAISubscriptionOAuthClient.mapFailure(400, """{"error":{"code":"usage_not_included"}}"""),
        )
        assertEquals(
            OpenAISubscriptionError.Unauthorized,
            OpenAISubscriptionOAuthClient.mapFailure(400, """{"error":{"type":"invalid_grant"}}"""),
        )
        assertEquals(
            OpenAISubscriptionError.QuotaExhausted,
            OpenAISubscriptionOAuthClient.mapFailure(400, """{"error":"rate_limit_exceeded"}"""),
        )
        assertEquals(
            OpenAISubscriptionError.Unauthorized,
            OpenAISubscriptionOAuthClient.mapFailure(400, """{"error":"refresh_token_invalidated"}"""),
        )
        // A non-JSON body must not blow up the translation; fall back to the status code.
        assertEquals(
            OpenAISubscriptionError.Unauthorized,
            OpenAISubscriptionOAuthClient.mapFailure(401, "<html>nope</html>"),
        )
    }

    @Test
    fun `only 426 forces a configuration refresh, it is the one early signal that OpenAI changed something`() {
        assertTrue(OpenAISubscriptionError.ClientVersionRejected.requiresConfigRefresh)
        listOf(
            OpenAISubscriptionError.Unauthorized,
            OpenAISubscriptionError.QuotaExhausted,
            OpenAISubscriptionError.SubscriptionNotEligible,
            OpenAISubscriptionError.Transport("x"),
        ).forEach { assertFalse(it.toString(), it.requiresConfigRefresh) }
    }

    @Test
    fun `dead-end failures offer no retry button so users do not tap in vain`() {
        assertTrue(OpenAISubscriptionError.CodeExpired.allowsRetry)
        assertTrue(OpenAISubscriptionError.Transport("x").allowsRetry)
        assertTrue(OpenAISubscriptionError.Upstream(500, "x").allowsRetry)
        assertFalse(OpenAISubscriptionError.SubscriptionNotEligible.allowsRetry)
        assertFalse(OpenAISubscriptionError.QuotaExhausted.allowsRetry)
        assertFalse(OpenAISubscriptionError.Unauthorized.allowsRetry)
        assertFalse(OpenAISubscriptionError.ClientVersionRejected.allowsRetry)
        assertFalse(OpenAISubscriptionError.ConfigurationUnavailable.allowsRetry)
    }

    @Test
    fun `a network exception becomes a transport error rather than masquerading as an upstream status code`() = runTest {
        val client = clientOf(MockEngine { throw java.io.IOException("connection reset") })
        val error = runCatching { client.fetchModels(config, "t", accountId) }
            .exceptionOrNull() as OpenAISubscriptionException
        val transport = error.error as OpenAISubscriptionError.Transport
        assertTrue(transport.detail.contains("connection reset"))
    }

    // ── Reasoning level admission ──

    @Test
    fun `product levels map onto values inside the set upstream declared`() {
        val declared = listOf("low", "medium", "high", "xhigh")
        assertEquals("low", codexReasoningEffort("fast", declared))
        assertEquals("medium", codexReasoningEffort("balanced", declared))
        assertEquals("high", codexReasoningEffort("deep", declared))
        assertEquals("xhigh", codexReasoningEffort("max", declared))
    }

    @Test
    fun `with no declared level table nothing is injected, never send a value upstream does not know`() {
        // The grok reasoning_effort incident had exactly this shape: a level table on our side, none
        // on theirs.
        listOf("fast", "balanced", "deep", "max").forEach {
            assertNull(it, codexReasoningEffort(it, emptyList()))
        }
    }

    @Test
    fun `automatic and unknown levels never inject, leaving it to the upstream default_reasoning_level`() {
        val declared = listOf("low", "medium", "high", "xhigh")
        assertNull(codexReasoningEffort("automatic", declared))
        assertNull(codexReasoningEffort(null, declared))
        assertNull(codexReasoningEffort("turbo", declared))
    }

    @Test
    fun `when upstream declares fewer levels than the product offers, fall back along the candidate order rather than silently sending nothing`() {
        assertEquals("medium", codexReasoningEffort("max", listOf("low", "medium")))
        assertEquals("medium", codexReasoningEffort("deep", listOf("medium")))
        assertEquals("minimal", codexReasoningEffort("fast", listOf("minimal", "high")))
        assertEquals("low", codexReasoningEffort("balanced", listOf("low", "xhigh")))
    }

    @Test
    fun `when no product level matches anything upstream declared, send nothing rather than forcing a value`() {
        assertNull(codexReasoningEffort("fast", listOf("ultra")))
    }

    @Test
    fun `level comparison is case insensitive, so an upstream switch to uppercase cannot disable the feature wholesale`() {
        assertEquals("high", codexReasoningEffort("deep", listOf("LOW", "HIGH")))
    }
}
