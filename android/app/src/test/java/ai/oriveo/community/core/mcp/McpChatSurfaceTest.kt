package ai.oriveo.community.core.mcp

import androidx.room.Room
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * The data behind the chat screen's tool entry point, panel, confirmation and step block.
 *
 * The panel runs on real Room storage and the production entry point `McpChatToolRunner`; the available-tool
 * accounting is asserted to match the send path's `plan`.
 */
@RunWith(RobolectricTestRunner::class)
class McpChatSurfaceTest {

    private lateinit var db: OriveoDatabase
    private lateinit var credentials: McpCredentialStore
    private lateinit var store: McpServerStore
    private var config = McpRuntimeConfig.fallback

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        credentials = McpCredentialStore(InMemoryPrefs())
        // Monotonic clock: enable order sorts by `enabledAt`, and with a real clock two servers enabled within the same
        // millisecond would fall back to comparing ids (an intermittent failure).
        val clock = java.util.concurrent.atomic.AtomicLong(1_700_000_000_000L)
        store = McpServerStore(db.mcpServerDao(), credentials, now = { clock.incrementAndGet() })
        config = McpRuntimeConfig.fallback
    }

    @After
    fun tearDown() {
        db.close()
    }

    private fun runner() = McpChatToolRunner(
        httpClient = HttpClient(MockEngine { respond("") }),
        json = Json { ignoreUnknownKeys = true },
        store = store,
        credentialStore = credentials,
        runtimeConfig = { config },
    )

    private fun snapshot(name: String, readOnly: Boolean = true, pendingReview: Boolean = false, oversized: Boolean = false) = McpToolSnapshot(
        serverId = "",
        toolName = name,
        title = name,
        description = "Tool $name",
        inputSchema = buildJsonObject { put("type", "object") },
        annotations = buildJsonObject { put("readOnlyHint", readOnly) },
        contentHash = mcpSha256Hex(name),
        readOnly = readOnly,
        pendingReview = pendingReview,
        oversized = oversized,
        updatedAt = 1L,
    )

    private suspend fun seed(
        id: String,
        name: String,
        tools: List<McpToolSnapshot>,
        permissions: Map<String, McpToolPermission> = emptyMap(),
        status: McpConnectionStatus = McpConnectionStatus.Connected,
        lastSuccessAt: Long? = null,
        url: String = "https://$name.example.com/mcp",
        localOnly: Boolean = false,
    ) {
        store.addServer(
            McpServerAddition(
                id = id, name = name, url = url, authKind = McpAuthKind.Auto, localOnly = localOnly, iconURL = null,
                createdAt = 1L, snapshots = tools.map { it.copy(serverId = id) }, permissions = permissions,
                connectionState = McpConnectionState(id, status, lastSuccessAt = lastSuccessAt),
            ),
            maxServers = 20,
        )
    }

    private fun relay(toolCall: Boolean? = true): Pair<Provider, AIModel> {
        val model = AIModel(id = "m", name = "M", toolCall = toolCall)
        val provider = Provider(
            id = "relay", kind = ProviderKind.Relay, apiKey = "k", baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions), models = listOf(model),
        )
        return provider to model
    }

    // ── Availability ──────────────────────────────────────────

    @Test
    fun `availability follows what is known about the connection and the model`() {
        val runner = runner()
        val (provider, relayModel) = relay()
        assertEquals(McpToolAvailability.Available, runner.availability(provider, relayModel, memoryVerdict = null, localIdentity = IDENTITY))
        assertEquals(
            "without a connection identity the Relay decision stays pending and nothing is let through",
            McpToolAvailability.ModelUnsupported,
            runner.availability(provider, relayModel, memoryVerdict = null),
        )
        val (_, declaredOff) = relay(toolCall = false)
        assertEquals(
            "the connection declares that this model does not support tool calls",
            McpToolAvailability.ModelUnsupported,
            runner.availability(provider, declaredOff, memoryVerdict = null, localIdentity = IDENTITY),
        )
        assertEquals("no model selected yet is not treated as unavailable", McpToolAvailability.Available, runner.availability(null, null, null))
    }

    @Test
    fun `the entry follows the enabled switch of the runtime config`() {
        val runner = runner()
        assertTrue(runner.isFeatureEnabled)
        config = config.copy(enabled = false)
        assertFalse(runner.isFeatureEnabled)
    }

    // ── Panel ─────────────────────────────────────────────────

    @Test
    fun `panel rows carry status tool counts and the per conversation switch`() = runBlocking {
        seed(LINEAR, "linear", listOf(snapshot("search"), snapshot("read"), snapshot("hidden", pendingReview = true)))
        seed(
            NOTION, "notion", listOf(snapshot("find"), snapshot("create", readOnly = false), snapshot("off")),
            permissions = mapOf("off" to McpToolPermission.Off),
        )
        seed(GITHUB, "github", listOf(snapshot("issues")), status = McpConnectionStatus.NeedsAuth)
        seed(NAS, "nas", listOf(snapshot("files")), status = McpConnectionStatus.Unreachable, lastSuccessAt = 1_000L)
        store.setServerEnabled(true, CONV, NOTION)
        store.setServerEnabled(true, CONV, GITHUB)

        val panel = runner().loadPanel(CONV, McpToolAvailability.Available)

        val rows = panel.rows.associateBy { it.id }
        assertEquals("quarantined tools are not counted", 2, rows.getValue(LINEAR).toolCount)
        assertEquals("tools set to never use are not counted", 2, rows.getValue(NOTION).toolCount)
        assertEquals(McpToolPanelServerRow.Status.Ready, rows.getValue(LINEAR).status)
        assertEquals(McpToolPanelServerRow.Status.NeedsAuth, rows.getValue(GITHUB).status)
        assertEquals(McpToolPanelServerRow.Status.Unreachable(1_000L), rows.getValue(NAS).status)
        assertFalse(rows.getValue(LINEAR).isEnabled)
        assertTrue(rows.getValue(NOTION).isEnabled)

        assertTrue(rows.getValue(LINEAR).canToggle)
        assertFalse("a row that needs re-authorization has no switch", rows.getValue(GITHUB).canToggle)
        assertFalse("a row that is unreachable and off has its switch disabled", rows.getValue(NAS).canToggle)

        // Pill count = servers that are enabled and usable: GitHub is on but needs re-authorization, so it does not count.
        assertEquals(1, panel.enabledServerCount)
        // Same accounting as the send path: the tool count the panel reports is the number of tools plan will carry.
        val plan = McpToolBridge.plan(CONV, store, credentials, LOCAL_PARTITION_ID, config)
        assertEquals(plan.tools.size, panel.outboundToolCount)
        assertEquals(2, panel.outboundToolCount)
        assertEquals(McpToolPanelModel.estimatedTokens(plan), panel.estimatedTokens)
        assertEquals("with tools present the estimate is at least 100", 100, panel.estimatedTokens)
        assertFalse(panel.truncated)
    }

    @Test
    fun `an unavailable connection keeps the server list but counts nothing`() = runBlocking {
        seed(LINEAR, "linear", listOf(snapshot("search")))
        store.setServerEnabled(true, CONV, LINEAR)

        val panel = runner().loadPanel(CONV, McpToolAvailability.ModelUnsupported)

        assertTrue(panel.hasServers)
        assertEquals("the pill is greyed out and shows no number", 0, panel.enabledServerCount)
        assertEquals(0, panel.outboundToolCount)
        assertEquals(0, panel.estimatedTokens)
    }

    @Test
    fun `more tools than the per request limit are truncated and reported`() = runBlocking {
        config = config.copy(maxToolsPerRequest = 2)
        seed(LINEAR, "linear", listOf(snapshot("a"), snapshot("b"), snapshot("c")))
        store.setServerEnabled(true, CONV, LINEAR)

        val panel = runner().loadPanel(CONV, McpToolAvailability.Available)

        assertTrue(panel.truncated)
        assertEquals(2, panel.outboundToolCount)
        assertEquals(2, panel.maxToolsPerRequest)
    }

    @Test
    fun `a local-only server whose address is not on this device asks for the address again`() = runBlocking {
        seed(NAS, "nas", listOf(snapshot("files")), url = "https://nas.example.com/mcp?token=secret-token-value", localOnly = true)
        store.setServerEnabled(true, CONV, NAS)
        credentials.deleteEndpoint(NAS, LOCAL_PARTITION_ID)

        val row = runner().loadPanel(CONV, McpToolAvailability.Available).rows.single()

        assertEquals(McpToolPanelServerRow.Status.NeedsAddress, row.status)
        assertFalse(row.contributesTools)
    }

    @Test
    fun `token estimate is the serialized definition length over four rounded to hundreds`() {
        assertEquals(0, McpToolPanelModel.estimatedTokens(McpToolPlan.Empty))
        val long = snapshot("search").copy(serverId = LINEAR, description = "d".repeat(2_000))
        val plan = McpToolBridge.plan(
            listOf(
                McpBridgeServerInput(
                    record = McpServerRecord(LINEAR, "Linear", "linear", "https://l.example.com/mcp", McpAuthKind.Auto, false, null, 1L, 1L),
                    endpoint = McpServerEndpointResolution.Ready("https://l.example.com/mcp"),
                    connectionStatus = McpConnectionStatus.Connected,
                    snapshots = listOf(long),
                    permissions = emptyMap(),
                ),
            ),
            McpRuntimeConfig.fallback,
        )
        // About 2,100 characters / 4 ≈ 525 -> 500.
        assertEquals(500, McpToolPanelModel.estimatedTokens(plan))
    }

    // ── Switches on a draft conversation ──────────────────────

    @Test
    fun `switches made in a draft follow the conversation once the first message creates it`() = runBlocking {
        seed(LINEAR, "linear", listOf(snapshot("search")))
        seed(NOTION, "notion", listOf(snapshot("find")))
        val runner = runner()
        runner.setServerEnabled(true, DRAFT, NOTION)
        runner.setServerEnabled(true, DRAFT, LINEAR)

        runner.adoptDraftSwitches(DRAFT, CONV)

        assertEquals("enable order is kept as is", listOf(NOTION, LINEAR), store.fetchEnabledServerIds(CONV))
        assertEquals("nothing is left under the draft", emptyList<String>(), store.fetchEnabledServerIds(DRAFT))
        val (provider, model) = relay()
        assertEquals(2, runner.plan(CONV, provider, model, memoryVerdict = null, localIdentity = IDENTITY).tools.size)
        assertTrue("Relay without a connection identity carries no tools", runner.plan(CONV, provider, model, memoryVerdict = null).isEmpty)
    }

    @Test
    fun `discarding a draft leaves the next new chat with everything off`() = runBlocking {
        seed(LINEAR, "linear", listOf(snapshot("search")))
        val runner = runner()
        runner.setServerEnabled(true, DRAFT, LINEAR)
        runner.setServerEnabled(true, CONV, LINEAR)

        runner.discardDraftSwitches(DRAFT)

        assertEquals(0, runner.loadPanel(DRAFT, McpToolAvailability.Available).enabledServerCount)
        assertEquals("other conversations are unaffected", 1, runner.loadPanel(CONV, McpToolAvailability.Available).enabledServerCount)
    }

    // ── Parameter display in the confirmation dialog ──────────

    private fun args(vararg pairs: Pair<String, String>): JsonElement = McpJson.parse(
        pairs.joinToString(",", "{", "}") { (key, raw) -> "${McpJson.encodeString(key)}:$raw" },
    )

    @Test
    fun `confirmation shows the first four top level parameters in the order the model gave them`() {
        val long = "x".repeat(640)
        val arguments = args(
            "parent" to "\"Sprint notes\"",
            "title" to "\"Week 40\"",
            "content" to McpJson.encodeString(long),
            "tags" to "[\"a\",\"b\"]",
            "draft" to "true",
        )

        val parameters = McpConfirmationContent.parameters(arguments)

        assertEquals(listOf("parent", "title", "content", "tags"), parameters.map { it.key })
        assertEquals(McpConfirmationParameter.Display.Inline("Sprint notes"), parameters[0].display)
        assertEquals("long text shows only its length", McpConfirmationParameter.Display.Long(640), parameters[2].display)
        assertEquals("the full-text page has the original text", long, parameters[2].fullText)
        assertEquals("non-strings are shown as JSON text", McpConfirmationParameter.Display.Inline("[\"a\",\"b\"]"), parameters[3].display)
        assertTrue(McpConfirmationContent.hasMoreParameters(arguments))
        assertTrue("the full-text page has every parameter, including the fifth", "draft: true" in McpConfirmationContent.allParametersText(arguments))
    }

    @Test
    fun `a short value with a line break is treated as long text`() {
        val parameters = McpConfirmationContent.parameters(args("body" to "\"line one\\nline two\""))
        assertTrue(parameters.single().display is McpConfirmationParameter.Display.Long)
        assertFalse(McpConfirmationContent.hasMoreParameters(args("body" to "\"x\"")))
        assertEquals(emptyList<McpConfirmationParameter>(), McpConfirmationContent.parameters(JsonObject(emptyMap())))
    }

    @Test
    fun `stored payload arguments render one key per line and unparseable text is shown as is`() {
        assertEquals("label: \"bug\"\nstate: \"open\"", McpConfirmationContent.allParametersText("{\"label\":\"bug\",\"state\":\"open\"}"))
        assertEquals("not json", McpConfirmationContent.allParametersText("not json"))
    }

    // ── The UI side of the confirmation gate ──────────────────

    private fun request(conversationId: String = CONV, tool: String = "create") = McpConfirmationRequest(
        conversationId = conversationId, serverId = NOTION, serverName = "Notion", serverHost = "mcp.notion.com",
        toolName = tool, toolTitle = tool, arguments = JsonObject(emptyMap()), inputSchema = JsonObject(emptyMap()),
    )

    @Test
    fun `confirmations queue in proposal order and each waits for its own answer`() = runBlocking {
        val coordinator = McpConfirmationCoordinator()
        val first = async { coordinator.requestConfirmation(request(tool = "create")) }
        yield()
        val second = async { coordinator.requestConfirmation(request(tool = "delete")) }
        yield()

        assertEquals(listOf("create", "delete"), coordinator.pending.value.map { it.request.toolName })
        coordinator.resolve(coordinator.pending.value.first().id, McpConfirmationChoice.Deny)
        assertEquals(McpConfirmationChoice.Deny, first.await())
        assertEquals("denying one does not stop the rest from being asked", listOf("delete"), coordinator.pending.value.map { it.request.toolName })

        coordinator.resolve(coordinator.pending.value.first().id, McpConfirmationChoice.Conversation)
        assertEquals(McpConfirmationChoice.Conversation, second.await())
        assertTrue(coordinator.pending.value.isEmpty())
    }

    @Test
    fun `stopping the answer withdraws its pending confirmation without returning a choice`() = runBlocking {
        val coordinator = McpConfirmationCoordinator()
        val stopped = async { runCatching { coordinator.requestConfirmation(request(conversationId = CONV)) } }
        val other = async { coordinator.requestConfirmation(request(conversationId = "other-conversation")) }
        yield()
        yield()

        coordinator.cancelConversation(CONV)

        assertTrue(stopped.await().exceptionOrNull() is CancellationException)
        assertEquals("the other conversation's confirmation is still waiting", listOf("other-conversation"), coordinator.pending.value.map { it.request.conversationId })
        other.cancelAndJoin()
        assertTrue("the entry is withdrawn when the coroutine that raised it is cancelled", coordinator.pending.value.isEmpty())
    }

    // ── Presentation rules of the step block ──────────────────

    private fun step(
        number: Int,
        status: McpToolStepUpdate.Status,
        server: String = "Linear",
        errorCode: McpErrorCode? = null,
        summary: String = "",
    ) = McpToolStep(
        id = "$number:c$number", serverId = LINEAR, serverName = server, toolName = "tool_$number", title = "Tool $number",
        argsSummary = summary, status = status.wireValue, errorCode = errorCode?.wireValue, step = number,
    )

    @Test
    fun `running block shows the current step number and stays open`() {
        val presentation = McpToolStepsPresentation.make(
            listOf(step(1, McpToolStepUpdate.Status.Done), step(2, McpToolStepUpdate.Status.Done), step(3, McpToolStepUpdate.Status.Running, "Notion", summary = "Weekly")),
            isGenerating = true,
        )

        assertEquals(McpToolStepsPresentation.Header.Running, presentation.header)
        assertEquals(McpToolStepsPresentation.Trailing.Step(3), presentation.trailing)
        assertTrue(presentation.isActive)
        assertEquals(McpToolStepsPresentation.RowDetail.ArgsSummary("Weekly"), presentation.rows.last().detail)
        assertFalse("a step that is still running does not open details", presentation.rows.last().opensDetail)
        assertTrue(presentation.rows.first().opensDetail)
    }

    @Test
    fun `between steps the block is still in progress`() {
        val presentation = McpToolStepsPresentation.make(listOf(step(1, McpToolStepUpdate.Status.Done)), isGenerating = true)
        assertEquals(McpToolStepsPresentation.Header.Running, presentation.header)
        assertEquals(McpToolStepsPresentation.Trailing.Step(1), presentation.trailing)
    }

    @Test
    fun `finished block counts completed steps and lists servers once each`() {
        val presentation = McpToolStepsPresentation.make(
            listOf(
                step(1, McpToolStepUpdate.Status.Done), step(2, McpToolStepUpdate.Status.Done),
                step(3, McpToolStepUpdate.Status.Done, "Notion"), step(4, McpToolStepUpdate.Status.Done, "Notion"),
            ),
            isGenerating = false,
        )

        assertEquals(McpToolStepsPresentation.Header.Finished(4), presentation.header)
        assertEquals(McpToolStepsPresentation.Trailing.Servers(listOf("Linear", "Notion")), presentation.trailing)
        assertFalse(presentation.isActive)
        assertEquals(0, presentation.hiddenEarlierCount)
    }

    @Test
    fun `declined failed and interrupted steps are not counted as used and say what happened`() {
        val declined = McpToolStepsPresentation.make(
            listOf(step(1, McpToolStepUpdate.Status.Done), step(2, McpToolStepUpdate.Status.Denied, errorCode = McpErrorCode.UserDenied)),
            isGenerating = false,
        )
        assertEquals(McpToolStepsPresentation.Header.Finished(1), declined.header)
        assertEquals(McpToolStepsPresentation.Trailing.Declined(1), declined.trailing)
        assertEquals(McpToolStepsPresentation.RowDetail.Declined, declined.rows.last().detail)

        val failed = McpToolStepsPresentation.make(
            listOf(
                step(1, McpToolStepUpdate.Status.Denied),
                step(2, McpToolStepUpdate.Status.Failed, errorCode = McpErrorCode.ToolError),
                step(3, McpToolStepUpdate.Status.NeedsAuth, "Notion", errorCode = McpErrorCode.NeedsAuth),
            ),
            isGenerating = false,
        )
        assertEquals("failure takes precedence over denial", McpToolStepsPresentation.Trailing.Failed(2), failed.trailing)
        assertEquals(McpToolStepsPresentation.RowDetail.Failure("tool_error"), failed.rows[1].detail)
        assertEquals(McpToolStepsPresentation.RowDetail.SignInExpired("Notion"), failed.rows[2].detail)

        // Once the message is no longer generating, a step still marked running is drawn as interrupted; so is an unknown status.
        val interrupted = McpToolStepsPresentation.make(
            listOf(step(1, McpToolStepUpdate.Status.Running), step(2, McpToolStepUpdate.Status.Done).copy(status = "future_status")),
            isGenerating = false,
        )
        assertEquals(listOf(McpToolStepUpdate.Status.Interrupted, McpToolStepUpdate.Status.Interrupted), interrupted.rows.map { it.status })
        assertEquals(McpToolStepsPresentation.RowDetail.Interrupted, interrupted.rows.first().detail)
        assertEquals(McpToolStepsPresentation.Header.Finished(0), interrupted.header)
    }

    @Test
    fun `a step waiting for sign-in pauses the block only while the answer is still running`() {
        val steps = listOf(step(1, McpToolStepUpdate.Status.Done), step(2, McpToolStepUpdate.Status.NeedsAuth, "Notion"))

        val paused = McpToolStepsPresentation.make(steps, isGenerating = true, pausedStepId = "2:c2")
        assertEquals(McpToolStepsPresentation.Header.WaitingForSignIn, paused.header)
        assertEquals(McpToolStepsPresentation.Trailing.Step(2), paused.trailing)
        assertEquals("2:c2", paused.pausedForSignIn?.id)

        val after = McpToolStepsPresentation.make(steps, isGenerating = false, pausedStepId = "2:c2")
        assertNull(after.pausedForSignIn)
        assertEquals(McpToolStepsPresentation.Trailing.Failed(1), after.trailing)
    }

    @Test
    fun `many steps collapse the earlier ones and the limit tail is carried`() {
        val steps = (1..8).map { step(it, McpToolStepUpdate.Status.Done) }
        val presentation = McpToolStepsPresentation.make(steps, isGenerating = false, limitReached = true)

        assertEquals(6, presentation.hiddenEarlierCount)
        assertTrue(presentation.limitReached)
        assertEquals(McpToolStepsPresentation.Header.Finished(8), presentation.header)
        assertEquals(0, McpToolStepsPresentation.make(steps.take(5), isGenerating = false).hiddenEarlierCount)
    }

    private companion object {
        val IDENTITY = CapabilityEvidenceIdentity(
            partitionId = "user", connectionInstanceId = "relay", connectionGeneration = "g1", credentialEpoch = "c1",
            providerKind = ProviderKind.Relay.rawValue, metadataRevision = "m1", generationRevision = "g1",
        )
        const val CONV = "conversation-a"
        const val DRAFT = "draft-session-1"
        const val LINEAR = "aaaaaaaa-0000-4000-8000-000000000001"
        const val NOTION = "bbbbbbbb-0000-4000-8000-000000000002"
        const val GITHUB = "cccccccc-0000-4000-8000-000000000003"
        const val NAS = "dddddddd-0000-4000-8000-000000000004"
    }
}
