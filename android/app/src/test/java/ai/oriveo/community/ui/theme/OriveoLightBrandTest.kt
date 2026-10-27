package ai.oriveo.community.ui.theme

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import ai.oriveo.community.core.navigation.AppRoute
import ai.oriveo.community.core.navigation.tabSelectedLabelColor
import ai.oriveo.community.ui.component.OriveoTabBarIcons
import ai.oriveo.community.ui.component.OriveoTabGlyph
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.math.abs

/**
 * Light brand colors: the derivation is aligned with `dark-palettes.v1.json#light.palettes` and
 * `custom.derivationCases[].light`, the default palette equals the hand-tuned values value for value, and the light theme and tabs follow the palette. Expected values are always read live from the fixture.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class OriveoLightBrandTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val light: JsonObject get() = DarkPaletteContract.root.getValue("light").jsonObject

    private fun hex(text: String): Int = requireNotNull(OriveoCustomPalette.parseSeed(text)) { "not #RRGGBB: $text" }

    private fun Color.rgb(): Int = toArgb() and 0xFFFFFF

    private fun field(b: OriveoLightBrand, key: String): Color = when (key) {
        "ink" -> b.ink
        "textSafe" -> b.textSafe
        "fill" -> b.fill
        "fillText" -> b.fillText
        "fillPressed" -> b.fillPressed
        "gradStart" -> b.gradStart
        "gradEnd" -> b.gradEnd
        "onPrimary" -> b.onPrimary
        "soft" -> b.soft
        "accent" -> b.accent
        "bgTop" -> b.bgTop
        "bgBottom" -> b.bgBottom
        "pill" -> b.pill
        else -> error("unknown field $key")
    }

    /** Every channel of every field differs by at most 1; mode must be exactly equal. Returns the number of color fields compared. */
    private fun assertBrandClose(label: String, expect: JsonObject, actual: OriveoLightBrand, exact: Boolean = false): Int {
        var count = 0
        for ((key, value) in expect) {
            if (key == "mode") {
                assertEquals("$label.mode", value.jsonPrimitive.content, actual.mode.id)
                continue
            }
            val e = hex(value.jsonPrimitive.content)
            val a = field(actual, key).rgb()
            for (shift in listOf(16, 8, 0)) {
                val diff = abs((e shr shift and 255) - (a shr shift and 255))
                assertTrue(
                    "$label.$key expected ${OriveoCustomPalette.format(e)} got ${OriveoCustomPalette.format(a)}",
                    if (exact) diff == 0 else diff <= 1,
                )
            }
            count += 1
        }
        return count
    }

    @Test
    fun `preset light palettes match the contract`() {
        val palettes = light.getValue("palettes").jsonObject
        assertEquals(DarkPaletteId.entries.map { it.id }.toSet(), palettes.keys)
        for ((id, expect) in palettes) {
            val choice = DarkPaletteChoice.Preset(DarkPaletteId.fromId(id))
            assertEquals(13, assertBrandClose(id, expect.jsonObject, choice.lightBrand))
        }
    }

    @Test
    fun `custom derivation cases match the light contract`() {
        val cases = DarkPaletteContract.custom.getValue("derivationCases").jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val seed = case.getValue("seed").jsonPrimitive.content
            val brand = DarkPaletteChoice.Custom(hex(seed)).lightBrand
            assertEquals(13, assertBrandClose("custom $seed", case.getValue("light").jsonObject, brand))
        }
    }

    @Test
    fun `default palette keeps the hand tuned light values exactly`() {
        val brand = DarkPaletteChoice.Default.lightBrand
        assertSame(OriveoLightBrand.Default, brand)
        assertBrandClose("dark", light.getValue("palettes").jsonObject.getValue("dark").jsonObject, brand, exact = true)
        // The default palette's whole light token set is unchanged value for value
        assertEquals(LightOriveoColors, lightOriveoColorsOf(brand))
        // Light window background: the default palette keeps #F6F5FA, the others follow bgTop
        assertEquals(0xF6F5FA, brand.windowBackground.rgb())
        val oceanBrand = DarkPaletteChoice.Preset(DarkPaletteId.Ocean).lightBrand
        assertEquals(oceanBrand.bgTop, oceanBrand.windowBackground)
        // The derivation is cached per palette
        val ocean = DarkPaletteChoice.Preset(DarkPaletteId.Ocean)
        assertSame(ocean.lightBrand, ocean.lightBrand)
        assertSame(DarkPaletteChoice.Custom(0x22D3EE).lightBrand, DarkPaletteChoice.Custom(0x22D3EE).lightBrand)
    }

    private data class Captured(val primary: Color, val textSafe: Color, val onPrimary: Color, val brand: OriveoLightBrand)

    private fun capture(palette: DarkPaletteChoice): Captured {
        var captured: Captured? = null
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false, palette = palette) {
                val c = OriveoTheme.colors
                captured = Captured(c.primary, c.primaryTextSafe, c.onPrimary, OriveoTheme.lightBrand)
            }
        }
        composeRule.waitForIdle()
        return requireNotNull(captured)
    }

    @Test
    fun `light theme primary follows the palette ink`() {
        val oceanInk = hex(light.getValue("palettes").jsonObject.getValue("dark-ocean").jsonObject.getValue("ink").jsonPrimitive.content)
        val ocean = capture(DarkPaletteChoice.Preset(DarkPaletteId.Ocean))
        assertEquals(oceanInk, ocean.primary.rgb())
        assertEquals(ocean.brand.textSafe, ocean.textSafe)
        assertEquals(ocean.brand.onPrimary, ocean.onPrimary)

        val default = capture(DarkPaletteChoice.Default)
        assertEquals(0x8C5FF8, default.primary.rgb())
        assertEquals(LightOriveoColors.primaryTextSafe, default.textSafe)
    }

    @Test
    fun `light tabs keep three tints on default and use ink on other palettes`() {
        val default = OriveoLightBrand.Default
        val tints = OriveoTabGlyph.entries.map { OriveoTabBarIcons.gradient(it, isDark = false, lightBrand = default).first }
        assertEquals(OriveoTabGlyph.entries.map { OriveoTabBarIcons.gradient(it, isDark = false).first }, tints)
        assertEquals(3, tints.toSet().size)

        val ocean = DarkPaletteChoice.Preset(DarkPaletteId.Ocean).lightBrand
        OriveoTabGlyph.entries.forEach { glyph ->
            assertEquals("$glyph", ocean.ink to ocean.ink, OriveoTabBarIcons.gradient(glyph, isDark = false, lightBrand = ocean))
        }
        listOf(AppRoute.Home, AppRoute.Providers, AppRoute.Settings).forEach { route ->
            assertEquals("$route", ocean.ink, tabSelectedLabelColor(route, isDark = false, darkPrimary = Color.Red, lightBrand = ocean))
        }
        assertEquals(
            listOf(AppRoute.Home, AppRoute.Providers, AppRoute.Settings).map { tabSelectedLabelColor(it, false, Color.Red) },
            listOf(AppRoute.Home, AppRoute.Providers, AppRoute.Settings).map { tabSelectedLabelColor(it, false, Color.Red, default) },
        )
    }

    @Test
    fun `light gradients follow the palette brand`() {
        val ocean = DarkPaletteChoice.Preset(DarkPaletteId.Ocean).lightBrand
        val colors = lightOriveoColorsOf(ocean)
        assertEquals(listOf(ocean.gradStart, ocean.gradEnd), OriveoGradients.primaryStops(colors, isDark = false, lightBrand = ocean))
        assertEquals(listOf(ocean.fillPressed, ocean.gradEnd), OriveoGradients.primaryPressedStops(colors, isDark = false, lightBrand = ocean))
        assertEquals(ocean.onPrimary, OriveoGradients.onPrimaryContent(colors, isDark = false))
        val default = OriveoLightBrand.Default
        assertEquals(listOf(default.gradStart, default.gradEnd), OriveoGradients.primaryStops(LightOriveoColors, isDark = false))
    }
}
