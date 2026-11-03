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

    /** Price reminder card: the leading icon block, title + hint and trailing switch are vertically centered as one row; the footnote icon and text stay centered the same way. */
    @Test
    fun `context_reminder_card_and_footer_center_vertically`() {
        val source = File("src/main/java/ai/oriveo/community/feature/settings/ContextSettingsScreen.kt").readText()
        listOf("private fun PriceLineReminderGroup(", "private fun OverflowFooter(").forEach { name ->
            val start = source.indexOf(name)
            assertTrue(name, start >= 0)
            val body = source.substring(start, minOf(source.length, start + 900))
            assertTrue(name, body.contains("verticalAlignment = Alignment.CenterVertically"))
            assertFalse(name, body.contains("verticalAlignment = Alignment.Top"))
        }
    }

    /** Skills master switch (P4 contract 24): its own card with the localized title and footer, centred like the reminder card. */
    @Test
    fun `context_skills_auto_invoke_card_has_toggle_and_footer`() {
        val source = File("src/main/java/ai/oriveo/community/feature/settings/ContextSettingsScreen.kt").readText()
        val screen = source.substringAfter("fun ContextSettingsScreen(").substringBefore("\n}\n")
        assertTrue(screen.contains("SkillsAutoInvokeGroup("))
        assertTrue(screen.indexOf("PriceLineReminderGroup(") < screen.indexOf("SkillsAutoInvokeGroup("))
        val start = source.indexOf("private fun SkillsAutoInvokeGroup(")
        assertTrue(start >= 0)
        val body = source.substring(start).substringBefore("\n}\n")
        assertTrue(body.contains("R.string.skills_settings_autoToggle)"))
        assertTrue(body.contains("R.string.skills_settings_autoToggleFooter)"))
        assertTrue(body.contains("Switch("))
        assertTrue(body.contains("sentryClickTag(\"settings_skills_auto_invoke\""))
        assertTrue(body.contains("verticalAlignment = Alignment.CenterVertically"))
        assertFalse(body.contains("verticalAlignment = Alignment.Top"))
    }
}
