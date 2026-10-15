package ai.oriveo.community.feature.chat.crosscheck

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrosscheckOriginalAnswerPreviewTest {

    @Test
    fun `preview strips bold list heading inline code and link markers`() {
        val answer = """
            ## Conclusion

            **Consistency beats intensity**

            1. **Read first**, then write
            2. Review with `git log`
            - See [Stoic notes](https://example.com/notes)
        """.trimIndent()
        val preview = originalAnswerPreview(answer)
        assertEquals("Conclusion Consistency beats intensity Read first, then write Review with git log See Stoic notes", preview)
        listOf("**", "`", "##", "](", "1. ", "- ").forEach { marker ->
            assertFalse("leftover marker $marker", preview.contains(marker))
        }
    }

    @Test
    fun `preview truncates to 220 chars after stripping`() {
        val answer = (0 until 80).joinToString("\n") { "**bold$it**" }
        val preview = originalAnswerPreview(answer)
        assertFalse(preview.contains("**"))
        assertTrue(preview.endsWith("…"))
        assertTrue(preview.length <= 221)
    }

    @Test
    fun `short plain answer is only collapsed`() {
        assertEquals("Plain answer. Second line.", originalAnswerPreview("  Plain answer.\n\nSecond line. "))
    }
}
