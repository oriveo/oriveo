package ai.oriveo.community.feature.settings

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Multi-line rows center their leading control against the whole row: the radio of a Context page option row must not be pinned to the title line. */
class ContextSettingsLayoutTest {
    @Test
    fun `context_option_row_centers_lead_vertically`() {
        val source = File("src/main/java/ai/oriveo/community/feature/settings/ContextSettingsScreen.kt").readText()
        val start = source.indexOf("private fun ContextModeOptionRow(")
        assertTrue(start >= 0)
        val body = source.substring(start, minOf(source.length, start + 1400))
        assertTrue(body.contains("verticalAlignment = Alignment.CenterVertically"))
        assertFalse(body.contains("verticalAlignment = Alignment.Top"))
        assertFalse(body.contains("padding(top = 3.dp)"))
    }
}
