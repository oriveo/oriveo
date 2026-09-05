package ai.oriveo.community.core.provider.openai

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic contract for parsing the Codex (ChatGPT subscription sign-in) configuration.
 *
 * Nothing here touches the network: the three availability states, the host allow-list, the
 * version gate and the URL joining are all decidable offline, and they are exactly the parts
 * that are easiest to get quietly wrong - on a real device such a mistake shows up only as
 * "the entry point never appears". Whether an endpoint is actually reachable, or whether the
 * upstream accepts a given parameter, is a question only real traffic can answer, and these
 * tests do not pretend to cover it.
 */
class OpenAISubscriptionAuthTest {

    // ── Fixtures ──

    /**
     * The openAI subscription section exactly as the model catalog serves it, copied verbatim.
     *
     * Hand-rolled raw fixtures cannot prove the real payload works: misspell a single field name
     * (`redirectURI` written as `redirectUri`), or leave one host out of the allow-list, and the
     * hand-rolled cases still go green while the real payload resolves to unavailable and the
     * entry point simply disappears.
     */
    private val productionSubscriptionAuth = """
        {"chatPath":"/responses","clientId":"app_EMoamEEZ73f0CkXaXp7hrann","deviceAuthorizationEndpoint":"https://auth.openai.com/api/accounts/deviceauth/usercode","deviceTokenEndpoint":"https://auth.openai.com/api/accounts/deviceauth/token","disabledNotice":null,"enabled":true,"flow":"codex_device_code","minAppVersion":{"ios":"1.2.6"},"modelsPath":"/models","pollIntervalSeconds":5,"pollTimeoutSeconds":900,"redirectURI":"https://auth.openai.com/deviceauth/callback","requiredHeaders":{"OpenAI-Beta":"responses=experimental","originator":"oriveo","version":"0.148.0"},"resourceBaseURL":"https://chatgpt.com/backend-api/codex","tokenEndpoint":"https://auth.openai.com/oauth/token","trustedAuthHosts":["auth.openai.com"],"trustedVerificationHosts":["auth.openai.com"],"verificationURL":"https://auth.openai.com/codex/device"}
    """.trimIndent()

    /**
     * Same configuration as the `Json{}` instance inside `MetadataClient`.
     *
     * `coerceInputValues` is not optional: the real payload carries `"disabledNotice":null`, and
     * kotlinx throws by default when an explicit null is assigned to a non-nullable field, so
     * without this one flag the entire section fails to decode. What gets pinned here is the real
     * decoding boundary - the serializer plus the resolver.
     */
    private val metadataJson = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    /** Decodes the whole `protocolFeatures` section, the same entry shape MetadataClient uses. */
    private fun productionRaw(): RawOpenAISubscriptionAuth {
        val features = metadataJson.decodeFromString(
            RawOpenAIProtocolFeatures.serializer(),
            """{"authMethod":"bearer","subscriptionAuth":$productionSubscriptionAuth}""",
        )
        return requireNotNull(features.subscriptionAuth) { "the catalog payload decoded without a subscriptionAuth section" }
    }

    /** Same shape the catalog serves; each case changes only the one field it is about. */
    private fun makeRaw(
        enabled: Boolean? = true,
        flow: String? = "codex_device_code",
        clientId: String? = "app_EMoamEEZ73f0CkXaXp7hrann",
        deviceAuthorizationEndpoint: String? = "https://auth.openai.com/api/accounts/deviceauth/usercode",
        deviceTokenEndpoint: String? = "https://auth.openai.com/api/accounts/deviceauth/token",
        tokenEndpoint: String? = "https://auth.openai.com/oauth/token",
        verificationUrl: String? = "https://auth.openai.com/codex/device",
        redirectUri: String? = "https://auth.openai.com/deviceauth/callback",
        trustedAuthHosts: List<String>? = listOf("auth.openai.com"),
        trustedVerificationHosts: List<String>? = listOf("auth.openai.com"),
        resourceBaseUrl: String? = "https://chatgpt.com/backend-api/codex",
        requiredHeaders: Map<String, String>? = mapOf(
            "OpenAI-Beta" to "responses=experimental",
            "originator" to "oriveo",
            "version" to "0.148.0",
        ),
        modelsPath: String? = "/models",
        chatPath: String? = "/responses",
        pollIntervalSeconds: Int? = 5,
        pollTimeoutSeconds: Int? = 900,
        minAppVersion: Map<String, String>? = mapOf("ios" to "1.2.6"),
        disabledNotice: String? = null,
    ) = RawOpenAISubscriptionAuth(
        enabled = enabled,
        flow = flow,
        clientId = clientId,
        deviceAuthorizationEndpoint = deviceAuthorizationEndpoint,
        deviceTokenEndpoint = deviceTokenEndpoint,
        tokenEndpoint = tokenEndpoint,
        verificationUrl = verificationUrl,
        redirectUri = redirectUri,
        trustedAuthHosts = trustedAuthHosts,
        trustedVerificationHosts = trustedVerificationHosts,
        resourceBaseUrl = resourceBaseUrl,
        requiredHeaders = requiredHeaders,
        modelsPath = modelsPath,
        chatPath = chatPath,
        pollIntervalSeconds = pollIntervalSeconds,
        pollTimeoutSeconds = pollTimeoutSeconds,
        minAppVersion = minAppVersion,
        disabledNotice = disabledNotice,
    )

    private fun resolvedConfig(
        raw: RawOpenAISubscriptionAuth,
        appVersion: String = "1.2.6",
    ): OpenAISubscriptionAuthConfig? =
        (OpenAISubscriptionAuthResolver.resolve(raw, appVersion) as? OpenAISubscriptionAvailability.Available)
            ?.config

    // ── Real catalog payload, end to end ──

    @Test
    fun `the real providerConfig decodes into a usable config through the production decode path`() {
        val availability = OpenAISubscriptionAuthResolver.resolve(productionRaw(), appVersion = "1.2.6")
        val config = (availability as? OpenAISubscriptionAvailability.Available)?.config
        assertNotNull("the catalog payload was not judged available, got $availability", config)
        requireNotNull(config)

        assertEquals("app_EMoamEEZ73f0CkXaXp7hrann", config.clientId)
        assertEquals(
            "https://auth.openai.com/api/accounts/deviceauth/usercode",
            config.deviceAuthorizationEndpoint,
        )
        assertEquals("https://auth.openai.com/api/accounts/deviceauth/token", config.deviceTokenEndpoint)
        assertEquals("https://auth.openai.com/oauth/token", config.tokenEndpoint)
        assertEquals("https://auth.openai.com/deviceauth/callback", config.redirectUri)
        assertEquals("https://auth.openai.com/codex/device", config.verificationUrl)
        assertEquals("https://chatgpt.com/backend-api/codex", config.resourceBaseUrl)
        assertEquals("responses=experimental", config.requiredHeaders["OpenAI-Beta"])
        assertEquals("oriveo", config.requiredHeaders["originator"])
        assertEquals("0.148.0", config.requiredHeaders["version"])
        assertEquals(5, config.pollIntervalSeconds)
        assertEquals(900, config.pollTimeoutSeconds)
    }

    @Test
    fun `URLs built from the real payload land on the Codex backend paths with no duplicated or dropped segment`() {
        val config = requireNotNull(resolvedConfig(productionRaw()))
        assertEquals("https://chatgpt.com/backend-api/codex/responses", config.responsesUrl)
        assertEquals("https://chatgpt.com/backend-api/codex/models", config.modelsUrl)
        // Grok once produced a /v1/v1 404 exactly here: joining happens once, at config resolution.
        assertFalse(config.responsesUrl.contains("/codex/codex"))
    }

    @Test
    fun `the catalog URL must carry client_version taken from the served version header, or upstream answers 400`() {
        val config = requireNotNull(resolvedConfig(productionRaw()))
        assertEquals(
            "https://chatgpt.com/backend-api/codex/models?client_version=0.148.0",
            config.modelsUrlWithClientVersion,
        )
    }

    /**
     * The served payload currently carries **only `minAppVersion.ios`** and no `android` key.
     *
     * Getting "missing platform key means no gate" wrong fails almost invisibly: the entry point
     * vanishes on every Android device while every other parsing case stays green. That is why the
     * real payload is pinned once on its own.
     */
    @Test
    fun `a payload with no android version key imposes no gate`() {
        val availability = OpenAISubscriptionAuthResolver.resolve(productionRaw(), appVersion = "0.0.1")
        assertTrue(
            "a missing android key must count as no gate, got $availability",
            availability is OpenAISubscriptionAvailability.Available,
        )
    }

    @Test
    fun `the platform key on this app is android`() {
        assertEquals("android", OpenAISubscriptionAuthResolver.PLATFORM_KEY)
    }

    // ── The three availability states ──

    @Test
    fun `a catalog with no subscription section hides the entry point instead of leaving a dead button`() {
        assertEquals(
            OpenAISubscriptionAvailability.Unavailable,
            OpenAISubscriptionAuthResolver.resolve(null, "1.2.6"),
        )
    }

    @Test
    fun `an unrecognised flow steps aside rather than driving a new scheme with the two-leg device code logic`() {
        // Grok's oauth_device_code is single-leg: running Codex on that logic falls apart on the first poll.
        assertEquals(
            OpenAISubscriptionAvailability.Unavailable,
            OpenAISubscriptionAuthResolver.resolve(makeRaw(flow = "oauth_device_code"), "1.2.6"),
        )
        assertEquals(
            OpenAISubscriptionAvailability.Unavailable,
            OpenAISubscriptionAuthResolver.resolve(makeRaw(flow = null), "1.2.6"),
        )
    }

    @Test
    fun `a closed kill switch resolves to disabled rather than unavailable so connected users see the reason`() {
        val result = OpenAISubscriptionAuthResolver.resolve(
            makeRaw(enabled = false, disabledNotice = "Adapting to OpenAI's latest release"),
            "1.2.6",
        )
        assertEquals(OpenAISubscriptionAvailability.Disabled("Adapting to OpenAI's latest release"), result)
    }

    @Test
    fun `a client below minAppVersion steps aside as disabled rather than silently unavailable`() {
        val result = OpenAISubscriptionAuthResolver.resolve(
            makeRaw(minAppVersion = mapOf("android" to "1.3.0"), disabledNotice = "Please update the app"),
            "1.2.9",
        )
        assertEquals(OpenAISubscriptionAvailability.Disabled("Please update the app"), result)
    }

    @Test
    fun `versions compare segment by segment and never as strings, so 1_2_10 outranks 1_2_9`() {
        val availability = OpenAISubscriptionAuthResolver.resolve(
            makeRaw(minAppVersion = mapOf("android" to "1.2.9")),
            "1.2.10",
        )
        assertTrue(
            "1.2.10 should satisfy a 1.2.9 gate, got $availability",
            availability is OpenAISubscriptionAvailability.Available,
        )
    }

    @Test
    fun `a blank version key counts as no gate`() {
        val availability = OpenAISubscriptionAuthResolver.resolve(
            makeRaw(minAppVersion = mapOf("android" to "  ")),
            "0.0.1",
        )
        assertTrue(availability is OpenAISubscriptionAvailability.Available)
    }

    // ── Any missing required field degrades the whole config ──

    @Test
    fun `one missing required field degrades to unavailable instead of stranding the user halfway`() {
        val cases = mapOf(
            "clientId" to makeRaw(clientId = null),
            "deviceAuthorizationEndpoint" to makeRaw(deviceAuthorizationEndpoint = null),
            "deviceTokenEndpoint" to makeRaw(deviceTokenEndpoint = null),
            "tokenEndpoint" to makeRaw(tokenEndpoint = null),
            "redirectURI" to makeRaw(redirectUri = null),
            "verificationURL" to makeRaw(verificationUrl = null),
            "resourceBaseURL" to makeRaw(resourceBaseUrl = null),
            "trustedAuthHosts" to makeRaw(trustedAuthHosts = emptyList()),
            "trustedVerificationHosts" to makeRaw(trustedVerificationHosts = emptyList()),
        )
        cases.forEach { (field, raw) ->
            assertEquals(
                "missing $field should degrade to unavailable",
                OpenAISubscriptionAvailability.Unavailable,
                OpenAISubscriptionAuthResolver.resolve(raw, "1.2.6"),
            )
        }
    }

    // ── Security gates ──

    @Test
    fun `an auth endpoint whose host is not on the trusted list is rejected, the gate against phishing redirects`() {
        val cases = mapOf(
            "deviceAuthorizationEndpoint" to makeRaw(
                deviceAuthorizationEndpoint = "https://auth.openai.com.evil.test/usercode",
            ),
            "deviceTokenEndpoint" to makeRaw(
                deviceTokenEndpoint = "https://evil.test/api/accounts/deviceauth/token",
            ),
            "tokenEndpoint" to makeRaw(tokenEndpoint = "https://auth.openai.com.evil.test/oauth/token"),
            "redirectURI" to makeRaw(redirectUri = "https://evil.test/deviceauth/callback"),
            "verificationURL" to makeRaw(verificationUrl = "https://evil.test/codex/device"),
        )
        cases.forEach { (field, raw) ->
            assertEquals(
                "$field outside the allow-list should degrade to unavailable",
                OpenAISubscriptionAvailability.Unavailable,
                OpenAISubscriptionAuthResolver.resolve(raw, "1.2.6"),
            )
        }
    }

    /**
     * `resourceBaseURL` decides where the access token is sent, so one rewritten value is one
     * leaked credential. The allow-list holds `chatgpt.com` alone and demands an **exact** match:
     * admitting subdomains has no legitimate use here.
     */
    @Test
    fun `resourceBaseURL host must equal chatgpt_com exactly, subdomains and lookalikes are rejected`() {
        listOf("evil.chatgpt.com", "chatgpt.com.evil.test", "api.openai.com").forEach { host ->
            assertEquals(
                "$host is not the Codex backend, it should degrade to unavailable",
                OpenAISubscriptionAvailability.Unavailable,
                OpenAISubscriptionAuthResolver.resolve(
                    makeRaw(resourceBaseUrl = "https://$host/backend-api/codex"),
                    "1.2.6",
                ),
            )
        }
    }

    @Test
    fun `a URL carrying credentials or a rewritten port is rejected`() {
        // The host of https://user:pass@auth.openai.com/... is still auth.openai.com, so comparing
        // hosts alone would wave it through.
        assertEquals(
            OpenAISubscriptionAvailability.Unavailable,
            OpenAISubscriptionAuthResolver.resolve(
                makeRaw(tokenEndpoint = "https://user:pass@auth.openai.com/oauth/token"),
                "1.2.6",
            ),
        )
        assertEquals(
            OpenAISubscriptionAvailability.Unavailable,
            OpenAISubscriptionAuthResolver.resolve(
                makeRaw(tokenEndpoint = "https://auth.openai.com:8443/oauth/token"),
                "1.2.6",
            ),
        )
    }

    @Test
    fun `plaintext http is rejected`() {
        assertEquals(
            OpenAISubscriptionAvailability.Unavailable,
            OpenAISubscriptionAuthResolver.resolve(
                makeRaw(resourceBaseUrl = "http://chatgpt.com/backend-api/codex"),
                "1.2.6",
            ),
        )
        assertEquals(
            OpenAISubscriptionAvailability.Unavailable,
            OpenAISubscriptionAuthResolver.resolve(
                makeRaw(tokenEndpoint = "http://auth.openai.com/oauth/token"),
                "1.2.6",
            ),
        )
    }

    // ── Joining and fallbacks ──

    @Test
    fun `missing modelsPath and chatPath fall back to defaults instead of breaking the whole path`() {
        val config = requireNotNull(resolvedConfig(makeRaw(modelsPath = null, chatPath = null)))
        assertEquals("https://chatgpt.com/backend-api/codex/models", config.modelsUrl)
        assertEquals("https://chatgpt.com/backend-api/codex/responses", config.responsesUrl)
    }

    @Test
    fun `a trailing slash on resourceBaseURL still joins without a double slash`() {
        val config = requireNotNull(
            resolvedConfig(makeRaw(resourceBaseUrl = "https://chatgpt.com/backend-api/codex/"))
        )
        assertEquals("https://chatgpt.com/backend-api/codex/responses", config.responsesUrl)
    }

    @Test
    fun `a path missing its leading slash gets one, so the result is not codexmodels`() {
        val config = requireNotNull(resolvedConfig(makeRaw(modelsPath = "models")))
        assertEquals("https://chatgpt.com/backend-api/codex/models", config.modelsUrl)
    }

    @Test
    fun `polling cadence is clamped to its floor, refusing a 0 second interval or a 1 second timeout`() {
        val config = requireNotNull(
            resolvedConfig(makeRaw(pollIntervalSeconds = 0, pollTimeoutSeconds = 1))
        )
        assertEquals(1, config.pollIntervalSeconds)
        assertEquals(60, config.pollTimeoutSeconds)
    }

    @Test
    fun `with no version header served the catalog URL is returned as is rather than hardcoding one`() {
        val config = requireNotNull(
            resolvedConfig(makeRaw(requiredHeaders = mapOf("originator" to "oriveo")))
        )
        assertEquals("https://chatgpt.com/backend-api/codex/models", config.modelsUrlWithClientVersion)
    }

    @Test
    fun `the authorization page URL is checked against the verification allow-list, subdomains pass and other domains do not`() {
        val config = requireNotNull(resolvedConfig(productionRaw()))
        assertTrue(config.allowsVerificationUrl("https://auth.openai.com/codex/device"))
        assertTrue(config.allowsVerificationUrl("https://sub.auth.openai.com/codex/device"))
        assertFalse(config.allowsVerificationUrl("https://auth.openai.com.evil.test/x"))
        assertFalse(config.allowsVerificationUrl("http://auth.openai.com/codex/device"))
        assertFalse(config.allowsVerificationUrl(null))
    }

    @Test
    fun `the outbound context carries only the fully joined URL and the resolved accountId`() {
        val config = requireNotNull(resolvedConfig(productionRaw()))
        val context = OpenAISubscriptionRequestContext(
            responsesUrl = config.responsesUrl,
            accountId = "acct-1",
            requiredHeaders = config.requiredHeaders,
        )
        assertEquals("https://chatgpt.com/backend-api/codex/responses", context.responsesUrl)
        assertEquals("acct-1", context.accountId)
        assertEquals("oriveo", context.requiredHeaders["originator"])
    }
}
