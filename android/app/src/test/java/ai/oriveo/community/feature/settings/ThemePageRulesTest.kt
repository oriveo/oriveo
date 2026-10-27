package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.ui.theme.DarkPaletteContract
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.OriveoCustomPalette
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The theme page's pure interaction functions, aligned case by case with the contract's `appearancePageCases` (taken by name, one test per case), plus the selection rules. */
class ThemePageRulesTest {

    private val cases: List<JsonObject> = DarkPaletteContract.root.getValue("appearancePageCases").jsonArray.map { it.jsonObject }

    private fun case(name: String): JsonObject = cases.first { it.getValue("name").jsonPrimitive.content == name }

    private fun theme(value: String): ThemeOption = requireNotNull(AppPreferencesRepository.parseThemePreference(value))

    private fun JsonElement.stringOrNull(): String? = if (this is JsonNull) null else jsonPrimitive.content

    private fun state(json: JsonObject) = ThemePageState(
        theme = theme(json.getValue("theme").jsonPrimitive.content),
        darkPalette = json.getValue("darkPalette").stringOrNull(),
        seed = json.getValue("seed").stringOrNull(),
    )

    /** Runs [ThemePageRules.apply] on the case's before + action and compares with after. */
    private fun assertCase(name: String) {
        val c = case(name)
        val action = when {
            c.containsKey("segment") -> ThemePageAction.SetAppearance(theme(c.getValue("segment").jsonPrimitive.content))
            c.containsKey("tap") -> when (val tap = c.getValue("tap").jsonPrimitive.content) {
                OriveoCustomPalette.ID -> ThemePageAction.TapCustom
                else -> ThemePageAction.TapPalette(requireNotNull(DarkPaletteId.fromIdOrNull(tap)) { "unknown palette $tap" })
            }
            c.containsKey("pickSeed") -> ThemePageAction.PickSeed(
                requireNotNull(OriveoCustomPalette.parseSeed(c.getValue("pickSeed").jsonPrimitive.content)),
            )
            else -> error("$name has no recognizable action")
        }
        assertEquals(name, state(c.getValue("after").jsonObject), ThemePageRules.apply(state(c.getValue("before").jsonObject), action))
    }

    @Test fun `segment_light`() = assertCase("segment_light")

    @Test fun `segment_dark`() = assertCase("segment_dark")

    @Test fun `segment_system`() = assertCase("segment_system")

    @Test fun `tap_palette_keeps_appearance_light`() = assertCase("tap_palette_keeps_appearance_light")

    @Test fun `tap_palette_keeps_appearance_system`() = assertCase("tap_palette_keeps_appearance_system")

    @Test fun `tap_default_card`() = assertCase("tap_default_card")

    @Test fun `tap_custom_without_seed_writes_default_seed`() = assertCase("tap_custom_without_seed_writes_default_seed")

    @Test fun `tap_custom_keeps_existing_seed`() = assertCase("tap_custom_keeps_existing_seed")

    @Test fun `pick_seed_selects_custom`() = assertCase("pick_seed_selects_custom")

    @Test fun `tap_preset_keeps_seed`() = assertCase("tap_preset_keeps_seed")

    @Test
    fun `every appearance page case has its own test`() {
        val tested = ThemePageRulesTest::class.java.declaredMethods
            .filter { it.isAnnotationPresent(Test::class.java) }
            .map { it.name }
            .toSet()
        val names = cases.map { it.getValue("name").jsonPrimitive.content }
        assertTrue(names.isNotEmpty())
        assertEquals("cases without a test", emptyList<String>(), names.filterNot { it in tested })
    }

    @Test
    fun `tap custom with an invalid stored seed writes the default seed`() {
        val result = ThemePageRules.apply(ThemePageState(ThemeOption.Dark, "dark", "nope"), ThemePageAction.TapCustom)
        assertEquals(ThemePageState(ThemeOption.Dark, OriveoCustomPalette.ID, OriveoCustomPalette.format(OriveoCustomPalette.DEFAULT_SEED)), result)
    }

    @Test
    fun `selection resolves the stored palette regardless of appearance`() {
        assertEquals(ThemeSwatchSelection.Palette(DarkPaletteId.Ocean), ThemePageRules.selection("dark-ocean"))
        assertEquals(ThemeSwatchSelection.Custom, ThemePageRules.selection(OriveoCustomPalette.ID))
        // Unset or unknown ids always render as the default
        assertEquals(ThemeSwatchSelection.Palette(DarkPaletteId.Dark), ThemePageRules.selection(null))
        assertEquals(ThemeSwatchSelection.Palette(DarkPaletteId.Dark), ThemePageRules.selection("dark-unknown"))
    }

    @Test
    fun `every card and preset dot has a distinct localized name`() {
        assertEquals(ThemePaletteCardOrder.size, ThemePaletteCardOrder.map(::themeSwatchNameRes).toSet().size)
        assertEquals(OriveoCustomPalette.presets.size, CustomPresetNameRes.toSet().size)
    }
}
