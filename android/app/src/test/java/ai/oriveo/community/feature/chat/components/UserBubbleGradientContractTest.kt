package ai.oriveo.community.feature.chat.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.DarkPaletteContract
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.OriveoCustomPalette
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoUserBubble
import java.io.File
import kotlin.math.abs
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The user bubble's viewport-anchored vertical gradient:
 * the stops are aligned with `dark-palettes.v1.json#userBubbleStops` and `custom.derivationCases[].bubble`,
 * plus the anchoring pure function, the production style and the production bubble source. Expected values are always read live from the fixture.
 */
class UserBubbleGradientContractTest {

    private val spec: JsonObject get() = DarkPaletteContract.derived.getValue("userBubble").jsonObject

    private fun rgb(color: Color): Int = color.toArgb() and 0xFFFFFF

    private fun hex(text: String): Int = requireNotNull(OriveoCustomPalette.parseSeed(text)) { "not #RRGGBB: $text" }

    private fun assertStopsClose(label: String, expected: List<String>, actual: List<Color>) {
        assertEquals("$label stop count", expected.size, actual.size)
        expected.forEachIndexed { i, text ->
            val e = hex(text)
            val a = rgb(actual[i])
            for (shift in listOf(16, 8, 0)) {
                assertTrue(
                    "$label[$i] expected $text got ${OriveoCustomPalette.format(a)}",
                    abs((e shr shift and 255) - (a shr shift and 255)) <= 1,
                )
            }
        }
    }

    private fun JsonObject.hexList(key: String): List<String> = getValue(key).jsonArray.map { it.jsonPrimitive.content }

    // ── 1. Stop contract ──

    @Test
    fun `preset stops match fixture per channel within one`() {
        val presets = DarkPaletteContract.root.getValue("userBubbleStops").jsonObject
        assertEquals("7 presets", DarkPaletteContract.order.toSet(), presets.keys)
        for ((id, value) in presets) {
            val choice = DarkPaletteChoice.Preset(DarkPaletteId.fromId(id))
            val stops = value.jsonObject
            assertStopsClose("$id.dark", stops.hexList("dark"), OriveoUserBubble.stops(choice, isDark = true))
            assertStopsClose("$id.light", stops.hexList("light"), OriveoUserBubble.stops(choice, isDark = false))
        }
    }

    @Test
    fun `custom derivation case stops match fixture per channel within one`() {
        val cases = DarkPaletteContract.custom.getValue("derivationCases").jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val seed = case.getValue("seed").jsonPrimitive.content
            val choice = DarkPaletteChoice.Custom(hex(seed))
            val bubble = case.getValue("bubble").jsonObject
            assertStopsClose("$seed.dark", bubble.hexList("dark"), OriveoUserBubble.stops(choice, isDark = true))
            assertStopsClose("$seed.light", bubble.hexList("light"), OriveoUserBubble.stops(choice, isDark = false))
        }
    }

    @Test
    fun `spec constants match fixture`() {
        assertEquals("viewport", spec.getValue("anchor").jsonPrimitive.content)
        assertEquals("vertical", spec.getValue("axis").jsonPrimitive.content)
        assertEquals(spec.getValue("stops").jsonPrimitive.content.toInt(), OriveoUserBubble.STOP_COUNT)
        val highlight = spec.getValue("highlight").jsonObject
        val alpha = highlight.getValue("alpha").jsonObject
        assertEquals(DarkPaletteContract.float(alpha.getValue("dark")), OriveoUserBubble.HIGHLIGHT_ALPHA_DARK)
        assertEquals(DarkPaletteContract.float(alpha.getValue("light")), OriveoUserBubble.HIGHLIGHT_ALPHA_LIGHT)
        assertEquals(DarkPaletteContract.float(highlight.getValue("width")), OriveoUserBubble.HIGHLIGHT_WIDTH_DP)
        val shadow = spec.getValue("shadow").jsonObject
        assertEquals("bottom", shadow.getValue("from").jsonPrimitive.content)
        assertEquals(DarkPaletteContract.float(shadow.getValue("alpha")), OriveoUserBubble.SHADOW_ALPHA)
        assertEquals(DarkPaletteContract.float(shadow.getValue("blur")), OriveoUserBubble.SHADOW_BLUR_DP)
        assertEquals(DarkPaletteContract.float(shadow.getValue("y")), OriveoUserBubble.SHADOW_Y_DP)
    }

    // ── 2. Anchoring pure function ──

    @Test
    fun `span runs from minus top to viewport height minus top`() {
        val h = 800f
        val first = OriveoUserBubble.span(viewportHeight = h, bubbleTop = 120f)
        assertEquals(-120f, first.startY)
        assertEquals(680f, first.endY)
        // Scrolling: the bubble top moves up to 40 and the gradient segment moves down with it
        val scrolled = OriveoUserBubble.span(viewportHeight = h, bubbleTop = 40f)
        assertEquals(-40f, scrolled.startY)
        assertEquals(760f, scrolled.endY)
        assertNotEquals(first, scrolled)
        // Keyboard up: the viewport gets shorter and the end follows
        val keyboard = OriveoUserBubble.span(viewportHeight = 500f, bubbleTop = 120f)
        assertEquals(-120f, keyboard.startY)
        assertEquals(380f, keyboard.endY)
        // The total gradient length is always the viewport height
        assertEquals(h, first.endY - first.startY)
    }

    // ── 3. Production path ──

    @Test
    fun `production style uses vertical stops with converged shadow`() {
        for (isDark in listOf(true, false)) {
            for (choice in listOf(DarkPaletteChoice.Default, DarkPaletteChoice.Custom(OriveoCustomPalette.DEFAULT_SEED))) {
                val style = OriveoUserBubble.style(choice, isDark)
                assertEquals("7 vertical stops", OriveoUserBubble.STOP_COUNT, style.stops.size)
                val old135 = OriveoGradients.primaryStops(choice.colors, isDark, choice.lightBrand)
                assertNotEquals("no longer the old two-color 135-degree gradient", old135, style.stops)
                assertEquals("shadow alpha", 0.16f, style.shadowColor.alpha, 0.002f)
                assertEquals("shadow takes the bottom color", rgb(style.stops.last()), rgb(style.shadowColor))
                assertEquals(
                    "top inner highlight alpha",
                    if (isDark) OriveoUserBubble.HIGHLIGHT_ALPHA_DARK else OriveoUserBubble.HIGHLIGHT_ALPHA_LIGHT,
                    style.highlightColor.alpha,
                    0.002f,
                )
            }
        }
    }

    @Test
    fun `production user bubble draws anchored fill instead of old glow`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt").readText()
        val start = source.indexOf("private fun UserBubble(")
        assertTrue(start >= 0)
        val body = source.substring(start, source.indexOf("\n@Composable", start + 1))
        assertTrue(body.contains("OriveoUserBubble.style("))
        assertTrue(body.contains(".userBubbleFill(bubbleStyle, bubbleShape, LocalUserBubbleViewport.current)"))
        assertFalse("old 135-degree gradient", body.contains("OriveoGradients.primary,"))
        assertFalse("old outer glow", source.contains("userBubbleGlow"))

        val list = File("src/main/java/ai/oriveo/community/feature/chat/ChatMessagesList.kt").readText()
        assertTrue(list.contains("LocalUserBubbleViewport provides bubbleViewport"))
        assertTrue(list.contains(".userBubbleViewport(bubbleViewport)"))
    }
}
