package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.mcp.McpManagementHarness
import ai.oriveo.community.feature.mcp.McpManagementHarness.Companion.UID
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respondOk
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Cascading deletion of per-step payloads: deleting a message, deleting a conversation or removing a server must take
 * the raw arguments and results along. They must never be write-only.
 *
 * Everything goes through production paths: payloads are written to a real Room database via
 * `McpChatToolRunner.saveStepPayload` (where the chat send path lands); deletion goes through `ConversationRepository`
 * (delete a conversation / drop later messages on edit-and-resend) and `McpServerActions.remove` (remove a server).
 * Cleaning up after a deleted message or conversation is part of the delete methods of `MessageDao` /
 * `ConversationDao`, so no caller has to remember the payloads.
 */
@RunWith(RobolectricTestRunner::class)
class McpStepPayloadCascadeTest {

    private lateinit var harness: McpManagementHarness
    private lateinit var runner: McpChatToolRunner
    private lateinit var conversations: ConversationRepository

    @Before
    fun setUp() {
        harness = McpManagementHarness()
        runner = McpChatToolRunner(
            httpClient = HttpClient(MockEngine { respondOk() }),
            json = Json { ignoreUnknownKeys = true },
            store = harness.store,
            credentialStore = harness.credentials,
        )
        conversations = ConversationRepository(
            conversationDao = harness.db.conversationDao(),
            messageDao = harness.db.messageDao(),
        )
    }

    @After
    fun tearDown() {
        harness.close()
    }

    private suspend fun seedConversation(conversationId: String, messageIds: List<String>) {
        harness.db.conversationDao().upsert(
            Conversation(id = conversationId, title = "MCP", providerID = "p", providerKind = ProviderKind.Relay, modelID = "m").toEntity(UID),
        )
        messageIds.forEachIndexed { index, id ->
            harness.db.messageDao().upsert(
                ChatMessage(
                    id = id, role = if (index % 2 == 0) ChatRole.User else ChatRole.Assistant, text = "t$index",
                    providerKind = ProviderKind.Relay, providerName = "Relay", modelName = "m", state = ChatMessageState.Delivered,
                ).toEntity(UID, conversationId, index),
            )
        }
    }

    /** The two callbacks of a step on the production path: arguments arrive with the first, the result with the terminal state. */
    private suspend fun recordStep(messageId: String, serverId: String, stepId: String = "1:c1") {
        val running = McpToolStepUpdate(
            id = stepId, serverId = serverId, serverName = "Linear", toolName = "get_weather", title = "Get weather",
            argsSummary = "", status = McpToolStepUpdate.Status.Running, step = 1,
            payload = McpToolStepPayload(arguments = "{\"city\":\"RAW-ARGUMENT\"}"),
        )
        runner.saveStepPayload(messageId, running)
        runner.saveStepPayload(
            messageId,
            running.copy(status = McpToolStepUpdate.Status.Done, payload = McpToolStepPayload(resultPrefix = "RAW-RESULT")),
        )
        assertNotNull("precondition: the payload was written", harness.store.fetchStepPayload(messageId, stepId))
    }

    private fun payloadRows(): Int =
        harness.db.openHelper.readableDatabase.query("SELECT COUNT(*) FROM mcp_step_payload").use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }

    @Test
    fun `deleting a conversation deletes the step payloads of its messages and leaves other conversations alone`() = runBlocking {
        val serverId = harness.addServer()
        seedConversation(CONV_A, listOf(MSG_A1, MSG_A2))
        seedConversation(CONV_B, listOf(MSG_B1, MSG_B2))
        recordStep(MSG_A2, serverId)
        recordStep(MSG_B2, serverId)

        conversations.delete(CONV_A)

        assertNull(harness.store.fetchStepPayload(MSG_A2, "1:c1"))
        assertNotNull("payloads of other conversations are untouched", harness.store.fetchStepPayload(MSG_B2, "1:c1"))

        conversations.deleteMultiple(listOf(CONV_B))

        assertEquals(0, payloadRows())
    }

    @Test
    fun `deleting messages deletes their step payloads and keeps the ones before the cut`() = runBlocking {
        val serverId = harness.addServer()
        seedConversation(CONV_A, listOf(MSG_A1, MSG_A2, MSG_A3, MSG_A4))
        recordStep(MSG_A2, serverId)
        recordStep(MSG_A4, serverId)

        // Edit the third message and resend: everything from the third message on is deleted.
        conversations.deleteMessagesStartingAt(CONV_A, MSG_A3)

        assertNotNull("the message before the cut is still there, and so is its payload", harness.store.fetchStepPayload(MSG_A2, "1:c1"))
        assertNull(harness.store.fetchStepPayload(MSG_A4, "1:c1"))

        // Regenerate: everything after the first message is deleted.
        conversations.deleteMessagesAfter(CONV_A, MSG_A1)

        assertEquals(0, payloadRows())
    }

    @Test
    fun `deleting a message row through the dao deletes its step payloads and keeps the other messages`() = runBlocking {
        val serverId = harness.addServer()
        seedConversation(CONV_A, listOf(MSG_A1, MSG_A2, MSG_A3, MSG_A4))
        recordStep(MSG_A2, serverId)
        recordStep(MSG_A4, serverId)

        harness.db.messageDao().deleteById(UID, MSG_A4)

        assertNull(harness.store.fetchStepPayload(MSG_A4, "1:c1"))
        assertNotNull("a message that was not deleted keeps its payload", harness.store.fetchStepPayload(MSG_A2, "1:c1"))
    }

    @Test
    fun `rewriting a message row keeps its step payloads and rows of another account are left alone`() = runBlocking {
        val serverId = harness.addServer()
        seedConversation(CONV_A, listOf(MSG_A1, MSG_A2))
        recordStep(MSG_A2, serverId)
        // A payload under the same message id and a different account id in the same database.
        harness.db.mcpServerDao().upsertStepPayload(
            ai.oriveo.community.core.data.entity.McpStepPayloadEntity(
                messageId = MSG_A2, stepId = "1:c1", accountId = "other-account", arguments = "{}", resultPrefix = null, createdAt = 1,
            ),
        )

        // Saving a streaming message overwrites the existing row with INSERT OR REPLACE: the row is replaced and
        // written again, not deleted. Room turns recursive_triggers on, so REPLACE would fire a delete trigger on
        // messages, which is why the cascade is not a trigger.
        val row = harness.db.messageDao().getById(UID, MSG_A2)!!
        harness.db.messageDao().upsertAll(listOf(row.copy(text = "rewritten")))
        assertNotNull("an overwrite is not a deletion, so the payload stays", harness.store.fetchStepPayload(MSG_A2, "1:c1"))

        conversations.delete(CONV_A)
        assertNull(harness.store.fetchStepPayload(MSG_A2, "1:c1"))
        assertNotNull("only the payloads in the account of the deleted message go", harness.db.mcpServerDao().getStepPayload("other-account", MSG_A2, "1:c1"))
    }

    @Test
    fun `removing a server deletes its step payloads and keeps the ones of other servers`() = runBlocking {
        val removed = harness.addServer(name = "Linear")
        val kept = harness.addServer(name = "Notion", url = "https://notion.example.com/mcp")
        seedConversation(CONV_A, listOf(MSG_A1, MSG_A2))
        recordStep(MSG_A2, removed, stepId = "1:c1")
        recordStep(MSG_A2, kept, stepId = "2:c2")

        assertEquals(true, harness.actions().remove(removed))

        assertNull("raw arguments and results are deleted together with the server", harness.store.fetchStepPayload(MSG_A2, "1:c1"))
        assertNotNull(harness.store.fetchStepPayload(MSG_A2, "2:c2"))
        assertEquals("the message itself is untouched (the step summary lives on the message)", 2, harness.db.messageDao().getByConversation(UID, CONV_A).size)
    }

    private companion object {
        const val CONV_A = "c0000000-0000-4000-8000-00000000000a"
        const val CONV_B = "c0000000-0000-4000-8000-00000000000b"
        const val MSG_A1 = "a0000000-0000-4000-8000-000000000001"
        const val MSG_A2 = "a0000000-0000-4000-8000-000000000002"
        const val MSG_A3 = "a0000000-0000-4000-8000-000000000003"
        const val MSG_A4 = "a0000000-0000-4000-8000-000000000004"
        const val MSG_B1 = "b0000000-0000-4000-8000-000000000001"
        const val MSG_B2 = "b0000000-0000-4000-8000-000000000002"
    }
}
