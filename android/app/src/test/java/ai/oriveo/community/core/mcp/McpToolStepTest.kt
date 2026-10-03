package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.mapper.MessageMapper.toDomain
import ai.oriveo.community.core.data.mapper.MessageMapper.toEntity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Tool steps on a message: merging, interruption on reload, and the round trip through the stored row. */
class McpToolStepTest {

    private fun update(
        id: String = "1:c1",
        status: McpToolStepUpdate.Status = McpToolStepUpdate.Status.Running,
        errorCode: McpErrorCode? = null,
        payload: McpToolStepPayload? = null,
    ) = McpToolStepUpdate(
        id = id,
        serverId = "AAAAAAAA-0000-4000-8000-000000000001",
        serverName = "Notion",
        toolName = "create_page",
        title = "Create page",
        argsSummary = "Weekly",
        status = status,
        errorCode = errorCode,
        step = 1,
        durationMs = if (status == McpToolStepUpdate.Status.Running) null else 1200,
        payload = payload,
    )

    private fun message(state: ChatMessageState, steps: List<McpToolStep>?) = ChatMessage(
        id = "11111111-0000-4000-8000-000000000001",
        role = ChatRole.Assistant,
        text = "answer",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "m",
        state = state,
        toolSteps = steps,
    )

    @Test
    fun `an update becomes a summary with a lowercase server id and no payload`() {
        val step = McpToolStep.from(update(payload = McpToolStepPayload(arguments = "{\"body\":\"RAW\"}")))

        assertEquals("aaaaaaaa-0000-4000-8000-000000000001", step.serverId)
        assertEquals("mcp", step.scope)
        assertEquals("running", step.status)
        assertTrue("the summary must not contain payloads: $step", "RAW" !in step.toString())
    }

    @Test
    fun `merging replaces the same id in place and appends a new one`() {
        val first = McpToolStep.merging(update(), emptyList())
        val done = McpToolStep.merging(update(status = McpToolStepUpdate.Status.Done), first)
        val two = McpToolStep.merging(update(id = "2:c2"), done)

        assertEquals(listOf("done"), done.map { it.status })
        assertEquals(listOf("1:c1", "2:c2"), two.map { it.id })
    }

    @Test
    fun `a reloaded message that is no longer generating shows running steps as interrupted`() {
        val running = McpToolStep.merging(update(), emptyList()) +
            McpToolStep.from(update(id = "0:c0", status = McpToolStepUpdate.Status.Done))

        // After the process is killed, the startup cleanup only sets the message state to Interrupted; the step column still says running.
        val killed = message(ChatMessageState.Interrupted, running).toEntity(LOCAL_PARTITION_ID, "conv", 0).toDomain()
        assertEquals(listOf("interrupted", "done"), killed.toolSteps!!.map { it.status })
        assertEquals("interrupted", killed.toolSteps!!.first().errorCode)

        // A message that is still generating is left as is: this step really is running.
        val live = message(ChatMessageState.Generating, running).toEntity(LOCAL_PARTITION_ID, "conv", 0).toDomain()
        assertEquals(listOf("running", "done"), live.toolSteps!!.map { it.status })
    }

    @Test
    fun `interruptingRunning returns the same list when nothing is running`() {
        val steps = listOf(McpToolStep.from(update(status = McpToolStepUpdate.Status.Denied, errorCode = McpErrorCode.UserDenied)))
        assertSame(steps, McpToolStep.interruptingRunning(steps))
    }

    @Test
    fun `room roundtrip keeps every summary field and an empty list is stored as null`() {
        val steps = listOf(McpToolStep.from(update(status = McpToolStepUpdate.Status.Failed, errorCode = McpErrorCode.ToolError)))
        val entity = message(ChatMessageState.Delivered, steps).toEntity(LOCAL_PARTITION_ID, "conv", 0)

        assertEquals(steps, entity.toDomain().toolSteps)
        assertNull(message(ChatMessageState.Delivered, emptyList()).toEntity(LOCAL_PARTITION_ID, "conv", 0).toolStepsJson)
        assertNull(message(ChatMessageState.Delivered, null).toEntity(LOCAL_PARTITION_ID, "conv", 0).toDomain().toolSteps)
    }

    /** A step with an unknown status keeps its place in the list; only its typed status is unresolved. */
    @Test
    fun `stored steps tolerate unknown fields and unknown status values`() {
        val entity = message(ChatMessageState.Delivered, null).toEntity(LOCAL_PARTITION_ID, "conv", 0).copy(
            toolStepsJson = """[{"id":"1:a","serverId":"s","serverName":"Notion","toolName":"search","title":"",""" +
                """"argsSummary":"","status":"some_future_status","step":1,"futureField":true}]""",
        )

        val step = entity.toDomain().toolSteps!!.single()

        assertNull(step.statusValue)
        assertEquals("mcp", step.scope)
        assertEquals("the raw tool name stands in for a missing title", "search", step.displayTitle)
        assertNull(
            "a column that cannot be decoded reads as no steps instead of failing the message",
            entity.copy(toolStepsJson = "not json").toDomain().toolSteps,
        )
    }
}
