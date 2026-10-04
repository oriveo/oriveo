package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Remote MCP authorization.
 *
 * Mostly fixture replay: `shared/test-fixtures/mcp/auth/` is the single source of truth. A fake transport and a
 * fake browser replay the fixtures; every asserted object comes from the production code path (`McpAuthorizer` /
 * pure functions).
 */
class McpAuthorizerTest {

    private fun authFixture(name: String): JsonElement = McpFixture.json("auth/$name")

    private class Env(
        val transport: FakeMcpAuthTransport = FakeMcpAuthTransport(),
        val browser: FakeMcpBrowserSession = FakeMcpBrowserSession(),
        val prefs: InMemoryPrefs = InMemoryPrefs(),
        var clock: Long = 1_800_000_000_000L,
        /** The client metadata document this build identifies itself with; empty means it has none. */
        val clientMetadataUrl: String = CLIENT_METADATA_URL,
    ) {
        val store = McpCredentialStore(prefs)
        val authorizer = restarted()

        fun restarted() = McpAuthorizer(transport, browser, store, now = { clock }, clientMetadataUrl = clientMetadataUrl)
    }

    private fun stubProtectedResource(env: Env) {
        val fixture = authFixture("protected-resource-metadata.json")
        env.transport.stub(fixture["status"].longOrNull?.toInt() ?: 200, fixture["body"]!!, PROTECTED_RESOURCE_URL)
    }

    private fun stubAuthorizationServer(env: Env, name: String) {
        val fixture = authFixture(name)
        env.transport.stub(fixture["status"].longOrNull?.toInt() ?: 200, fixture["body"]!!, AUTHORIZATION_SERVER_URL)
    }

    private fun stubToken(env: Env, name: String) {
        val fixture = authFixture(name)
        env.transport.stub(fixture["status"].longOrNull?.toInt() ?: 200, fixture["body"]!!, TOKEN_URL)
    }

    private fun stubDcr(env: Env) {
        stubAuthorizationServer(env, "authorization-server-metadata.dcr.json")
        val dcr = authFixture("dcr.json")
        env.transport.stub(dcr["status"].longOrNull?.toInt() ?: 201, dcr["body"]!!, REGISTRATION_URL)
    }

    private val challenge = McpAuthChallenge(resourceMetadata = PROTECTED_RESOURCE_URL)

    private suspend fun readyPlan(env: Env, challenge: McpAuthChallenge = this.challenge): McpAuthorizationPlan {
        val outcome = env.authorizer.discover(challenge, ENDPOINT)
        return (outcome as? McpAuthDiscoveryOutcome.Ready)?.plan ?: error("expected ready, got $outcome")
    }

    private fun replacing(json: JsonElement, key: String, value: JsonElement?): JsonElement {
        val obj = json as JsonObject
        val pairs = obj.filterKeys { it != key }.toMutableMap()
        if (value != null) pairs[key] = value
        return JsonObject(pairs)
    }

    /** Redirects to the redirect URI used at the start, carrying `state` back unchanged. */
    private val echoingCallback: (String, String) -> String = { authorizeUrl, redirectUri ->
        val state = McpCallbackValidator.parameters(authorizeUrl)["state"].orEmpty()
        "$redirectUri?code=ac_123&state=$state&iss=https://auth.example.com"
    }

    private fun saveCredentials(env: Env, serverId: String, expiresAt: Long? = null, accessToken: String = "old") {
        env.store.save(
            McpCredentials(
                accessToken = accessToken,
                refreshToken = "mcp_rt_example",
                expiresAtMillis = expiresAt,
                issuer = "https://auth.example.com",
                clientId = CLIENT_METADATA_URL,
                resource = "https://mcp.example.com/mcp",
            ),
            serverId,
            UID,
        )
    }

    private suspend fun expectAuthError(expected: McpAuthorizerException, block: suspend () -> Unit) {
        try {
            block()
            fail("expected $expected")
        } catch (error: McpAuthorizerException) {
            assertEquals(expected, error)
        }
    }

    private fun kind(kind: McpAuthorizerException.Kind) = McpAuthorizerException.of(kind)

    private suspend fun cimdAttempt(env: Env): McpAuthorizationAttempt {
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        stubToken(env, "token.success.json")
        return env.authorizer.beginAuthorization(readyPlan(env), UID, REDIRECT_URI, state = "st_test", codeVerifier = "verifier_test")
    }

    // ── Discovery ──────────────────────────────────────────

    @Test
    fun `fixture 401 challenge parses resource_metadata and scope and builds well-known uris`() {
        val fixture = authFixture("401.www-authenticate.json")
        val challenge = McpWwwAuthenticate.parse(fixture["headers"]["WWW-Authenticate"].stringOrNull)!!
        assertEquals(fixture["expect"]["resourceMetadataURL"].stringOrNull, challenge.resourceMetadata)
        assertEquals(fixture["expect"]["scope"].stringOrNull, challenge.scope)

        val noMetadata = authFixture("401.no-metadata.json")
        val bare = McpWwwAuthenticate.parse(noMetadata["headers"]["WWW-Authenticate"].stringOrNull)!!
        assertNull(bare.resourceMetadata)
        val expected = (noMetadata["expect"]["constructedURIs"] as JsonArray).map { it.stringOrNull }
        assertEquals(expected, McpProtectedResourceDiscovery.candidates(bare, ENDPOINT))
    }

    @Test
    fun `fixture 403 insufficient_scope is needs_auth without step-up`() {
        val fixture = authFixture("403.insufficient-scope.json")
        val code = McpAuthResponseMapping.needsAuthErrorCode(403, fixture["headers"]["WWW-Authenticate"].stringOrNull)
        assertEquals(fixture["expect"]["errorCode"].stringOrNull, code?.wireValue)
        assertEquals(fixture["expect"]["stepUpImplemented"].booleanOrNull, McpAuthResponseMapping.STEP_UP_IMPLEMENTED)
    }

    @Test
    fun `fixture metadata parsing and well-known order`() {
        val prm = authFixture("protected-resource-metadata.json")
        val parsed = McpProtectedResourceMetadata.fromJson(prm["body"]!!)!!
        assertEquals(prm["expect"]["issuer"].stringOrNull, parsed.authorizationServers.first())
        assertNull(McpProtectedResourceMetadata.fromJson(replacing(prm["body"]!!, "authorization_servers", JsonArray(emptyList()))))

        val fixture = authFixture("authorization-server-metadata.cimd.json")
        val metadata = McpAuthorizationServerMetadata.fromJson(fixture["body"]!!)!!
        assertEquals("https://auth.example.com", metadata.issuer)
        assertTrue(metadata.clientIdMetadataDocumentSupported)
        assertTrue(metadata.authorizationResponseIssParameterSupported)
        val kind = McpClientRegistrationDecision.decide(metadata, CLIENT_METADATA_URL)
        assertEquals(McpClientRegistrationKind.Cimd, kind)
        assertEquals(fixture["expect"]["registration"].stringOrNull, kind?.wireValue)
        val tried = (fixture["expect"]["wellKnownTried"] as JsonArray).map { it.stringOrNull }
        assertEquals(tried, McpAuthorizationServerDiscovery.candidates(metadata.issuer).take(tried.size))
        assertEquals(
            listOf(
                "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
                "https://auth.example.com/.well-known/openid-configuration/tenant1",
                "https://auth.example.com/tenant1/.well-known/openid-configuration",
            ),
            McpAuthorizationServerDiscovery.candidates("https://auth.example.com/tenant1"),
        )
    }

    // ── The three client registration tiers ────────────────

    @Test
    fun `registration path one CIMD uses the configured document url as the client id and never registers`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        val plan = readyPlan(env)
        assertEquals(McpClientRegistrationKind.Cimd, plan.registrationKind)
        assertNull(plan.registrationEndpoint)
        assertEquals("stops at the first well-known hit", listOf(PROTECTED_RESOURCE_URL, AUTHORIZATION_SERVER_URL), env.transport.getUrls)
        val registration = env.authorizer.register(plan, UID)
        assertEquals(McpClientRegistrationKind.Cimd, registration.kind)
        assertEquals(CLIENT_METADATA_URL, registration.clientId)
        assertEquals(CLIENT_METADATA_URL, env.authorizer.beginAuthorization(plan, UID).request.queryItems["client_id"])
        assertTrue("CIMD needs no registration request", env.transport.jsonRequests.isEmpty())
        assertTrue("CIMD stores no registration", env.prefs.all.isEmpty())
    }

    @Test
    fun `without a client metadata document a server that supports both methods is registered dynamically`() = runBlocking {
        val metadata = McpAuthorizationServerMetadata.fromJson(authFixture("authorization-server-metadata.cimd.json")["body"]!!)!!
        assertTrue(metadata.clientIdMetadataDocumentSupported)
        assertEquals(McpClientRegistrationKind.Dcr, McpClientRegistrationDecision.decide(metadata, clientMetadataUrl = ""))

        val env = Env(clientMetadataUrl = "")
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        val dcr = authFixture("dcr.json")
        env.transport.stub(dcr["status"].longOrNull?.toInt() ?: 201, dcr["body"]!!, REGISTRATION_URL)
        val plan = readyPlan(env)
        assertEquals(McpClientRegistrationKind.Dcr, plan.registrationKind)
        assertEquals(REGISTRATION_URL, plan.registrationEndpoint)

        val attempt = env.authorizer.beginAuthorization(plan, UID)
        assertEquals(McpClientRegistrationKind.Dcr, attempt.registrationKind)
        assertEquals("oriveo_mcp_2f9c41", attempt.clientId)
        assertEquals(listOf(REGISTRATION_URL), env.transport.jsonRequests.map { it.first })
    }

    @Test
    fun `without a client metadata document and without a registration endpoint discovery needs a token`() = runBlocking {
        val body = replacing(authFixture("authorization-server-metadata.cimd.json")["body"]!!, "registration_endpoint", null)
        val metadata = McpAuthorizationServerMetadata.fromJson(body)!!
        assertTrue(metadata.clientIdMetadataDocumentSupported)
        assertNull(McpClientRegistrationDecision.decide(metadata, clientMetadataUrl = ""))
        assertEquals(McpClientRegistrationKind.Cimd, McpClientRegistrationDecision.decide(metadata, CLIENT_METADATA_URL))

        val env = Env(clientMetadataUrl = "")
        stubProtectedResource(env)
        env.transport.stub(200, body, AUTHORIZATION_SERVER_URL)
        assertEquals(McpAuthDiscoveryOutcome.NeedsToken, env.authorizer.discover(challenge, ENDPOINT))
        assertTrue(env.transport.jsonRequests.isEmpty())
        assertTrue(env.browser.openedUrls.isEmpty())
        assertTrue(env.prefs.all.isEmpty())
    }

    @Test
    fun `registration path two DCR registers only when authorization begins with native application type`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubDcr(env)
        val plan = readyPlan(env)
        assertEquals(McpClientRegistrationKind.Dcr, plan.registrationKind)
        assertEquals(REGISTRATION_URL, plan.registrationEndpoint)
        assertTrue("discovery must not register", env.transport.jsonRequests.isEmpty())
        assertTrue("discovery writes nothing to storage", env.prefs.all.isEmpty())

        val attempt = env.authorizer.beginAuthorization(plan, UID)
        assertEquals("oriveo_mcp_2f9c41", attempt.clientId)
        assertEquals("oriveo_mcp_2f9c41", attempt.request.queryItems["client_id"])
        val (url, body) = env.transport.jsonRequests.single()
        assertEquals(REGISTRATION_URL, url)
        assertEquals("native", body["application_type"].stringOrNull)
        assertEquals("none", body["token_endpoint_auth_method"].stringOrNull)
        assertEquals("Oriveo", body["client_name"].stringOrNull)
        assertEquals(
            "exactly the redirect URIs of the fixture are registered",
            authFixture("dcr.json")["request"]["body"]["redirect_uris"],
            body["redirect_uris"],
        )
        assertEquals(REDIRECT_URI, attempt.redirectUri)
        assertEquals(REDIRECT_URI, attempt.request.queryItems["redirect_uri"])
    }

    @Test
    fun `DCR registration is stored per partition and issuer and reused across flows and restarts`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubDcr(env)
        val plan = readyPlan(env)
        env.authorizer.beginAuthorization(plan, UID)
        env.authorizer.beginAuthorization(plan, UID)
        assertEquals("the second authorization reuses the existing registration", 1, env.transport.jsonRequests.size)
        assertEquals(setOf(McpCredentialStore.registrationKey("https://auth.example.com", UID)), env.prefs.all.keys)
        val stored = env.store.loadClientRegistration("https://auth.example.com", UID)!!
        assertEquals("oriveo_mcp_2f9c41", stored.clientId)
        assertEquals(McpClientMetadata.REDIRECT_URIS, stored.redirectUris)

        val restarted = env.restarted()
        assertEquals("oriveo_mcp_2f9c41", restarted.beginAuthorization(plan, UID).clientId)
        assertEquals(1, env.transport.jsonRequests.size)
        restarted.beginAuthorization(plan, "other")
        assertEquals("another partition does not share the registration", 2, env.transport.jsonRequests.size)
    }

    @Test
    fun `two concurrent DCR authorization starts register once`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubDcr(env)
        val plan = readyPlan(env)
        val attempts = listOf(async { env.authorizer.beginAuthorization(plan, UID) }, async { env.authorizer.beginAuthorization(plan, UID) }).awaitAll()
        assertTrue(attempts.all { it.clientId == "oriveo_mcp_2f9c41" })
        assertEquals(1, env.transport.jsonRequests.size)
    }

    @Test
    fun `full add flow discovers once and registers once`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubDcr(env)
        stubToken(env, "token.success.json")
        env.browser.callbackBuilder = echoingCallback
        val plan = readyPlan(env)
        val credentials = env.authorizer.authorize(plan, SERVER_ID, UID)
        assertEquals("oriveo_mcp_2f9c41", credentials.clientId)
        assertEquals("oriveo_mcp_2f9c41", env.store.load(SERVER_ID, UID)?.clientId)
        assertEquals(1, env.transport.jsonRequests.size)
        assertEquals("authorization does not repeat discovery", listOf(PROTECTED_RESOURCE_URL, AUTHORIZATION_SERVER_URL), env.transport.getUrls)
        assertEquals(1, env.browser.openedUrls.size)
    }

    @Test
    fun `invalid_client on token exchange discards the registration and retries once`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.dcr.json")
        val registered = authFixture("dcr.json")["body"]!!
        env.transport.enqueue(201, registered, REGISTRATION_URL)
        env.transport.enqueue(201, replacing(registered, "client_id", JsonPrimitive("oriveo_mcp_second")), REGISTRATION_URL)
        val invalidClient = (authFixture("token.error.json")["cases"] as JsonArray).first { it["caseId"].stringOrNull == "invalid_client" }
        env.transport.enqueue(400, invalidClient["body"]!!, TOKEN_URL)
        stubToken(env, "token.success.json")
        env.browser.callbackBuilder = echoingCallback

        val credentials = env.authorizer.authorize(readyPlan(env), SERVER_ID, UID)
        assertEquals("oriveo_mcp_second", credentials.clientId)
        assertEquals(2, env.transport.jsonRequests.size)
        assertEquals(2, env.browser.openedUrls.size)
        assertEquals("oriveo_mcp_second", env.store.loadClientRegistration("https://auth.example.com", UID)?.clientId)
        assertEquals(listOf("oriveo_mcp_2f9c41", "oriveo_mcp_second"), env.transport.formRequests.map { (_, form) -> form.first { it.name == "client_id" }.value })
    }

    @Test
    fun `invalid_client twice gives up without storing tokens or the rejected registration`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubDcr(env)
        env.transport.stub(400, """{"error":"invalid_client"}""", TOKEN_URL)
        env.browser.callbackBuilder = echoingCallback
        val plan = readyPlan(env)
        expectAuthError(kind(McpAuthorizerException.Kind.ClientRejected)) { env.authorizer.authorize(plan, SERVER_ID, UID) }
        assertEquals(2, env.transport.jsonRequests.size)
        assertEquals(2, env.browser.openedUrls.size)
        assertNull(env.store.load(SERVER_ID, UID))
        assertNull(env.store.loadClientRegistration("https://auth.example.com", UID))
    }

    @Test
    fun `validated callback error invalid_client discards the DCR cache but a forged one does not`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubDcr(env)
        val attempt = env.authorizer.beginAuthorization(readyPlan(env), UID, REDIRECT_URI, "st_test", "verifier_test")
        assertNotNull(env.store.loadClientRegistration("https://auth.example.com", UID))

        expectAuthError(McpAuthorizerException.rejected(McpCallbackRejectionReason.StateMismatch)) {
            env.authorizer.completeAuthorization(attempt, "$REDIRECT_URI?error=invalid_client&state=st_other", SERVER_ID, UID)
        }
        assertNotNull("a callback with a mismatched state is not trusted", env.store.loadClientRegistration("https://auth.example.com", UID))

        expectAuthError(kind(McpAuthorizerException.Kind.ClientRejected)) {
            env.authorizer.completeAuthorization(attempt, "$REDIRECT_URI?error=invalid_client&state=st_test", SERVER_ID, UID)
        }
        assertNull(env.store.loadClientRegistration("https://auth.example.com", UID))
        assertTrue(env.transport.formRequests.isEmpty())
    }

    @Test
    fun `registration transient failure and rejection never write storage`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.dcr.json")
        val plan = readyPlan(env)
        env.transport.setUnreachable(true, REGISTRATION_URL)
        expectAuthError(kind(McpAuthorizerException.Kind.TemporarilyUnavailable)) { env.authorizer.beginAuthorization(plan, UID) }
        env.transport.setUnreachable(false, REGISTRATION_URL)
        env.transport.stub(400, """{"error":"invalid_redirect_uri"}""", REGISTRATION_URL)
        expectAuthError(kind(McpAuthorizerException.Kind.RegistrationFailed)) { env.authorizer.beginAuthorization(plan, UID) }
        assertTrue(env.prefs.all.isEmpty())
    }

    @Test
    fun `registration path three none supported needs a token`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.none.json")
        assertEquals(McpAuthDiscoveryOutcome.NeedsToken, env.authorizer.discover(challenge, ENDPOINT))
        assertTrue(env.transport.jsonRequests.isEmpty())
    }

    @Test
    fun `issuer mismatch in server metadata is refused and needs a token`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.issuer-mismatch.json")
        assertEquals(McpAuthDiscoveryOutcome.NeedsToken, env.authorizer.discover(challenge, ENDPOINT))
        assertTrue(env.transport.getUrls.contains(AUTHORIZATION_SERVER_URL))
        assertTrue(env.transport.getUrls.contains("https://auth.example.com/.well-known/openid-configuration"))
    }

    // ── Authorization request / token request ──────────────

    @Test
    fun `fixture authorization request uses S256 resource state and scope`() {
        val fixture = authFixture("authorization-request.json")
        val query = fixture["query"]!!
        val record = fixture["perRequestRecord"]!!
        val verifier = record["codeVerifier"].stringOrNull!!
        assertEquals(query["code_challenge"].stringOrNull, McpPkce.codeChallenge(verifier))
        val request = McpOAuthRequests.authorizationRequest(
            authorizationEndpoint = fixture["url"].stringOrNull!!,
            clientId = query["client_id"].stringOrNull!!,
            redirectUri = query["redirect_uri"].stringOrNull!!,
            state = query["state"].stringOrNull!!,
            codeVerifier = verifier,
            issuer = record["issuer"].stringOrNull!!,
            resource = query["resource"].stringOrNull!!,
            scope = query["scope"].stringOrNull!!,
        )
        val items = request.queryItems
        for (key in listOf("response_type", "client_id", "redirect_uri", "state", "code_challenge", "resource", "scope")) {
            assertEquals(key, query[key].stringOrNull, items[key])
        }
        assertEquals("S256", items["code_challenge_method"])
        assertEquals(record["state"].stringOrNull, request.state)
        assertEquals(record["issuer"].stringOrNull, request.issuer)
        assertEquals(verifier, request.codeVerifier)
        assertTrue(request.url.startsWith("https://auth.example.com/authorize?"))
    }

    @Test
    fun `fixture DCR body token exchange form and refresh form`() {
        val dcr = authFixture("dcr.json")
        val expected = dcr["request"]["body"]!!
        val body = McpClientMetadata.registrationBody(expected["scope"].stringOrNull)
        for (key in listOf("client_name", "redirect_uris", "grant_types", "response_types", "token_endpoint_auth_method", "application_type", "scope")) {
            assertEquals(key, expected[key], body[key])
        }
        assertNull("no scope member when there is nothing to request", McpClientMetadata.registrationBody(null)["scope"])
        assertEquals(false, dcr["expect"]["reusableAcrossIssuers"].booleanOrNull)

        val form = authFixture("token.request.json")["form"]!!
        val fields = McpOAuthRequests.tokenExchangeForm(
            form["code"].stringOrNull!!, form["client_id"].stringOrNull!!, form["redirect_uri"].stringOrNull!!,
            form["code_verifier"].stringOrNull!!, form["resource"].stringOrNull!!,
        ).associate { it.name to it.value }
        for (key in listOf("grant_type", "code", "redirect_uri", "client_id", "code_verifier", "resource")) {
            assertEquals(key, form[key].stringOrNull, fields[key])
        }

        val refresh = authFixture("token.refresh.success.json")
        val refreshForm = refresh["request"]["form"]!!
        val refreshFields = McpOAuthRequests.refreshForm(
            refreshForm["refresh_token"].stringOrNull!!, refreshForm["client_id"].stringOrNull!!, refreshForm["resource"].stringOrNull!!,
        ).associate { it.name to it.value }
        for (key in listOf("grant_type", "refresh_token", "client_id", "resource")) {
            assertEquals(key, refreshForm[key].stringOrNull, refreshFields[key])
        }
        val tokens = McpTokenResponse.fromJson(refresh["body"]!!)!!
        assertEquals("mcp_at_example_2", tokens.accessToken)
        assertEquals("mcp_rt_example_2", tokens.refreshToken)
        assertEquals(3600.0, tokens.expiresIn!!, 0.0)

        val success = authFixture("token.success.json")
        val exchanged = McpTokenResponse.fromJson(success["body"]!!)!!
        assertEquals("mcp_at_example", exchanged.accessToken)
        assertEquals(success["expect"]["hasRefreshToken"].booleanOrNull, exchanged.refreshToken != null)
    }

    // ── Callback validation (RFC 9207) ─────────────────────

    @Test
    fun `fixture callback vectors all go through the production path`() = runBlocking {
        val fixture = authFixture("callback.params.json")
        val expectedIssuer = fixture["expectedIssuer"].stringOrNull!!
        val expectedState = fixture["expectedState"].stringOrNull!!
        val cases = fixture["cases"] as JsonArray
        assertEquals(9, cases.size)
        val metadata = authFixture("authorization-server-metadata.cimd.json")["body"]!!

        for (item in cases) {
            val caseId = item["caseId"].stringOrNull!!
            val supported = item["metadata"]["authorization_response_iss_parameter_supported"].booleanOrNull
            val params = (item["params"] as JsonObject).mapValues { it.value.stringOrNull.orEmpty() }
            val callbackUrl = REDIRECT_URI + "?" + McpPercentEncoding.encodeForm(params.map { McpFormField(it.key, it.value) })
            val expectAccepted = item["expect"]["accepted"].booleanOrNull ?: false
            val expectedReason = item["expect"]["reason"].stringOrNull

            val result = McpCallbackValidator.validate(params, expectedState, expectedIssuer, supported ?: false, callbackUrl, REDIRECT_URI)
            assertEquals(caseId, expectAccepted, result.isAccepted)
            assertEquals(caseId, expectedReason, result.rejection?.wireValue)

            val env = Env()
            stubProtectedResource(env)
            env.transport.stub(
                200,
                replacing(metadata, "authorization_response_iss_parameter_supported", supported?.let(::JsonPrimitive)),
                AUTHORIZATION_SERVER_URL,
            )
            stubToken(env, "token.success.json")
            val plan = readyPlan(env)
            assertEquals(caseId, supported ?: false, plan.issParameterSupported)
            assertEquals(caseId, expectedIssuer, plan.issuer)
            val attempt = env.authorizer.beginAuthorization(plan, UID, REDIRECT_URI, expectedState, "verifier_test")
            try {
                val credentials = env.authorizer.completeAuthorization(attempt, callbackUrl, SERVER_ID, UID)
                assertTrue(caseId, expectAccepted)
                assertEquals(caseId, "mcp_at_example", credentials.accessToken)
                assertEquals(caseId, 1, env.transport.formRequests.size)
            } catch (error: McpAuthorizerException) {
                assertFalse(caseId, expectAccepted)
                val reason = McpCallbackRejectionReason.entries.first { it.wireValue == expectedReason }
                assertEquals(caseId, McpAuthorizerException.rejected(reason), error)
                assertTrue(caseId, env.transport.formRequests.isEmpty())
                assertNull(caseId, env.store.load(SERVER_ID, UID))
                if (item["expect"]["surfaceErrorText"].booleanOrNull == false) {
                    assertEquals("user said no", params["error_description"])
                    for (text in listOf(error.toString(), error.message.orEmpty(), error.localizedMessage.orEmpty())) {
                        assertFalse(caseId, text.contains("user said no"))
                        assertFalse(caseId, text.contains("access_denied"))
                    }
                }
            }
        }
    }

    @Test
    fun `redirect uri matching compares scheme host and path only`() {
        val accepted = listOf(
            "oriveo://mcp/oauth/callback",
            "oriveo://mcp/oauth/callback?code=x&state=y",
            "ORIVEO://MCP/oauth/callback",
        )
        val rejected = listOf(
            "oriveo://mcp/oauth/other?code=x",
            "oriveo://mcp/oauth/callbac?code=x",
            "oriveo://mcp/oauth/callback/extra",
            "oriveo://mcp/prefix/oauth/callback",
            "oriveo://evil/oauth/callback?code=x",
            "oriveo://mcp.evil.example/oauth/callback?code=x",
            "oriveox://mcp/oauth/callback?code=x",
            "https://mcp/oauth/callback?code=x",
            "https://app.example.com/mcp/oauth/callback?code=x",
        )
        accepted.forEach { assertTrue(it, McpRedirectUri.matches(it, REDIRECT_URI)) }
        rejected.forEach { assertFalse(it, McpRedirectUri.matches(it, REDIRECT_URI)) }
    }

    @Test
    fun `state iss and redirect mismatches are rejected without storing tokens`() = runBlocking {
        val cases = listOf(
            "$REDIRECT_URI?code=ac_123&state=st_other&iss=https://auth.example.com" to McpCallbackRejectionReason.StateMismatch,
            "$REDIRECT_URI?code=ac_123&state=st_test&iss=https://evil.example" to McpCallbackRejectionReason.IssMismatch,
            // Correct state and issuer, but it arrives somewhere other than the redirect URI the request was sent with.
            "https://app.example.com/mcp/oauth/callback?code=ac_123&state=st_test&iss=https://auth.example.com" to McpCallbackRejectionReason.RedirectUriMismatch,
        )
        for ((callback, reason) in cases) {
            val env = Env()
            val attempt = cimdAttempt(env)
            expectAuthError(McpAuthorizerException.rejected(reason)) { env.authorizer.completeAuthorization(attempt, callback, SERVER_ID, UID) }
            assertNull(reason.wireValue, env.store.load(SERVER_ID, UID))
            assertTrue(reason.wireValue, env.transport.formRequests.isEmpty())
        }
    }

    @Test
    fun `valid callback exchanges the token with resource and persists`() = runBlocking {
        val env = Env()
        val attempt = cimdAttempt(env)
        val credentials = env.authorizer.completeAuthorization(
            attempt, "$REDIRECT_URI?code=ac_123&state=st_test&iss=https://auth.example.com", SERVER_ID, UID,
        )
        assertEquals("mcp_at_example", credentials.accessToken)
        assertEquals("mcp_rt_example", credentials.refreshToken)
        assertEquals("https://auth.example.com", credentials.issuer)
        assertEquals("mcp_at_example", env.store.load(SERVER_ID, UID)?.accessToken)
        val (url, form) = env.transport.formRequests.single()
        assertEquals(TOKEN_URL, url)
        val items = form.associate { it.name to it.value }
        assertEquals("https://mcp.example.com/mcp", items["resource"])
        assertEquals("verifier_test", items["code_verifier"])
        assertEquals("authorization_code", items["grant_type"])
        assertEquals(REDIRECT_URI, items["redirect_uri"])
    }

    @Test
    fun `persist false returns the credentials without writing them`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        stubToken(env, "token.success.json")
        env.browser.callbackBuilder = echoingCallback
        val credentials = env.authorizer.authorize(readyPlan(env), SERVER_ID, UID, persist = false)
        assertEquals("mcp_at_example", credentials.accessToken)
        assertNull("nothing is written to secure storage before the server row is saved, so a killed process leaves no orphan token", env.store.load(SERVER_ID, UID))
        env.authorizer.persistCredentials(credentials, SERVER_ID, UID)
        assertEquals(credentials, env.store.load(SERVER_ID, UID))
    }

    @Test
    fun `browser flow redirects to the custom scheme and saves the credentials it returns`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        stubToken(env, "token.success.json")
        env.browser.callbackBuilder = echoingCallback
        val credentials = env.authorizer.authorize(readyPlan(env), SERVER_ID, UID)
        assertEquals("mcp_at_example", credentials.accessToken)
        assertEquals("the returned credential is the one that was persisted", credentials, env.store.load(SERVER_ID, UID))
        assertEquals("auth.example.com", McpOrigin.parse(env.browser.openedUrls.single())?.host)
        assertEquals(REDIRECT_URI, McpCallbackValidator.parameters(env.browser.openedUrls.single())["redirect_uri"])
        assertEquals(REDIRECT_URI, env.transport.formRequests.single().second.first { it.name == "redirect_uri" }.value)
    }

    @Test
    fun `user cancelling the browser stores nothing`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        expectAuthError(kind(McpAuthorizerException.Kind.Cancelled)) { env.authorizer.authorize(readyPlan(env), SERVER_ID, UID) }
        assertTrue(env.prefs.all.isEmpty())
        assertTrue(env.transport.formRequests.isEmpty())
    }

    // ── Refresh ────────────────────────────────────────────

    @Test
    fun `concurrent refreshes are serialized into one request and persisted`() = runBlocking {
        val env = Env()
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        stubToken(env, "token.refresh.success.json")
        env.transport.postFormDelayMillis = 150
        saveCredentials(env, SERVER_ID)

        val (a, b) = listOf(async { env.authorizer.refresh(SERVER_ID, UID) }, async { env.authorizer.refresh(SERVER_ID, UID) }).awaitAll()
        assertEquals(a, b)
        assertEquals("mcp_at_example_2", a.accessToken)
        assertEquals(1, env.transport.formRequests.size)
        val stored = env.store.load(SERVER_ID, UID)!!
        assertEquals(a, stored)
        assertEquals("mcp_rt_example_2", stored.refreshToken)
        assertNotNull(stored.expiresAtMillis)

        val fixture = authFixture("token.refresh.success.json")
        val expected = fixture["request"]["form"] as JsonObject
        val (url, form) = env.transport.formRequests.single()
        assertEquals(fixture["request"]["url"].stringOrNull, url)
        assertEquals(expected.size, form.size)
        for ((key, value) in expected) assertEquals(key, value.stringOrNull, form.first { it.name == key }.value)

        // Serialization only covers the same moment: the next refresh after it finishes sends a request as usual.
        env.authorizer.refresh(SERVER_ID, UID)
        assertEquals(2, env.transport.formRequests.size)
    }

    /**
     * Serialization is scoped to "this refresh is still running", not "the caller that started it is still waiting".
     * When the initiator is cancelled (the user tapped stop)
     * the refresh is still in flight, and the next caller must wait for that same one rather than send another:
     * using one refresh token twice makes a rotating authorization server revoke both.
     */
    @Test
    fun `a refresh whose first caller was cancelled is still shared by the next caller`() = runBlocking {
        val env = Env()
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        stubToken(env, "token.refresh.success.json")
        env.transport.postFormDelayMillis = 400
        saveCredentials(env, SERVER_ID)

        val first = launch(Dispatchers.Default) { env.authorizer.refresh(SERVER_ID, UID) }
        assertTrue(McpClientHarness.eventually { env.transport.formRequests.size == 1 })
        first.cancelAndJoin()

        val second = env.authorizer.refresh(SERVER_ID, UID)

        assertEquals("mcp_at_example_2", second.accessToken)
        assertEquals("the refresh token is sent only once", 1, env.transport.formRequests.size)
        assertEquals("mcp_rt_example_2", env.store.load(SERVER_ID, UID)?.refreshToken)
    }

    /**
     * On `invalid_grant`, storage is re-read before anything is written. While the request was in flight something
     * else (another process / a fresh sign-in) already rotated the refresh token:
     * what was declared invalid is the old token we sent, so the new one in storage must not be wiped and is adopted directly.
     */
    @Test
    fun `invalid_grant does not wipe credentials that were rotated elsewhere while the request was in flight`() = runBlocking {
        val env = Env()
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        val invalidGrant = (authFixture("token.error.json")["cases"] as JsonArray).first { it["caseId"].stringOrNull == "invalid_grant" }
        env.transport.stub(invalidGrant["status"].longOrNull?.toInt() ?: 400, invalidGrant["body"]!!, TOKEN_URL)
        env.transport.postFormDelayMillis = 300
        saveCredentials(env, SERVER_ID)

        val refreshing = async(Dispatchers.Default) { env.authorizer.refresh(SERVER_ID, UID) }
        assertTrue(McpClientHarness.eventually { env.transport.formRequests.size == 1 })
        val rotated = env.store.load(SERVER_ID, UID)!!.copy(accessToken = "rotated_at", refreshToken = "rotated_rt")
        env.store.save(rotated, SERVER_ID, UID)

        assertEquals("adopts the new credential from storage", rotated, refreshing.await())
        assertEquals("a token that was just rotated elsewhere must not be wiped", rotated, env.store.load(SERVER_ID, UID))
    }

    @Test
    fun `fixture token errors fail and invalid_grant drops tokens but keeps registration`() = runBlocking {
        val cases = authFixture("token.error.json")["cases"] as JsonArray
        assertEquals(3, cases.size)
        for (item in cases) {
            val caseId = item["caseId"].stringOrNull!!
            val env = Env()
            stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
            env.transport.stub(item["status"].longOrNull?.toInt() ?: 400, item["body"]!!, TOKEN_URL)
            saveCredentials(env, SERVER_ID)
            expectAuthError(kind(McpAuthorizerException.Kind.TokenRequestFailed)) { env.authorizer.refresh(SERVER_ID, UID) }
            val stored = env.store.load(SERVER_ID, UID)
            if (caseId == "invalid_grant") {
                assertNull(caseId, stored?.accessToken)
                assertNull(caseId, stored?.refreshToken)
                assertNotNull(caseId, stored?.clientId)
            } else {
                assertEquals(caseId, "mcp_rt_example", stored?.refreshToken)
            }
        }
    }

    @Test
    fun `expiring token is refreshed before use and the new expiry persisted`() = runBlocking {
        val env = Env()
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        stubToken(env, "token.refresh.success.json")
        saveCredentials(env, SERVER_ID, expiresAt = env.clock + 10_000)
        assertEquals("mcp_at_example_2", env.authorizer.validAccessToken(SERVER_ID, UID))
        val stored = env.store.load(SERVER_ID, UID)!!
        assertEquals("mcp_rt_example_2", stored.refreshToken)
        assertEquals(env.clock + 3_600_000, stored.expiresAtMillis)
        assertEquals("mcp_at_example_2", env.authorizer.validAccessToken(SERVER_ID, UID))
        assertEquals(1, env.transport.formRequests.size)
    }

    @Test
    fun `pasted token is returned by validAccessToken`() = runBlocking {
        val env = Env()
        env.authorizer.storePastedToken("pasted_abc", SERVER_ID, UID)
        assertEquals("pasted_abc", env.authorizer.validAccessToken(SERVER_ID, UID))
    }

    /** Saving a pasted token clears the OAuth set: the OAuth access token wins when a token is fetched, so leaving it would mean the pasted token is never used. */
    @Test
    fun `storing a pasted token clears the oauth group so the pasted token is the one used`() = runBlocking {
        val env = Env()
        saveCredentials(env, SERVER_ID, accessToken = "stale_oauth_at")

        env.authorizer.storePastedToken("pasted_abc", SERVER_ID, UID)

        assertEquals("pasted_abc", env.authorizer.validAccessToken(SERVER_ID, UID))
        assertEquals(McpCredentials(pastedToken = "pasted_abc"), env.store.load(SERVER_ID, UID))
    }

    // ── resource validation of protected resource metadata (RFC 9728 section 3.3) ──────────

    @Test
    fun `metadata whose resource does not match the endpoint is never used`() = runBlocking {
        val body = authFixture("protected-resource-metadata.json")["body"]!!
        val mismatched = listOf(
            "https://other.example.com/mcp", "https://mcp.example.com/other", "https://mcp.example.com/mcp/deeper",
            "https://mcp.example.com/mc", "http://mcp.example.com/mcp", "https://mcp.example.com:8443/mcp",
            "https://mcp.example.com/?tenant=1", null,
        )
        for (resource in mismatched) {
            val env = Env()
            env.transport.stub(200, replacing(body, "resource", resource?.let(::JsonPrimitive)), PROTECTED_RESOURCE_URL)
            stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
            assertEquals("$resource", McpAuthDiscoveryOutcome.NeedsToken, env.authorizer.discover(challenge, ENDPOINT))
            assertFalse("the authorization server named by rejected metadata must not be contacted", env.transport.getUrls.contains(AUTHORIZATION_SERVER_URL))
        }
    }

    @Test
    fun `resource equal by canonical uri or a parent path is accepted and resource sent is always the endpoint`() = runBlocking {
        val body = authFixture("protected-resource-metadata.json")["body"]!!
        for (resource in listOf(
            "https://mcp.example.com/mcp", "https://MCP.example.com/mcp/", "HTTPS://mcp.example.com/mcp#frag",
            "https://mcp.example.com", "https://mcp.example.com/", "https://mcp.example.com:443/mcp",
        )) {
            val env = Env()
            env.transport.stub(200, replacing(body, "resource", JsonPrimitive(resource)), PROTECTED_RESOURCE_URL)
            stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
            assertEquals(resource, "https://mcp.example.com/mcp", readyPlan(env).resource)
        }
    }

    @Test
    fun `header metadata with wrong resource falls through to the next well-known candidate`() = runBlocking {
        val env = Env()
        val body = authFixture("protected-resource-metadata.json")["body"]!!
        val fromHeader = "https://mcp.example.com/somewhere/else.json"
        env.transport.stub(200, replacing(body, "resource", JsonPrimitive("https://other.example.com/mcp")), fromHeader)
        env.transport.stub(200, body, "https://mcp.example.com/.well-known/oauth-protected-resource/mcp")
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        readyPlan(env, McpAuthChallenge(resourceMetadata = fromHeader))
        assertEquals(listOf(fromHeader, "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"), env.transport.getUrls.take(2))
    }

    // ── PKCE method ────────────────────────────────────────

    @Test
    fun `metadata without S256 is refused and nothing is registered`() = runBlocking {
        val variants: List<JsonElement?> = listOf(
            null, JsonArray(emptyList()), JsonArray(listOf(JsonPrimitive("plain"))), JsonArray(listOf(JsonPrimitive("s256"))), JsonPrimitive("S256"),
        )
        for (value in variants) {
            for (fixture in listOf("authorization-server-metadata.cimd.json", "authorization-server-metadata.dcr.json")) {
                val env = Env()
                stubProtectedResource(env)
                env.transport.stub(200, replacing(authFixture(fixture)["body"]!!, "code_challenge_methods_supported", value), AUTHORIZATION_SERVER_URL)
                assertEquals("$value / $fixture", McpAuthDiscoveryOutcome.NeedsToken, env.authorizer.discover(challenge, ENDPOINT))
                assertTrue(env.transport.jsonRequests.isEmpty())
                assertTrue(env.browser.openedUrls.isEmpty())
                assertTrue(env.prefs.all.isEmpty())
            }
        }
        val env = Env()
        stubProtectedResource(env)
        env.transport.stub(
            200,
            replacing(authFixture("authorization-server-metadata.cimd.json")["body"]!!, "code_challenge_methods_supported", JsonArray(listOf(JsonPrimitive("plain"), JsonPrimitive("S256")))),
            AUTHORIZATION_SERVER_URL,
        )
        assertEquals(McpClientRegistrationKind.Cimd, readyPlan(env).registrationKind)
    }

    // ── https only ─────────────────────────────────────────

    @Test
    fun `non-https authorization token and registration endpoints and issuers are refused`() = runBlocking {
        for (key in listOf("authorization_endpoint", "token_endpoint")) {
            val env = Env()
            stubProtectedResource(env)
            env.transport.stub(200, replacing(authFixture("authorization-server-metadata.cimd.json")["body"]!!, key, JsonPrimitive("http://auth.example.com/insecure")), AUTHORIZATION_SERVER_URL)
            assertEquals(key, McpAuthDiscoveryOutcome.NeedsToken, env.authorizer.discover(challenge, ENDPOINT))
            assertFalse(env.transport.getUrls.any { it.startsWith("http://") })
        }
        val dcrEnv = Env()
        stubProtectedResource(dcrEnv)
        dcrEnv.transport.stub(200, replacing(authFixture("authorization-server-metadata.dcr.json")["body"]!!, "registration_endpoint", JsonPrimitive("http://auth.example.com/register")), AUTHORIZATION_SERVER_URL)
        assertEquals(McpAuthDiscoveryOutcome.NeedsToken, dcrEnv.authorizer.discover(challenge, ENDPOINT))
        assertTrue(dcrEnv.transport.jsonRequests.isEmpty())

        val issuerEnv = Env()
        issuerEnv.transport.stub(
            200,
            replacing(authFixture("protected-resource-metadata.json")["body"]!!, "authorization_servers", JsonArray(listOf(JsonPrimitive("http://auth.example.com")))),
            PROTECTED_RESOURCE_URL,
        )
        assertEquals(McpAuthDiscoveryOutcome.NeedsToken, issuerEnv.authorizer.discover(challenge, ENDPOINT))
        issuerEnv.authorizer.discover(McpAuthChallenge(resourceMetadata = "http://mcp.example.com/prm.json"), ENDPOINT)
        assertFalse(issuerEnv.transport.getUrls.any { it.startsWith("http://") })
    }

    // ── Transient errors versus definitive failures ────────────────

    @Test
    fun `discovery transient failures are temporarilyUnavailable not needs token`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        env.transport.setUnreachable(true, AUTHORIZATION_SERVER_URL)
        env.transport.setUnreachable(true, "https://auth.example.com/.well-known/openid-configuration")
        assertEquals(McpAuthDiscoveryOutcome.TemporarilyUnavailable, env.authorizer.discover(challenge, ENDPOINT))
        env.transport.setUnreachable(false, AUTHORIZATION_SERVER_URL)
        env.transport.stub(503, "", AUTHORIZATION_SERVER_URL)
        assertEquals(McpAuthDiscoveryOutcome.TemporarilyUnavailable, env.authorizer.discover(challenge, ENDPOINT))
        env.transport.setUnreachable(true, PROTECTED_RESOURCE_URL)
        assertEquals(McpAuthDiscoveryOutcome.TemporarilyUnavailable, env.authorizer.discover(challenge, ENDPOINT))
    }

    @Test
    fun `refresh without refresh token sends nothing`() = runBlocking {
        val env = Env()
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        env.store.save(
            McpCredentials(accessToken = "only_access", issuer = "https://auth.example.com", clientId = CLIENT_METADATA_URL, resource = "https://mcp.example.com/mcp"),
            SERVER_ID,
            UID,
        )
        expectAuthError(kind(McpAuthorizerException.Kind.NoRefreshToken)) { env.authorizer.refresh(SERVER_ID, UID) }
        assertTrue(env.transport.getUrls.isEmpty())
        assertTrue(env.transport.formRequests.isEmpty())
    }

    @Test
    fun `refresh transient failures keep credentials and later succeed`() = runBlocking {
        val env = Env()
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        stubToken(env, "token.refresh.success.json")
        saveCredentials(env, SERVER_ID)
        val before = env.store.load(SERVER_ID, UID)

        env.transport.setUnreachable(true, AUTHORIZATION_SERVER_URL)
        try {
            env.authorizer.refresh(SERVER_ID, UID)
            fail()
        } catch (error: McpAuthorizerException) {
            assertTrue(error.isTransient)
        }
        assertTrue(env.transport.formRequests.isEmpty())
        assertEquals(before, env.store.load(SERVER_ID, UID))

        env.transport.setUnreachable(false, AUTHORIZATION_SERVER_URL)
        env.transport.setUnreachable(true, TOKEN_URL)
        expectAuthError(kind(McpAuthorizerException.Kind.TemporarilyUnavailable)) { env.authorizer.refresh(SERVER_ID, UID) }
        assertEquals(before, env.store.load(SERVER_ID, UID))

        env.transport.setUnreachable(false, TOKEN_URL)
        env.transport.enqueue(503, JsonObject(emptyMap()), TOKEN_URL)
        expectAuthError(kind(McpAuthorizerException.Kind.TemporarilyUnavailable)) { env.authorizer.refresh(SERVER_ID, UID) }
        assertEquals(before, env.store.load(SERVER_ID, UID))

        assertEquals("mcp_at_example_2", env.authorizer.refresh(SERVER_ID, UID).accessToken)
    }

    @Test
    fun `refresh with metadata definitely gone is metadataUnavailable and not transient`() = runBlocking {
        val env = Env()
        saveCredentials(env, SERVER_ID)
        try {
            env.authorizer.refresh(SERVER_ID, UID)
            fail()
        } catch (error: McpAuthorizerException) {
            assertEquals(McpAuthorizerException.Kind.MetadataUnavailable, error.kind)
            assertFalse(error.isTransient)
        }
    }

    @Test
    fun `validAccessToken survives a transient refresh failure until the token really expires`() = runBlocking {
        val env = Env()
        stubAuthorizationServer(env, "authorization-server-metadata.cimd.json")
        env.transport.setUnreachable(true, TOKEN_URL)
        saveCredentials(env, SERVER_ID, expiresAt = env.clock + 30_000, accessToken = "still_valid")
        assertEquals("still_valid", env.authorizer.validAccessToken(SERVER_ID, UID))
        assertEquals("a refresh really was attempted", 1, env.transport.formRequests.size)

        saveCredentials(env, SERVER_ID, expiresAt = env.clock - 5_000, accessToken = "still_valid")
        expectAuthError(kind(McpAuthorizerException.Kind.TemporarilyUnavailable)) { env.authorizer.validAccessToken(SERVER_ID, UID) }
        assertEquals("a transient error does not drop the refresh token", "mcp_rt_example", env.store.load(SERVER_ID, UID)?.refreshToken)
    }

    // ── A persistence failure must not be treated as saved ───────────

    @Test
    fun `persistence failures are reported for exchange refresh paste and registration`() = runBlocking {
        val env = Env()
        val attempt = cimdAttempt(env)
        env.prefs.failWrites = true
        expectAuthError(kind(McpAuthorizerException.Kind.CredentialPersistenceFailed)) {
            env.authorizer.completeAuthorization(attempt, "$REDIRECT_URI?code=ac_123&state=st_test&iss=https://auth.example.com", SERVER_ID, UID)
        }
        assertEquals("the token was obtained, it just was not stored", 1, env.transport.formRequests.size)
        assertNull(env.store.load(SERVER_ID, UID))

        val refreshEnv = Env()
        stubAuthorizationServer(refreshEnv, "authorization-server-metadata.cimd.json")
        stubToken(refreshEnv, "token.refresh.success.json")
        saveCredentials(refreshEnv, SERVER_ID)
        refreshEnv.prefs.failWrites = true
        expectAuthError(kind(McpAuthorizerException.Kind.CredentialPersistenceFailed)) { refreshEnv.authorizer.refresh(SERVER_ID, UID) }
        assertEquals("storage still holds the old one", "old", refreshEnv.store.load(SERVER_ID, UID)?.accessToken)
        try {
            refreshEnv.authorizer.storePastedToken("pasted_abc", OTHER_SERVER_ID, UID)
            fail()
        } catch (error: McpAuthorizerException) {
            assertEquals(McpAuthorizerException.Kind.CredentialPersistenceFailed, error.kind)
        }

        val dcrEnv = Env()
        stubProtectedResource(dcrEnv)
        stubDcr(dcrEnv)
        dcrEnv.browser.callbackBuilder = echoingCallback
        val plan = readyPlan(dcrEnv)
        dcrEnv.prefs.failWrites = true
        expectAuthError(kind(McpAuthorizerException.Kind.CredentialPersistenceFailed)) { dcrEnv.authorizer.authorize(plan, SERVER_ID, UID) }
        assertTrue("the browser is not opened with a registration that failed to save", dcrEnv.browser.openedUrls.isEmpty())
    }

    @Test
    fun `reauthorization keeps the previously pasted token`() = runBlocking {
        val env = Env()
        val attempt = cimdAttempt(env)
        env.authorizer.storePastedToken("pasted_abc", SERVER_ID, UID)
        env.authorizer.completeAuthorization(attempt, "$REDIRECT_URI?code=ac_123&state=st_test&iss=https://auth.example.com", SERVER_ID, UID)
        val stored = env.store.load(SERVER_ID, UID)!!
        assertEquals("mcp_at_example", stored.accessToken)
        assertEquals("pasted_abc", stored.pastedToken)
    }

    // ── Token response ─────────────────────────────────────

    @Test
    fun `token response validation`() = runBlocking {
        fun parse(text: String) = McpTokenResponse.fromJson(McpJson.parse(text))
        assertNull(parse("""{"access_token":"a","token_type":"DPoP"}"""))
        assertNull(parse("""{"access_token":"","token_type":"Bearer"}"""))
        assertEquals("a", parse("""{"access_token":"a","token_type":"bearer"}""")?.accessToken)
        assertEquals("a", parse("""{"access_token":"a"}""")?.accessToken)
        assertNull(parse("""{"access_token":"a","expires_in":0}""")?.expiresIn)
        assertNull(parse("""{"access_token":"a","expires_in":-5}""")?.expiresIn)
        assertNull(parse("""{"access_token":"a","refresh_token":""}""")?.refreshToken)
        assertEquals(McpTokenResponse.MAX_EXPIRES_IN_SECONDS, parse("""{"access_token":"a","expires_in":1e30}""")?.expiresIn!!, 0.0)

        val env = Env()
        val attempt = cimdAttempt(env)
        env.transport.stub(200, """{"access_token":"dpop_token","token_type":"DPoP"}""", TOKEN_URL)
        expectAuthError(kind(McpAuthorizerException.Kind.TokenRequestFailed)) {
            env.authorizer.completeAuthorization(attempt, "$REDIRECT_URI?code=ac_123&state=st_test&iss=https://auth.example.com", SERVER_ID, UID)
        }
        assertNull(env.store.load(SERVER_ID, UID))
    }

    // ── Redaction ──────────────────────────────────────────

    @Test
    fun `objects produced by the authorization flow never print secrets`() = runBlocking {
        val env = Env()
        stubProtectedResource(env)
        stubDcr(env)
        stubToken(env, "token.success.json")
        val plan = readyPlan(env)
        val registration = env.authorizer.register(plan, UID)
        val attempt = env.authorizer.beginAuthorization(plan, UID, REDIRECT_URI, "st_secret_state", "verifier_secret_value")
        val credentials = env.authorizer.completeAuthorization(attempt, "$REDIRECT_URI?code=ac_secret_code&state=st_secret_state", SERVER_ID, UID)
        val sentForm = env.transport.formRequests.single().second
        val tokens = McpTokenResponse.fromJson(authFixture("token.success.json")["body"]!!)!!
        val stored = env.store.loadClientRegistration("https://auth.example.com", UID)!!

        val secrets = listOf(
            "st_secret_state", "verifier_secret_value", "ac_secret_code", "oriveo_mcp_2f9c41",
            "mcp_at_example", "mcp_rt_example", McpPkce.codeChallenge("verifier_secret_value"),
        )
        // Precondition: these objects really carry secrets (otherwise the "does not contain" checks below are empty).
        assertEquals("verifier_secret_value", attempt.codeVerifier)
        assertTrue(attempt.request.url.contains("st_secret_state"))
        assertEquals("oriveo_mcp_2f9c41", registration.clientId)
        assertTrue(sentForm.any { it.value == "ac_secret_code" })
        assertEquals("mcp_at_example", tokens.accessToken)

        val subjects: List<Any> = listOf(
            attempt, attempt.request, registration, plan, tokens, sentForm, credentials, stored,
            McpAuthDiscoveryOutcome.Ready(plan), McpCallbackValidation.Accepted("ac_secret_code"),
        )
        for (subject in subjects) {
            val text = subject.toString()
            for (secret in secrets) assertFalse("${subject::class.simpleName} leaks $secret", text.contains(secret))
        }
        assertTrue(attempt.toString().contains("https://auth.example.com"))
        assertTrue(attempt.request.toString().contains("https://auth.example.com/authorize"))
        assertTrue(sentForm.toString().contains("code_verifier"))
    }

    // ── Callback hand-off ──────────────────────────────────

    @Test
    fun `callback router hands the callback to the waiting authorization by state and only once`() = runBlocking {
        val router = McpOAuthCallbackRouter()
        val first = router.register("st_a")
        val second = router.register("st_b")
        assertFalse("without a state it is not claimed", router.deliver("$REDIRECT_URI?code=x"))
        assertFalse("not the registered redirect URI", router.deliver("https://evil.example/mcp/oauth/callback?state=st_a"))
        assertFalse("a state nobody is waiting for", router.deliver("$REDIRECT_URI?code=x&state=st_zzz"))
        assertTrue(router.deliver("$REDIRECT_URI?code=x&state=st_a"))
        assertFalse("a state is claimed only once", router.deliver("$REDIRECT_URI?code=y&state=st_a"))
        assertTrue(router.deliver("$REDIRECT_URI?code=z&state=st_b"))
        assertEquals("$REDIRECT_URI?code=x&state=st_a", first.await())
        assertEquals("$REDIRECT_URI?code=z&state=st_b", second.await())

        val cancelled = router.register("st_c")
        router.cancel("st_c")
        assertTrue(cancelled.isCancelled)
        assertFalse(router.deliver("$REDIRECT_URI?code=z&state=st_c"))
    }

    companion object {
        const val ENDPOINT = "https://mcp.example.com/mcp"
        const val UID = LOCAL_PARTITION_ID
        const val REDIRECT_URI = "oriveo://mcp/oauth/callback"

        /** The client metadata document the shared fixtures were recorded with. */
        const val CLIENT_METADATA_URL = "https://app.example.com/oauth/mcp-client.json"
        const val PROTECTED_RESOURCE_URL = "https://mcp.example.com/.well-known/oauth-protected-resource"
        const val AUTHORIZATION_SERVER_URL = "https://auth.example.com/.well-known/oauth-authorization-server"
        const val REGISTRATION_URL = "https://auth.example.com/register"
        const val TOKEN_URL = "https://auth.example.com/token"
        const val SERVER_ID = "6f1d2c3b-4a59-4e68-9d7c-0b1a2c3d4e5f"
        const val OTHER_SERVER_ID = "7a2e3d4c-5b6a-4f79-8e8d-1c2b3d4e5f60"
    }
}
