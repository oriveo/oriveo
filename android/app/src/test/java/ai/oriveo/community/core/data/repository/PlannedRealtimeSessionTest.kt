package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.CheckpointCoveredMessage
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.RealtimeHistoryItem
import ai.oriveo.community.core.context.RealtimeSessionConstants
import ai.oriveo.community.core.context.RealtimeSessionReject
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.test.runTest
import org.junit.Test

/** Real ChatMessage values go through RealtimeSessionProjector, then assembleRealtimeSession, then PlannedRealtimeSession. */
class PlannedRealtimeSessionTest {

    private val request = ChatContextRequest(
        conversation = ContextConversation(id = "conv-1", useMemory = false, instructions = "Be brief."),
    )

    private fun message(
        id: String,
        role: ChatRole,
        text: String,
        attachments: List<Attachment>? = null,
        state: ChatMessageState = ChatMessageState.Delivered,
    ) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "gpt",
        state = state,
        attachments = attachments,
    )

    private val stored = listOf(
        message("u1", ChatRole.User, "hello"),
        message("a1", ChatRole.Assistant, "hi there"),
        message("u2", ChatRole.User, "spoken question"),
        message("a2", ChatRole.Assistant, "spoken answer"),
    )

    private fun planned(currentSessionId: String?, messages: List<ChatMessage> = stored, window: Int? = 128_000) =
        RealtimeSessionProjector.project(
            request = request,
            rawMessages = messages,
            contextWindow = window,
            currentSessionId = currentSessionId,
            sessionMessageIds = setOf("u2", "a2"),
        )

    @Test
    fun `current_session_transcript_excluded`() {
        val plan = planned(currentSessionId = "rt-1")
        assertNull(plan.reject)
        assertEquals(listOf("u1", "a1"), plan.historyIds)
        val input = PlannedRealtimeSession.from(plan)!!.transportInput()
        assertEquals(
            listOf(RealtimeHistoryItem(ChatRole.User, "hello"), RealtimeHistoryItem(ChatRole.Assistant, "hi there")),
            input.history,
        )
    }

    @Test
    fun `unanswered_chat_user_kept_before_session_transcript`() {
        val messages = listOf(
            message("u1", ChatRole.User, "hello"),
            message("a1", ChatRole.Assistant, "hi there"),
            message("c1", ChatRole.User, "typed but unanswered"),
            message("u2", ChatRole.User, "spoken question"),
            message("a2", ChatRole.Assistant, "spoken answer"),
        )
        val plan = planned(currentSessionId = "rt-1", messages = messages)
        assertEquals(listOf("u1", "a1", "c1"), plan.historyIds)
        val history = PlannedRealtimeSession.from(plan)!!.transportInput().history
        assertEquals(RealtimeHistoryItem(ChatRole.User, "typed but unanswered"), history.last())
        assertTrue(history.none { it.text.contains("spoken") })
    }

    @Test
    fun `new_session_without_current_id_reads_session_messages`() {
        val plan = planned(currentSessionId = null)
        assertEquals(listOf("u1", "a1", "u2", "a2"), plan.historyIds)
        assertEquals("a2", plan.fingerprint?.lastHistoryId)
    }

    @Test
    fun `rejected_plan_not_constructed`() {
        val unknown = planned(currentSessionId = null, window = null)
        assertEquals(RealtimeSessionReject.UNKNOWN_WINDOW, unknown.reject)
        assertNull(PlannedRealtimeSession.from(unknown))

        val tooLong = planned(currentSessionId = null, window = 40)
        assertEquals(RealtimeSessionReject.INSTRUCTIONS_TOO_LONG, tooLong.reject)
        assertNull(PlannedRealtimeSession.from(tooLong))
    }

    @Test
    fun `transport_input_only_instructions_and_history`() {
        val plan = planned(currentSessionId = "rt-1")
        val input = PlannedRealtimeSession.from(plan)!!.transportInput()
        assertEquals(plan.instructions, input.instructions)
        assertEquals(plan.history, input.history)
        assertTrue(input.instructions.contains("Be brief."))
        assertTrue(input.instructions.endsWith("${RealtimeSessionConstants.DELIVERY_REALTIME}\n</oriveo-delivery>"))
        val fields = RealtimeTransportInput::class.java.declaredFields
            .filterNot { it.isSynthetic || java.lang.reflect.Modifier.isStatic(it.modifiers) }.map { it.name }.toSet()
        assertEquals(setOf("instructions", "history"), fields)
    }

    @Test
    fun `attachment_message_uses_placeholder`() {
        val messages = listOf(
            message(
                "u1",
                ChatRole.User,
                "look at this",
                listOf(
                    Attachment(id = "att-1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png"),
                    Attachment(id = "att-2", kind = AttachmentKind.File, fileName = "b.pdf", mimeType = "application/pdf"),
                ),
            ),
            message("a1", ChatRole.Assistant, "nice"),
        )
        val session = PlannedRealtimeSession.from(planned(currentSessionId = null, messages = messages))
        assertNotNull(session)
        assertEquals(
            "look at this\n" + RealtimeSessionConstants.placeholder("image") + "\n" + RealtimeSessionConstants.placeholder("file"),
            session!!.transportInput().history.first().text,
        )
    }

    @Test
    fun `failed_message_not_in_history`() {
        val messages = listOf(
            message("u1", ChatRole.User, "hello"),
            message("a1", ChatRole.Assistant, "partial", state = ChatMessageState.Failed),
            message("u2", ChatRole.User, "again"),
            message("a2", ChatRole.Assistant, "answer"),
        )
        val plan = planned(currentSessionId = null, messages = messages)
        assertTrue(plan.historyIds.orEmpty().none { it == "a1" })
        val history = PlannedRealtimeSession.from(plan)!!.transportInput().history
        assertTrue(history.none { it.text.contains("partial") })
        assertEquals(listOf(ChatRole.User, ChatRole.Assistant), history.map { it.role })
    }

    @Test
    fun `checkpoint_prefixes_first_user_and_drops_covered`() {
        val row = ContextCheckpointRecord(
            conversationId = "conv-1",
            checkpointId = "cp-1",
            kind = ContextCheckpointKind.SUMMARY,
            coversFrom = "u1",
            coversTo = "a1",
            coversDigest = "digest",
            messagesCovered = 2,
            userMessageIds = listOf("u1"),
            text = "CHECKPOINT SUMMARY",
            summary = null,
            language = null,
            model = "gpt",
            packerVersion = "1",
            createdAt = 0L,
            cost = null,
        )
        val plan = RealtimeSessionProjector.project(
            request = request,
            rawMessages = stored,
            contextWindow = 128_000,
            currentSessionId = null,
            sessionMessageIds = emptySet(),
            checkpoint = row,
        )
        assertEquals(listOf("u2", "a2"), plan.historyIds)
        val history = PlannedRealtimeSession.from(plan)!!.transportInput().history
        assertTrue(history.none { it.text.contains("hello") || it.text.contains("hi there") })
        assertTrue(history.first().text.startsWith("CHECKPOINT SUMMARY"))
        assertTrue(history.first().text.endsWith("spoken question"))

        val stale = RealtimeSessionProjector.project(
            request = request,
            rawMessages = stored,
            contextWindow = 128_000,
            currentSessionId = null,
            sessionMessageIds = emptySet(),
            checkpoint = row.copy(coversTo = "missing"),
        )
        assertEquals(listOf("u1", "a1", "u2", "a2"), stale.historyIds)
        assertEquals("hello", stale.history!!.first().text)
    }

    @Test
    fun `realtime_input_applies_latest_valid_checkpoint`() = runTest {
        val row = ContextCheckpointRecord(
            conversationId = "conv-1",
            checkpointId = "cp-1",
            kind = ContextCheckpointKind.SUMMARY,
            coversFrom = "u1",
            coversTo = "a1",
            coversDigest = "digest",
            messagesCovered = 2,
            userMessageIds = listOf("u1"),
            text = "CHECKPOINT SUMMARY",
            summary = null,
            language = null,
            model = "gpt",
            packerVersion = "1",
            createdAt = 0L,
            cost = null,
        )
        val asked = mutableListOf<Pair<String, List<CheckpointCoveredMessage>>>()
        val plan = RealtimeSessionProjector.projectOpening(
            request = request,
            conversationId = "conv-1",
            rawMessages = stored,
            contextWindow = 128_000,
            latestValid = { id, history -> asked += id to history; row },
        )
        // Same as chat: latestValid is fetched with the conversation id and the stored history after quote expansion (realtime has no pending user message, so the last message is kept)
        assertEquals(listOf("conv-1"), asked.map { it.first })
        assertEquals(listOf("u1", "a1", "u2", "a2"), asked.single().second.map { it.id })
        assertEquals(listOf("u2", "a2"), plan.historyIds)
        val history = PlannedRealtimeSession.from(plan)!!.transportInput().history
        assertTrue(history.none { it.text.contains("hello") || it.text.contains("hi there") })
        assertTrue(history.first().text.startsWith("CHECKPOINT SUMMARY"))

        // When it cannot be fetched the checkpoint is simply omitted
        val none = RealtimeSessionProjector.projectOpening(
            request = request,
            conversationId = "conv-1",
            rawMessages = stored,
            contextWindow = 128_000,
            latestValid = { _, _ -> null },
        )
        assertEquals(listOf("u1", "a1", "u2", "a2"), none.historyIds)
        assertEquals("hello", none.history!!.first().text)
    }
}
