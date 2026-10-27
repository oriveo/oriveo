package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.ui.theme.DarkPaletteContract
import ai.oriveo.community.ui.theme.DarkPaletteId
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** The pure interaction functions of the theme page, aligned case by case with the contract's `themePageCases` (taken by name), plus the selection display rule and the row summary. */
class ThemePageRulesTest {

    private fun case(name: String): JsonObject = DarkPaletteContract.root.getValue("themePageCases").jsonArray
        .map { it.jsonObject }
        .first { it.getValue("name").jsonPrimitive.content == name }

    private fun theme(value: String): ThemeOption = requireNotNull(AppPreferencesRepository.parseThemePreference(value))

    /** Runs [ThemePageRules.apply] on the case's before + action and compares with after. */
    private fun assertCase(name: String) {
        val c = case(name)
        val before = c.getValue("before").jsonObject
        val after = c.getValue("after").jsonObject
        val state = ThemePageState(
            theme = theme(before.getValue("theme").jsonPrimitive.content),
            darkPalette = before.getValue("darkPalette").jsonPrimitive.content,
        )
        assertEquals(before.getValue("follow").jsonPrimitive.boolean, state.theme == ThemeOption.System)
        val systemDark = before["systemAppearance"]?.jsonPrimitive?.content == "dark"
        val action = when {
            c.containsKey("tap") -> {
                val tap = c.getValue("tap").jsonPrimitive.content
                if (tap == "light") ThemePageAction.TapLight else ThemePageAction.TapPalette(requireNotNull(DarkPaletteId.fromIdOrNull(tap)))
            }
            else -> ThemePageAction.ToggleFollow(c.getValue("toggleFollow").jsonPrimitive.boolean)
        }
        val result = ThemePageRules.apply(state, systemDark, action)
        assertEquals(
            ThemePageState(
                theme = theme(after.getValue("theme").jsonPrimitive.content),
                darkPalette = after.getValue("darkPalette").jsonPrimitive.content,
            ),
            result,
        )
    }

    @Test fun `tap_light`() = assertCase("tap_light")

    @Test fun `tap_palette_follow_off`() = assertCase("tap_palette_follow_off")

    @Test fun `tap_palette_follow_on`() = assertCase("tap_palette_follow_on")

    @Test fun `turn_follow_on`() = assertCase("turn_follow_on")

    @Test fun `turn_follow_off_uses_current_system_appearance`() = assertCase("turn_follow_off_uses_current_system_appearance")

    @Test
    fun `turning follow off in light system appearance selects light`() {
        val result = ThemePageRules.apply(
            ThemePageState(ThemeOption.System, "dark-black"),
            systemDark = false,
            action = ThemePageAction.ToggleFollow(false),
        )
        assertEquals(ThemePageState(ThemeOption.Light, "dark-black"), result)
    }

    @Test
    fun `selection follows theme and resolves the stored palette`() {
        assertEquals(ThemeSwatchSelection.Light, ThemePageRules.selection(ThemeOption.Light, "dark-ocean"))
        assertEquals(
            ThemeSwatchSelection.Palette(DarkPaletteId.Ocean),
            ThemePageRules.selection(ThemeOption.Dark, "dark-ocean"),
        )
        assertEquals(
            ThemeSwatchSelection.Palette(DarkPaletteId.Sunset),
            ThemePageRules.selection(ThemeOption.System, "dark-sunset"),
        )
        // Unset or unknown ids always show as dark
        assertEquals(ThemeSwatchSelection.Palette(DarkPaletteId.Dark), ThemePageRules.selection(ThemeOption.Dark, null))
        assertEquals(
            ThemeSwatchSelection.Palette(DarkPaletteId.Dark),
            ThemePageRules.selection(ThemeOption.System, "dark-unknown"),
        )
    }

    private fun summary(theme: ThemeOption, darkPalette: String?): String = themeSummaryLabel(
        theme = theme,
        darkPalette = darkPalette,
        lightLabel = "Light",
        paletteLabel = { if (it == DarkPaletteId.Dark) "Dark" else it.name },
        followSystemLabel = { "Follow System · $it" },
    )

    @Test
    fun `theme row summary covers light dark and follow system`() {
        assertEquals("Light", summary(ThemeOption.Light, "dark-ocean"))
        assertEquals("Ocean", summary(ThemeOption.Dark, "dark-ocean"))
        assertEquals("Dark", summary(ThemeOption.Dark, null))
        assertEquals("Follow System · Forest", summary(ThemeOption.System, "dark-forest"))
        assertEquals("Follow System · Dark", summary(ThemeOption.System, "dark-unknown"))
    }

    @Test
    fun `every palette has a localized name resource`() {
        assertEquals(DarkPaletteId.entries.size, DarkPaletteId.entries.map(::darkPaletteNameRes).toSet().size)
    }
}
