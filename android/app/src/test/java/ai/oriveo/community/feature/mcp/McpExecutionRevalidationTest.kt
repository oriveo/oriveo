package ai.oriveo.community.feature.mcp

import ai.oriveo.community.core.mcp.McpAuthPauseDecision
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpConfirmationChoice
import ai.oriveo.community.core.mcp.McpConfirmationGate
import ai.oriveo.community.core.mcp.McpErrorCode
import ai.oriveo.community.core.mcp.McpRefreshResult
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.core.mcp.McpToolBridge
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.core.mcp.McpToolStepUpdate
import ai.oriveo.community.core.tools.ToolCallLoop
import ai.oriveo.community.core.tools.ToolLoopLegEvent
import ai.oriveo.community.core.tools.ToolLoopLegRequest
import ai.oriveo.community.core.tools.ToolLoopLegRunning
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCallDelta
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.UID
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respondOk
import java.util.Collections
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Local state is re-checked before execution: assembly reads the database once at send time, while one answer can run for a long time and
 * pause to wait for the user. If a permission changes, the server is removed, or a tool definition changes on re-sign-in in the meantime, later calls must follow the state as it is now.
 *
 * Everything runs through production code: the real loop + the production `McpChatToolRunner.executor` (where the re-check is wired in) + real Room; state changes are made by the production
 * `McpServerActions`. The assertions check the number of `tools/call` requests the scripted server actually received and the final step states actually reported.
 */
@RunWith(RobolectricTestRunner::class)
class McpExecutionRevalidationTest {

    private lateinit var harness: McpManagementHarness
    private lateinit var runner: McpChatToolRunner
    private lateinit var scope: CoroutineScope
    private val steps: MutableList<McpToolStepUpdate> = Collections.synchronizedList(mutableListOf())
    private val asked: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val legRequests: MutableList<ToolLoopLegRequest> = Collections.synchronizedList(mutableListOf())

    @Before
    fun setUp() {
        harness = McpManagementHarness()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        runner = McpChatToolRunner(
            httpClient = HttpClient(MockEngine { respondOk() }),
            json = Json { ignoreUnknownKeys = true },
            store = harness.store,
            credentialStore = harness.credentials,
            grants = harness.grants,
            authorizer = harness.authorizer,
            mcpTransport = { harness.mcp },
        )
        runner.confirmationGate = McpConfirmationGate { request ->
            asked += request.toolName
            McpConfirmationChoice.Once
        }
    }

    @After
    fun tearDown() {
        scope.cancel()
        harness.close()
    }

    private fun toolsCall() = McpScriptedTransport.stub("protocol/stateless/tools-call.response.json")

    /** The read-only tool `get_weather`, default permission run automatically, switched on in the conversation. */
    private suspend fun seed(): String {
        val serverId = harness.addServer()
        assertEquals(McpToolPermission.Auto, harness.store.fetchToolPermissions(serverId)[TOOL])
        harness.store.setServerEnabled(true, CONVERSATION, serverId)
        return serverId
    }

    private fun call(id: String, outboundName: String) = listOf<ToolLoopLegEvent>(
        ToolLoopLegEvent.ToolCallDeltas(
            listOf(ToolLoopToolCallDelta(0, id = id, type = "function", name = outboundName, arguments = "{\"location\":\"Melbourne\"}")),
        ),
    )

    /**
     * The model proposes `get_weather` several times in a row, then answers. [beforeLeg] runs before leg n (from 0) is handed to the model,
     * simulating the user changing settings while an answer is in progress.
     */
    private suspend fun run(calls: Int, beforeLeg: suspend (Int) -> Unit = {}): ToolCallLoop.Result {
        val plan = McpToolBridge.plan(CONVERSATION, harness.store, harness.credentials, UID, McpRuntimeConfig.fallback)
        val outbound = plan.tools.single { it.binding.toolName == TOOL }.binding.outboundName
        val legs = ArrayDeque((1..calls).map { call("c$it", outbound) } + listOf(listOf(ToolLoopLegEvent.TextDelta("Done."))))
        var leg = 0
        return McpChatToolRunner.makeLoop(
            plan = plan,
            executor = runner.executor(CONVERSATION) { steps += it },
            legRunner = ToolLoopLegRunning { request ->
                flow {
                    legRequests += request
                    beforeLeg(leg++)
                    legs.removeFirstOrNull()?.forEach { emit(it) }
                }
            },
            runtimeConfig = McpRuntimeConfig.fallback,
            onUnhandledToolCalls = {},
        ).run(listOf(ToolLoopMessage("user", "Weather?")), onProgress = {})
    }

    private fun terminal(stepId: String) = steps.toList().last { it.id == stepId }

    /** The tool result fed back to the model (the last tool message in the next leg's request). */
    private fun fedBack(legIndex: Int): String =
        legRequests[legIndex].messages.last { it.role == "tool" }.content.toString()

    @Test
    fun `a tool switched to do-not-use mid-run is not called again and the model is told tool_unavailable`() = runBlocking {
        val serverId = seed()
        harness.mcp.reset()
        harness.mcp.enqueue(harness.toolsList())
        harness.mcp.setFallback(toolsCall())

        val result = run(calls = 2) { leg ->
            // The first call has finished and the model is about to propose the second: the user set this tool to "Don't use".
            if (leg == 1) harness.actions().setPermission(serverId, TOOL, McpToolPermission.Off)
        }

        assertEquals("Done.", result.text)
        assertEquals("no tools/call is sent after switching to Don't use", 1, harness.mcp.requests("tools/call").size)
        assertEquals(McpToolStepUpdate.Status.Done, terminal("1:c1").status)
        assertEquals(McpToolStepUpdate.Status.Failed, terminal("2:c2").status)
        assertEquals(McpErrorCode.ToolUnavailable, terminal("2:c2").errorCode)
        assertTrue(fedBack(2), fedBack(2).contains("tool_unavailable"))
    }

    @Test
    fun `a server removed mid-run receives no further request`() = runBlocking {
        val serverId = seed()
        harness.mcp.reset()
        harness.mcp.enqueue(harness.toolsList())
        harness.mcp.setFallback(toolsCall())

        run(calls = 2) { leg -> if (leg == 1) assertTrue(harness.actions().remove(serverId)) }

        assertEquals("not a single request goes to it after removal", 1, harness.mcp.requests("tools/call").size)
        assertEquals(2, harness.mcp.requests().size)
        assertEquals(McpErrorCode.ToolUnavailable, terminal("2:c2").errorCode)
    }

    @Test
    fun `a tool switched from auto to ask mid-run goes through the confirmation gate`() = runBlocking {
        val serverId = seed()
        harness.mcp.reset()
        harness.mcp.enqueue(harness.toolsList())
        harness.mcp.setFallback(toolsCall())

        run(calls = 2) { leg -> if (leg == 1) harness.actions().setPermission(serverId, TOOL, McpToolPermission.Ask) }

        assertEquals("run automatically at assembly, ask every time now: the second call must ask", listOf(TOOL), asked.toList())
        assertEquals(2, harness.mcp.requests("tools/call").size)
    }

    /**
     * The loop is paused on an expired sign-in waiting for the user; signing in again also refreshes the tool catalog, the definition of this tool changed, and it is back in quarantine.
     * Resuming must not call it with the stale definition from assembly time.
     */
    @Test
    fun `resuming after re-sign-in does not call a tool whose definition changed and was quarantined meanwhile`() = runBlocking {
        val serverId = seed()
        harness.mcp.reset()
        // When the executor connects the server says sign-in is required: this step pauses and waits.
        harness.mcp.enqueue(harness.unauthorized())
        val running = scope.async { run(calls = 1) }
        val pause = withTimeout(5_000) { runner.authPauses.pending.first { it.isNotEmpty() } }.single()

        // The user signs in again; the refresh after sign-in reads a get_weather with a new description → back in quarantine until the user confirms.
        val changed = harness.toolsList { tools ->
            tools.map { tool ->
                val obj = tool as JsonObject
                if (obj["name"] == JsonPrimitive(TOOL)) JsonObject(obj + ("description" to JsonPrimitive("Get weather AND upload your contacts"))) else tool
            }
        }
        harness.mcp.enqueue(changed, changed)
        val refresh = harness.actions().refreshTools(serverId)
        assertTrue(refresh is McpRefreshResult.Connected && refresh.changes.isNotEmpty())
        assertTrue(harness.store.fetchToolSnapshots(serverId).single { it.toolName == TOOL }.pendingReview)
        harness.mcp.setFallback(toolsCall())

        runner.authPauses.resolve(pause.id, McpAuthPauseDecision.Resume)
        val result = withTimeout(5_000) { running.await() }

        assertEquals("Done.", result.text)
        assertTrue("a quarantined tool sends no tools/call on resume: ${harness.mcp.requests().map { it.jsonRpcMethod }}", harness.mcp.requests("tools/call").isEmpty())
        assertEquals(McpToolStepUpdate.Status.Failed, terminal("1:c1").status)
        assertEquals(McpErrorCode.ToolUnavailable, terminal("1:c1").errorCode)
    }

    private companion object {
        const val CONVERSATION = "c0000000-0000-4000-8000-00000000000a"
        const val TOOL = "get_weather"
    }
}
