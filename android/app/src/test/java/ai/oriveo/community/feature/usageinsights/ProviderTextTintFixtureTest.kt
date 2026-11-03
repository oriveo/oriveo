package ai.oriveo.community.feature.usageinsights

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.providers.detail.heroPillLabel
import ai.oriveo.community.feature.providers.detail.heroPressedBrand
import ai.oriveo.community.feature.providers.detail.heroSubduedBrand
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.OriveoCustomPalette
import ai.oriveo.community.ui.theme.ProviderUsageBreakdownPalette
import ai.oriveo.community.ui.theme.lightOriveoColorsOf
import java.nio.file.Files
import java.nio.file.Paths
import kotlin.math.abs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Provider text tint vs the shared fixture provider-text-tint.v1.json (read-only). */
class ProviderTextTintFixtureTest {

    private val root: JsonObject by lazy {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/test-fixtures/provider-tint/provider-text-tint.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("provider-text-tint.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private val cases: List<JsonObject> get() = root.getValue("cases").jsonArray.map { it.jsonObject }
    private val rule: JsonObject get() = root.getValue("rule").jsonObject

    private fun rgb(hex: String): Int {
        val h = hex.removePrefix("#")
        require(h.length == 6) { "expected #RRGGBB: $hex" }
        return h.toInt(16)
    }

    private fun hex(rgb: Int): String = "#%06X".format(rgb and 0xFFFFFF)

    private fun assertClose(expected: Int, actual: Int, message: String) {
        val ok = listOf(16, 8, 0).all { shift -> abs((expected shr shift and 255) - (actual shr shift and 255)) <= 1 }
        assertTrue("$message: expected ${hex(expected)}, got ${hex(actual)}", ok)
    }

    @Test
    fun providerTextTintMatchesSharedFixture() {
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val id = case.getValue("id").jsonPrimitive.content
            val brand = rgb(case.getValue("brand").jsonPrimitive.content) or 0xFF000000.toInt()
            assertClose(rgb(case.getValue("light").jsonPrimitive.content), providerTextTint(brand, isDark = false), "$id light")
            assertClose(rgb(case.getValue("dark").jsonPrimitive.content), providerTextTint(brand, isDark = true), "$id dark")
        }
    }

    @Test
    fun providerTextTintRuleMatchesFixture() {
        assertEquals(rule.getValue("minContrast").jsonPrimitive.double, PROVIDER_TEXT_TINT_MIN_CONTRAST, 0.0)
        assertEquals(rule.getValue("step").jsonPrimitive.double, PROVIDER_TEXT_TINT_STEP, 0.0)
        assertEquals(
            rule.getValue("light").jsonArray.map { rgb(it.jsonPrimitive.content) },
            PROVIDER_TEXT_TINT_LIGHT_BACKGROUNDS,
        )
        assertEquals(
            rule.getValue("dark").jsonArray.map { rgb(it.jsonPrimitive.content) },
            PROVIDER_TEXT_TINT_DARK_BACKGROUNDS,
        )
    }

    @Test
    fun providerTextTintPalettesMatchFixture() {
        var checked = 0
        for (case in cases) {
            val id = case.getValue("id").jsonPrimitive.content
            val brand = rgb(case.getValue("brand").jsonPrimitive.content)
            val local: Color = when {
                id.startsWith("brand.") -> providerTintFor(id.removePrefix("brand."))
                id.startsWith("relay.") -> RELAY_PALETTE.getOrNull(id.removePrefix("relay.").toInt()) ?: continue
                id.startsWith("fallback.") -> FALLBACK_PALETTE.getOrNull(id.removePrefix("fallback.").toInt()) ?: continue
                else -> continue
            }
            assertEquals(id, hex(brand), hex(local.toArgb()))
            checked += 1
        }
        assertEquals(cases.size, checked)
        assertEquals(cases.count { it.getValue("id").jsonPrimitive.content.startsWith("relay.") }, RELAY_PALETTE.size)
        assertEquals(cases.count { it.getValue("id").jsonPrimitive.content.startsWith("fallback.") }, FALLBACK_PALETTE.size)
    }

    @Test
    fun heroPillLabelMeetsContrast() {
        val worst = rgb(root.getValue("pillLabel").jsonObject.getValue("worstBackground").jsonPrimitive.content)
        // Hero palette: production usage breakdown constants (light, dark). Relay uses theme primary.
        val inputs = mutableListOf<Triple<String, Color, ProviderKind>>()
        for ((kind, pair) in ProviderUsageBreakdownPalette.argb) {
            if (kind == ProviderKind.Relay) continue
            inputs += Triple("$kind light", Color(pair.light), kind)
            inputs += Triple("$kind dark", Color(pair.dark), kind)
        }
        assertEquals(ProviderKind.entries.size - 1, inputs.size / 2)
        for (preset in DarkPaletteId.entries) {
            val light = lightOriveoColorsOf(DarkPaletteChoice.Preset(preset).lightBrand).primary
            inputs += Triple("relay ${preset.id} light", light, ProviderKind.Relay)
            inputs += Triple("relay ${preset.id} dark", preset.colors.primary, ProviderKind.Relay)
        }
        for ((name, brand, kind) in inputs) {
            val label = heroPillLabel(heroPressedBrand(heroSubduedBrand(brand, kind)))
            val ratio = OriveoCustomPalette.contrast(label.toArgb() and 0xFFFFFF, worst)
            assertTrue("$name label ${hex(label.toArgb())} contrast $ratio", ratio >= 4.5)
        }
    }
}
