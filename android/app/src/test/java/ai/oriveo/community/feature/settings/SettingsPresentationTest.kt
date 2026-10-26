package ai.oriveo.community.feature.settings

import java.io.File
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ThemeOption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsPresentationTest {

    @Test
    fun `settings hub stacks on narrow phones or accessibility font scale`() {
        assertFalse(shouldStackSettingsHubCards(maxWidthDp = 322f, fontScale = 1f))
        assertTrue(shouldStackSettingsHubCards(maxWidthDp = 321f, fontScale = 1f))
        assertFalse(shouldStackSettingsHubCards(maxWidthDp = 390f, fontScale = 1.29f))
        assertTrue(shouldStackSettingsHubCards(maxWidthDp = 390f, fontScale = 1.3f))
    }

    @Test
    fun `voice row follows skills with tag`() {
        val source = File("src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt").readText()
        val afterSkills = source
            .substringAfter("title = stringResource(R.string.skills_title),")
            .substringBefore("SettingsToolsSection(")

        assertTrue(source.contains("onNavigateToVoiceSettings: () -> Unit = {}"))
        assertTrue(afterSkills.contains("InsetHairline()"))
        assertTrue(afterSkills.contains("onClick = onNavigateToVoiceSettings"))
        assertTrue(afterSkills.contains("Modifier.testTag(\"settings_voice_row\")"))
        assertTrue(afterSkills.contains("Icons.Outlined.GraphicEq"))
        assertTrue(afterSkills.contains("R.string.voice_settings_title"))
    }

    @Test
    fun `about logo reveals endpoint only on tenth tap and resets counter`() {
        var count = 0
        repeat(9) {
            val result = registerAboutLogoTap(count)
            assertFalse(result.shouldRevealEndpoint)
            count = result.nextCount
        }

        assertEquals(9, count)
        val tenthTap = registerAboutLogoTap(count)
        assertTrue(tenthTap.shouldRevealEndpoint)
        assertEquals(0, tenthTap.nextCount)
    }

    @Test
    fun `appearance theme and language share OriveoSettingsRow caption value`() {
        val appearance = File("src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt")
            .readText()
            .substringAfter("R.string.appearance")
            .substringBefore("R.string.help_feedback")
        val rowSource = File("src/main/java/ai/oriveo/community/ui/component/OriveoSettingsRows.kt").readText()
        val valueBlock = rowSource
            .substringAfter("if (!value.isNullOrBlank())")
            .substringBefore("trailingContent")

        assertTrue(appearance.contains("value = themeSummaryLabel("))
        assertTrue(appearance.contains("value = languageSummaryLabel("))
        assertFalse(appearance.contains("DropdownMenu"))
        assertFalse(appearance.contains("ExposedDropdownMenu"))
        assertTrue(valueBlock.contains("OriveoTheme.typography.caption"))
        assertFalse(valueBlock.contains("OriveoTheme.typography.body"))
    }

    @Test
    fun `theme summary label mirrors iOS style labels`() {
        assertEquals(
            "Follow System",
            themeSummaryLabel(
                theme = ThemeOption.System,
                systemLabel = "Follow System",
                lightLabel = "Light",
                darkLabel = "Dark",
            ),
        )
        assertEquals(
            "Light",
            themeSummaryLabel(
                theme = ThemeOption.Light,
                systemLabel = "Follow System",
                lightLabel = "Light",
                darkLabel = "Dark",
            ),
        )
        assertEquals(
            "Dark",
            themeSummaryLabel(
                theme = ThemeOption.Dark,
                systemLabel = "Follow System",
                lightLabel = "Light",
                darkLabel = "Dark",
            ),
        )
    }

    @Test
    fun `language summary label uses native names except for system`() {
        assertEquals(
            "Follow System",
            languageSummaryLabel(
                language = LanguageOption.System,
                systemLabel = "Follow System",
            ),
        )
        assertEquals(
            "\u65e5\u672c\u8a9e",
            languageSummaryLabel(
                language = LanguageOption.Japanese,
                systemLabel = "Follow System",
            ),
        )
    }

    @Test
    fun `app version format stays aligned with iOS about card`() {
        assertEquals("V1.2.3 (45)", formatAppVersion("1.2.3", 45))
    }

    @Test
    fun `memory row content uses trailing value when memory exists`() {
        val content = memoryRowContent(
            memoryText = "Remember that I like cats, and end every reply with a meow from now on, please.",
            notSetLabel = "Not set",
            maxPreviewGraphemes = 20,
        )

        assertNull(content.subtitle)
        assertEquals("Remember that I like...", content.value)
    }

    @Test
    fun `memory row content uses trailing value for not set text aligned with iOS`() {
        val content = memoryRowContent(
            memoryText = "   ",
            notSetLabel = "Not set",
        )

        // "Not set" also goes in the trailing value, not in a subtitle under the title
        assertNull(content.subtitle)
        assertEquals("Not set", content.value)
    }
}
