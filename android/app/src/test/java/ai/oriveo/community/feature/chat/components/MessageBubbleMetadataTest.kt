package ai.oriveo.community.feature.chat.components

import ai.oriveo.community.core.model.ChatMessageState
import org.junit.Assert.assertEquals
import org.junit.Test

/** Cost in the assistant metadata line for delivered and stopped replies. */
class MessageBubbleMetadataTest {

    @Test
    fun `interrupted reply with a cost shows the cost`() {
        assertEquals(
            "OpenAI · GPT-A · $0.0012",
            assistantMetadataText("OpenAI", "GPT-A", ChatMessageState.Interrupted, "$0.0012"),
        )
    }

    @Test
    fun `interrupted reply without a cost shows no cost`() {
        assertEquals("OpenAI · GPT-A", assistantMetadataText("OpenAI", "GPT-A", ChatMessageState.Interrupted, ""))
    }

    @Test
    fun `delivered reply still shows the cost`() {
        assertEquals(
            "OpenAI · GPT-A · $0.0012",
            assistantMetadataText("OpenAI", "GPT-A", ChatMessageState.Delivered, "$0.0012"),
        )
    }

    @Test
    fun `failed reply shows no cost`() {
        assertEquals("OpenAI · GPT-A", assistantMetadataText("OpenAI", "GPT-A", ChatMessageState.Failed, "$0.0012"))
    }
}
