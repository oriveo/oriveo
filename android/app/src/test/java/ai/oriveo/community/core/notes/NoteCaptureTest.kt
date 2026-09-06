package ai.oriveo.community.core.notes

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.NoteCaptureKind
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NoteCaptureTest {

    private fun msg(
        id: String,
        role: ChatRole,
        text: String,
        modelID: String? = "gpt-5",
        modelName: String = "GPT-5",
        providerKind: ProviderKind = ProviderKind.OpenAI,
        providerName: String = "OpenAI",
    ) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerKind = providerKind,
        providerName = providerName,
        modelID = modelID,
        modelName = modelName,
        state = ChatMessageState.Delivered,
    )

    private val conversationId = "CONV-1"

    @Test
    fun `assistant fullAnswer pulls sourcePrompt from previous user message`() {
        val messages = listOf(
            msg("U1", ChatRole.User, "first question"),
            msg("A1", ChatRole.Assistant, "first answer"),
            msg("U2", ChatRole.User, "second question"),
            msg("A2", ChatRole.Assistant, "second answer"),
        )
        val input = NoteCapture.fromMessage(messages[3], conversationId, messages)

        assertEquals(NoteCaptureKind.FullAnswer, input.captureKind)
        assertEquals("second answer", input.body)
        assertEquals("second answer", input.bodySnapshot)
        assertEquals("second question", input.sourcePrompt)
        assertEquals("A2", input.sourceMessageId)
        assertEquals(conversationId, input.sourceConversationId)
        assertEquals("GPT-5", input.sourceModelName)
        assertEquals(ProviderKind.OpenAI, input.sourceProviderKind)
    }

    @Test
    fun `assistant skips blank user messages when resolving sourcePrompt`() {
        val messages = listOf(
            msg("U1", ChatRole.User, "real question"),
            msg("U2", ChatRole.User, "   "),
            msg("A1", ChatRole.Assistant, "answer"),
        )
        val input = NoteCapture.fromMessage(messages[2], conversationId, messages)
        assertEquals("real question", input.sourcePrompt)
    }

    @Test
    fun `assistant with no prior user message has null sourcePrompt`() {
        val messages = listOf(
            msg("A1", ChatRole.Assistant, "answer with no question"),
        )
        val input = NoteCapture.fromMessage(messages[0], conversationId, messages)
        assertNull(input.sourcePrompt)
    }

    @Test
    fun `user message captureKind is userMessage and sourcePrompt is own text`() {
        val messages = listOf(
            msg("U1", ChatRole.User, "my own prompt"),
            msg("A1", ChatRole.Assistant, "answer"),
        )
        val input = NoteCapture.fromMessage(messages[0], conversationId, messages)

        assertEquals(NoteCaptureKind.UserMessage, input.captureKind)
        assertEquals("my own prompt", input.body)
        assertEquals("my own prompt", input.bodySnapshot)
        assertEquals("my own prompt", input.sourcePrompt)
        assertEquals("U1", input.sourceMessageId)
    }

    @Test
    fun `selection keeps selected body but full message snapshot`() {
        val messages = listOf(
            msg("U1", ChatRole.User, "question"),
            msg("A1", ChatRole.Assistant, "full answer with ```code block``` inside"),
        )
        val input = NoteCapture.fromSelection(
            messages[1],
            selectedText = "```code block```",
            conversationId,
            messages,
        )

        assertEquals(NoteCaptureKind.Selection, input.captureKind)
        assertEquals("```code block```", input.body)
        assertEquals("full answer with ```code block``` inside", input.bodySnapshot)
        assertEquals("question", input.sourcePrompt)
        assertEquals("A1", input.sourceMessageId)
    }
}
