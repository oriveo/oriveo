package ai.oriveo.community.core.mcp

import androidx.room.Room
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.database.OriveoDatabase
import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolLoopLegEvent
import ai.oriveo.community.core.tools.ToolLoopLegRequest
import ai.oriveo.community.core.tools.ToolLoopLegRunning
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCallDelta
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import java.util.ArrayDeque
import java.util.Collections
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Abnormal states of the tool loop.
 *
 * The executor is built by the production entry point `McpChatToolRunner.executor()` (the pause gate and the
 * connection-state write-back sit on its callback chain), and the loop comes from the production constructor
 * `McpChatToolRunner.makeLoop`; the model legs and the MCP server are scripted.
 */
@RunWith(RobolectricTestRunner::class)
class McpToolLoopExceptionTest {

    private lateinit var db: OriveoDatabase
    private lateinit var store: McpServerStore
    private lateinit var runner: McpChatToolRunner
    private val mcp = McpScriptedTransport()
    private val steps: MutableList<McpToolStepUpdate> = Collections.synchronizedList(mutableListOf())
    private var config = McpRuntimeConfig.fallback

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        val credentials = McpCredentialStore(InMemoryPrefs())
        store = McpServerStore(db.mcpServerDao(), credentials)
        runner = McpChatToolRunner(
            httpClient = HttpClient(MockEngine { respond("") }),
            json = Json { ignoreUnknownKeys = true },
            store = store,
            credentialStore = credentials,
            runtimeConfig = { config },
            mcpTransport = { mcp },
        )
        runBlocking {
            store.addServer(
                McpServerAddition(
                    id = SERVER, name = SERVER_NAME, url = ENDPOINT, authKind = McpAuthKind.Auto, localOnly = false,
                    iconURL = null, createdAt = 1L,
                    snapshots = listOf(
                        McpToolSnapshot(
                            serverId = SERVER, toolName = TOOL, title = "Find page", description = "Finds a page",
                            inputSchema = buildJsonObject {
                                put("type", "object")
                                put("properties", buildJsonObject { put("query", buildJsonObject { put("type", "string") }) })
                            },
                            annotations = buildJsonObject { put("readOnlyHint", true) },
                            contentHash = mcpSha256Hex(TOOL), readOnly = true, updatedAt = 1L,
                        ),
                    ),
                    permissions = mapOf(TOOL to McpToolPermission.Auto),
                    connectionState = McpConnectionState(SERVER, McpConnectionStatus.Connected),
                ),
                maxServers = 20,
            )
            store.setServerEnabled(true, CONV, SERVER)
        }
    }

    @After
    fun tearDown() {
        db.close()
    }

    // ── Setup ────────────────────────────────────────

    private class ScriptedLegs(legs: List<List<ToolLoopLegEvent>>) : ToolLoopLegRunning {
        private val legs = ArrayDeque(legs)
        val requests: MutableList<ToolLoopLegRequest> = Collections.synchronizedList(mutableListOf())

        override fun run(request: ToolLoopLegRequest): Flow<ToolLoopLegEvent> = flow {
            requests += request
            (legs.pollFirst() ?: error("No scripted model leg")).forEach { emit(it) }
        }
    }

    private fun toolLeg(id: String, query: String = SECRET_ARGUMENT) = listOf<ToolLoopLegEvent>(
        ToolLoopLegEvent.ToolCallDeltas(
            listOf(ToolLoopToolCallDelta(0, id = id, type = "function", name = OUTBOUND, arguments = "{\"query\":\"$query\"}")),
        ),
    )

    private fun textLeg(text: String) = listOf<ToolLoopLegEvent>(ToolLoopLegEvent.TextDelta(text))

    private fun toolsList() = McpScriptedTransport.stub("protocol/stateless/tools-list.response.json")

    private fun toolsCall(text: String = RESULT_TEXT) = McpScriptedTransport.stub(
        McpJson.parse(
            """{"status":200,"headers":{"Content-Type":"application/json"},"body":{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","content":[{"type":"text","text":"$text"}],"isError":false}}}""",
        ),
    )

    private fun toolError(text: String) = McpScriptedTransport.stub(
        McpJson.parse(
            """{"status":200,"headers":{"Content-Type":"application/json"},"body":{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","content":[{"type":"text","text":"$text"}],"isError":true}}}""",
        ),
    )

    private fun unauthorized() = McpScriptedTransport.status(401, mapOf("WWW-Authenticate" to "Bearer"))

    private suspend fun run(legs: ScriptedLegs): ToolCallLoop.Result {
        val plan = McpToolBridge.plan(CONV, store, McpCredentialStore(InMemoryPrefs()), LOCAL_PARTITION_ID, config)
        return McpChatToolRunner.makeLoop(plan, runner.executor(CONV) { steps += it }, legs, config) { }
            .run(McpToolBridge.initialMessages(listOf(ToolLoopMessage("user", "Find the page")), null))
    }

    private suspend fun awaitPause(): PendingMcpAuthPause =
        withTimeout(5_000) { runner.authPauses.pending.first { it.isNotEmpty() } }.first()

    private fun toolResults(legs: ScriptedLegs, legIndex: Int): List<String> =
        legs.requests[legIndex].messages.filter { it.role == "tool" }.mapNotNull { it.textContent }

    private fun statuses() = steps.map { it.status.wireValue + if (it.awaitingAuth) "(waiting)" else "" }

    // ── Authorization expired midway: pause and resume ────────────────────────────────────────

    @Test
    fun `an expired sign-in pauses on that step and picks up from it after signing in again`() = runBlocking {
        mcp.enqueue(toolsList(), unauthorized(), toolsList(), toolsCall())
        val legs = ScriptedLegs(listOf(toolLeg("c1"), textLeg("Found it.")))

        val result: Deferred<ToolCallLoop.Result> = async(Dispatchers.Default) { run(legs) }
        val pause = awaitPause()

        assertEquals(listOf("running", "needsAuth(waiting)"), statuses())
        assertEquals("1:c1", pause.request.stepId)
        assertEquals(SERVER_NAME, pause.request.serverName)
        assertEquals("the panel shows authorization expired accordingly", McpConnectionStatus.NeedsAuth, store.fetchConnectionState(SERVER)?.status)
        assertEquals("the model has not been asked for the next leg yet", 1, legs.requests.size)

        runner.authPauses.resolve(pause.id, McpAuthPauseDecision.Resume)
        val finished = result.await()

        assertEquals(listOf("running", "needsAuth(waiting)", "running", "done"), statuses())
        assertEquals("the same step reconnects with the new credentials and calls once more", 2, mcp.requests("tools/call").size)
        assertEquals("Found it.", finished.text)
        assertTrue("the result is fed back to the model as usual", toolResults(legs, 1).single().contains(RESULT_TEXT))
        assertTrue(runner.authPauses.pending.value.isEmpty())
    }

    @Test
    fun `skipping the step tells the model it was skipped and does not stop again for the same server`() = runBlocking {
        mcp.enqueue(toolsList(), unauthorized())
        mcp.setFallback(unauthorized())
        val legs = ScriptedLegs(listOf(toolLeg("c1"), toolLeg("c2"), textLeg("Answer without the page.")))

        val result = async(Dispatchers.Default) { run(legs) }
        val pause = awaitPause()
        runner.authPauses.resolve(pause.id, McpAuthPauseDecision.Skip)
        val finished = result.await()

        assertEquals("Answer without the page.", finished.text)
        assertEquals(
            listOf("running", "needsAuth(waiting)", "failed", "running", "failed"),
            statuses(),
        )
        assertEquals(listOf(McpErrorCode.AuthSkipped, McpErrorCode.AuthSkipped), steps.filter { it.status == McpToolStepUpdate.Status.Failed }.map { it.errorCode })
        assertTrue("what is fed back is a closed-set code", toolResults(legs, 1).single().contains("auth_skipped"))
        assertEquals("the second call did not pause to ask again", 0, runner.authPauses.pending.value.size)
        assertEquals("no more calls go to that server after skipping", 1, mcp.requests("tools/call").size)
    }

    @Test
    fun `if signing in again does not help the step ends as needing sign-in instead of pausing forever`() = runBlocking {
        mcp.enqueue(toolsList(), unauthorized(), toolsList(), unauthorized())
        val legs = ScriptedLegs(listOf(toolLeg("c1"), textLeg("Could not read it.")))

        val result = async(Dispatchers.Default) { run(legs) }
        runner.authPauses.resolve(awaitPause().id, McpAuthPauseDecision.Resume)
        result.await()

        assertEquals(listOf("running", "needsAuth(waiting)", "running", "needsAuth"), statuses())
        assertTrue(runner.authPauses.pending.value.isEmpty())
        assertTrue(toolResults(legs, 1).single().contains("needs_auth"))
    }

    @Test
    fun `stopping while paused leaves the step interrupted and withdraws the pause`() = runBlocking {
        mcp.enqueue(toolsList(), unauthorized())
        val legs = ScriptedLegs(listOf(toolLeg("c1"), textLeg("unreachable")))

        val job = async(Dispatchers.Default) { runCatching { run(legs) } }
        awaitPause()
        job.cancelAndJoin()

        assertEquals(listOf("running", "needsAuth(waiting)", "interrupted"), statuses())
        assertEquals(McpErrorCode.Cancelled, steps.last().errorCode)
        assertTrue(runner.authPauses.pending.value.isEmpty())
        assertEquals("the model was not asked for another leg after the stop", 1, legs.requests.size)
    }

    @Test
    fun `stopping from the chat page cancels the pause for that conversation only`() = runBlocking {
        mcp.enqueue(toolsList(), unauthorized())
        val legs = ScriptedLegs(listOf(toolLeg("c1"), textLeg("unreachable")))
        val job = async(Dispatchers.Default) { runCatching { run(legs) } }
        awaitPause()

        runner.authPauses.cancelConversation("another-conversation")
        assertEquals(1, runner.authPauses.pending.value.size)
        runner.authPauses.cancelConversation(CONV)

        assertTrue(job.await().exceptionOrNull() is CancellationException)
        assertEquals("interrupted", steps.last().status.wireValue)
    }

    // ── Tool execution failure ────────────────────────────────────────

    @Test
    fun `a tool error keeps the server's words out of the summary and the model feedback and the answer continues`() = runBlocking {
        val serverText = "Page not found or no access: $SECRET_RESULT " + "x".repeat(400)
        mcp.enqueue(toolsList(), toolError(serverText))
        val legs = ScriptedLegs(listOf(toolLeg("c1"), textLeg("I could not find it.")))

        val result = run(legs)

        assertEquals("I could not find it.", result.text)
        val failed = steps.last()
        assertEquals(McpToolStepUpdate.Status.Failed, failed.status)
        assertEquals(McpErrorCode.ToolError, failed.errorCode)
        assertEquals("the server's error text is truncated to 200 characters and stays in the step payload only", 200, failed.payload?.resultPrefix?.length)
        assertTrue(failed.payload!!.resultPrefix!!.startsWith("Page not found"))
        val summary = McpToolStep.from(failed)
        assertFalse("the summary on the message carries no server text: $summary", SECRET_RESULT in summary.toString())
        assertFalse("only the closed-set code is fed back to the model", SECRET_RESULT in toolResults(legs, 1).single())
        assertTrue(toolResults(legs, 1).single().contains("tool_error"))
        // A failing third-party server must not blow up the whole answer.
        assertFalse(result.stepLimitReached)
    }

    // ── Step limit reached ────────────────────────────────────────

    @Test
    fun `at the step limit the loop stops offering tools and answers from what it has`() = runBlocking {
        config = config.copy(maxSteps = 2)
        mcp.enqueue(toolsList())
        mcp.setFallback(toolsCall())
        val legs = ScriptedLegs(listOf(toolLeg("c1"), toolLeg("c2"), textLeg("Here is what I have so far.")))

        val result = run(legs)

        assertTrue(result.stepLimitReached)
        assertEquals(2, result.executedToolSteps)
        assertEquals("Here is what I have so far.", result.text)
        assertEquals(listOf("done", "done"), steps.filter { it.status != McpToolStepUpdate.Status.Running }.map { it.status.wireValue })
        // Synthesis leg: no tools any more, and the model is told explicitly to answer in place.
        val synthesis = legs.requests.last()
        assertTrue(
            "the synthesis leg must not propose tools again",
            synthesis.tools.isEmpty() || synthesis.toolChoice == ai.oriveo.community.core.tools.ToolLoopToolChoice.None,
        )
        assertTrue(synthesis.messages.any { it.role == "system" && it.textContent == McpToolBridge.prompts.stepLimitReached })
    }

    // ── Confirmation declined ────────────────────────────────────────

    @Test
    fun `a call declined in the confirmation dialog sends nothing and the answer continues`() = runBlocking {
        store.setToolPermission(McpToolPermission.Ask, SERVER, TOOL)
        val confirmations = McpConfirmationCoordinator()
        runner.confirmationGate = confirmations
        val legs = ScriptedLegs(listOf(toolLeg("c1"), textLeg("Okay, I will not.")))

        val result = async(Dispatchers.Default) { run(legs) }
        val pending = withTimeout(5_000) { confirmations.pending.first { it.isNotEmpty() } }.first()
        assertEquals(TOOL, pending.request.toolName)
        assertEquals(SERVER_NAME, pending.request.serverName)
        assertEquals("the step is shown as running while the dialog is open", listOf("running"), statuses())
        confirmations.resolve(pending.id, McpConfirmationChoice.Deny)
        val finished = result.await()

        assertEquals("Okay, I will not.", finished.text)
        assertEquals(listOf("running", "denied"), statuses())
        assertEquals(McpErrorCode.UserDenied, steps.last().errorCode)
        assertEquals("nothing ran, so there is no duration", null, steps.last().durationMs)
        assertTrue(toolResults(legs, 1).single().contains("user_denied"))
        assertTrue("the server received no request after the denial", mcp.requests().isEmpty())
        assertTrue(confirmations.pending.value.isEmpty())
    }

    private companion object {
        const val CONV = "conversation-a"
        const val SERVER = "aaaaaaaa-0000-4000-8000-000000000001"
        const val SERVER_NAME = "Notionish"
        const val ENDPOINT = "https://mcp.example.com/mcp"
        const val TOOL = "find_page"
        const val OUTBOUND = "mcp_notionish_find_page"
        const val SECRET_ARGUMENT = "sprint-notes-argument"
        const val SECRET_RESULT = "result-body-marker"
        const val RESULT_TEXT = "Found the page"
    }
}
