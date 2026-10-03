package ai.oriveo.community.feature.mcp

import ai.oriveo.community.core.mcp.McpAddressUpdate
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpConfirmChangesResult
import ai.oriveo.community.core.mcp.McpConnectionStatus
import ai.oriveo.community.core.mcp.McpInvalidUrlReason
import ai.oriveo.community.core.mcp.McpReauthPhase
import ai.oriveo.community.core.mcp.McpReauthorizationCoordinator
import ai.oriveo.community.core.mcp.McpRefreshResult
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.core.mcp.McpServerActions
import ai.oriveo.community.core.mcp.McpServerEndpoint
import ai.oriveo.community.core.mcp.McpServerEndpointResolution
import ai.oriveo.community.core.mcp.McpServerHealth
import ai.oriveo.community.core.mcp.McpServerOverview
import ai.oriveo.community.core.mcp.McpServerProbe
import ai.oriveo.community.core.mcp.McpToolCatalog
import ai.oriveo.community.core.mcp.McpToolChangeKind
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.ENDPOINT
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.TOKEN_URL
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.UID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The operations behind the management pages: reloading tools and confirming changes, re-signing in (`McpReauthorizer`),
 * removal (credentials and record deleted), and entering the address again.
 *
 * Under test are the production `McpServerActions` / `McpReauthorizationCoordinator` / `McpServerDetailController`, with servers added through
 * the production add path; only the network is replayed.
 */
@RunWith(RobolectricTestRunner::class)
class McpServerManagementTest {

    private lateinit var harness: McpManagementHarness
    private lateinit var scope: CoroutineScope
    private lateinit var actions: McpServerActions

    @Before
    fun setUp() {
        harness = McpManagementHarness()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        actions = harness.actions()
    }

    @After
    fun tearDown() {
        scope.cancel()
        harness.close()
    }

    private fun JsonElement.withFields(vararg fields: Pair<String, JsonElement>): JsonElement =
        JsonObject((this as JsonObject) + fields.toMap())

    private fun JsonElement.toolName(): String = (this as JsonObject).getValue("name").jsonPrimitive.content

    private fun newTool(name: String, title: String, readOnly: Boolean): JsonElement = buildJsonObject {
        put("name", name)
        put("title", title)
        put("description", "A new tool")
        put("inputSchema", buildJsonObject { put("type", "object") })
        put("annotations", buildJsonObject { put("readOnlyHint", readOnly) })
    }

    private suspend fun outboundNames(serverId: String): List<String> = McpToolCatalog.outboundSnapshots(
        harness.store.fetchToolSnapshots(serverId),
        harness.store.fetchToolPermissions(serverId),
    ).map { it.toolName }

    private fun coordinator() = McpReauthorizationCoordinator(actions = actions, store = harness.store)

    private fun detailController(serverId: String, reauthorizer: McpReauthorizationCoordinator = coordinator()) =
        McpServerDetailController(serverId, scope, harness.store, harness.credentials, actions, reauthorizer)

    private suspend fun McpReauthorizationCoordinator.awaitPhase(predicate: (McpReauthPhase) -> Boolean): McpReauthPhase =
        withTimeout(5_000) { session.first { it != null && predicate(it.phase) }!!.phase }

    // ── List ───────────────────────────────────────────────────

    @Test
    fun `the overview reports each server's health tool count and what needs attention`() = runBlocking {
        val linear = harness.addServer(name = "Linear")
        val github = harness.addServer(name = "GitHub", url = "https://api.githubcopilot.com/mcp")
        val nas = harness.addServer(name = "Home NAS", url = "https://nas.example.net/mcp")
        harness.store.saveConnectionState(harness.store.fetchConnectionState(github)!!.copy(status = McpConnectionStatus.NeedsAuth))
        harness.store.saveConnectionState(harness.store.fetchConnectionState(nas)!!.copy(status = McpConnectionStatus.Unreachable))

        val overview = McpServerOverview.load(harness.store, harness.credentials, UID).associateBy { it.record.id }

        assertEquals(McpServerHealth.Connected, overview.getValue(linear).health)
        assertEquals(2, overview.getValue(linear).toolCount)
        assertEquals(McpServerHealth.NeedsAuth, overview.getValue(github).health)
        assertEquals(McpServerHealth.Unreachable, overview.getValue(nas).health)
        assertNotNull("an unreachable server keeps its last success time", overview.getValue(nas).lastSuccessAt)
        assertEquals(2, McpServerOverview.attentionCount(overview.values.toList()))
    }

    @Test
    fun `refreshing the list probes every server and writes the result back`() = runBlocking {
        val linear = harness.addServer(name = "Linear")
        val nas = harness.addServer(name = "Home NAS", url = "https://nas.example.net/mcp")
        val before = harness.store.fetchConnectionState(nas)!!.lastSuccessAt
        harness.mcp.enqueue(harness.unauthorized(), McpScriptedTransport.networkError())

        actions.probeAll()

        assertEquals(McpConnectionStatus.NeedsAuth, harness.store.fetchConnectionState(linear)?.status)
        assertEquals(McpConnectionStatus.Unreachable, harness.store.fetchConnectionState(nas)?.status)
        assertEquals("being unreachable does not erase the last success time", before, harness.store.fetchConnectionState(nas)?.lastSuccessAt)
        assertTrue("probing does not read the tool list or touch the catalog", harness.store.fetchToolSnapshots(linear).none { it.pendingReview })
    }

    // ── Per-tool permission ────────────────────────────────────

    @Test
    fun `a tool set to don't use is no longer offered to the model and setting it back restores it`() = runBlocking {
        val server = harness.addServer()
        assertEquals(setOf("get_weather", "create_issue"), outboundNames(server).toSet())

        actions.setPermission(server, "create_issue", McpToolPermission.Off)
        assertEquals(listOf("get_weather"), outboundNames(server))

        actions.setPermission(server, "create_issue", McpToolPermission.Auto)
        assertEquals(McpToolPermission.Auto, harness.store.fetchToolPermissions(server)["create_issue"])
        assertEquals(setOf("get_weather", "create_issue"), outboundNames(server).toSet())
    }

    // ── Confirming tool changes ────────────────────────────────

    @Test
    fun `reloading tools quarantines new and changed tools reports removed ones and keeps the rest released`() = runBlocking {
        val server = harness.addServer()
        // Server side: the description of create_issue changed, get_weather is gone, bulk_update is new.
        val changed = harness.toolsList { tools ->
            tools.filterNot { it.toolName() == "get_weather" }
                .map { it.withFields("description" to JsonPrimitive("Create an issue. Also email it to everyone.")) } +
                newTool("bulk_update", "Bulk update issues", readOnly = false)
        }
        harness.mcp.enqueue(changed, changed)

        val result = actions.refreshTools(server) as McpRefreshResult.Connected

        assertEquals(
            setOf(McpToolChangeKind.Added to "bulk_update", McpToolChangeKind.Changed to "create_issue", McpToolChangeKind.Removed to "get_weather"),
            result.changes.map { it.kind to it.toolName }.toSet(),
        )
        assertEquals("the previous snapshot is kept for the see-what-changed comparison", "Create a new issue in a repository", result.previous.first { it.toolName == "create_issue" }.description)
        assertTrue("changed tools are not offered to the model before confirmation", outboundNames(server).isEmpty())
        val pending = McpServerActions.pendingChanges(harness.store.fetchToolSnapshots(server), harness.store.fetchToolPermissions(server))
        assertEquals(
            mapOf("create_issue" to McpToolChangeKind.Changed, "bulk_update" to McpToolChangeKind.Added),
            pending.associate { it.snapshot.toolName to it.kind },
        )
        assertEquals("the new tool does not declare read-only: ask every time after confirmation", McpToolPermission.Ask, pending.first { it.snapshot.toolName == "bulk_update" }.permissionAfter)
        assertEquals(McpServerHealth.NeedsReview, McpServerOverview.load(harness.store, harness.credentials, UID).single().health)
    }

    @Test
    fun `a tool whose title alone changed is quarantined too`() = runBlocking {
        val server = harness.addServer()
        val renamed = harness.toolsList { tools ->
            tools.map { if (it.toolName() == "get_weather") it.withFields("title" to JsonPrimitive("Delete everything")) else it }
        }
        harness.mcp.enqueue(renamed, renamed)

        val result = actions.refreshTools(server) as McpRefreshResult.Connected

        assertEquals(listOf(McpToolChangeKind.Changed to "get_weather"), result.changes.map { it.kind to it.toolName })
        assertEquals("unchanged tools stay released", listOf("create_issue"), outboundNames(server))
    }

    @Test
    fun `confirming releases the tools and only ever lowers a permission`() = runBlocking {
        val server = harness.addServer()
        // Earlier the user left the read-only get_weather on run automatically and also set create_issue to run automatically.
        actions.setPermission(server, "create_issue", McpToolPermission.Auto)
        // The server no longer declares get_weather read-only, the description of create_issue changed, and there is a new read-only tool.
        val changed = harness.toolsList { tools ->
            tools.map {
                when (it.toolName()) {
                    "get_weather" -> it.withFields("annotations" to buildJsonObject { put("readOnlyHint", false) })
                    else -> it.withFields("description" to JsonPrimitive("Create an issue, differently"))
                }
            } + newTool("list_teams", "List teams", readOnly = true)
        }
        harness.mcp.enqueue(changed, changed)
        actions.refreshTools(server)
        assertTrue(outboundNames(server).isEmpty())

        harness.mcp.enqueue(changed, changed)
        val result = actions.confirmChanges(server)

        assertEquals(McpConfirmChangesResult.Confirmed(emptyList()), result)
        assertTrue(harness.store.fetchToolSnapshots(server).none { it.pendingReview })
        val permissions = harness.store.fetchToolPermissions(server)
        assertEquals("no longer read-only and previously run automatically → falls back to ask every time", McpToolPermission.Ask, permissions["get_weather"])
        assertEquals("a tool that changes data does not stay on run automatically after confirmation", McpToolPermission.Ask, permissions["create_issue"])
        assertEquals("a new read-only tool gets the read-only default", McpToolPermission.Auto, permissions["list_teams"])
        assertEquals(setOf("get_weather", "create_issue", "list_teams"), outboundNames(server).toSet())
    }

    @Test
    fun `confirming never raises a permission the user had lowered`() = runBlocking {
        val server = harness.addServer()
        actions.setPermission(server, "get_weather", McpToolPermission.Off)
        val changed = harness.toolsList { tools -> tools.map { it.withFields("description" to JsonPrimitive("changed")) } }
        harness.mcp.enqueue(changed, changed)
        actions.refreshTools(server)
        harness.mcp.enqueue(changed, changed)
        actions.confirmChanges(server)

        val permissions = harness.store.fetchToolPermissions(server)
        assertEquals("Don't use stays Don't use after confirmation", McpToolPermission.Off, permissions["get_weather"])
        assertEquals(McpToolPermission.Ask, permissions["create_issue"])
        assertEquals(listOf("create_issue"), outboundNames(server))
    }

    @Test
    fun `a tool the server changed again while the user was confirming stays quarantined`() = runBlocking {
        val server = harness.addServer()
        val seen = harness.toolsList { tools -> tools.map { it.withFields("description" to JsonPrimitive("first rewrite")) } }
        harness.mcp.enqueue(seen, seen)
        actions.refreshTools(server)

        // The user confirms while looking at "first rewrite"; by now the server serves a different description for create_issue.
        val swapped = harness.toolsList { tools ->
            tools.map {
                it.withFields("description" to JsonPrimitive(if (it.toolName() == "create_issue") "second rewrite" else "first rewrite"))
            }
        }
        harness.mcp.enqueue(swapped, swapped)
        val result = actions.confirmChanges(server)

        assertEquals(McpConfirmChangesResult.Confirmed(listOf("create_issue")), result)
        val snapshots = harness.store.fetchToolSnapshots(server).associateBy { it.toolName }
        assertFalse(snapshots.getValue("get_weather").pendingReview)
        assertTrue(snapshots.getValue("create_issue").pendingReview)
        assertEquals("what awaits confirmation is the server's current version, which is what the next sheet shows the user", "second rewrite", snapshots.getValue("create_issue").description)
        assertEquals(listOf("get_weather"), outboundNames(server))
    }

    @Test
    fun `pausing the server turns it off in every chat and leaves the tools quarantined`() = runBlocking {
        val server = harness.addServer()
        harness.store.setServerEnabled(true, "chat-1", server)
        harness.store.setServerEnabled(true, "chat-2", server)
        val changed = harness.toolsList { tools -> tools.map { it.withFields("description" to JsonPrimitive("changed")) } }
        harness.mcp.enqueue(changed, changed)
        actions.refreshTools(server)

        actions.pause(server)

        assertTrue(harness.store.fetchEnabledServerIds("chat-1").isEmpty())
        assertTrue(harness.store.fetchEnabledServerIds("chat-2").isEmpty())
        assertTrue(harness.store.fetchToolSnapshots(server).all { it.pendingReview })
        assertNotNull("the server record is still there", harness.store.fetchServer(server))
    }

    // ── Re-signing in after expiry (McpReauthorizer) ───────────

    @Test
    fun `re-sign-in shows the prompt first and only after continue opens the browser and restores the connection`() = runBlocking {
        val server = harness.addServer(oauth = true)
        val oldToken = harness.credentials.load(server, UID)?.accessToken
        harness.store.saveConnectionState(harness.store.fetchConnectionState(server)!!.copy(status = McpConnectionStatus.NeedsAuth))
        val opensBefore = harness.fakeBrowser.openedUrls.size
        val exchangesBefore = harness.auth.formRequests.size
        // The stored token is no longer accepted → browser sign-in → connect with the new token and read the tools.
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        harness.auth.stub(200, McpScriptedTransportTokens.rotated, TOKEN_URL)
        val coordinator = coordinator()

        val result = async(Dispatchers.Default) { coordinator.reauthorize(server) }
        val prompt = coordinator.awaitPhase { it is McpReauthPhase.Prompt } as McpReauthPhase.Prompt

        assertEquals("the prompt shows the host name of the sign-in page", "auth.example.com", prompt.authorizationHost)
        assertEquals("mcp.example.com", prompt.serverHost)
        assertEquals("Linear", coordinator.session.value?.serverName)
        assertEquals("the browser is not opened before consent", opensBefore, harness.fakeBrowser.openedUrls.size)
        assertEquals("no token exchange before consent", exchangesBefore, harness.auth.formRequests.size)

        coordinator.approve()

        assertTrue(result.await())
        assertNull("the sheet is dismissed when finished", coordinator.session.value)
        assertEquals(opensBefore + 1, harness.fakeBrowser.openedUrls.size)
        val credentials = harness.credentials.load(server, UID)
        assertEquals("the credentials are updated", "rotated-access-token", credentials?.accessToken)
        assertNotEquals(oldToken, credentials?.accessToken)
        assertEquals("the connection state is back to connected", McpConnectionStatus.Connected, harness.store.fetchConnectionState(server)?.status)
        assertEquals("the new token is really used", "Bearer rotated-access-token", harness.mcp.requests().last().header("Authorization"))
    }

    @Test
    fun `cancelling at the prompt changes nothing and reports failure to the caller`() = runBlocking {
        val server = harness.addServer(oauth = true)
        val before = harness.credentials.load(server, UID)
        harness.store.saveConnectionState(harness.store.fetchConnectionState(server)!!.copy(status = McpConnectionStatus.NeedsAuth))
        val opensBefore = harness.fakeBrowser.openedUrls.size
        harness.mcp.enqueue(harness.unauthorized())
        val coordinator = coordinator()

        val result = async(Dispatchers.Default) { coordinator.reauthorize(server) }
        coordinator.awaitPhase { it is McpReauthPhase.Prompt }
        coordinator.cancel()

        assertFalse(result.await())
        assertNull(coordinator.session.value)
        assertEquals(opensBefore, harness.fakeBrowser.openedUrls.size)
        assertEquals("the credentials are untouched", before, harness.credentials.load(server, UID))
        assertEquals(McpConnectionStatus.NeedsAuth, harness.store.fetchConnectionState(server)?.status)
    }

    @Test
    fun `closing the sign-in page lands on the failed step and sign in again can still succeed`() = runBlocking {
        val server = harness.addServer(oauth = true)
        harness.mcp.enqueue(harness.unauthorized())
        harness.fakeBrowser.callbackBuilder = null // the user closed the sign-in page
        val coordinator = coordinator()

        val result = async(Dispatchers.Default) { coordinator.reauthorize(server) }
        coordinator.awaitPhase { it is McpReauthPhase.Prompt }
        coordinator.approve()
        val failed = coordinator.awaitPhase { it is McpReauthPhase.Failed } as McpReauthPhase.Failed
        assertFalse("sign-in was not finished, which is different from unreachable", failed.unreachable)

        harness.approveInBrowser()
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        coordinator.retry()
        coordinator.awaitPhase { it is McpReauthPhase.Prompt }
        coordinator.approve()

        assertTrue(result.await())
        assertEquals(McpConnectionStatus.Connected, harness.store.fetchConnectionState(server)?.status)
    }

    @Test
    fun `a token server asks for a new token rejects a bad one and stores the good one`() = runBlocking {
        val server = harness.addServer(name = "GitHub", authKind = McpAuthKind.Token, token = "old-token")
        harness.store.saveConnectionState(harness.store.fetchConnectionState(server)!!.copy(status = McpConnectionStatus.NeedsAuth))
        harness.mcp.enqueue(harness.unauthorized())
        val coordinator = coordinator()

        val result = async(Dispatchers.Default) { coordinator.reauthorize(server) }
        assertEquals(McpReauthPhase.Token(), coordinator.awaitPhase { it is McpReauthPhase.Token })

        harness.mcp.enqueue(harness.unauthorized())
        coordinator.submitToken("bad-token")
        coordinator.awaitPhase { it is McpReauthPhase.Token && it.rejected }
        assertEquals("a rejected token is not stored", "old-token", harness.credentials.load(server, UID)?.pastedToken)

        // New token: verify it connects first, then store it, then connect with it once and read the tools.
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList(), harness.toolsList())
        coordinator.submitToken("  new-token ")

        assertTrue(result.await())
        assertEquals("new-token", harness.credentials.load(server, UID)?.pastedToken)
        assertEquals(McpConnectionStatus.Connected, harness.store.fetchConnectionState(server)?.status)
        assertEquals("Bearer new-token", harness.mcp.requests().last().header("Authorization"))
    }

    @Test
    fun `an unreachable server is reported as such and not as a sign-in problem`() = runBlocking {
        val server = harness.addServer(oauth = true)
        harness.mcp.enqueue(McpScriptedTransport.networkError())
        val coordinator = coordinator()

        val result = async(Dispatchers.Default) { coordinator.reauthorize(server) }
        val failed = coordinator.awaitPhase { it is McpReauthPhase.Failed } as McpReauthPhase.Failed
        assertTrue(failed.unreachable)
        coordinator.cancel()

        assertFalse(result.await())
        assertNotNull("being unreachable leaves the credentials alone", harness.credentials.load(server, UID)?.accessToken)
    }

    @Test
    fun `the detail page's re-sign-in goes through the same reauthorizer and the page picks up the result`() = runBlocking {
        val server = harness.addServer(oauth = true)
        harness.store.saveConnectionState(harness.store.fetchConnectionState(server)!!.copy(status = McpConnectionStatus.NeedsAuth))
        harness.mcp.enqueue(harness.unauthorized(), harness.toolsList(), harness.toolsList())
        val coordinator = coordinator()
        val controller = detailController(server, coordinator)
        controller.reload()
        val before = withTimeout(5_000) { controller.state.first { it.loaded } }
        assertEquals(McpServerHealth.NeedsAuth, before.health)
        assertTrue("the tool list is dimmed while sign-in is expired", before.toolsLocked)
        assertEquals(McpSignInLabel.Browser, before.signIn)

        controller.reauthorize()
        coordinator.awaitPhase { it is McpReauthPhase.Prompt }
        coordinator.approve()

        val after = withTimeout(5_000) { controller.state.first { it.health == McpServerHealth.Connected } }
        assertFalse(after.toolsLocked)
    }

    // ── Reload and confirm on the detail page ──────────────────

    @Test
    fun `reload tools on the detail page opens the changes sheet and confirm closes it`() = runBlocking {
        val server = harness.addServer()
        val controller = detailController(server)
        controller.reload()
        withTimeout(5_000) { controller.state.first { it.loaded } }
        val changed = harness.toolsList { tools ->
            tools.filterNot { it.toolName() == "get_weather" }.map { it.withFields("description" to JsonPrimitive("rewritten")) }
        }
        harness.mcp.enqueue(changed, changed)

        controller.reloadTools()
        val opened = withTimeout(5_000) { controller.state.first { it.changes != null && it.busy == null } }

        assertEquals(listOf("create_issue"), opened.pending.map { it.snapshot.toolName })
        assertEquals(listOf("get_weather"), opened.changes!!.removed.map { it.toolName })
        assertEquals("Create a new issue in a repository", opened.changes!!.previous.first { it.toolName == "create_issue" }.description)
        assertEquals(McpServerHealth.NeedsReview, opened.health)

        harness.mcp.enqueue(changed, changed)
        controller.confirmChanges()
        val closed = withTimeout(5_000) { controller.state.first { it.changes == null && it.busy == null } }
        assertEquals(McpServerHealth.Connected, closed.health)
        assertTrue(closed.pending.isEmpty())
    }

    @Test
    fun `a failed reload says the server could not be reached and keeps the tools as they were`() = runBlocking {
        val server = harness.addServer()
        val controller = detailController(server)
        harness.mcp.enqueue(McpScriptedTransport.networkError())

        controller.reloadTools()
        val state = withTimeout(5_000) { controller.state.first { it.notice != null && it.busy == null } }

        assertEquals(McpDetailNotice.Unreachable, state.notice)
        assertEquals(McpServerHealth.Unreachable, state.health)
        assertEquals(setOf("get_weather", "create_issue"), outboundNames(server).toSet())
    }

    // ── Removal ────────────────────────────────────────────────

    @Test
    fun `removing deletes the credentials and the record with everything stored for it`() = runBlocking {
        val server = harness.addServer(oauth = true)
        harness.store.setServerEnabled(true, "chat-1", server)
        assertNotNull(harness.credentials.load(server, UID)?.accessToken)

        assertTrue(actions.remove(server))

        assertNull("the credentials are deleted", harness.credentials.load(server, UID))
        assertEquals(emptyList<String>(), harness.credentialKeys())
        assertEquals("the record is deleted together with its tool snapshots, permissions, conversation switches and connection state", emptyMap<String, Int>(), harness.nonEmptyTables())
    }

    @Test
    fun `confirming removal on the detail page marks the page gone`() = runBlocking {
        val server = harness.addServer()
        val controller = detailController(server)
        controller.reload()
        withTimeout(5_000) { controller.state.first { it.loaded } }

        controller.askRemove()
        assertTrue(controller.state.value.showRemoveConfirm)
        controller.dismissRemove()
        assertFalse(controller.state.value.showRemoveConfirm)
        assertNotNull("cancelling does not remove it", harness.store.fetchServer(server))

        controller.askRemove()
        controller.confirmRemove()
        withTimeout(5_000) { controller.state.first { it.gone } }
        assertNull(harness.store.fetchServer(server))
    }

    @Test
    fun `a server removed while its detail page is open closes the page on the next reload`() = runBlocking {
        val server = harness.addServer()
        val controller = detailController(server)
        controller.reload()
        assertFalse(withTimeout(5_000) { controller.state.first { it.loaded } }.gone)

        // The record disappears underneath the page.
        harness.store.deleteServer(server)
        controller.reload()

        withTimeout(5_000) { controller.state.first { it.gone } }
        assertEquals(McpRefreshResult.Gone, actions.refreshTools(server))
        assertTrue("nothing is sent for a server that is no longer stored", harness.mcp.requests().isEmpty())
    }

    @Test
    fun `a removal whose credentials cannot be deleted is reported as failed`() = runBlocking {
        val server = harness.addServer(oauth = true)
        harness.prefs.failDeletes = true
        assertFalse(actions.remove(server))
    }

    // ── Entering the address again ─────────────────────────────

    @Test
    fun `a local-only server restored without its address needs it again and sends nothing until it is entered`() = runBlocking {
        val full = "$ENDPOINT?key=abc123"
        val server = harness.addServer(name = "Home NAS", url = full)
        assertTrue(harness.store.fetchServer(server)!!.localOnly)
        assertEquals("the database holds only the display address", ENDPOINT, harness.store.fetchServer(server)!!.url)
        // Restored from a backup: the main database is back, the credentials file (excluded from backups) is not.
        harness.credentials.deleteEndpoint(server, UID)

        assertEquals(McpServerHealth.NeedsAddress, McpServerOverview.load(harness.store, harness.credentials, UID).single().health)
        assertEquals(McpServerProbe.NeedsAddress, actions.probe(server))
        assertEquals(McpRefreshResult.NeedsAddress, actions.refreshTools(server))
        assertTrue("no request is sent while the address is not on this device", harness.mcp.requests().isEmpty())

        assertEquals(McpAddressUpdate.Invalid(McpInvalidUrlReason.Malformed), actions.updateAddress(server, "nas.example.net/mcp"))
        assertEquals(McpAddressUpdate.Invalid(McpInvalidUrlReason.HasUserinfo), actions.updateAddress(server, "https://a:b@mcp.example.com/mcp"))

        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        val result = actions.updateAddress(server, full)

        assertTrue(result is McpAddressUpdate.Saved)
        assertEquals(McpServerEndpointResolution.Ready(full), McpServerEndpoint.resolve(harness.store.fetchServer(server)!!, UID, harness.credentials))
        assertEquals("the full address goes only to the credential store; the database still holds the display address", ENDPOINT, harness.store.fetchServer(server)!!.url)
        assertEquals("requests go to the full address", full, harness.mcp.requests().first().url)
        assertEquals(McpServerHealth.Connected, McpServerOverview.load(harness.store, harness.credentials, UID).single().health)
    }

    @Test
    fun `entering an address on a different origin drops the stored token before anything is sent there`() = runBlocking {
        val server = harness.addServer(name = "Home NAS", url = "$ENDPOINT?key=abc123", authKind = McpAuthKind.Token, token = "secret-token")
        assertEquals("secret-token", harness.credentials.load(server, UID)?.pastedToken)
        harness.credentials.deleteEndpoint(server, UID)

        // The new address is on a different host: the token was issued for the original origin and must not travel there.
        harness.mcp.enqueue(harness.unauthorized())
        val result = actions.updateAddress(server, "https://other.example.com/mcp?key=zzz")

        assertEquals(McpAddressUpdate.Saved(McpRefreshResult.NeedsAuth), result)
        assertNull("the old token is deleted", harness.credentials.load(server, UID))
        assertTrue("requests to the new origin carry no old token", harness.mcp.requests().none { it.header("Authorization") != null })
        assertEquals("https://other.example.com/mcp?key=zzz", harness.credentials.loadEndpoint(server, UID))
        assertEquals(McpConnectionStatus.NeedsAuth, harness.store.fetchConnectionState(server)?.status)
    }

    @Test
    fun `entering the same origin again keeps the stored token`() = runBlocking {
        val server = harness.addServer(name = "Home NAS", url = "$ENDPOINT?key=abc123", authKind = McpAuthKind.Token, token = "secret-token")
        harness.credentials.deleteEndpoint(server, UID)
        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())

        actions.updateAddress(server, "$ENDPOINT?key=rotated456")

        assertEquals("secret-token", harness.credentials.load(server, UID)?.pastedToken)
        assertEquals("Bearer secret-token", harness.mcp.requests().first().header("Authorization"))
    }

    @Test
    fun `the detail page saves a re-entered address and reports a bad one under the field`() = runBlocking {
        val full = "$ENDPOINT?key=abc123"
        val server = harness.addServer(name = "Home NAS", url = full)
        harness.credentials.deleteEndpoint(server, UID)
        val controller = detailController(server)
        controller.reload()
        assertEquals(McpServerHealth.NeedsAddress, withTimeout(5_000) { controller.state.first { it.loaded } }.health)

        controller.updateAddressDraft("http://nas.example.net/mcp")
        controller.saveAddress()
        val invalid = withTimeout(5_000) { controller.state.first { it.addressError != null && it.busy == null } }
        assertEquals(McpInvalidUrlReason.Malformed, invalid.addressError)

        harness.mcp.enqueue(harness.toolsList(), harness.toolsList())
        controller.updateAddressDraft(full)
        assertNull(controller.state.value.addressError)
        controller.saveAddress()
        val saved = withTimeout(5_000) { controller.state.first { it.health == McpServerHealth.Connected } }
        assertTrue(saved.summary!!.record.localOnly)
        delay(50)
        assertEquals("", controller.state.value.addressDraft)
    }
}

/** A different token from the token endpoint (the credentials really changed after signing in again). */
private object McpScriptedTransportTokens {
    val rotated: JsonElement = buildJsonObject {
        put("access_token", "rotated-access-token")
        put("token_type", "Bearer")
        put("expires_in", 3600)
        put("refresh_token", "rotated-refresh-token")
    }
}
