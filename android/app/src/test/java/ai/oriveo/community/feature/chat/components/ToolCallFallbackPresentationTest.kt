package ai.oriveo.community.feature.chat.components

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolCallFallbackPresentationTest {
    @Test
    fun `arguments preview pretty prints JSON and caps UTF-8 on scalar boundaries`() {
        assertEquals("{\n    \"a\": 1,\n    \"b\": 2\n}", toolCallArgumentsPreview("{\"b\":2,\"a\":1}").text)
        val preview = toolCallArgumentsPreview("😀あ".repeat(800))
        assertTrue(preview.truncated)
        assertTrue(preview.text.endsWith("…"))
        assertTrue(preview.text.dropLast(1).toByteArray(Charsets.UTF_8).size <= 2048)
        assertTrue(!preview.text.contains('\uFFFD'))
    }

    @Test
    fun `expanded diagnostics remain selectable and follow the iOS typography contract`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt")
            .readText()
        val card = source.substring(
            source.indexOf("private fun UnhandledToolCallsCard"),
            source.indexOf("private fun ToolFallbackNoticeRow"),
        )
        val headerStart = card.indexOf("Row(")
        val detailsStart = card.indexOf("if (expanded) {", headerStart)
        val header = card.substring(headerStart, detailsStart)

        assertFalse(
            "the whole card must not collapse while the user selects arguments",
            card.substring(0, headerStart).contains(".clickable("),
        )
        assertTrue(header.contains(".clickable(role = Role.Button)"))
        assertTrue(header.contains("stateDescription = expansionState"))
        assertTrue(card.contains("R.string.tool_call_unhandled_title"))
        assertTrue(card.contains("fontFamily = FontFamily.Monospace"))
        assertTrue(card.contains("SelectionContainer"))
    }
}
