package ai.oriveo.community.core.provider.openai

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.provider.MetadataTestFixtures
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whether the Codex subscription entry point can appear at the **real metadata decode entry**.
 *
 * `OpenAISubscriptionAuthTest` only reaches the serializer plus resolver boundary, which cannot
 * prove that once a catalog snapshot arrives `MetadataClient` really pulls this section out of
 * `providerConfigs[openAI]`. Read the wrong provider row, fail to wire `protocolFeatures` through,
 * or forget the companion forwarder, and that test stays green while on a real device the entry
 * point simply never shows up.
 *
 * So the whole snapshot is injected through `MetadataTestFixtures.applyRaw` and only what comes
 * back out of `MetadataClient` is asserted on.
 */
class OpenAISubscriptionMetadataTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `with an openAI subscription section in the snapshot MetadataClient resolves available and builds the catalog URL with client_version`() {
        MetadataTestFixtures.applyRaw(metadata(openAISubscriptionAuth()))

        val availability = MetadataClient.openAISubscriptionAvailability()

        val config = (availability as? OpenAISubscriptionAvailability.Available)?.config
        assertTrue("a snapshot shaped like the real one must resolve available, or the entry point will not appear on a device", config != null)
        requireNotNull(config)
        assertEquals("app_EMoamEEZ73f0CkXaXp7hrann", config.clientId)
        assertEquals("https://chatgpt.com/backend-api/codex/responses", config.responsesUrl)
        // /models without client_version always comes back 400 missing field client_version.
        assertEquals(
            "https://chatgpt.com/backend-api/codex/models?client_version=0.148.0",
            config.modelsUrlWithClientVersion,
        )
    }

    /**
     * The lookup reads the `providerConfigs[openAI]` row specifically, not "the first config in the
     * snapshot that happens to carry a subscriptionAuth".
     *
     * With only a grok section present the answer must be unavailable, otherwise the Codex entry
     * point would show up under OpenAI holding xAI's endpoints.
     */
    @Test
    fun `a snapshot holding only a grok subscription section leaves the Codex side unavailable`() {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "providers": {},
              "providerConfigs": [
                {
                  "kind": "grok",
                  "displayName": "Grok",
                  "defaultBaseURL": "https://api.x.ai/v1",
                  "protocolFeatures": {
                    "subscriptionAuth": {
                      "enabled": true,
                      "flow": "oauth_device_code",
                      "clientId": "grok-client",
                      "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
                      "tokenEndpoint": "https://auth.x.ai/oauth2/token",
                      "trustedAuthHosts": ["auth.x.ai"],
                      "trustedVerificationHosts": ["accounts.x.ai"],
                      "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1"
                    }
                  }
                }
              ]
            }
            """.trimIndent()
        )

        assertTrue(
            MetadataClient.openAISubscriptionAvailability() is OpenAISubscriptionAvailability.Unavailable,
        )
    }

    /** A snapshot with no providerConfigs at all hides the entry point, exactly as before this feature existed. */
    @Test
    fun `a snapshot without providerConfigs is unavailable`() {
        MetadataTestFixtures.applyRaw("""{"version":1,"providers":{}}""")

        assertTrue(
            MetadataClient.openAISubscriptionAvailability() is OpenAISubscriptionAvailability.Unavailable,
        )
    }

    /**
     * The kill switch keeps already connected instances in place; the detail page turns read-only and
     * shows the notice that came with the catalog. It is kept distinct from unavailable because "the
     * catalog never carried this section" and "someone deliberately turned it off" are two different
     * situations from the user's point of view.
     */
    @Test
    fun `enabled false resolves to disabled and carries the served notice`() {
        MetadataTestFixtures.applyRaw(
            metadata(
                openAISubscriptionAuth(
                    enabled = false,
                    disabledNotice = "\"Codex sign-in is under maintenance\"",
                )
            )
        )

        val availability = MetadataClient.openAISubscriptionAvailability()
        assertEquals(
            OpenAISubscriptionAvailability.Disabled("Codex sign-in is under maintenance"),
            availability,
        )
    }

    /**
     * The version gate reads `minAppVersion.android`, not the ios slot.
     *
     * The catalog currently carries only `{"ios": ...}`, so reading the wrong platform key shows up as
     * Android users being locked out by a floor that was never meant for them.
     */
    @Test
    fun `an android key in minAppVersion above the running version resolves to disabled`() {
        MetadataTestFixtures.applyRaw(
            metadata(openAISubscriptionAuth(minAppVersion = """{"ios":"1.2.6","android":"99.0.0"}"""))
        )

        assertTrue(
            MetadataClient.instance.openAISubscriptionAvailability(appVersion = "1.2.6")
                is OpenAISubscriptionAvailability.Disabled,
        )
        // Same snapshot: a version that clears the floor must pass, which proves the version gate is
        // what blocked it rather than some other field.
        assertTrue(
            MetadataClient.instance.openAISubscriptionAvailability(appVersion = "99.0.0")
                is OpenAISubscriptionAvailability.Available,
        )
    }

    private fun metadata(subscriptionAuth: String): String = """
        {
          "version": 1,
          "providers": {},
          "providerConfigs": [
            {
              "kind": "openAI",
              "displayName": "OpenAI",
              "defaultBaseURL": "https://api.openai.com/v1",
              "protocolFeatures": {
                "authMethod": "bearer",
                "subscriptionAuth": $subscriptionAuth
              }
            }
          ]
        }
    """.trimIndent()

    /**
     * The openAI subscription section exactly as the catalog serves it, with only the fields a case
     * needs to vary parameterised.
     *
     * Keeping `disabledNotice` at `null` is not decoration: kotlinx throws by default when an explicit
     * null is assigned to a non-nullable field, so if the Json inside MetadataClient ever loses its
     * `coerceInputValues` the whole section stops decoding. That is a failure shape this project has
     * actually hit.
     */
    private fun openAISubscriptionAuth(
        enabled: Boolean = true,
        disabledNotice: String = "null",
        minAppVersion: String = """{"ios":"1.2.6"}""",
    ): String = """
        {
          "chatPath": "/responses",
          "clientId": "app_EMoamEEZ73f0CkXaXp7hrann",
          "deviceAuthorizationEndpoint": "https://auth.openai.com/api/accounts/deviceauth/usercode",
          "deviceTokenEndpoint": "https://auth.openai.com/api/accounts/deviceauth/token",
          "disabledNotice": $disabledNotice,
          "enabled": $enabled,
          "flow": "codex_device_code",
          "minAppVersion": $minAppVersion,
          "modelsPath": "/models",
          "pollIntervalSeconds": 5,
          "pollTimeoutSeconds": 900,
          "redirectURI": "https://auth.openai.com/deviceauth/callback",
          "requiredHeaders": {
            "OpenAI-Beta": "responses=experimental",
            "originator": "oriveo",
            "version": "0.148.0"
          },
          "resourceBaseURL": "https://chatgpt.com/backend-api/codex",
          "tokenEndpoint": "https://auth.openai.com/oauth/token",
          "trustedAuthHosts": ["auth.openai.com"],
          "trustedVerificationHosts": ["auth.openai.com"],
          "verificationURL": "https://auth.openai.com/codex/device"
        }
    """.trimIndent()
}
