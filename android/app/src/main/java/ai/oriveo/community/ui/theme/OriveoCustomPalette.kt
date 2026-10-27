package ai.oriveo.community.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cbrt
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Custom dark palette: the user supplies a seed color `#RRGGBB` and the whole dark token set is derived from it by the contract.
 *
 * Contract source: `shared/theme-contracts/dark-palettes.v1.json#custom`; the derivation is a step-by-step port of the
 * `oklch` / `fromOklch` / `hueSliderSeed` / `deriveCustom` functions of that contract's reference implementation.
 * The parameter constants below correspond one to one with JSON `custom.derivation` / `custom.hueSlider`; change the JSON first when changing a value.
 * A seed color is always an Int of `0xRRGGBB` (no alpha).
 */
object OriveoCustomPalette {

    /** JSON `custom.id`: darkPalette storing this value means custom was chosen. */
    const val ID = "custom"

    /** JSON `custom.defaultSeed`. */
    const val DEFAULT_SEED: Int = 0x60A5FA

    /** JSON `custom.presets` (same order as the JSON). */
    val presets: List<Int> = listOf(
        0xFF8A65, 0xFB923C, 0xFBBF24, 0xA3E635, 0x4ADE80, 0x2DD4BF,
        0x22D3EE, 0x60A5FA, 0x818CF8, 0xC084FC, 0xF472B6, 0xFB7185,
    )

    // JSON `custom.hueSlider`
    private const val HUE_SLIDER_LIGHTNESS = 0.78
    private const val HUE_SLIDER_CHROMA = 0.14
    const val HUE_SLIDER_MIN = 0
    const val HUE_SLIDER_MAX = 359

    // JSON `custom.derivation`
    private const val MIN_CHROMA = 0.04
    private const val PRIMARY_LIGHTNESS_MIN = 0.72
    private const val PRIMARY_LIGHTNESS_MAX = 0.88
    private const val MAX_LIGHTNESS = 0.96
    private const val LIGHTEN_STEP = 0.01
    private const val ACCENT_HUE_SHIFT = 35.0
    private const val ACCENT_LIGHTNESS_DELTA = 0.05
    private const val ACCENT_CHROMA_SCALE = 0.9
    private const val ACCENT_MAX_LIGHTNESS = 0.9
    private const val HOVER_LIGHTNESS_DELTA = 0.07
    private const val HOVER_CHROMA_SCALE = 0.8
    private const val HOVER_MAX_LIGHTNESS = 0.94
    private const val ACTIVE_LIGHTNESS_DELTA = 0.08
    private const val ON_PRIMARY_START_LIGHTNESS = 0.22
    private const val ON_PRIMARY_MIN_LIGHTNESS = 0.08
    private const val ON_PRIMARY_MAX_CHROMA = 0.06
    private const val GAMUT_STEP = 0.004
    private const val ADJUSTED_NOTICE_DELTA = 0.02

    /** JSON `custom.derivation.glowK`. */
    const val GLOW_K = 1f

    // JSON `contrastRules.minSecondaryOnSurfaces` / `minOnPrimary`
    private const val MIN_SECONDARY_ON_SURFACES = 4.5
    private const val MIN_ON_PRIMARY = 4.5

    /** Whether the primary was lightened / darkened by the derivation (drives the one-line notice under the color picker); null = essentially the original color. */
    enum class Adjusted(val id: String) { Lightened("lightened"), Darkened("darkened") }

    /** Derivation result: key names match the 15 color fields of the JSON (values are `0xRRGGBB`). */
    data class Derived(
        val bg: Int,
        val bgSubtle: Int,
        val bgInset: Int,
        val surface: Int,
        val surfaceRaised: Int,
        val text: Int,
        val textSecondary: Int,
        val textTertiary: Int,
        val codeBg: Int,
        val codeHeaderBg: Int,
        val primary: Int,
        val primaryHover: Int,
        val primaryActive: Int,
        val accent: Int,
        val onPrimary: Int,
        val adjusted: Adjusted?,
    )

    private val derivedCache = ConcurrentHashMap<Int, Derived>()
    private val colorsCache = ConcurrentHashMap<Int, OriveoColors>()

    /** Only `#RRGGBB` is accepted (either case); anything else is null. */
    fun parseSeed(value: Any?): Int? {
        val text = value as? String ?: return null
        if (text.length != 7 || text[0] != '#') return null
        if (!text.substring(1).all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return text.substring(1).toInt(16)
    }

    /** Uppercase `#RRGGBB`. */
    fun format(seed: Int): String = "#%06X".format(seed and 0xFFFFFF)

    /** Hue bar value (integer degrees) -> seed color. */
    fun hueSliderSeed(hue: Int): Int = fromOklch(HUE_SLIDER_LIGHTNESS, HUE_SLIDER_CHROMA, hue.toDouble())

    /** Derives from a seed (cached; called at high frequency during rendering). */
    fun derive(seed: Int): Derived = derivedCache.getOrPut(seed and 0xFFFFFF) { computeDerived(seed and 0xFFFFFF) }

    /** The whole dark token set of a custom palette (cached). Derived fields follow [linkDarkPaletteFields]; status colors are shared. */
    fun colors(seed: Int): OriveoColors = colorsCache.getOrPut(seed and 0xFFFFFF) {
        val d = derive(seed)
        DarkOriveoColors.copy(
            backgroundBase = d.bg.toColor(),
            background = d.bgSubtle.toColor(),
            surfaceInset = d.bgInset.toColor(),
            surface = d.surface.toColor(),
            surfaceElevated = d.surfaceRaised.toColor(),
            textPrimary = d.text.toColor(),
            textSecondary = d.textSecondary.toColor(),
            textTertiary = d.textTertiary.toColor(),
            primary = d.primary.toColor(),
            primaryPressed = d.primaryHover.toColor(),
            primaryActive = d.primaryActive.toColor(),
            accent = d.accent.toColor(),
            onPrimary = d.onPrimary.toColor(),
            codeBlockBg = d.codeBg.toColor(),
            codeBlockHeaderBg = d.codeHeaderBg.toColor(),
            glowK = GLOW_K,
        ).linkDarkPaletteFields()
    }

    private fun Int.toColor(): Color = Color(0xFF000000.toInt() or this)

    private fun Color.rgb(): Int = toArgb() and 0xFFFFFF

    // ── Derivation (step by step as deriveCustom) ──

    private fun computeDerived(seed: Int): Derived {
        // ladderFrom = "dark": take the OKLCH lightness of each step of the default dark
        val ladder = DarkOriveoColors
        val (l0, c0, h) = oklch(seed)
        val c = max(c0, MIN_CHROMA)
        // familyChroma
        fun family(source: Color, chroma: Double): Int = fromOklch(oklch(source.rgb())[0], chroma, h)
        val bg = family(ladder.backgroundBase, 0.014)
        val bgSubtle = family(ladder.background, 0.015)
        val bgInset = family(ladder.surfaceInset, 0.016)
        val surface = family(ladder.surface, 0.017)
        val surfaceRaised = family(ladder.surfaceElevated, 0.02)
        val text = family(ladder.textPrimary, 0.008)
        val textSecondary = family(ladder.textSecondary, 0.02)
        val textTertiary = family(ladder.textTertiary, 0.02)
        val codeBg = family(ladder.codeBlockBg, 0.012)
        val codeHeaderBg = family(ladder.codeBlockHeaderBg, 0.016)

        // contrastRules.surfaces = bg / surface / surfaceRaised
        val surfaces = listOf(bg, surface, surfaceRaised)
        fun minOnSurfaces(color: Int): Double = surfaces.minOf { contrast(color, it) }

        // Primary: clamp lightness into range; if it still fails the gate, lighten by steps (hue and chroma unchanged)
        val pBase = min(PRIMARY_LIGHTNESS_MAX, max(PRIMARY_LIGHTNESS_MIN, l0))
        var pL = pBase
        var primary = if (pBase == l0) seed else fromOklch(pL, c, h)
        var i = 1
        while (minOnSurfaces(primary) < MIN_SECONDARY_ON_SURFACES && pBase + LIGHTEN_STEP * i <= MAX_LIGHTNESS) {
            pL = pBase + LIGHTEN_STEP * i
            primary = fromOklch(pL, c, h)
            i += 1
        }
        // Accent: shifted hue, slightly higher lightness, slightly lower chroma; lighten likewise if it fails the gate
        val aBase = min(ACCENT_MAX_LIGHTNESS, pL + ACCENT_LIGHTNESS_DELTA)
        val aC = c * ACCENT_CHROMA_SCALE
        val aH = (h + ACCENT_HUE_SHIFT) % 360
        var accent = fromOklch(aBase, aC, aH)
        i = 1
        while (minOnSurfaces(accent) < MIN_SECONDARY_ON_SURFACES && aBase + LIGHTEN_STEP * i <= MAX_LIGHTNESS) {
            accent = fromOklch(aBase + LIGHTEN_STEP * i, aC, aH)
            i += 1
        }
        val primaryHover = fromOklch(min(HOVER_MAX_LIGHTNESS, pL + HOVER_LIGHTNESS_DELTA), c * HOVER_CHROMA_SCALE, h)
        val actBase = pL - ACTIVE_LIGHTNESS_DELTA
        var primaryActive = fromOklch(actBase, c, h)

        // on-primary: a dark of the same hue, pushed down from the starting lightness until all four backgrounds pass the gate
        val onC = min(c, ON_PRIMARY_MAX_CHROMA)
        fun minOnP(color: Int): Double = listOf(primary, accent, primaryHover, primaryActive).minOf { contrast(color, it) }
        var onPrimary = fromOklch(ON_PRIMARY_START_LIGHTNESS, onC, h)
        i = 1
        while (minOnP(onPrimary) < MIN_ON_PRIMARY && ON_PRIMARY_START_LIGHTNESS - LIGHTEN_STEP * i >= ON_PRIMARY_MIN_LIGHTNESS) {
            onPrimary = fromOklch(ON_PRIMARY_START_LIGHTNESS - LIGHTEN_STEP * i, onC, h)
            i += 1
        }
        // When a too-dark pressed state makes on-primary fail the gate, lighten back (not beyond the primary lightness)
        i = 1
        while (contrast(onPrimary, primaryActive) < MIN_ON_PRIMARY && actBase + LIGHTEN_STEP * i <= pL) {
            primaryActive = fromOklch(actBase + LIGHTEN_STEP * i, c, h)
            i += 1
        }
        val adjusted = when {
            abs(pL - l0) <= ADJUSTED_NOTICE_DELTA -> null
            pL > l0 -> Adjusted.Lightened
            else -> Adjusted.Darkened
        }
        return Derived(
            bg = bg, bgSubtle = bgSubtle, bgInset = bgInset, surface = surface, surfaceRaised = surfaceRaised,
            text = text, textSecondary = textSecondary, textTertiary = textTertiary,
            codeBg = codeBg, codeHeaderBg = codeHeaderBg,
            primary = primary, primaryHover = primaryHover, primaryActive = primaryActive,
            accent = accent, onPrimary = onPrimary, adjusted = adjusted,
        )
    }

    // ── Color math (channel / luminance / contrast / oklch / fromOklch of the reference implementation) ──

    private fun channel(c: Int): Double {
        val s = c / 255.0
        return if (s <= 0.04045) s / 12.92 else ((s + 0.055) / 1.055).pow(2.4)
    }

    private fun fromLinear(x: Double): Double {
        val v = if (x <= 0.0031308) 12.92 * x else 1.055 * x.pow(1 / 2.4) - 0.055
        return v * 255
    }

    private fun luminance(rgb: Int): Double =
        0.2126 * channel(rgb shr 16 and 255) + 0.7152 * channel(rgb shr 8 and 255) + 0.0722 * channel(rgb and 255)

    internal fun contrast(a: Int, b: Int): Double {
        val la = luminance(a)
        val lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /** sRGB -> [L, C, H (degrees)]. */
    internal fun oklch(rgb: Int): DoubleArray {
        val r = channel(rgb shr 16 and 255)
        val g = channel(rgb shr 8 and 255)
        val b = channel(rgb and 255)
        val l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        val m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        val s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        val bigL = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
        val bigA = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
        val bigB = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        val hue = (atan2(bigB, bigA) * 180 / Math.PI + 360) % 360
        return doubleArrayOf(bigL, hypot(bigA, bigB), hue)
    }

    private fun encode(r: Double, g: Double, b: Double): Int {
        fun ch(v: Double): Int = floor(v + 0.5).toInt().coerceIn(0, 255)
        return (ch(r) shl 16) or (ch(g) shl 8) or ch(b)
    }

    /** OKLCH -> sRGB: when out of gamut, chroma drops step by [GAMUT_STEP] until it falls inside the gamut. */
    internal fun fromOklch(lightness: Double, chroma: Double, hue: Double): Int {
        val rad = hue * Math.PI / 180
        var i = 0
        while (chroma - GAMUT_STEP * i >= 0) {
            val c = chroma - GAMUT_STEP * i
            val a = c * cos(rad)
            val b = c * sin(rad)
            val l = (lightness + 0.3963377774 * a + 0.2158037573 * b).pow(3)
            val m = (lightness - 0.1055613458 * a - 0.0638541728 * b).pow(3)
            val s = (lightness - 0.0894841775 * a - 1.291485548 * b).pow(3)
            val rgb = doubleArrayOf(
                4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
            )
            if (rgb.all { it >= -1e-4 && it <= 1 + 1e-4 }) {
                return encode(
                    fromLinear(rgb[0].coerceIn(0.0, 1.0)),
                    fromLinear(rgb[1].coerceIn(0.0, 1.0)),
                    fromLinear(rgb[2].coerceIn(0.0, 1.0)),
                )
            }
            i += 1
        }
        val grey = fromLinear(lightness.pow(3).coerceIn(0.0, 1.0))
        return encode(grey, grey, grey)
    }
}
