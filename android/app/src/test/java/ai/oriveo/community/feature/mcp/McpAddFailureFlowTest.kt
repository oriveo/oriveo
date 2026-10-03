package ai.oriveo.community.feature.mcp

import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpCallbackValidator
import ai.oriveo.community.core.mcp.McpInvalidUrlReason
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.ENDPOINT
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.UID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Failures while adding a server: bad address, unreachable, not recognized, token needed, sign-in not finished, limit reached, cancelled, could not save, and pasted tokens.
 *
 * After every failure the MCP tables and the credential store hold no trace of the attempt.
 */
@RunWith(RobolectricTestRunner::class)
class McpAddFailureFlowTest {

    private lateinit var harness: McpManagementHarness
    private lateinit var scope: CoroutineScope

    @Before
    fun setUp() {
        harness = McpManagementHarness()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

    @After
    fun tearDown() {
        scope.cancel()
        harness.close()
    }

    private fun flow(runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback) = McpAddServerFlow(
        scope = scope,
        coordinator = harness.coordinator(runtimeConfig),
        store = harness.store,
        cleanupScope = scope,
    )

    private suspend fun McpAddServerFlow.awaitScreen(predicate: (McpAddScreen) -> Boolean): McpAddUiState =
        withTimeout(5_000) { state.first { predicate(it.screen) } }

    private suspend fun McpAddServerFlow.awaitFailure(): McpAddScreen.Failure =
        awaitScreen { it is McpAddScreen.Failure }.screen as McpAddScreen.Failure

    private fun assertNothingStored(label: String) {
        assertEquals("$label: no table should keep a row", emptyMap<String, Int>(), harness.nonEmptyTables())
        assertEquals("$label: the credential store should keep no token or address", emptyList<String>(), harness.credentialKeys())
    }

    // ── Malformed address ──────────────────────────────────────

    @Test
    fun `a malformed or non-https address stays on the form with a field error and sends nothing`() = runBlocking {
        for (bad in listOf("linear.app/mcp", "http://mcp.example.com/mcp", "ftp://mcp.example.com/mcp", "https://")) {
            val flow = flow()
            flow.updateUrl(bad)
            flow.connect()
            val state = flow.state.value
            assertEquals(bad, McpAddScreen.Form, state.screen)
            assertEquals(bad, McpInvalidUrlReason.Malformed, state.urlError)
            assertFalse("the primary button is disabled while the error shows", state.canConnect)
            // Editing the address clears the error.
            flow.updateUrl("$bad/")
            assertNull(flow.state.value.urlError)
        }
        assertTrue("no network request should be sent for an invalid address", harness.mcp.requests().isEmpty())
        assertNothingStored("invalid url")
    }

    @Test
    fun `an address with a userinfo segment is rejected with its own explanation and sends nothing`() = runBlocking {
        for (bad in listOf("https://alice:secret@mcp.example.com/mcp", "https://alice@mcp.example.com/mcp")) {
            val flow = flow()
            flow.updateUrl(bad)
            flow.connect()
            assertEquals(McpAddScreen.Form, flow.state.value.screen)
            assertEquals(McpInvalidUrlReason.HasUserinfo, flow.state.value.urlError)
        }
        assertTrue(harness.mcp.requests().isEmpty())
        assertNothingStored("userinfo")
    }

    // ── Cannot connect / not recognized ────────────────────────

    @Test
    fun `a network failure lands on cannot connect and retry runs the same input again`() = runBlocking {
        harness.mcp.enqueue(McpScriptedTransport.networkError())
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        assertEquals(McpAddFailure.Unreachable, flow.awaitFailure().kind)
        assertNothingStored("unreachable")

        // "Edit address" returns to the form with what was typed still there.
        flow.editAddress()
        assertEquals(McpAddScreen.Form, flow.state.value.screen)
        assertEquals(ENDPOINT, flow.state.value.url)

        // "Try again": this time the server answers.
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        flow.retry()
        val review = flow.awaitScreen { it is McpAddScreen.Review }.screen as McpAddScreen.Review
        assertNotNull(harness.store.fetchServer(review.serverId))
    }

    @Test
    fun `every not-an-mcp-server response lands on not recognized and leaves nothing`() = runBlocking {
        for ((caseId, stub) in McpScriptedTransport.notMcpCases()) {
            harness.mcp.reset()
            harness.mcp.setFallback(stub)
            val flow = flow()
            flow.updateUrl(ENDPOINT)
            flow.connect()
            assertEquals(caseId, McpAddFailure.NotMcp, flow.awaitFailure().kind)
            assertNothingStored(caseId)
        }
    }

    // ── Access token needed + pasting a token ──────────────────

    @Test
    fun `a server without automatic sign-in asks for a token and pasting one finishes the add`() = runBlocking {
        // No authorization metadata is stubbed → automatic registration is impossible → an access token is needed.
        harness.mcp.enqueue(harness.unauthorized())
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        val failure = flow.awaitFailure()
        assertEquals(McpAddFailure.NeedsToken, failure.kind)
        assertFalse(failure.tokenRejected)
        assertNothingStored("needs token")

        // Connect after pasting the token in place: the first attempt without credentials is still 401, the retry with the token succeeds.
        harness.mcp.reset()
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        flow.updateToken("  pat_123  ")
        flow.connectWithToken()
        val review = flow.awaitScreen { it is McpAddScreen.Review }.screen as McpAddScreen.Review

        assertEquals(McpAuthKind.Token, harness.store.fetchServer(review.serverId)?.authKind)
        assertEquals("the token is stored in the credential store with surrounding whitespace trimmed", "pat_123", harness.credentials.load(review.serverId, UID)?.pastedToken)
        assertEquals("the request with a token uses it", "Bearer pat_123", harness.mcp.requests().last().header("Authorization"))
        assertNull("the first probe carries no credentials", harness.mcp.requests().first().header("Authorization"))
    }

    @Test
    fun `a token the server rejects keeps the token page with a field error and stores nothing`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized())
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        flow.awaitFailure()

        harness.mcp.reset()
        harness.mcp.enqueue(harness.unauthorized(), harness.unauthorized())
        flow.updateToken("bad")
        flow.connectWithToken()
        val rejected = flow.awaitScreen { it is McpAddScreen.Failure && it.tokenRejected }.screen as McpAddScreen.Failure
        assertEquals("stays on the access-token page", McpAddFailure.NeedsToken, rejected.kind)
        assertNothingStored("token rejected on the token page")

        // Editing the token clears the error.
        flow.updateToken("bad2")
        assertFalse((flow.state.value.screen as McpAddScreen.Failure).tokenRejected)
    }

    /** The sign-in method is decided by probing. Going back to the form and pressing Connect starts over: the previously pasted token is not carried along, and the probe goes out without credentials first. */
    @Test
    fun `connecting from the form always probes without credentials even after a token was tried`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized())
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        flow.awaitFailure()
        harness.mcp.reset()
        harness.mcp.enqueue(harness.unauthorized(), harness.unauthorized())
        flow.updateToken("bad")
        flow.connectWithToken()
        flow.awaitScreen { it is McpAddScreen.Failure && it.tokenRejected }

        flow.editAddress()
        assertTrue(flow.state.value.canConnect)
        harness.mcp.reset()
        harness.mcp.enqueue(harness.unauthorized())
        flow.connect()
        val failure = flow.awaitScreen { it is McpAddScreen.Failure && !it.tokenRejected }.screen as McpAddScreen.Failure

        assertEquals(McpAddFailure.NeedsToken, failure.kind)
        assertEquals(McpAuthKind.Auto, flow.state.value.authKind)
        assertTrue("probes started from the form carry no credentials", harness.mcp.requests().all { it.header("Authorization") == null })
        assertNothingStored("reconnect from the form")
    }

    // ── Sign-in not finished ───────────────────────────────────

    @Test
    fun `closing the sign-in page lands on sign-in not finished and sign in again reaches review`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized())
        harness.stubAuthorization()
        // callbackBuilder is null → the fake browser throws (the user closed the sign-in page).
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        flow.awaitScreen { it is McpAddScreen.Progress && it.stage == McpAddStage.AuthPrompt }
        flow.approveSignIn()
        assertEquals(McpAddFailure.AuthCancelled, flow.awaitFailure().kind)
        assertNothingStored("auth cancelled")

        // "Sign in again": run it once more; the pre-sign-in prompt must be agreed to again.
        harness.mcp.reset()
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        harness.approveInBrowser()
        flow.retry()
        flow.awaitScreen { it is McpAddScreen.Progress && it.stage == McpAddStage.AuthPrompt }
        assertEquals("the earlier consent does not carry over to this attempt", 1, harness.fakeBrowser.openedUrls.size)
        flow.approveSignIn()
        flow.awaitScreen { it is McpAddScreen.Review }
        assertEquals(2, harness.fakeBrowser.openedUrls.size)
    }

    @Test
    fun `a provider that denies the request stores no token`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized())
        harness.stubAuthorization()
        harness.fakeBrowser.callbackBuilder = { authorizeUrl, redirectUri ->
            val state = McpCallbackValidator.parameters(authorizeUrl)["state"].orEmpty()
            "$redirectUri?error=access_denied&state=$state&iss=${McpManagementHarness.ISSUER}"
        }
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        flow.awaitScreen { it is McpAddScreen.Progress && it.stage == McpAddStage.AuthPrompt }
        flow.approveSignIn()
        assertEquals(McpAddFailure.AuthCancelled, flow.awaitFailure().kind)
        assertTrue("no token exchange may happen after a denial", harness.auth.formRequests.isEmpty())
        assertNothingStored("provider denied")
    }

    // ── Limit reached / could not save / cancelled ─────────────

    @Test
    fun `the server limit is reported before any request with the limit number`() = runBlocking {
        // Fill the limit with one server first (the limit is set to 1).
        val config = McpRuntimeConfig.fallback.copy(maxServers = 1)
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        val first = flow(config)
        first.updateUrl(ENDPOINT)
        first.connect()
        first.awaitScreen { it is McpAddScreen.Review }
        first.finish()
        withTimeout(5_000) { first.state.first { it.completedServerId != null } }
        val tablesBefore = harness.nonEmptyTables()
        harness.mcp.reset()

        val flow = flow(config)
        flow.updateUrl("https://other.example.com/mcp")
        flow.connect()
        val failure = flow.awaitFailure()
        assertEquals(McpAddFailure.LimitReached, failure.kind)
        assertEquals(1, failure.max)
        assertTrue("no request is sent once the limit is reached", harness.mcp.requests().isEmpty())
        assertEquals("the existing server is unaffected and no record is added", tablesBefore, harness.nonEmptyTables())
    }

    @Test
    fun `a token that cannot be written to the device ends in could not save and removes the record`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        harness.prefs.failWrites = true
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.updateToken("pat_123")
        flow.connectWithToken()
        assertEquals(McpAddFailure.SaveFailed, flow.awaitFailure().kind)
        assertNothingStored("save failed")
    }

    @Test
    fun `cancelling while connecting returns to the form and a late success is not kept`() = runBlocking {
        harness.mcp.enqueue(McpScriptedTransport.json("{}", delayMillis = 400))
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        flow.awaitScreen { it is McpAddScreen.Progress }

        flow.cancel()

        assertEquals(McpAddScreen.Form, flow.state.value.screen)
        delay(600)
        assertEquals("a late callback no longer changes the page", McpAddScreen.Form, flow.state.value.screen)
        assertNothingStored("cancelled")
    }
}
