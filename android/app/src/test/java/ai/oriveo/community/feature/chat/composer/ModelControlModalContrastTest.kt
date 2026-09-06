package ai.oriveo.community.feature.chat.composer

import androidx.compose.ui.graphics.Color
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.LightOriveoColors
import ai.oriveo.community.ui.theme.OriveoColors
import java.io.File
import kotlin.math.pow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Computes real contrast ratios for the model options panel in both light and dark themes.
 *
 * The panel options are a row of wrapping pills rather than a segmented control, and the sheet
 * background is `OriveoTheme.colors.background` plus a card surface (`surface` in light,
 * `surfaceElevated` in dark).
 *
 * Measures the token the component actually references: colors are read live from
 * `OriveoColors` and alphas from the production pure functions, never copied as a second hex
 * literal. Copying a value would just prove "some color in the palette happens to pass", not
 * that the component itself passes.
 */
class ModelControlModalContrastTest {

    // The ModalBottomSheet's containerColor is set explicitly to OriveoTheme.colors.background;
    // the card sits on top of it (surface in light, surfaceElevated in dark, both with alpha).
    private val lightCard = composite(LightOriveoColors.surface, LightOriveoColors.background)
    private val darkCard = composite(DarkOriveoColors.surfaceElevated, DarkOriveoColors.background)

    // -- Negative control: without this we can't prove switching tokens actually changed anything --

    @Test
    fun `the raw brand and warning values would fail as text`() {
        assertTrue(
            "the raw primary value passes on the light card (${fmt(contrast(LightOriveoColors.primary, lightCard))}) -- this negative control is broken, recheck the baseline",
            contrast(LightOriveoColors.primary, lightCard) < 4.5,
        )
        val capsule = composite(
            LightOriveoColors.warning.copy(alpha = modelControlBadgeCapsuleAlpha(isDark = false)),
            lightCard,
        )
        assertTrue(
            "the raw warning value passes against its own capsule fill (${fmt(contrast(LightOriveoColors.warning, capsule))})",
            contrast(LightOriveoColors.warning, capsule) < 4.5,
        )
        // Light theme textTertiary doesn't even clear the non-text 3:1 floor -- which is why every caption in the panel uses textSecondary instead.
        assertTrue(
            "textTertiary passes on the light card, meaning the palette changed and the caption token choice needs to be reconsidered",
            contrast(LightOriveoColors.textTertiary, lightCard) < 3.0,
        )
    }

    // -- Text AA >= 4.5 (checked in both themes) --

    @Test
    fun `card titles status rows and notes meet AA in both themes`() {
        forBothThemes { name, colors, card ->
            assertAA("$name card title", colors.textPrimary, card)
            // Status rows, captions, pill annotations, and the candidate page header all use textSecondary.
            assertAA("$name caption and status row", colors.textSecondary, card)
            // Secondary entry points (view supported models / open advanced settings) are tappable text, not decorative color.
            assertAA("$name secondary entry point", colors.primaryTextSafe, card)
            // Warning captions (custom takeover / upstream rejection / cost and privacy) use warningText.
            assertAA("$name warning caption", colors.warningText, card)
        }
    }

    @Test
    fun `the selected pill label meets AA on its text safe fill`() {
        forBothThemes { name, colors, _ ->
            assertAA("$name selected pill label", colors.textInverse, colors.primaryTextSafe)
        }
    }

    @Test
    fun `both status badges meet AA on their own capsule`() {
        forBothThemes { name, colors, card ->
            val alpha = modelControlBadgeCapsuleAlpha(isDark = colors === DarkOriveoColors)
            assertAA(
                "$name \"Manual / Not ready\" badge",
                colors.warningText,
                composite(colors.warning.copy(alpha = alpha), card),
            )
            assertAA(
                "$name \"Unavailable\" badge",
                colors.textPrimary,
                composite(colors.textTertiary.copy(alpha = alpha), card),
            )
        }
    }

    @Test
    fun `the close bar label meets AA on the chrome surface`() {
        listOf(
            "Light" to (LightOriveoColors to LightOriveoColors.background),
            "Dark" to (DarkOriveoColors to DarkOriveoColors.background),
        ).forEach { (name, pair) ->
            val (colors, background) = pair
            assertAA("$name close bar", colors.textPrimary, composite(colors.surfaceChrome, background))
        }
    }

    // -- Non-text >= 3:1 --

    @Test
    fun `the selected pill fill carries state and meets the non text threshold`() {
        forBothThemes { name, colors, card ->
            val ratio = contrast(colors.primaryTextSafe, card)
            assertTrue(
                "$name selected pill fill against the card is only ${fmt(ratio)}, below the non-text 3:1 floor -- this fill is the only signal for which option is selected",
                ratio >= 3.0,
            )
        }
    }

    /**
     * Both the badge capsule fill and the unselected pill fill are deliberately low-opacity
     * decorative fills: this pins the measured values instead of an arbitrary threshold, so any
     * drift in either direction fails loudly instead of silently eroding a known trade-off. It
     * also asserts that dark theme never gets muddier than light theme.
     */
    @Test
    fun `the decorative fills stay pinned and never get muddier in dark`() {
        val badgeLight = fillRatio(LightOriveoColors.warning, modelControlBadgeCapsuleAlpha(false), lightCard)
        val badgeDark = fillRatio(DarkOriveoColors.warning, modelControlBadgeCapsuleAlpha(true), darkCard)
        assertEquals("the measured light badge fill changed, please re-evaluate", 1.0982, badgeLight, 0.001)
        assertEquals("the measured dark badge fill changed, please re-evaluate", 1.6620, badgeDark, 0.001)
        assertTrue("the dark capsule must not be muddier than the light one", badgeDark >= badgeLight)

        val pillLight = fillRatio(LightOriveoColors.textPrimary, modelControlUnselectedPillAlpha(false), lightCard)
        val pillDark = fillRatio(DarkOriveoColors.textPrimary, modelControlUnselectedPillAlpha(true), darkCard)
        assertEquals("the measured light unselected pill fill changed, please re-evaluate", 1.1283, pillLight, 0.001)
        assertEquals("the measured dark unselected pill fill changed, please re-evaluate", 1.3372, pillDark, 0.001)
        assertTrue("the dark pill fill must not be muddier than the light one", pillDark >= pillLight)
    }

    /**
     * The unselected pill label sits on a capsule fill of "card + 6%/10% textPrimary", and both
     * themes must clear 4.5:1.
     *
     * The global neutral `textSecondary` (`#6B7280` on Android) only reaches 4.283:1 against this
     * fill in light theme, which is too low to reuse directly here. [modelControlUnselectedPillLabel]
     * instead uses a component-local `#52525B` that matches the iOS/Web value, so the assertion
     * checks the real contrast rather than pinning a known-good number.
     */
    @Test
    fun `the unselected pill label meets AA in both themes`() {
        val lightFill = composite(
            LightOriveoColors.textPrimary.copy(alpha = modelControlUnselectedPillAlpha(false)),
            lightCard,
        )
        assertAA(
            "Light unselected pill label",
            modelControlUnselectedPillLabel(LightOriveoColors, isDark = false),
            lightFill,
        )
        val darkFill = composite(
            DarkOriveoColors.textPrimary.copy(alpha = modelControlUnselectedPillAlpha(true)),
            darkCard,
        )
        assertAA(
            "Dark unselected pill label",
            modelControlUnselectedPillLabel(DarkOriveoColors, isDark = true),
            darkFill,
        )
    }

    /**
     * The component-local light theme value must actually be darker than the global
     * `textSecondary` -- otherwise "changing the color" is just a different way of writing the
     * same thing. This also pins it to the same value as iOS's `Palette.textSecondary` in light
     * theme so the two platforms don't drift apart.
     */
    @Test
    fun `the pill label color is a component local override that beats the global neutral`() {
        assertEquals(Color(0xFF52525B), modelControlUnselectedPillLabel(LightOriveoColors, isDark = false))
        // Dark theme already matches on both platforms, so no separate constant is needed.
        assertEquals(DarkOriveoColors.textSecondary, modelControlUnselectedPillLabel(DarkOriveoColors, isDark = true))
        assertEquals(Color(0xFFB4BAC6), DarkOriveoColors.textSecondary)
        val lightFill = composite(
            LightOriveoColors.textPrimary.copy(alpha = modelControlUnselectedPillAlpha(false)),
            lightCard,
        )
        assertTrue(
            "the global textSecondary now passes against this fill, meaning this component-local override is no longer needed",
            contrast(LightOriveoColors.textSecondary, lightFill) < 4.5,
        )
        // The global neutral color is untouched.
        assertEquals(Color(0xFF6B7280), LightOriveoColors.textSecondary)
    }

    // -- Do the components actually use these tokens? --

    /** Passing contrast alone isn't enough: the component has to actually use the token, or the measurement is for a color nobody references. */
    @Test
    fun `the components actually reference the tokens this test measures`() {
        val components = repoFile("feature/chat/composer/ModelControlsComponents.kt").readText()
        listOf(
            "colors.primaryTextSafe",
            "colors.textInverse",
            "colors.warningText",
            "colors.textSecondary",
            "colors.textPrimary",
            "modelControlBadgeCapsuleAlpha(",
            "modelControlUnselectedPillAlpha(",
            "modelControlUnselectedPillLabel(",
        ).forEach { assertTrue("the component doesn't reference $it, so this file's measurements are meaningless", components.contains(it)) }
        // Captions must never fall back to textTertiary (light theme doesn't even clear 3:1).
        assertFalse("panel components must not use textTertiary", components.contains("colors.textTertiary"))
        assertFalse(
            "action text in the modal must use the text-safe content color",
            repoFile("feature/chat/composer/ModelControlsSheet.kt").readText().contains("colors.textTertiary"),
        )
        assertTrue(
            "TextButtons like the secondary page back action still use the text-safe content color",
            repoFile("feature/chat/composer/ModelControlsSheet.kt").readText()
                .contains("modelControlTextButtonColors()"),
        )
    }

    /** `primaryTextSafe`, `warningText`, and `textDisabledOnControl` are variants; the brand color itself is untouched. */
    @Test
    fun `the text safe variants match the cross platform values and leave primary untouched`() {
        assertEquals(Color(0xFF8C5FF8), LightOriveoColors.primary)
        assertEquals(Color(0xFFA78BFA), DarkOriveoColors.primary)
        assertEquals(Color(0xFF6D28D9), LightOriveoColors.primaryTextSafe)
        assertEquals(Color(0xFFA78BFA), DarkOriveoColors.primaryTextSafe)
        assertEquals(Color(0xFF6A6A73), LightOriveoColors.textDisabledOnControl)
        assertEquals(Color(0xFF9AA0AC), DarkOriveoColors.textDisabledOnControl)
        // Same name, same value across platforms: iOS's `Palette.warningText` uses these same two numbers.
        assertEquals(Color(0xFF92400E), LightOriveoColors.warningText)
        assertEquals(Color(0xFFFCD34D), DarkOriveoColors.warningText)
        assertEquals(Color(0xFFF59E0B), LightOriveoColors.warning)
    }

    // -- Helpers --

    private fun assertAA(label: String, foreground: Color, background: Color) {
        val ratio = contrast(composite(foreground, background), background)
        assertTrue("$label is only ${fmt(ratio)}, below AA 4.5", ratio >= 4.5)
    }

    private fun fillRatio(color: Color, alpha: Float, card: Color): Double =
        contrast(composite(color.copy(alpha = alpha), card), card)

    private fun forBothThemes(block: (String, OriveoColors, Color) -> Unit) {
        block("Light", LightOriveoColors, lightCard)
        block("Dark", DarkOriveoColors, darkCard)
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
