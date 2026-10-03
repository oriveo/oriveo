package ai.oriveo.community.feature.mcp

import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpConnectionStatus
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.ENDPOINT
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.REGISTRATION_URL
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.UID
import java.util.Collections
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
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
 * UI state of the add flow: the mapping from state machine to pages, the gate before sign-in, Done releasing the tools, and abandoning the add leaving no record.
 *
 * Under test are [McpAddServerFlow] and the production `McpAddCoordinator` (real Room, real authorizer); only the network is replayed.
 */
@RunWith(RobolectricTestRunner::class)
class McpAddServerFlowTest {

    private lateinit var harness: McpManagementHarness
    private lateinit var scope: CoroutineScope
    private lateinit var cleanupScope: CoroutineScope
    private val screens: MutableList<McpAddScreen> = Collections.synchronizedList(mutableListOf())
    private var watcher: Job? = null

    @Before
    fun setUp() {
        harness = McpManagementHarness()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        screens.clear()
    }

    @After
    fun tearDown() {
        scope.cancel()
        cleanupScope.cancel()
        harness.close()
    }

    private fun flow(runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback): McpAddServerFlow {
        val flow = McpAddServerFlow(
            scope = scope,
            coordinator = harness.coordinator(runtimeConfig),
            store = harness.store,
            cleanupScope = cleanupScope,
        )
        // Record every page passed through (StateFlow conflates equal values; page changes are always distinct values).
        watcher = scope.launch(Dispatchers.Unconfined) {
            flow.state.collect { state -> if (screens.lastOrNull() != state.screen) screens += state.screen }
        }
        return flow
    }

    private suspend fun McpAddServerFlow.awaitScreen(predicate: (McpAddScreen) -> Boolean): McpAddUiState =
        withTimeout(5_000) { state.first { predicate(it.screen) } }

    private suspend fun eventually(condition: suspend () -> Boolean) = withTimeout(5_000) {
        while (!condition()) delay(20)
    }

    private val stages: List<McpAddStage> get() = screens.filterIsInstance<McpAddScreen.Progress>().map { it.stage }

    // ── A server that needs no sign-in ─────────────────────────

    @Test
    fun `a server that needs no sign-in goes from the form through connecting and finishing to review`() = runBlocking {
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        val flow = flow()
        assertFalse("cannot connect while the address is empty", flow.state.value.canConnect)
        flow.updateUrl(ENDPOINT)
        assertTrue(flow.state.value.canConnect)
        assertEquals("the host name is shown while the name is unknown", "mcp.example.com", flow.state.value.displayName)

        flow.connect()
        val state = flow.awaitScreen { it is McpAddScreen.Review }
        val review = state.screen as McpAddScreen.Review

        assertEquals(listOf(McpAddStage.Connecting, McpAddStage.Finishing), stages)
        assertFalse("no browser was involved, so the second checklist step does not read signed in", screens.filterIsInstance<McpAddScreen.Progress>().last().signedIn)
        assertEquals(listOf("get_weather"), review.readOnlyTools.map { it.toolName })
        assertEquals(listOf("create_issue"), review.changingTools.map { it.toolName })
        assertEquals("read-only tools default to run automatically", McpToolPermission.Auto, review.readOnlyPermission)
        assertEquals("everything else defaults to ask every time", McpToolPermission.Ask, review.changesPermission)
        // The record is already stored at this point, but every tool is quarantined: the model gets no tool until the user presses Done.
        assertTrue(harness.store.fetchToolSnapshots(review.serverId).all { it.pendingReview })
        assertNull(state.completedServerId)
    }

    @Test
    fun `done releases the tools with the permissions chosen on the review page`() = runBlocking {
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.updateName("Weather")
        flow.connect()
        val review = flow.awaitScreen { it is McpAddScreen.Review }.screen as McpAddScreen.Review

        flow.setReadOnlyPermission(McpToolPermission.Ask)
        flow.setChangesPermission(McpToolPermission.Off)
        flow.finish()
        withTimeout(5_000) { flow.state.first { it.completedServerId != null } }

        assertEquals(review.serverId, flow.state.value.completedServerId)
        assertTrue("pressing Done lifts the quarantine", harness.store.fetchToolSnapshots(review.serverId).none { it.pendingReview })
        assertEquals(
            mapOf("get_weather" to McpToolPermission.Ask, "create_issue" to McpToolPermission.Off),
            harness.store.fetchToolPermissions(review.serverId),
        )
        val record = harness.store.fetchServer(review.serverId)
        assertEquals("Weather", record?.name)
        assertEquals(McpConnectionStatus.Connected, harness.store.fetchConnectionState(review.serverId)?.status)
        // Leaving the page after a finished add is not treated as abandoning it.
        flow.close()
        delay(100)
        assertNotNull(harness.store.fetchServer(review.serverId))
    }

    // ── The pre-sign-in prompt is a gate; browser; signed in ────

    @Test
    fun `the sign-in prompt shows the authorization host and nothing is registered or opened until continue`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        harness.stubDcrAuthorization()
        harness.approveInBrowser()
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()

        val prompt = flow.awaitScreen { it is McpAddScreen.Progress && it.stage == McpAddStage.AuthPrompt }.screen as McpAddScreen.Progress
        assertEquals("the host name of the sign-in page must be shown", "auth.example.com", prompt.authorizationHost)
        assertTrue("no client is registered before consent", harness.auth.jsonRequests.isEmpty())
        assertTrue("the browser is not opened before consent", harness.fakeBrowser.openedUrls.isEmpty())

        flow.approveSignIn()
        val review = flow.awaitScreen { it is McpAddScreen.Review }.screen as McpAddScreen.Review

        assertEquals(listOf(McpAddStage.Connecting, McpAddStage.AuthPrompt, McpAddStage.Browser, McpAddStage.Finishing), stages)
        assertTrue("after the redirect back the second checklist step reads signed in", screens.filterIsInstance<McpAddScreen.Progress>().last().signedIn)
        assertEquals(listOf(REGISTRATION_URL), harness.auth.jsonRequests.map { it.first })
        assertEquals(1, harness.fakeBrowser.openedUrls.size)
        assertNotNull("the token is stored in the credential store after the record is stored", harness.credentials.load(review.serverId, UID)?.accessToken)
    }

    @Test
    fun `cancelling at the sign-in prompt returns to the form and leaves nothing behind`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized())
        harness.stubDcrAuthorization()
        harness.approveInBrowser()
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.updateName("Linear")
        flow.connect()
        flow.awaitScreen { it is McpAddScreen.Progress && it.stage == McpAddStage.AuthPrompt }

        flow.cancel()

        assertEquals(McpAddScreen.Form, flow.state.value.screen)
        assertEquals("what was typed is kept", ENDPOINT, flow.state.value.url)
        assertEquals("Linear", flow.state.value.name)
        delay(150)
        assertEquals(McpAddScreen.Form, flow.state.value.screen)
        assertTrue(harness.auth.jsonRequests.isEmpty())
        assertTrue(harness.fakeBrowser.openedUrls.isEmpty())
        assertEquals(emptyMap<String, Int>(), harness.nonEmptyTables())
        assertEquals(emptyList<String>(), harness.credentialKeys())
    }

    // ── Abandoning the add ─────────────────────────────────────

    @Test
    fun `leaving at the review page abandons the add and removes the record and its credentials`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        harness.stubAuthorization()
        harness.approveInBrowser()
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        flow.awaitScreen { it is McpAddScreen.Progress && it.stage == McpAddStage.AuthPrompt }
        flow.approveSignIn()
        val review = flow.awaitScreen { it is McpAddScreen.Review }.screen as McpAddScreen.Review
        assertNotNull(harness.store.fetchServer(review.serverId))
        assertNotNull(harness.credentials.load(review.serverId, UID))

        flow.close()

        // Cleanup runs on the app-level scope: the record is deleted first, then the credentials; wait for both.
        eventually { harness.store.fetchServer(review.serverId) == null && harness.credentials.load(review.serverId, UID) == null }
        assertNull("the credentials are deleted too", harness.credentials.load(review.serverId, UID))
        assertEquals(emptyList<String>(), harness.credentialKeys())
        assertEquals(emptyMap<String, Int>(), harness.nonEmptyTables())
    }

    // ── Until the default permissions are confirmed the server is not listed; the launch sweep ────

    @Test
    fun `a server is not listed until done`() = runBlocking {
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        val review = flow.awaitScreen { it is McpAddScreen.Review }.screen as McpAddScreen.Review

        // Paused on the default-permissions review: the record is stored but carries the unconfirmed flag.
        assertNotNull(harness.store.fetchServer(review.serverId))
        assertTrue("it does not appear in the server list before Done", harness.store.fetchAllServers().isEmpty())

        flow.finish()
        withTimeout(5_000) { flow.state.first { it.completedServerId != null } }

        assertEquals(listOf(review.serverId), harness.store.fetchAllServers().map { it.id })
    }

    @Test
    fun `a record never confirmed is swept on the next launch with its credentials`() = runBlocking {
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        harness.stubAuthorization()
        harness.approveInBrowser()
        val flow = flow()
        flow.updateUrl(ENDPOINT)
        flow.connect()
        flow.awaitScreen { it is McpAddScreen.Progress && it.stage == McpAddStage.AuthPrompt }
        flow.approveSignIn()
        val review = flow.awaitScreen { it is McpAddScreen.Review }.screen as McpAddScreen.Review
        assertNotNull(harness.credentials.load(review.serverId, UID))
        // A server whose add finished normally: the sweep must not touch it.
        val kept = harness.addServer(name = "Kept", url = "https://kept.example.com/mcp")

        // The process died before the user pressed Done: no cleanup code ever ran. The next launch sweeps it.
        val nextLaunch = McpServerStore(harness.db.mcpServerDao(), harness.credentials)
        assertEquals("an add in progress in this process is not swept", 0, nextLaunch.sweepUnconfirmedAdditions(createdBefore = 0L))
        assertEquals(1, nextLaunch.sweepUnconfirmedAdditions(createdBefore = System.currentTimeMillis() + 1))

        assertNull(harness.store.fetchServer(review.serverId))
        assertNull("the credentials are cleared too", harness.credentials.load(review.serverId, UID))
        assertNotNull("a server whose add finished is left alone", harness.store.fetchServer(kept))
        assertEquals(
            setOf("mcp_server", "mcp_connection_state", "mcp_tool_snapshot", "mcp_tool_permission"),
            harness.nonEmptyTables().keys,
        )
        assertEquals(1, harness.nonEmptyTables()["mcp_server"])
    }

    @Test
    fun `done survives leaving the page right after the tap`() = runBlocking {
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        val pageScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val flow = McpAddServerFlow(scope = pageScope, coordinator = harness.coordinator(), store = harness.store, cleanupScope = scope)
        flow.updateUrl(ENDPOINT)
        flow.connect()
        val review = withTimeout(5_000) { flow.state.first { it.screen is McpAddScreen.Review } }.screen as McpAddScreen.Review

        // The page is destroyed right after Done is pressed (the page scope is cancelled).
        pageScope.cancel()
        flow.finish()
        flow.close()

        eventually { harness.store.fetchAllServers().any { it.id == review.serverId } }
        assertEquals("a finished add is not swept as a leftover on the next launch", 0, harness.store.sweepUnconfirmedAdditions(System.currentTimeMillis() + 1))
        assertTrue(harness.store.fetchToolSnapshots(review.serverId).none { it.pendingReview })
    }

    @Test
    fun `a url that looks like it carries a key is stored as local-only with only its display address in the database`() = runBlocking {
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        val flow = flow()
        flow.updateUrl("$ENDPOINT?key=abc")
        flow.connect()
        val review = flow.awaitScreen { it is McpAddScreen.Review }.screen as McpAddScreen.Review
        val record = harness.store.fetchServer(review.serverId)!!
        assertTrue(record.localOnly)
        assertEquals(ENDPOINT, record.url)
        assertEquals("the full address is kept in the credential store", "$ENDPOINT?key=abc", harness.credentials.loadEndpoint(review.serverId, UID))
    }

    /** The form has only an address and a name, and Connect works once the address is filled; the user does not pick a sign-in method up front. */
    @Test
    fun `the form needs only an address to connect`() {
        val flow = flow()
        assertFalse(flow.state.value.canConnect)
        flow.updateUrl(ENDPOINT)
        assertTrue(flow.state.value.canConnect)
        assertEquals(McpAuthKind.Auto, flow.state.value.authKind)
    }
}
