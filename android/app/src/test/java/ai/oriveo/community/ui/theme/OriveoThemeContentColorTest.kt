package ai.oriveo.community.ui.theme

import androidx.compose.material3.contentColorFor
import androidx.compose.ui.graphics.Color
import java.io.File
import kotlin.math.pow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
/**
 * The theme must take over Material3's `LocalContentColor`.
 *
 * What goes wrong without it (confirmed on a real device: a token-count dialog's title
 * and its three numbers rendered as pure black `(0,0,0)`, a contrast ratio of roughly 1.1:1):
 *
 * 1. M3's default is `compositionLocalOf { Color.Black }` -- a literal black that never
 *    flips with the theme.
 * 2. Nothing in this codebase wires it up: the root is a `Box`, not a `Surface`; every
 *    screen's `Scaffold` uses `containerColor = Color.Transparent` (so `OriveoScreenBackground`
 *    shows through), `contentColorFor(Transparent)` matches no role in the ColorScheme and
 *    returns `Unspecified`, and `takeOrElse` falls back to that same default.
 * 3. So any `Text` without an explicit `color`, or `Icon` without a `tint`, renders as a
 *    near-black smear in dark mode.
 *
 * Why this survives all the way to a shipped build: in light mode, black text on a light
 * background looks perfectly normal. Pure function tests, layout assertions and light-mode
 * screenshots can't catch this -- only a gate like this one can.
 */
class OriveoThemeContentColorTest {

    private val themeSource = repoFile("ui/theme/OriveoTheme.kt").readText()

    // -- gate: the provide call must never be removed --

    @Test
    fun `theme provides LocalContentColor from the palette`() {
        assertTrue(
            "OriveoTheme must provide LocalContentColor, otherwise the whole app falls back to M3's literal black",
            themeSource.contains("LocalContentColor provides"),
        )
        assertTrue(
            "LocalContentColor must be wired to the theme's textPrimary, not some other constant",
            themeSource.contains("LocalContentColor provides oriveoColors.textPrimary"),
        )
    }

    /**
     * Both M3 schemes are derived from the palette instance, so `ColorScheme.contentColorFor(surface)` hits and must
     * yield the same textPrimary the theme provides explicitly; otherwise text inside M3 containers drifts from the rest.
     */
    @Test
    fun `light and dark schemes hit the palette surface with the provided content color`() {
        // The dark ColorScheme is derived from the palette instance (darkColorSchemeOf), so surface hits;
        // the content color it yields must be textPrimary, the same as the explicitly provided one, or text inside M3 containers would differ from text outside.
        for (palette in DarkPaletteId.entries) {
            val scheme = darkColorSchemeOf(palette.colors)
            assertEquals("${palette.id} M3 surface should equal the palette surface", palette.colors.surface, scheme.surface)
            assertEquals("${palette.id} M3 onSurface should equal textPrimary", palette.colors.textPrimary, scheme.onSurface)
        }
        // Light scheme is derived the same way: an M3 container on the palette surface must get textPrimary,
        // not the M3 default ink that differs from the explicitly provided content color.
        val light = lightColorSchemeOf(LightOriveoColors)
        assertEquals("light M3 surface should equal the palette surface", LightOriveoColors.surface, light.surface)
        assertEquals(
            "light contentColorFor(surface) should be textPrimary",
            LightOriveoColors.textPrimary,
            light.contentColorFor(light.surface),
        )
    }

    // -- negative control: without this step there's no way to prove the takeover changed anything --

    @Test
    fun `the material default black is unreadable on every dark surface`() {
        for ((label, background) in darkBackgrounds()) {
            val ratio = contrast(Color.Black, background)
            assertTrue(
                "M3's default Color.Black against $label reached a contrast of ${fmt(ratio)} -- this control is no longer valid, re-check the baseline",
                ratio < 3.0,
            )
        }
    }

    // -- positive: the provided content color meets AA in both themes --

    @Test
    fun `the provided content color meets AA on both themes`() {
        for ((label, background) in darkBackgrounds()) {
            assertAA("dark $label", DarkOriveoColors.textPrimary, background)
        }
        for ((label, background) in lightBackgrounds()) {
            assertAA("light $label", LightOriveoColors.textPrimary, background)
        }
    }

    // -- helpers --

    /** Content color actually lands on these backgrounds: screen background, sheet background, cards, nested cards. */
    private fun darkBackgrounds() = listOf(
        "background" to DarkOriveoColors.background,
        "backgroundBase" to DarkOriveoColors.backgroundBase,
        "surface" to DarkOriveoColors.surface,
        "surfaceInset" to DarkOriveoColors.surfaceInset,
        "surfaceElevated" to DarkOriveoColors.surfaceElevated,
    )

    private fun lightBackgrounds() = listOf(
        "background" to LightOriveoColors.background,
        "surface" to composite(LightOriveoColors.surface, LightOriveoColors.background),
        "surfaceInset" to composite(LightOriveoColors.surfaceInset, LightOriveoColors.background),
    )

    private fun assertAA(label: String, foreground: Color, background: Color) {
        val ratio = contrast(composite(foreground, background), background)
        assertTrue("the content color on $label is only ${fmt(ratio)}, below the AA threshold of 4.5", ratio >= 4.5)
    }

    private fun fmt(ratio: Double) = "%.4f:1".format(ratio)

    /** source-over: composites a translucent foreground onto an opaque background. */
    private fun composite(foreground: Color, background: Color): Color {
        val a = foreground.alpha
        if (a >= 1f) return foreground.copy(alpha = 1f)
        return Color(
            red = a * foreground.red + (1 - a) * background.red,
            green = a * foreground.green + (1 - a) * background.green,
            blue = a * foreground.blue + (1 - a) * background.blue,
            alpha = 1f,
        )
    }

    private fun relativeLuminance(color: Color): Double {
        fun channel(value: Float): Double {
            val v = value.toDouble()
            return if (v <= 0.03928) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    private fun contrast(a: Color, b: Color): Double {
        val la = relativeLuminance(a)
        val lb = relativeLuminance(b)
        return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
    }

    private fun repoFile(relative: String): File {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct
        var dir = File(System.getProperty("user.dir")!!).absoluteFile
        val prefix = "android/app/src/main/java/ai/oriveo/community/"
        while (true) {
            val candidate = File(dir, prefix + relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile ?: break
        }
        error("could not find $relative")
    }
}
