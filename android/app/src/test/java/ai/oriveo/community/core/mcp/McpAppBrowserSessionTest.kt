package ai.oriveo.community.core.mcp

import android.content.Intent
import android.net.Uri
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The Android browser sign-in wiring: the production [McpAppBrowserSession] + [McpOAuthCallbackRouter] +
 * [McpOAuthCallbackIntents] + [McpAuthorizer]. The "browser" is a script in the test: it receives the
 * authorization URL built by production code,
 * wraps the redirect URL in a VIEW intent the way the system does, and follows the same hand-off path as the
 * trampoline Activity. The token endpoint is a replayed fixture.
 */
@RunWith(RobolectricTestRunner::class)
class McpAppBrowserSessionTest {

    private lateinit var router: McpOAuthCallbackRouter
    private lateinit var auth: FakeMcpAuthTransport
    private lateinit var credentials: McpCredentialStore
    private lateinit var authorizer: McpAuthorizer
    private val opened = mutableListOf<String>()

    /** How the "browser" comes back this time; null means no redirect (the user closed the sign-in page themselves). */
    private var browserReturns: (authorizeUrl: String) -> String? = { null }

    @Before
    fun setUp() {
        router = McpOAuthCallbackRouter()
        val session = McpAppBrowserSession(
            router = router,
            openPage = { url ->
                opened += url
                browserReturns(url)?.let(::deliverLikeTheRedirectActivity)
                true
            },
            dismissGraceMillis = 10,
        )
        auth = FakeMcpAuthTransport()
        credentials = McpCredentialStore(InMemoryPrefs())
        authorizer = McpAuthorizer(auth, session, credentials, clientMetadataUrl = CLIENT_METADATA_URL)
        stubAuthFixture("protected-resource-metadata.json", PROTECTED_RESOURCE_URL)
        stubAuthFixture("authorization-server-metadata.cimd.json", AUTHORIZATION_SERVER_URL)
        stubAuthFixture("token.success.json", TOKEN_URL)
    }

    private fun stubAuthFixture(name: String, url: String) {
        val fixture = McpFixture.json("auth/$name")
        auth.stub(fixture["status"].longOrNull?.toInt() ?: 200, fixture["body"]!!, url)
    }

    /** What the trampoline Activity does: take the redirect URL from the VIEW intent, hand it to the router, then bring the main UI back to the foreground. */
    private fun deliverLikeTheRedirectActivity(callbackUrl: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(callbackUrl))
        val delivered = McpOAuthCallbackIntents.callbackUrl(intent)?.let(router::deliver) ?: false
        router.notifyHostResumed()
        return delivered
    }

    private suspend fun plan(): McpAuthorizationPlan {
        val outcome = authorizer.discover(null, ENDPOINT)
        return (outcome as McpAuthDiscoveryOutcome.Ready).plan
    }

    private fun state(authorizeUrl: String) = McpCallbackValidator.parameters(authorizeUrl)["state"].orEmpty()

    /** A successful sign-in: the redirect carries the authorization code and the correct state / iss. */
    private fun successCallback(authorizeUrl: String, redirectUri: String) =
        "$redirectUri?code=ac_123&state=${state(authorizeUrl)}&iss=$ISSUER"

    // ── The redirect reaches a completed authorization ─────────────────────

    @Test
    fun `the custom scheme callback completes authorization`() = runBlocking {
        browserReturns = { url -> successCallback(url, REDIRECT_URI) }
        val obtained = authorizer.authorize(plan(), "s1", UID)

        assertNotNull("an access token was obtained", obtained.accessToken)
        assertEquals("the token is stored in the credential store", obtained.accessToken, credentials.load("s1", UID)?.accessToken)
        val authorizeUrl = opened.single()
        assertEquals(REDIRECT_URI, McpCallbackValidator.parameters(authorizeUrl)["redirect_uri"])
        val exchange = auth.formRequests.single()
        assertEquals(TOKEN_URL, exchange.first)
        assertEquals(
            "the token exchange carries the same redirect URI",
            REDIRECT_URI,
            exchange.second.first { it.name == "redirect_uri" }.value,
        )
    }

    // ── A state mismatch or an origin mismatch is rejected ──────────────────

    @Test
    fun `a callback whose state does not match is not claimed and no token is exchanged`() = runBlocking {
        browserReturns = { "$REDIRECT_URI?code=ac_123&state=someone-elses-state&iss=$ISSUER" }
        try {
            authorizer.authorize(plan(), "s1", UID)
            fail("a callback with a mismatched state must not complete the authorization")
        } catch (error: McpAuthorizerException) {
            assertEquals(McpAuthorizerException.Kind.Cancelled, error.kind)
        }
        assertTrue("no token exchange", auth.formRequests.isEmpty())
        assertNull("no credential was stored", credentials.load("s1", UID))
    }

    @Test
    fun `a callback arriving on a redirect uri other than the one sent is rejected before the token exchange`() = runBlocking {
        // The authorization request was sent with another redirect URI, yet a callback with the correct state arrives on
        // the custom scheme.
        browserReturns = { url -> successCallback(url, REDIRECT_URI) }
        try {
            authorizer.authorize(plan(), "s1", UID, redirectUri = "https://app.example.com/mcp/oauth/callback")
            fail("a callback from the wrong origin must not complete the authorization")
        } catch (error: McpAuthorizerException) {
            assertEquals(McpAuthorizerException.Kind.CallbackRejected, error.kind)
            assertEquals(McpCallbackRejectionReason.RedirectUriMismatch, error.rejection)
        }
        assertTrue("no token exchange", auth.formRequests.isEmpty())
        assertNull(credentials.load("s1", UID))
    }

    @Test
    fun `an issuer mismatch on the callback is rejected before the token exchange`() = runBlocking {
        browserReturns = { url -> "$REDIRECT_URI?code=ac_123&state=${state(url)}&iss=https://evil.example.com" }
        try {
            authorizer.authorize(plan(), "s1", UID)
            fail("a callback with a mismatched iss must not complete the authorization")
        } catch (error: McpAuthorizerException) {
            assertEquals(McpCallbackRejectionReason.IssMismatch, error.rejection)
        }
        assertTrue(auth.formRequests.isEmpty())
    }

    @Test
    fun `only the registered callback address is taken from an intent`() {
        fun view(url: String) = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        assertEquals(
            "oriveo://mcp/oauth/callback?code=a&state=b",
            McpOAuthCallbackIntents.callbackUrl(view("oriveo://mcp/oauth/callback?code=a&state=b")),
        )
        for (foreign in listOf(
            "oriveo://mcp/oauth/callbackX?state=b",
            "oriveo://mcp/oauth/callback/extra?state=b",
            "oriveo://mcp/oauth?state=b",
            "oriveo://other/oauth/callback?state=b",
            "other://mcp/oauth/callback?state=b",
            "https://mcp/oauth/callback?state=b",
            "https://app.example.com/mcp/oauth/callback?code=a&state=b",
            "https://evil.example.com/mcp/oauth/callback?state=b",
        )) {
            assertNull(foreign, McpOAuthCallbackIntents.callbackUrl(view(foreign)))
        }
        assertNull("a non-VIEW intent is not accepted", McpOAuthCallbackIntents.callbackUrl(Intent(Intent.ACTION_SEND, Uri.parse("oriveo://mcp/oauth/callback?state=b"))))
        assertNull(McpOAuthCallbackIntents.callbackUrl(null))
    }

    @Test
    fun `a callback is claimed once and never without a waiting authorization`() {
        val waiter = router.register("st")
        assertFalse("no state", router.deliver("oriveo://mcp/oauth/callback?code=a"))
        assertFalse("a state nobody is waiting for", router.deliver("oriveo://mcp/oauth/callback?code=a&state=other"))
        assertTrue(router.deliver("oriveo://mcp/oauth/callback?code=a&state=st"))
        assertTrue(waiter.isCompleted)
        assertFalse("a state is claimed only once", router.deliver("oriveo://mcp/oauth/callback?code=b&state=st"))
    }

    // ── The user closes the sign-in page / the browser cannot be opened ─────

    @Test
    fun `coming back to the app without a callback ends the sign-in as cancelled`() = runBlocking {
        browserReturns = { null }
        val returning = launch(Dispatchers.Default) {
            delay(80)
            router.notifyHostResumed()
        }
        try {
            authorizer.authorize(plan(), "s1", UID)
            fail("without a redirect the authorization must not complete")
        } catch (error: McpAuthorizerException) {
            assertEquals(McpAuthorizerException.Kind.Cancelled, error.kind)
        }
        returning.join()
        assertTrue(auth.formRequests.isEmpty())
        // This authorization is over: nobody claims a late callback.
        assertFalse(router.deliver(successCallback(opened.single(), REDIRECT_URI)))
    }

    @Test
    fun `a browser that cannot be opened ends the sign-in as cancelled`() = runBlocking {
        val session = McpAppBrowserSession(router = router, openPage = { false })
        val unopenable = McpAuthorizer(auth, session, credentials, clientMetadataUrl = CLIENT_METADATA_URL)
        val outcome = unopenable.discover(null, ENDPOINT) as McpAuthDiscoveryOutcome.Ready
        try {
            unopenable.authorize(outcome.plan, "s1", UID)
            fail("a browser that cannot be opened must not complete the authorization")
        } catch (error: McpAuthorizerException) {
            assertEquals(McpAuthorizerException.Kind.Cancelled, error.kind)
        }
    }

    private companion object {
        const val UID = LOCAL_PARTITION_ID
        const val REDIRECT_URI = McpClientMetadata.REDIRECT_URI
        const val CLIENT_METADATA_URL = "https://app.example.com/oauth/mcp-client.json"
        const val ENDPOINT = "https://mcp.example.com/mcp"
        const val ISSUER = "https://auth.example.com"
        const val PROTECTED_RESOURCE_URL = "https://mcp.example.com/.well-known/oauth-protected-resource"
        const val AUTHORIZATION_SERVER_URL = "https://auth.example.com/.well-known/oauth-authorization-server"
        const val TOKEN_URL = "https://auth.example.com/token"
    }
}
