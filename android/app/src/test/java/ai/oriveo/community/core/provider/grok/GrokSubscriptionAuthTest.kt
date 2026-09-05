package ai.oriveo.community.core.provider.grok

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.provider.MetadataTestFixtures
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic contract for the Grok subscription sign-in.
 *
 * Nothing here touches the network: parsing the served configuration, the host allow-list, the
 * version gate, translating upstream error codes and deciding when to renew are all decidable
 * offline, and they are exactly the parts that are easiest to get quietly wrong while a real
 * device shows nothing but one vague error message. Whether an endpoint is reachable, or whether
 * upstream accepts a given parameter, is a question only real traffic can answer, and these tests
 * do not pretend to cover it.
 */
class GrokSubscriptionAuthTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    // ── Fixtures ──

    /** Same shape the catalog serves; each case changes only the one field it is about. */
    private fun makeRaw(
        enabled: Boolean? = true,
        flow: String? = "oauth_device_code",
        clientId: String? = "b1a00492-073a-47ea-816f-4c329264a828",
        scopes: String? = "openid profile email offline_access grok-cli:access api:access",
        deviceAuthorizationEndpoint: String? = "https://auth.x.ai/oauth2/device/code",
        tokenEndpoint: String? = "https://auth.x.ai/oauth2/token",
        revocationEndpoint: String? = "https://auth.x.ai/oauth2/revoke",
        trustedAuthHosts: List<String>? = listOf("auth.x.ai"),
        trustedVerificationHosts: List<String>? = listOf("accounts.x.ai", "x.ai"),
        resourceBaseUrl: String? = "https://cli-chat-proxy.grok.com/v1",
        requiredHeaders: Map<String, String>? = mapOf("x-grok-client-version" to "1.0.4"),
        modelsPath: String? = "/models",
        chatPath: String? = "/chat/completions",
        responsesPath: String? = "/responses",
        apiBackend: String? = "responses",
        pollIntervalSeconds: Int? = 5,
        pollTimeoutSeconds: Int? = 1800,
        minAppVersion: Map<String, String>? = mapOf("android" to "1.2.6"),
        disabledNotice: String? = null,
    ) = RawGrokSubscriptionAuth(
        enabled = enabled,
        flow = flow,
        clientId = clientId,
        scopes = scopes,
        deviceAuthorizationEndpoint = deviceAuthorizationEndpoint,
        tokenEndpoint = tokenEndpoint,
        revocationEndpoint = revocationEndpoint,
        trustedAuthHosts = trustedAuthHosts,
        trustedVerificationHosts = trustedVerificationHosts,
        resourceBaseUrl = resourceBaseUrl,
        requiredHeaders = requiredHeaders,
        modelsPath = modelsPath,
        chatPath = chatPath,
        responsesPath = responsesPath,
        apiBackend = apiBackend,
        pollIntervalSeconds = pollIntervalSeconds,
        pollTimeoutSeconds = pollTimeoutSeconds,
        minAppVersion = minAppVersion,
        disabledNotice = disabledNotice,
    )

    private fun resolvedConfig(
        raw: RawGrokSubscriptionAuth,
        appVersion: String = "1.2.6",
    ): GrokSubscriptionAuthConfig? =
        (GrokSubscriptionAuthResolver.resolve(raw, appVersion) as? GrokSubscriptionAvailability.Available)
            ?.config

    // ── Real catalog payload, end to end ──

    /**
     * The grok entry exactly as the model catalog serves it.
     *
     * Every other case below starts from a **hand-built** Raw, which can only prove "given the right
     * values, the verdict is right"; it cannot prove "the JSON actually served decodes into a usable
     * configuration". Without that link, any mismatch in the decoding layer leaves every unit test
     * green while the entry point never appears on a device.
     *
     * So this one goes through the **production decode path**: the whole payload is fed to
     * `MetadataClient` (the same decode and publication boundary a 200 response goes through), and
     * then the production method `grokSubscriptionAvailability()` is asked for the answer.
     */
    @Test
    fun `the real providerConfig decodes into a usable config through the production decode path`() {
        MetadataTestFixtures.applyRaw(PRODUCTION_METADATA_PAYLOAD)

        val availability = MetadataClient.instance.grokSubscriptionAvailability(appVersion = "1.2.6")
        val config = (availability as? GrokSubscriptionAvailability.Available)?.config
        assertNotNull("the catalog payload was not judged available, got $availability", config)
        requireNotNull(config)

        assertEquals("https://cli-chat-proxy.grok.com/v1", config.resourceBaseUrl)
        assertEquals("https://cli-chat-proxy.grok.com/v1/models", config.modelsUrl)
        assertEquals("https://cli-chat-proxy.grok.com/v1/chat/completions", config.chatUrl)
        assertEquals("https://cli-chat-proxy.grok.com/v1/responses", config.responsesUrl)
        assertEquals("1.0.4", config.requiredHeaders["x-grok-client-version"])
        assertEquals("oriveo", config.requiredHeaders["x-grok-client-identifier"])
        assertEquals("b1a00492-073a-47ea-816f-4c329264a828", config.clientId)
    }

    /**
     * The served payload currently carries **only `minAppVersion.ios`** and no `android` key.
     *
     * Getting "missing platform key means no gate" wrong fails almost invisibly: the entry point
     * disappears on every Android device while the parsing unit tests stay green. That is why the
     * real payload is pinned once on its own.
     */
    @Test
    fun `a payload with no android version key imposes no gate`() {
        MetadataTestFixtures.applyRaw(PRODUCTION_METADATA_PAYLOAD)

        // A version far below the ios floor: if the ios key were read by mistake, this would be
        // judged disabled.
        val availability = MetadataClient.instance.grokSubscriptionAvailability(appVersion = "0.0.1")
        assertTrue(
            "a missing android key must count as no gate, got $availability",
            availability is GrokSubscriptionAvailability.Available,
        )
    }

    /** A neighbouring provider entry with no `protocolFeatures` must not disturb decoding. */
    @Test
    fun `a provider entry in the snapshot without protocolFeatures does not affect decoding`() {
        MetadataTestFixtures.applyRaw(PRODUCTION_METADATA_PAYLOAD)
        val configs = MetadataClient.instance.listPublicProviderConfigs()
        assertTrue(configs.any { it.kind == "openAI" })
        assertTrue(configs.any { it.kind == "grok" })
    }

    @Test
    fun `a snapshot with no grok entry returns unavailable`() {
        MetadataTestFixtures.applyRaw("""{"version":1,"providers":{},"providerConfigs":[]}""")
        assertEquals(
            GrokSubscriptionAvailability.Unavailable,
            MetadataClient.instance.grokSubscriptionAvailability(appVersion = "1.2.6"),
        )
    }

    // ── The three availability states ──

    @Test
    fun `with nothing served the entry point does not appear at all, rather than degrading to a dead button`() {
        assertEquals(
            GrokSubscriptionAvailability.Unavailable,
            GrokSubscriptionAuthResolver.resolve(null, "1.2.6"),
        )
    }

    @Test
    fun `a closed kill switch resolves to disabled rather than unavailable so connected users see the reason`() {
        val result = GrokSubscriptionAuthResolver.resolve(
            makeRaw(enabled = false, disabledNotice = "Temporarily unavailable on the xAI side"),
            "1.2.6",
        )
        assertEquals(GrokSubscriptionAvailability.Disabled("Temporarily unavailable on the xAI side"), result)
    }

    @Test
    fun `an unrecognised flow steps aside rather than driving a new scheme with the device code logic`() {
        assertEquals(
            GrokSubscriptionAvailability.Unavailable,
            GrokSubscriptionAuthResolver.resolve(makeRaw(flow = "pkce_authorization_code"), "1.2.6"),
        )
    }

    @Test
    fun `a complete configuration parses out every field`() {
        val config = requireNotNull(resolvedConfig(makeRaw()))
        assertEquals("b1a00492-073a-47ea-816f-4c329264a828", config.clientId)
        assertEquals("https://auth.x.ai/oauth2/token", config.tokenEndpoint)
        assertEquals("https://auth.x.ai/oauth2/device/code", config.deviceAuthorizationEndpoint)
        assertEquals("https://cli-chat-proxy.grok.com/v1", config.resourceBaseUrl)
        assertEquals("1.0.4", config.requiredHeaders["x-grok-client-version"])
        assertEquals(5, config.pollIntervalSeconds)
        assertEquals(1800, config.pollTimeoutSeconds)
    }

    // ── Any missing required field degrades the whole config ──

    @Test
    fun `one missing required field degrades to unavailable instead of stranding the user halfway`() {
        val cases = mapOf(
            "clientId" to makeRaw(clientId = null),
            "scopes" to makeRaw(scopes = null),
            "resourceBaseURL" to makeRaw(resourceBaseUrl = null),
            "deviceAuthorizationEndpoint" to makeRaw(deviceAuthorizationEndpoint = null),
            "tokenEndpoint" to makeRaw(tokenEndpoint = null),
            "trustedAuthHosts" to makeRaw(trustedAuthHosts = emptyList()),
            "trustedVerificationHosts" to makeRaw(trustedVerificationHosts = emptyList()),
        )
        cases.forEach { (field, raw) ->
            assertEquals(
                "missing $field should degrade to unavailable",
                GrokSubscriptionAvailability.Unavailable,
                GrokSubscriptionAuthResolver.resolve(raw, "1.2.6"),
            )
        }
    }

    @Test
    fun `the revocation endpoint is optional, one missing optional endpoint must not disable the whole flow`() {
        val config = requireNotNull(resolvedConfig(makeRaw(revocationEndpoint = null)))
        assertNull(config.revocationEndpoint)
    }

    // ── Endpoint validation, the line of defence against a tampered configuration ──

    @Test
    fun `an endpoint whose host is not on the trusted list is rejected, the gate against phishing redirects`() {
        assertEquals(
            GrokSubscriptionAvailability.Unavailable,
            GrokSubscriptionAuthResolver.resolve(
                makeRaw(tokenEndpoint = "https://evil.example.com/oauth2/token"), "1.2.6",
            ),
        )
    }

    @Test
    fun `a non-https endpoint is rejected`() {
        assertEquals(
            GrokSubscriptionAvailability.Unavailable,
            GrokSubscriptionAuthResolver.resolve(
                makeRaw(tokenEndpoint = "http://auth.x.ai/oauth2/token"), "1.2.6",
            ),
        )
    }

    @Test
    fun `a URL carrying credentials or a rewritten port is rejected`() {
        assertEquals(
            GrokSubscriptionAvailability.Unavailable,
            GrokSubscriptionAuthResolver.resolve(
                makeRaw(tokenEndpoint = "https://user:pass@auth.x.ai/oauth2/token"), "1.2.6",
            ),
        )
        assertEquals(
            GrokSubscriptionAvailability.Unavailable,
            GrokSubscriptionAuthResolver.resolve(
                makeRaw(tokenEndpoint = "https://auth.x.ai:8443/oauth2/token"), "1.2.6",
            ),
        )
    }

    @Test
    fun `the authorization page URL is checked against the verification allow-list, subdomains pass and other domains do not`() {
        val config = requireNotNull(resolvedConfig(makeRaw()))
        assertTrue(config.allowsVerificationUrl("https://accounts.x.ai/oauth2/device?user_code=AAAA-BBBB"))
        assertTrue(config.allowsVerificationUrl("https://login.x.ai/device"))
        assertFalse(config.allowsVerificationUrl("https://accounts.x.ai.evil.com/device"))
        assertFalse(config.allowsVerificationUrl("http://accounts.x.ai/device"))
        assertFalse(config.allowsVerificationUrl("https://evil.com/device"))
        assertFalse(config.allowsVerificationUrl("https://user:pass@accounts.x.ai/device"))
        assertFalse(config.allowsVerificationUrl(null))
    }

    /**
     * Regression sentinel for the 404 that hit the very first message on a real device.
     *
     * The first version swapped only the baseURL for the subscription CLI proxy while the chat path
     * still came from `providers.grok.transport`, where the base URL is `https://api.x.ai` and the
     * path is `/v1/chat/completions`. The two sides disagree about who owns the `/v1` segment, so
     * the join produced `.../v1/v1/chat/completions` and upstream answered nothing but a 404. The
     * catalog fetch got away with it because it has its own modelsPath, which is why the problem
     * stayed hidden until a message was actually sent.
     */
    @Test
    fun `the chat and catalog URLs are joined from the served paths with no duplicated v1 segment`() {
        val config = requireNotNull(resolvedConfig(makeRaw()))
        assertEquals("https://cli-chat-proxy.grok.com/v1/chat/completions", config.chatUrl)
        assertFalse(config.chatUrl.contains("/v1/v1"))
        assertEquals("https://cli-chat-proxy.grok.com/v1/models", config.modelsUrl)
        assertFalse(config.modelsUrl.contains("/v1/v1"))
    }

    @Test
    fun `missing paths fall back to defaults instead of breaking the whole path`() {
        val config = requireNotNull(resolvedConfig(makeRaw(modelsPath = null, chatPath = null)))
        assertEquals("https://cli-chat-proxy.grok.com/v1/models", config.modelsUrl)
        assertEquals("https://cli-chat-proxy.grok.com/v1/chat/completions", config.chatUrl)
    }

    @Test
    fun `a trailing slash on resourceBaseURL still joins without a double slash`() {
        val config = requireNotNull(
            resolvedConfig(makeRaw(resourceBaseUrl = "https://cli-chat-proxy.grok.com/v1/"))
        )
        assertEquals("https://cli-chat-proxy.grok.com/v1/models", config.modelsUrl)
    }

    @Test
    fun `a missing polling cadence falls back to the built-in values`() {
        val config = requireNotNull(
            resolvedConfig(makeRaw(pollIntervalSeconds = null, pollTimeoutSeconds = null))
        )
        assertEquals(5, config.pollIntervalSeconds)
        assertEquals(1800, config.pollTimeoutSeconds)
    }

    // ── Version gate ──

    @Test
    fun `a client below minAppVersion steps aside as disabled rather than silently unavailable`() {
        val result = GrokSubscriptionAuthResolver.resolve(
            makeRaw(minAppVersion = mapOf("android" to "1.3.0"), disabledNotice = "Please update the app"),
            "1.2.7",
        )
        assertEquals(GrokSubscriptionAvailability.Disabled("Please update the app"), result)
    }

    @Test
    fun `a version equal to or above minAppVersion passes`() {
        assertNotNull(resolvedConfig(makeRaw(), appVersion = "1.2.6"))
        assertNotNull(resolvedConfig(makeRaw(), appVersion = "1.3.0"))
    }

    /** The gate reads the `android` key; a payload carrying only the ios key means no gate here. */
    @Test
    fun `the version gate only honours the android key`() {
        assertNotNull(
            "reading the ios key by mistake would lock this app out forever under the served payload",
            resolvedConfig(makeRaw(minAppVersion = mapOf("ios" to "9.9.9")), appVersion = "1.0.0"),
        )
        // And the other way round: an android key that is present must take effect, it must not be
        // waved through just because the ios key would have passed.
        assertEquals(
            GrokSubscriptionAvailability.Disabled(null),
            GrokSubscriptionAuthResolver.resolve(
                makeRaw(minAppVersion = mapOf("ios" to "0.0.1", "android" to "9.9.9")),
                "1.0.0",
            ),
        )
    }

    @Test
    fun `versions compare segment by segment and never as strings`() {
        // A string comparison would rule 1.2.10 < 1.2.9, so the newer build would be the one locked out.
        assertEquals(1, GrokSubscriptionAuthResolver.compareVersions("1.2.10", "1.2.9"))
        assertEquals(0, GrokSubscriptionAuthResolver.compareVersions("1.2.7", "1.2.7"))
        assertEquals(0, GrokSubscriptionAuthResolver.compareVersions("1.2", "1.2.0"))
        assertEquals(-1, GrokSubscriptionAuthResolver.compareVersions("0.9.9", "1.0.0"))
        assertEquals(0, GrokSubscriptionAuthResolver.compareVersions("1.2.7-beta", "1.2.7"))
    }

    // ── Translating upstream failures ──

    @Test
    fun `the intermediate device code states arrive as a 400 plus an error code, and reading the status alone kills the flow`() {
        assertEquals(GrokSubscriptionError.AuthorizationPending, mapped(400, """{"error":"authorization_pending"}"""))
        assertEquals(GrokSubscriptionError.SlowDown, mapped(400, """{"error":"slow_down"}"""))
        assertEquals(GrokSubscriptionError.CodeExpired, mapped(400, """{"error":"expired_token"}"""))
        assertEquals(GrokSubscriptionError.AccessDenied, mapped(400, """{"error":"access_denied"}"""))
    }

    @Test
    fun `the four hard failures each map to their own meaning and must not collapse into one generic error`() {
        assertEquals(GrokSubscriptionError.ClientVersionRejected, mapped(426, ""))
        assertEquals(GrokSubscriptionError.SubscriptionNotEligible, mapped(403, ""))
        assertEquals(GrokSubscriptionError.Unauthorized, mapped(401, ""))
        assertEquals(GrokSubscriptionError.QuotaExhausted, mapped(429, ""))
    }

    @Test
    fun `only 426 forces a configuration refresh, it is the one early signal that xAI changed something`() {
        assertTrue(GrokSubscriptionError.ClientVersionRejected.requiresConfigRefresh)
        assertFalse(GrokSubscriptionError.SubscriptionNotEligible.requiresConfigRefresh)
        assertFalse(GrokSubscriptionError.Unauthorized.requiresConfigRefresh)
        assertFalse(GrokSubscriptionError.QuotaExhausted.requiresConfigRefresh)
    }

    @Test
    fun `dead-end failures offer no retry button so users do not tap in vain`() {
        assertTrue(GrokSubscriptionError.CodeExpired.allowsRetry)
        assertTrue(GrokSubscriptionError.AccessDenied.allowsRetry)
        assertTrue(GrokSubscriptionError.Transport("offline").allowsRetry)
        assertFalse(GrokSubscriptionError.SubscriptionNotEligible.allowsRetry)
        assertFalse(GrokSubscriptionError.QuotaExhausted.allowsRetry)
        assertFalse(GrokSubscriptionError.ClientVersionRejected.allowsRetry)
    }

    private fun mapped(status: Int, body: String) =
        GrokSubscriptionOAuthClient.mapFailure(status, body)

    // ── When to renew ──

    @Test
    fun `renewal starts 5 minutes before expiry, avoiding the random 401 where a token is valid at check time and expired on arrival`() {
        val now = 1_000_000_000L
        val tokens = GrokSubscriptionTokens(
            accessToken = "a",
            refreshToken = "r",
            expiresAt = now + 4 * 60 * 1000L, // expires in four minutes
            obtainedAt = now,
        )
        assertTrue(tokens.needsRefresh(now))
    }

    @Test
    fun `nothing is renewed while expiry is still far off`() {
        val now = 1_000_000_000L
        val tokens = GrokSubscriptionTokens(
            accessToken = "a",
            refreshToken = "r",
            expiresAt = now + 60 * 60 * 1000L,
            obtainedAt = now,
        )
        assertFalse(tokens.needsRefresh(now))
    }

    @Test
    fun `with no expiry from upstream nothing is renewed eagerly, rather than refreshing on every request`() {
        val tokens = GrokSubscriptionTokens(accessToken = "a", refreshToken = "r", expiresAt = null)
        assertFalse(tokens.needsRefresh(System.currentTimeMillis()))
    }

    private companion object {
        /**
         * The grok entry copied verbatim from the model catalog, together with a neighbouring entry
         * that has no `protocolFeatures`, which pins that a neighbour missing fields does not affect
         * decoding.
         */
        val PRODUCTION_METADATA_PAYLOAD = """
        {
          "version": 1,
          "providers": {},
          "providerConfigs": [
            {
              "kind": "openAI",
              "displayName": "OpenAI",
              "defaultBaseURL": "https://api.openai.com/v1"
            },
            {
              "kind": "grok",
              "displayName": "Grok",
              "defaultBaseURL": "https://api.x.ai/v1",
              "apiProtocol": "openai_compatible",
              "category": "direct",
              "supportsAutoSync": true,
              "sortOrder": 13,
              "protocolFeatures": {
                "authMethod": "bearer",
                "subscriptionAuth": {
                  "clientId": "b1a00492-073a-47ea-816f-4c329264a828",
                  "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
                  "disabledNotice": null,
                  "enabled": true,
                  "flow": "oauth_device_code",
                  "minAppVersion": {"ios": "1.2.6"},
                  "modelsPath": "/models",
                  "chatPath": "/chat/completions",
                  "pollIntervalSeconds": 5,
                  "pollTimeoutSeconds": 1800,
                  "requiredHeaders": {
                    "x-grok-client-identifier": "oriveo",
                    "x-grok-client-surface": "grok-build",
                    "x-grok-client-version": "1.0.4",
                    "x-xai-token-auth": "xai-grok-cli"
                  },
                  "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1",
                  "revocationEndpoint": "https://auth.x.ai/oauth2/revoke",
                  "scopes": "openid profile email offline_access grok-cli:access api:access",
                  "tokenEndpoint": "https://auth.x.ai/oauth2/token",
                  "trustedAuthHosts": ["auth.x.ai"],
                  "trustedVerificationHosts": ["accounts.x.ai", "x.ai"]
                }
              }
            }
          ]
        }
        """.trimIndent()
    }
}
