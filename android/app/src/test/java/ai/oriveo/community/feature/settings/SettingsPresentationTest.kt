package ai.oriveo.community.feature.settings

import java.io.File
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.ui.theme.DarkPaletteId
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
    fun `footer version line opens changelog while logo keeps isolated ten tap trigger`() {
        val source = File("src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt").readText()
        val footerSource = source
            .substringAfter("// Footer:")
            .substringBefore("Spacer(modifier = Modifier.height(OriveoTheme.spacing.xxl))")

        assertTrue(footerSource.contains("OriveoWebDestination.Changelog"))
        assertTrue(footerSource.contains("registerAboutLogoTap(aboutTapCount)"))
        assertTrue(footerSource.contains(".clearAndSetSemantics {}"))
        assertTrue(footerSource.contains("rememberBrandPainter(R.drawable.ic_oriveo_logo, 40.dp)"))
        assertTrue(footerSource.contains("formatAppVersion("))
        assertTrue(footerSource.contains("OriveoWebDestination.PrivacyPolicy"))
        assertTrue(footerSource.contains("OriveoWebDestination.TermsOfService"))
    }

    @Test
    fun `voice tile follows skills with its original tag and the tts engine value`() {
        val source = File("src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt").readText()
        val afterSkills = source
            .substringAfter("title = stringResource(R.string.skills_title),")
            .substringBefore("// Tools & connections")
        val gridSource = File("src/main/java/ai/oriveo/community/feature/settings/SettingsHomeGrid.kt").readText()

        assertTrue(source.contains("onNavigateToVoiceSettings: () -> Unit = {}"))
        assertTrue(afterSkills.contains("onClick = onNavigateToVoiceSettings"))
        assertTrue(afterSkills.contains("tag = \"settings_voice_row\""))
        assertTrue(afterSkills.contains("R.drawable.ic_settings_voice"))
        assertTrue(afterSkills.contains("R.string.voice_settings_title"))
        assertTrue(afterSkills.contains("value = voiceEngineLabel?.resolve(context)"))
        assertTrue(source.contains("tag = \"settings_context_row\""))
        assertTrue(gridSource.contains(".testTag(item.tag)"))
    }

    @Test
    fun `help and about grid orders report issue then source code`() {
        val help = File("src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt")
            .readText()
            .substringAfter("// Help & about")
            .substringBefore("// Footer:")
        val issue = help.indexOf("R.string.settings_report_issue")
        val source = help.indexOf("R.string.settings_source_code")
        assertTrue(help.contains("style = SettingsGridStyle.Compact"))
        assertTrue(issue in 0 until source)
        assertTrue(help.contains("OriveoWebDestination.Issues"))
        assertTrue(help.contains("OriveoWebDestination.SourceCode"))
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
    fun `general list merges theme language and backup`() {
        val source = File("src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt").readText()
        val general = source.substringAfter("// General:").substringBefore("// Help & about")

        assertTrue(general.contains("value = themeSummaryLabel("))
        assertTrue(general.contains("value = languageSummaryLabel("))
        assertTrue(general.contains("onClick = onNavigateToBackup"))
        assertFalse(general.contains("DropdownMenu"))
        assertFalse(general.contains("ExposedDropdownMenu"))
        // The old "Data" and "Appearance" group titles are merged into "General"
        assertFalse(source.contains("R.string.data_section"))
        assertFalse(source.contains("R.string.appearance"))
    }

    @Test
    fun `theme row opens the theme page instead of a bottom sheet`() {
        val source = File("src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt").readText()
        val general = source.substringAfter("// General:").substringBefore("// Help & about")

        assertTrue(general.contains("onClick = onNavigateToThemeSettings"))
        assertTrue(general.contains("darkPalette = darkPalette"))
        // The color dot only shows in dark
        assertTrue(general.contains("leadingValueDot = if (isDark) settingsThemeDotBrush(colors.primary, colors.accent) else null"))
        assertFalse(source.contains("showThemePicker"))
        assertFalse(source.contains("DebugDarkPalette"))
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

    private fun themeSummary(theme: ThemeOption, darkPalette: String?): String = themeSummaryLabel(
        theme = theme,
        darkPalette = darkPalette,
        appearanceLabel = { it.name },
        paletteLabel = { selection ->
            when (selection) {
                is ThemeSwatchSelection.Palette -> selection.palette.name
                ThemeSwatchSelection.Custom -> "Custom"
            }
        },
        appearanceWithPalette = { appearance, name -> "${appearance.name} · $name" },
    )

    @Test
    fun `theme summary shows only the appearance for the default palette`() {
        assertEquals("Light", themeSummary(ThemeOption.Light, "dark"))
        assertEquals("Dark", themeSummary(ThemeOption.Dark, null))
        assertEquals("System", themeSummary(ThemeOption.System, "dark-unknown"))
    }

    @Test
    fun `theme summary appends the palette name for other palettes`() {
        assertEquals("Light · Ocean", themeSummary(ThemeOption.Light, "dark-ocean"))
        assertEquals("Dark · Custom", themeSummary(ThemeOption.Dark, "custom"))
        assertEquals("System · Forest", themeSummary(ThemeOption.System, "dark-forest"))
    }

    @Test
    fun `theme summary resources map each appearance`() {
        assertEquals(R.string.theme_light, themeAppearanceNameRes(ThemeOption.Light))
        assertEquals(R.string.theme_dark, themeAppearanceNameRes(ThemeOption.Dark))
        assertEquals(R.string.theme_system, themeAppearanceNameRes(ThemeOption.System))
        assertEquals(R.string.theme_summary_light, themeSummaryWithPaletteRes(ThemeOption.Light))
        assertEquals(R.string.theme_summary_dark, themeSummaryWithPaletteRes(ThemeOption.Dark))
        assertEquals(R.string.theme_summary_follow_system, themeSummaryWithPaletteRes(ThemeOption.System))
        assertEquals(R.string.theme_palette_custom, themeSwatchNameRes(ThemeSwatchSelection.Custom))
        assertEquals(R.string.default_model_short, themeSwatchNameRes(ThemeSwatchSelection.Palette(DarkPaletteId.Dark)))
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

    @Test
    fun `memory row preview strips list markers and joins lines`() {
        assertEquals(
            "I am a PM be brief",
            memoryRowContent(memoryText = "- I am a PM\n- be brief", notSetLabel = "Not set").value,
        )
        assertEquals("a b", memoryRowContent(memoryText = "* a\n• b", notSetLabel = "Not set").value)
        // A bare list marker counts as unset; a hyphen inside the text is left alone
        assertEquals("Not set", memoryRowContent(memoryText = "  -  \n", notSetLabel = "Not set").value)
        assertEquals("a-b - c", memoryRowContent(memoryText = "a-b - c", notSetLabel = "Not set").value)
    }
}
