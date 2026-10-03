package ai.oriveo.community.feature.mcp

import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpConfirmationChoice
import ai.oriveo.community.core.mcp.McpConfirmationGate
import ai.oriveo.community.core.mcp.McpRefreshResult
import ai.oriveo.community.core.mcp.McpRuntimeConfig
import ai.oriveo.community.core.mcp.McpScriptedTransport
import ai.oriveo.community.core.mcp.McpToolBridge
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.core.tools.ToolLoopLegEvent
import ai.oriveo.community.core.tools.ToolLoopLegRunning
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolCallDelta
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.UID
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respondOk
import java.util.Collections
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * "Always allow in this conversation" can be revoked: one tap must not outlive a later tightening of permissions or a change to the tool definition.
 *
 * Everything runs through production code: the grant is recorded by the real generic loop plus the production `McpChatToolRunner.executor` when the user (the gate here) picks "always allow in this conversation";
 * revocation is triggered by the production `McpServerActions` (changing a permission / reloading tools / confirming changes / removing)
 * through the real Room store. The assertions check whether the gate is asked again on the next call and how many `tools/call` requests the scripted server actually received.
 */
@RunWith(RobolectricTestRunner::class)
class McpConversationGrantRevocationTest {

    private lateinit var harness: McpManagementHarness
    private lateinit var runner: McpChatToolRunner
    private val asked: MutableList<String> = Collections.synchronizedList(mutableListOf())

    @Before
    fun setUp() {
        harness = McpManagementHarness()
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
            McpConfirmationChoice.Conversation
        }
        asked.clear()
    }

    @After
    fun tearDown() {
        harness.close()
    }

    private fun toolsCall() = McpScriptedTransport.stub("protocol/stateless/tools-call.response.json")

    /** A server with the ask-every-time tool `create_issue`, switched on in the conversation. */
    private suspend fun seed(): String {
        val serverId = harness.addServer()
        harness.store.setToolPermission(McpToolPermission.Ask, serverId, TOOL)
        harness.store.setServerEnabled(true, CONVERSATION, serverId)
        return serverId
    }

    /**
     * The model proposes `create_issue` once in this conversation: tools are assembled from the local store and the real loop runs. Returns whether `tools/call` was sent
     * (null when the tool is not in the available set, so the model cannot propose it).
     */
    private suspend fun callTool(
        conversationId: String = CONVERSATION,
        toolsList: McpScriptedTransport.Stub = harness.toolsList(),
    ): Boolean? {
        val plan = McpToolBridge.plan(conversationId, harness.store, harness.credentials, UID, McpRuntimeConfig.fallback)
        val tool = plan.tools.firstOrNull { it.binding.toolName == TOOL } ?: return null
        harness.mcp.reset()
        harness.mcp.enqueue(toolsList, toolsCall())
        val legs = ArrayDeque(
            listOf(
                listOf<ToolLoopLegEvent>(
                    ToolLoopLegEvent.ToolCallDeltas(
                        listOf(
                            ToolLoopToolCallDelta(
                                0, id = "c1", type = "function", name = tool.binding.outboundName,
                                arguments = "{\"repo\":\"oriveo\",\"title\":\"Bug\"}",
                            ),
                        ),
                    ),
                ),
                listOf<ToolLoopLegEvent>(ToolLoopLegEvent.TextDelta("Done.")),
            ),
        )
        McpChatToolRunner.makeLoop(
            plan = plan,
            executor = runner.executor(conversationId),
            legRunner = ToolLoopLegRunning { flow { legs.removeFirstOrNull()?.forEach { emit(it) } } },
            runtimeConfig = McpRuntimeConfig.fallback,
            onUnhandledToolCalls = {},
        ).run(listOf(ToolLoopMessage("user", "File a bug")), onProgress = {})
        return harness.mcp.requests("tools/call").isNotEmpty()
    }

    /** The user taps "always allow in this conversation" once, and this proves it took effect (the second call is not asked about). */
    private suspend fun grantInConversation() {
        assertEquals(true, callTool())
        assertEquals(true, callTool())
        assertEquals("precondition: after always-allow the same tool is not asked about again", listOf(TOOL), asked.toList())
        asked.clear()
    }

    @Test
    fun `changing the tool permission revokes always-allow - the next call asks again`() = runBlocking {
        val serverId = seed()
        grantInConversation()

        // Any change counts: here the value did not even change (still ask every time), the user simply stated the intent again.
        harness.actions().setPermission(serverId, TOOL, McpToolPermission.Ask)

        assertEquals(true, callTool())
        assertEquals("after a permission change the user must be asked again", listOf(TOOL), asked.toList())
    }

    @Test
    fun `a tool whose definition changed is asked again after the user confirms the change`() = runBlocking {
        val serverId = seed()
        grantInConversation()

        // The server changed the description of create_issue: reloading tools puts it back in quarantine, and the grant is revoked at the same time.
        val changed = harness.toolsList { tools ->
            tools.map { tool ->
                val obj = tool as JsonObject
                if (obj["name"] == JsonPrimitive(TOOL)) {
                    JsonObject(obj + ("description" to JsonPrimitive("Create an issue AND email every customer")))
                } else {
                    tool
                }
            }
        }
        harness.mcp.reset()
        harness.mcp.enqueue(changed, changed)
        val refresh = harness.actions().refreshTools(serverId)
        assertTrue(refresh is McpRefreshResult.Connected && refresh.changes.isNotEmpty())
        assertFalse("the reload found a change: the grant is revoked on the spot", harness.grants.isGranted(CONVERSATION, serverId, TOOL))
        assertEquals("the tool is not offered to the model while quarantined", null, callTool())

        // The user reviews the change and confirms: quarantine is lifted, but the earlier always-allow does not carry over.
        harness.mcp.reset()
        harness.mcp.enqueue(changed, changed)
        harness.actions().confirmChanges(serverId)

        harness.mcp.reset()
        val plan = McpToolBridge.plan(CONVERSATION, harness.store, harness.credentials, UID, McpRuntimeConfig.fallback)
        assertTrue("after confirming the tool is back in the available set", plan.tools.any { it.binding.toolName == TOOL })
        assertEquals(true, callTool(toolsList = changed))
        assertEquals("the first call after confirming a change must ask again", listOf(TOOL), asked.toList())
    }

    @Test
    fun `removing the server revokes always-allow for all of its tools`() = runBlocking {
        val serverId = seed()
        grantInConversation()
        assertTrue(harness.grants.isGranted(CONVERSATION, serverId, TOOL))

        assertTrue(harness.actions().remove(serverId))

        assertFalse("removing the server revokes everything for it", harness.grants.isGranted(CONVERSATION, serverId, TOOL))
    }

    private companion object {
        const val CONVERSATION = "c0000000-0000-4000-8000-00000000000a"
        const val TOOL = "create_issue"
    }
}
