package ai.oriveo.community.ui.theme

import androidx.compose.ui.graphics.toArgb
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Custom palette: the derivation is aligned with `dark-palettes.v1.json#custom.derivationCases`
 * and parsing is aligned with `custom.resolveCases`. Expected values are always read live from the fixture.
 */
class OriveoCustomPaletteTest {

    private val custom: JsonObject get() = DarkPaletteContract.custom

    private fun hex(text: String): Int = requireNotNull(OriveoCustomPalette.parseSeed(text)) { "not #RRGGBB: $text" }

    private fun assertChannelsClose(message: String, expected: Int, actual: Int) {
        for (shift in listOf(16, 8, 0)) {
            val e = expected shr shift and 255
            val a = actual shr shift and 255
            assertTrue("$message expected ${OriveoCustomPalette.format(expected)} got ${OriveoCustomPalette.format(actual)}", abs(e - a) <= 1)
        }
    }

    private fun derivedField(d: OriveoCustomPalette.Derived, key: String): Int = when (key) {
        "bg" -> d.bg
        "bgSubtle" -> d.bgSubtle
        "bgInset" -> d.bgInset
        "surface" -> d.surface
        "surfaceRaised" -> d.surfaceRaised
        "text" -> d.text
        "textSecondary" -> d.textSecondary
        "textTertiary" -> d.textTertiary
        "codeBg" -> d.codeBg
        "codeHeaderBg" -> d.codeHeaderBg
        "primary" -> d.primary
        "primaryHover" -> d.primaryHover
        "primaryActive" -> d.primaryActive
        "accent" -> d.accent
        "onPrimary" -> d.onPrimary
        else -> error("unknown field $key")
    }

    @Test
    fun `derivation cases match per channel within one`() {
        val cases = custom.getValue("derivationCases").jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val seedText = case.getValue("seed").jsonPrimitive.content
            val derived = OriveoCustomPalette.derive(hex(seedText))
            val colors = DarkPaletteChoice.Custom(hex(seedText)).colors
            val expect = case.getValue("expect").jsonObject
            assertEquals("$seedText has every field", 15, expect.size)
            for ((key, value) in expect) {
                val expected = hex(value.jsonPrimitive.content)
                assertChannelsClose("$seedText.$key", expected, derivedField(derived, key))
                // The OriveoColors produced by the production path match the derivation (field mapping as in the contract)
                val reader = DarkPaletteContract.fieldReaders.getValue(key)
                assertEquals("$seedText.$key → OriveoColors", derivedField(derived, key), reader(colors).toArgb() and 0xFFFFFF)
            }
            val adjusted = case.getValue("adjusted")
            assertEquals(
                "$seedText adjusted",
                if (adjusted is JsonNull) null else adjusted.jsonPrimitive.content,
                derived.adjusted?.id,
            )
            assertEquals("$seedText glowK", DarkPaletteContract.float(custom.getValue("derivation").jsonObject.getValue("glowK")), colors.glowK)
        }
    }

    @Test
    fun `hue slider seed matches reference script`() {
        // Expected values computed from the contract's reference hueSliderSeed implementation
        assertEquals("#FF8FB4", OriveoCustomPalette.format(OriveoCustomPalette.hueSliderSeed(0)))
        assertEquals("#07D0D8", OriveoCustomPalette.format(OriveoCustomPalette.hueSliderSeed(200)))
        val slider = custom.getValue("hueSlider").jsonObject
        assertEquals(slider.getValue("min").jsonPrimitive.content.toInt(), OriveoCustomPalette.HUE_SLIDER_MIN)
        assertEquals(slider.getValue("max").jsonPrimitive.content.toInt(), OriveoCustomPalette.HUE_SLIDER_MAX)
    }

    @Test
    fun `default seed and presets match contract`() {
        assertEquals(custom.getValue("id").jsonPrimitive.content, OriveoCustomPalette.ID)
        assertEquals(custom.getValue("defaultSeed").jsonPrimitive.content, OriveoCustomPalette.format(OriveoCustomPalette.DEFAULT_SEED))
        assertEquals(
            custom.getValue("presets").jsonArray.map { it.jsonPrimitive.content },
            OriveoCustomPalette.presets.map(OriveoCustomPalette::format),
        )
    }

    @Test
    fun `parse seed accepts only RRGGBB in either case`() {
        assertEquals(0xC084FC, OriveoCustomPalette.parseSeed("#c084fc"))
        assertEquals(0xC084FC, OriveoCustomPalette.parseSeed("#C084FC"))
        assertEquals("#C084FC", OriveoCustomPalette.format(0xC084FC))
        for (bad in listOf<Any?>(null, "blue", "C084FC", "#C084F", "#C084FCF", "#GGGGGG", 42)) {
            assertNull("$bad", OriveoCustomPalette.parseSeed(bad))
        }
    }

    @Test
    fun `custom colors differ by seed and are cached`() {
        val a = OriveoCustomPalette.presets.first()
        val b = OriveoCustomPalette.presets.last()
        assertNotEquals(DarkPaletteChoice.Custom(a).colors.primary, DarkPaletteChoice.Custom(b).colors.primary)
        assertSame("cached per seed", DarkPaletteChoice.Custom(a).colors, DarkPaletteChoice.Custom(a).colors)
        assertSame(OriveoCustomPalette.derive(a), OriveoCustomPalette.derive(a))
    }

    @Test
    fun `custom resolve cases render per contract`() = runTest {
        val cases = DarkPaletteContract.customResolveCases
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val name = case.getValue("name").jsonPrimitive.content
            val stored = case.getValue("stored").jsonPrimitive.content
            val storedSeedElement = case.getValue("storedSeed")
            val storedSeed = if (storedSeedElement is JsonNull) null else storedSeedElement.jsonPrimitive.content

            val renders = case.getValue("renders").jsonPrimitive.content
            val expectedChoice = if (renders == OriveoCustomPalette.ID) {
                DarkPaletteChoice.Custom(hex(case.getValue("seed").jsonPrimitive.content))
            } else {
                DarkPaletteChoice.Preset(DarkPaletteId.fromId(renders))
            }
            assertEquals("$name renders", expectedChoice, DarkPaletteChoice.resolve(stored, storedSeed))
        }
    }
}
