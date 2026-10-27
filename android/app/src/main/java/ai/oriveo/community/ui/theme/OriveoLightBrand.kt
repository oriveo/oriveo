package ai.oriveo.community.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import java.util.concurrent.ConcurrentHashMap

/**
 * Light brand colors: in the light appearance a palette only swaps the brand color family; neutral surfaces, text greys and borders stay unchanged.
 *
 * Fields share names with `shared/theme-contracts/dark-palettes.v1.json#light`. The default palette is the hand-tuned constant [Default];
 * the other presets and custom palettes are derived by [derive] (a step-by-step port of the contract's reference `deriveLight`).
 */
@Immutable
data class OriveoLightBrand(
    /** Icons, strokes, emphasized words, cursor and link icons on a white background. */
    val ink: Color,
    /** Body-level text (links, chip text). */
    val textSafe: Color,
    /** Fill that only carries an icon (send button). */
    val fill: Color,
    /** Fill that carries text on top (primary button, selected segment block). */
    val fillText: Color,
    val fillPressed: Color,
    /** The two ends of the user bubble and the brand gradient. */
    val gradStart: Color,
    val gradEnd: Color,
    /** Text and icons on a fill / gradient. */
    val onPrimary: Color,
    /** Light chip background. */
    val soft: Color,
    /** Second brand color: the end of the home name gradient and the second glow. */
    val accent: Color,
    /** The two ends of the vertical page background gradient. */
    val bgTop: Color,
    val bgBottom: Color,
    /** Home model capsule background. */
    val pill: Color,
    val mode: Mode,
) {
    /** Fill mode: a darkened fill with white text, or a bright fill with dark text. */
    enum class Mode(val id: String) { White("white"), Bright("bright") }

    /** Light window background (navigation bar area): the default palette keeps the original #F6F5FA, the others use [bgTop]. */
    val windowBackground: Color get() = tuned(DefaultWindowBackground, bgTop)

    /** The default palette keeps the original hand-tuned value [defaultValue] here; the other palettes use the brand key [derived]. */
    fun tuned(defaultValue: Color, derived: Color): Color = if (this === Default) defaultValue else derived

    companion object {
        /** The hand-tuned values of the default palette ([DefaultLightBrand]). */
        val Default: OriveoLightBrand get() = DefaultLightBrand

        /** The light window background of the default palette: the value from before palette-following. */
        private val DefaultWindowBackground = Color(0xFFF6F5FA)

        private val cache = ConcurrentHashMap<DarkPaletteChoice, OriveoLightBrand>()

        /** Gets the light brand colors of a palette (cached; called at high frequency during rendering). */
        fun of(choice: DarkPaletteChoice): OriveoLightBrand =
            if (choice == DarkPaletteChoice.Default) {
                Default
            } else {
                cache.getOrPut(choice) {
                    val dark = choice.colors
                    derive(dark.primary.rgb(), dark.accent.rgb(), dark.onPrimary.rgb())
                }
            }

        // JSON `light.derivation`
        private const val STEP = 0.01
        private const val MIN_LIGHTNESS = 0.2
        private const val MAX_LIGHTNESS = 0.95
        private const val MIN_INK = 3.0
        private const val MIN_TEXT = 4.5
        private const val MIN_INK_TEXT = 3.8

        /** JSON `light.derivation.ladder`: [L, C]. */
        private enum class Key(val lightness: Double, val chroma: Double) {
            Ink(0.612, 0.22),
            TextSafe(0.491, 0.241),
            Fill(0.612, 0.22),
            FillText(0.491, 0.241),
            FillPressed(0.545, 0.246),
            GradStart(0.57, 0.242),
            GradEnd(0.493, 0.204),
            Soft(0.943, 0.028),
            Accent(0.667, 0.259),
            BgTop(0.973, 0.008),
            BgBottom(0.955, 0.013),
            Pill(0.96, 0.014),
        }

        /** JSON `light.derivation.bright`: the starting lightness of the bright-fill mode. */
        private val brightLightness = mapOf(
            Key.Fill to 0.75,
            Key.FillText to 0.75,
            Key.FillPressed to 0.7,
            Key.GradStart to 0.8,
            Key.GradEnd to 0.74,
        )

        private const val WHITE = 0xFFFFFF

        /**
         * Step by step as `deriveLight`. The parameters are the dark palette's primary / accent / onPrimary (`0xRRGGBB`).
         */
        internal fun derive(primary: Int, accent: Int, darkOnPrimary: Int): OriveoLightBrand {
            val hue = OriveoCustomPalette.oklch(primary)[2]
            val accentHue = OriveoCustomPalette.oklch(accent)[2]
            fun at(key: Key, lightness: Double = key.lightness): Int =
                OriveoCustomPalette.fromOklch(lightness, key.chroma, if (key == Key.Accent) accentHue else hue)
            fun contrast(a: Int, b: Int): Double = OriveoCustomPalette.contrast(a, b)

            val out = HashMap<Key, Int>()
            Key.entries.forEach { out[it] = at(it) }
            // Step the lightness down until test(color) >= min
            fun darken(key: Key, min: Double, test: (Int) -> Double) {
                var i = 1
                while (test(out.getValue(key)) < min && key.lightness - STEP * i >= MIN_LIGHTNESS) {
                    out[key] = at(key, key.lightness - STEP * i)
                    i += 1
                }
            }
            val bgTop = out.getValue(Key.BgTop)
            // Ink is used for small text such as emphasized words and links: not below the default hand-tuned purple (3.80)
            darken(Key.Ink, MIN_INK_TEXT) { contrast(it, bgTop) }
            darken(Key.Accent, MIN_INK) { contrast(it, bgTop) }
            val soft = out.getValue(Key.Soft)
            darken(Key.TextSafe, MIN_TEXT) { minOf(contrast(it, WHITE), contrast(it, bgTop), contrast(it, soft)) }

            // Fill: a darkened fill with white text vs a bright fill with dark text; pick the one with the higher chroma at the gradient start
            fun chroma(lightness: Double): Double =
                OriveoCustomPalette.oklch(OriveoCustomPalette.fromOklch(lightness, Key.GradStart.chroma, hue))[1]
            val bright = chroma(brightLightness.getValue(Key.GradStart)) > chroma(Key.GradStart.lightness)
            val onPrimary = if (bright) darkOnPrimary else WHITE
            if (bright) {
                brightLightness.forEach { (key, start) ->
                    out[key] = at(key, start)
                    var i = 1
                    while (contrast(onPrimary, out.getValue(key)) < MIN_TEXT && start + STEP * i <= MAX_LIGHTNESS) {
                        out[key] = at(key, start + STEP * i)
                        i += 1
                    }
                }
            } else {
                out[Key.Fill] = out.getValue(Key.Ink)
                out[Key.FillText] = out.getValue(Key.TextSafe)
                listOf(Key.FillPressed, Key.GradStart, Key.GradEnd).forEach { key ->
                    darken(key, MIN_TEXT) { contrast(it, WHITE) }
                }
            }
            fun color(key: Key): Color = out.getValue(key).toColor()
            return OriveoLightBrand(
                ink = color(Key.Ink),
                textSafe = color(Key.TextSafe),
                fill = color(Key.Fill),
                fillText = color(Key.FillText),
                fillPressed = color(Key.FillPressed),
                gradStart = color(Key.GradStart),
                gradEnd = color(Key.GradEnd),
                onPrimary = onPrimary.toColor(),
                soft = color(Key.Soft),
                accent = color(Key.Accent),
                bgTop = color(Key.BgTop),
                bgBottom = color(Key.BgBottom),
                pill = color(Key.Pill),
                mode = if (bright) Mode.Bright else Mode.White,
            )
        }

        private fun Int.toColor(): Color = Color(0xFF000000.toInt() or this)

        private fun Color.rgb(): Int = toArgb() and 0xFFFFFF
    }
}

/**
 * The whole token set in the light appearance: [LightOriveoColors] with only the brand fields swapped (mapped by purpose).
 * The default palette equals [LightOriveoColors] value for value.
 */
internal fun lightOriveoColorsOf(brand: OriveoLightBrand): OriveoColors = LightOriveoColors.copy(
    primary = brand.ink,
    primaryPressed = brand.fillPressed,
    primarySoft = brand.soft,
    // Light primary-glow = primary @ 10%
    primaryGlow = brand.ink.copy(alpha = 0.10f),
    primaryTextSafe = brand.textSafe,
    primaryActive = brand.fillPressed,
    // Light has no separate secondary color and equals primary (the second brand color is only read through [OriveoLightBrand.accent] on the home page / glows)
    accent = brand.ink,
    onPrimary = brand.onPrimary,
)
