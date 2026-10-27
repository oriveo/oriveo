package ai.oriveo.community.feature.home

import android.os.Build
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.RadialGradientShader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.SweepGradientShader
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalGraphicsContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.LocalOriveoColors
import ai.oriveo.community.ui.theme.DefaultLightBrandTuned
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoLightBrand
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.gradientBrandStops
import java.util.Calendar
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import android.graphics.BlurMaskFilter
import android.graphics.Matrix as AndroidMatrix
import android.graphics.Paint as AndroidPaint

/**
 * Aurora -- the home screen's dedicated visual system (matches iOS AuroraTheme).
 *
 * Design direction: iOS 26 liquid glass, a soft purple halo, and generous calm. Used only within Home so it
 * never leaks into the global OriveoTheme.
 *
 * Color convention: every token below that carries an alpha is an **absolute** value (the same meaning as
 * iOS `Color.dynamic(…, alpha:)`). Never `copy(alpha=)` on top of it: that replaces rather than multiplies,
 * and would turn a 5% stroke into something many times stronger.
 */
internal object AuroraTheme {

    // color palette -- fully aligned with iOS AuroraTheme.Colors
    object Colors {
        // accent / accentGlow / background / send button / name gradient / soft glows / aurora ring: dark is in [AuroraDarkColors],
        // light follows the current palette's light brand colors, see [AuroraLightColors]

        val auroraBlueLight = Color(0xFF60A5FA)
        val auroraBlueDark = Color(0xFF93C5FD)

        val textPrimaryLight = Color(0xFF0A0612)
        val textPrimaryDark = Color(0xFFFAFAFB)

        val textSecondaryLight = Color(0xFF6B6378)
        val textSecondaryDark = Color(0xFFC4BFD3)

        val textTertiaryLight = Color(0xFF9C95AA)
        val textTertiaryDark = Color(0xFF8C8499)

        val cardFillLight = Color(0xFFFFFFFF).copy(alpha = 0.72f)
        val cardBorderLight = Color(0xFF6B5BD0).copy(alpha = 0.10f)
        val cardBorderDark = Color(0xFFFFFFFF).copy(alpha = 0.08f)

        // hairline: black @ 0.06 / white @ 0.08
        val hairlineLight = Color(0xFF000000).copy(alpha = 0.06f)
        val hairlineDark = Color(0xFFFFFFFF).copy(alpha = 0.08f)

        // Fill of the header "search | new folder" capsule; no stroke. Light mode floats it with a very faint two-layer shadow
        val chromeFillLight = Color(0xFFFFFFFF).copy(alpha = 0.78f)
        val chromeFillDark = Color(0xFFFFFFFF).copy(alpha = 0.05f)

        // 1×16 vertical divider inside the capsule
        val chromeDividerLight = Color(0xFF000000).copy(alpha = 0.09f)
        val chromeDividerDark = Color(0xFFFFFFFF).copy(alpha = 0.11f)

        // Conversation group card fill (dark = palette surface / light pure white) and stroke (dark 5.5% white / light 5% black)
        val groupCardFillLight = Color(0xFFFFFFFF)
        val groupCardBorderLight = Color(0xFF000000).copy(alpha = 0.05f)
        val groupCardBorderDark = Color(0xFFFFFFFF).copy(alpha = 0.055f)

        // hero / Notes card face: light is pure white with two soft glows; dark is an "aurora rising" treatment where
        // the face itself is a deep base from the same family as the list cards (see [AuroraDarkColors]) and the aurora
        // only shows from behind the card's top edge (see [drawAuroraCrown]). The face stays uniform and gets
        // monotonically darker from top to bottom; high saturation appears only on the very bright edge light,
        // which is what makes it read as light rather than paint.

        // Light-mode in-card glow B = top-right pink (default palette; other palettes use the light brand accent, see [AuroraLightColors])
        val heroGlowBLight = Color(0xFFEC8FEA).copy(alpha = 0.08f)

        // Near-white hot core of the aurora crown (hero only); the three colored edge lights follow the palette primary / accent, see [AuroraDarkColors]
        val crownHot = Color(0xFFECE6FF)

        // Base of the dark card's 1dp inner stroke: outside the aurora crown the rim is still white, bright at the top and dark at the bottom
        val heroRimDarkTop = Color(0xFFFFFFFF).copy(alpha = 0.07f)
        val heroRimDarkBottom = Color(0xFFFFFFFF).copy(alpha = 0.035f)

        // Tertiary grey text inside the hero (placeholder, provider name, chevrons): same hue as the card face, cooler
        // than the global t3. The global t3 #8C8499 is a warm grey-purple (h 302); over a card face at h 288 the hue
        // mismatch is one of the things that makes the card look muddy
        val heroTextTertiaryDark = Color(0xFF9493A8)

        // Fixed colors in the light default palette's focus aurora ring (see [AuroraLightColors.ringColors] for the others)
        val auroraPink = Color(0xFFEC8FEA)
        val auroraSoftBlue = Color(0xFF8DB4FF)
        val auroraSoftCyan = Color(0xFF86D2E6)
    }

    /** Home colors derived from the current palette in dark; returns null in light (light uses the fixed values above). */
    @Composable
    fun darkColors(): AuroraDarkColors? {
        val isDark = OriveoTheme.isDark
        val palette = LocalOriveoColors.current
        return remember(isDark, palette) { if (isDark) AuroraDarkColors.from(palette) else null }
    }

    /** Light home colors: follow the current palette's light brand colors. Also readable in dark, but only used on the light branch. */
    @Composable
    fun lightColors(): AuroraLightColors {
        val brand = OriveoTheme.lightBrand
        return remember(brand) { AuroraLightColors.from(brand) }
    }

    /** The primary accent purple for the current mode. */
    @Composable
    fun accent(): Color = darkColors()?.accent ?: lightColors().accent

    @Composable
    fun accentGlow(): Color = darkColors()?.accentGlow ?: lightColors().accentGlow

    /** Send button fill: the palette primary in dark, the light brand fill in light (a flat purple for the default palette) */
    @Composable
    fun sendFill(): Color = darkColors()?.sendFill ?: lightColors().sendFill

    /** Arrow on the send button: white in dark, the light brand onPrimary in light (dark text in the bright-fill mode) */
    @Composable
    fun sendIcon(): Color = if (darkColors() != null) Color.White else lightColors().sendIcon

    /** Endpoints of the greeting-name gradient */
    @Composable
    fun nameGradient(): List<Color> = darkColors()?.nameGradient ?: lightColors().nameGradient

    @Composable
    fun textPrimary(): Color = if (OriveoTheme.isDark) Colors.textPrimaryDark else Colors.textPrimaryLight

    @Composable
    fun textSecondary(): Color = if (OriveoTheme.isDark) Colors.textSecondaryDark else Colors.textSecondaryLight

    @Composable
    fun textTertiary(): Color = if (OriveoTheme.isDark) Colors.textTertiaryDark else Colors.textTertiaryLight

    /** Tertiary grey inside the hero card: dark switches to a cool grey of the card's hue, light keeps the global t3 */
    @Composable
    fun heroTextTertiary(): Color = if (OriveoTheme.isDark) Colors.heroTextTertiaryDark else Colors.textTertiaryLight

    @Composable
    fun cardFill(): Color = darkColors()?.cardFill ?: Colors.cardFillLight

    @Composable
    fun cardBorder(): Color = if (OriveoTheme.isDark) Colors.cardBorderDark else Colors.cardBorderLight

    @Composable
    fun hairline(): Color = if (OriveoTheme.isDark) Colors.hairlineDark else Colors.hairlineLight

    @Composable
    fun chromeFill(): Color = if (OriveoTheme.isDark) Colors.chromeFillDark else Colors.chromeFillLight

    @Composable
    fun chromeDivider(): Color = if (OriveoTheme.isDark) Colors.chromeDividerDark else Colors.chromeDividerLight

    @Composable
    fun groupCardFill(): Color = darkColors()?.groupCardFill ?: Colors.groupCardFillLight

    @Composable
    fun groupCardBorder(): Color = if (OriveoTheme.isDark) Colors.groupCardBorderDark else Colors.groupCardBorderLight

    @Composable
    fun pillFill(): Color = darkColors()?.pillFill ?: lightColors().pillFill

    // Typography (matches iOS AuroraTheme.Typography). Line heights are always explicit: the 24sp floor of the
    // M3 default bodyLarge would stretch any small text that only sets a size. Values use the natural SF line
    // height (≈ size × 1.2).
    object Typography {
        val composerPlaceholder = TextStyle(
            fontSize = 18.sp,
            lineHeight = 22.sp,
            fontWeight = FontWeight.Medium,
        )
        val section = TextStyle(
            fontSize = 17.sp,
            lineHeight = 22.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = (-0.3).sp,
        )
        val countMono = TextStyle(
            fontSize = 13.sp,
            lineHeight = 16.sp,
            fontWeight = FontWeight.Medium,
            fontFamily = FontFamily.Monospace,
        )
    }
}

/**
 * Home colors derived from the current palette in dark (authority: the `derived` section of `shared/theme-contracts/dark-palettes.v1.json`);
 * switching to any dark palette takes effect immediately. Light does not go through here.
 *
 * - accent / cursor and send button = primary; accentGlow = accent; name gradient = [primary, accent]
 * - screen background background -> backgroundBase; group card face = surface; glass card face = surface @55%
 * - hero / Notes card face: the midpoint of surface and surfaceElevated -> surface; model pill = surfaceElevated (opaque)
 * - aurora crown / outer card halo: primary / accent, with intensity multiplied by the palette glowK
 */
@Immutable
internal data class AuroraDarkColors(
    val accent: Color,
    val accentGlow: Color,
    val sendFill: Color,
    val nameGradient: List<Color>,
    val bgTop: Color,
    val bgBottom: Color,
    val groupCardFill: Color,
    val cardFill: Color,
    val heroSurfaceTop: Color,
    val heroSurfaceBottom: Color,
    val pillFill: Color,
    /** The three edge lights of the aurora crown (left / middle / right) and the afterglow of the top edge */
    val crownLeft: Color,
    val crownMiddle: Color,
    val crownRight: Color,
    val crownWash: Color,
    /** Multiplier for the alpha of every aurora layer (palette glowK) */
    val glowK: Float,
    /** Scan color order of the focus aurora ring (first and last identical, so the seam has no break) */
    val ringColors: List<Color>,
) {
    companion object {
        fun from(colors: OriveoColors): AuroraDarkColors = AuroraDarkColors(
            accent = colors.primary,
            accentGlow = colors.accent,
            sendFill = colors.primary,
            nameGradient = colors.gradientBrandStops,
            bgTop = colors.background,
            bgBottom = colors.backgroundBase,
            groupCardFill = colors.surface,
            cardFill = colors.surface.copy(alpha = 0.55f),
            heroSurfaceTop = lerp(colors.surface, colors.surfaceElevated, 0.5f),
            heroSurfaceBottom = colors.surface,
            pillFill = colors.surfaceElevated,
            crownLeft = colors.accent,
            crownMiddle = colors.primary,
            crownRight = colors.accent,
            crownWash = colors.accent,
            glowK = colors.glowK,
            ringColors = listOf(colors.primary, colors.accent, colors.primary, colors.accent, colors.primary),
        )
    }
}

/**
 * Light home colors derived from the current palette's light brand colors. The default palette keeps the original hand-tuned values;
 * for the other palettes: in-card glow / hero shadow / stroke / cursor / accent -> ink, pink glow -> accent, name gradient ink -> accent,
 * send button fill + onPrimary, page background bgTop -> bgBottom, model capsule fill pill.
 */
@Immutable
internal data class AuroraLightColors(
    val accent: Color,
    val accentGlow: Color,
    val sendFill: Color,
    val sendIcon: Color,
    val nameGradient: List<Color>,
    val bgTop: Color,
    val bgBottom: Color,
    val pillFill: Color,
    /** In-card glows: A = top-left (also the Notes glow), B = top-right */
    val heroGlowA: Color,
    val heroGlowB: Color,
    /** Sweep color order of the focus aurora ring (first and last are the same color) */
    val ringColors: List<Color>,
    /** Hue of the hero card's light shadow (the alpha comes from [AuroraHeroCardAppearance]) */
    val shadowTint: Color,
    /** Section rule: the outer glow and the two ends of the vertical gradient */
    val sectionRuleGlow: Color,
    val sectionRuleStops: List<Color>,
) {
    companion object {
        fun from(brand: OriveoLightBrand): AuroraLightColors {
            val violet = brand.tuned(DefaultLightBrandTuned.homeViolet, brand.ink)
            return AuroraLightColors(
                accent = violet,
                accentGlow = violet,
                sendFill = brand.tuned(DefaultLightBrandTuned.homeViolet, brand.fill),
                sendIcon = brand.onPrimary,
                nameGradient = listOf(brand.ink, brand.accent),
                bgTop = brand.bgTop,
                bgBottom = brand.bgBottom,
                pillFill = brand.pill,
                heroGlowA = violet.copy(alpha = 0.10f),
                heroGlowB = brand.tuned(AuroraTheme.Colors.heroGlowBLight, brand.accent.copy(alpha = 0.08f)),
                ringColors = if (brand === OriveoLightBrand.Default) {
                    // The fixed color order of iOS `auroraGlowColors`: purple -> lavender -> pink -> blue -> soft teal -> pale purple -> purple
                    listOf(
                        violet,
                        DefaultLightBrandTuned.ringLavender,
                        AuroraTheme.Colors.auroraPink,
                        AuroraTheme.Colors.auroraSoftBlue,
                        AuroraTheme.Colors.auroraSoftCyan,
                        DefaultLightBrandTuned.lavender,
                        violet,
                    )
                } else {
                    listOf(brand.ink, brand.accent, brand.ink, brand.accent, brand.ink)
                },
                shadowTint = violet,
                sectionRuleGlow = violet.copy(alpha = 0.35f),
                sectionRuleStops = listOf(brand.tuned(DefaultLightBrandTuned.lavender, brand.ink.copy(alpha = 0.45f)), violet),
            )
        }

        val Default: AuroraLightColors by lazy { from(OriveoLightBrand.Default) }
    }
}

/**
 * The gradients in the design are all annotated as CSS `linear-gradient(<angle>deg, ...)`: 0 degrees points up and
 * angles grow clockwise, and the gradient line length is `|w*sin(theta)| + |h*cos(theta)|`, so the two diagonal corners
 * land exactly on 0% / 100%. Compose's linearGradient only takes start and end points, so they are converted here by
 * the same definition (the same formula as iOS AuroraCSSGradient), which keeps the color direction of cards and the
 * name consistent with the design.
 */
internal fun auroraCssGradientPoints(angleDegrees: Float, size: Size, origin: Offset = Offset.Zero): Pair<Offset, Offset> {
    val radians = Math.toRadians(angleDegrees.toDouble())
    val dx = sin(radians).toFloat()
    val dy = -cos(radians).toFloat()
    val half = (abs(size.width * dx) + abs(size.height * dy)) / 2f
    val center = Offset(origin.x + size.width / 2f, origin.y + size.height / 2f)
    return Offset(center.x - dx * half, center.y - dy * half) to Offset(center.x + dx * half, center.y + dy * half)
}

/**
 * CSS `box-shadow` blur value -> Compose [Shadow] radius.
 * A CSS blur B is a Gaussian sigma of B/2; Compose shadows go through BlurMaskFilter, where
 * sigma = 0.57735·r + 0.5px, hence r ≈ 0.866·B (the 0.5px constant is negligible at dp scale).
 * iOS `.shadow(radius:)` takes B/2.
 */
internal fun auroraCssShadowRadius(blur: Dp): Dp = blur * 0.866f

@Composable
internal fun AuroraScreenBackground(modifier: Modifier = Modifier) {
    val dark = AuroraTheme.darkColors()
    val light = AuroraTheme.lightColors()
    val brush = remember(dark, light) {
        Brush.verticalGradient(
            colors = if (dark != null) {
                listOf(dark.bgTop, dark.bgBottom)
            } else {
                listOf(light.bgTop, light.bgBottom)
            },
        )
    }
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(brush),
    )
}

// ── Hero surface (the material shared by the hero composer and the Notes entry) ──

/** How the in-card glow is placed: hero is the lead (two light-mode glows / a dark-mode crown with a near-white hot core); Notes is the softened version. */
internal enum class AuroraHeroGlow { HeroPair, NotesCorner }

/** Crown strength on the Notes card: the same light one step weaker, so both cards read as one material. */
private const val AURORA_CROWN_NOTES_SCALE = 0.55f
private const val AURORA_CROWN_NOTES_WASH_SCALE = 0.6f

/**
 * Draws the hero material plus the in-card glow, all clipped to the rounded rect.
 *
 * - Light: a pure white face with the design's two radial glows (top-left purple / top-right pink; Notes keeps
 *   only the top-right one). Each glow is converted from the design's absolute positioning: a w×h block of
 *   `radial-gradient(closest-side, color, transparent)`, whose ellipse is inscribed in the block with its center
 *   at the block's top-left plus half the size. Compose's radialGradient is circular only, so the ellipse comes
 *   from scaling a circular gradient vertically; the end stop is the same color at zero alpha to avoid a grey
 *   fringe from interpolation.
 * - Dark: the face is a deep base from the list-card family (brighter at the top, uniform left to right) with an
 *   aurora afterglow a finger's width below the top edge. The aurora proper sits outside the card and on the rim,
 *   see [drawAuroraCrown].
 */
internal fun DrawScope.drawAuroraHeroSurface(
    dark: AuroraDarkColors?,
    glow: AuroraHeroGlow,
    cornerRadius: Float,
    clip: Path,
    light: AuroraLightColors = AuroraLightColors.Default,
) {
    clipPath(clip) {
        if (dark != null) {
            drawRect(
                brush = Brush.verticalGradient(
                    colors = listOf(dark.heroSurfaceTop, dark.heroSurfaceBottom),
                    startY = 0f,
                    endY = size.height,
                ),
            )
            drawAuroraCrownWash(dark, if (glow == AuroraHeroGlow.HeroPair) 1f else AURORA_CROWN_NOTES_WASH_SCALE)
        } else {
            drawRoundRect(color = Color.White, cornerRadius = CornerRadius(cornerRadius, cornerRadius))
            when (glow) {
                AuroraHeroGlow.HeroPair -> {
                    // left -60 / top -80 / 260×220; right -70 / top -90 / 240×210
                    drawEllipticalGlow(light.heroGlowA, 260.dp.toPx(), 220.dp.toPx(), Offset(70.dp.toPx(), 30.dp.toPx()))
                    drawEllipticalGlow(light.heroGlowB, 240.dp.toPx(), 210.dp.toPx(), Offset(size.width - 50.dp.toPx(), 15.dp.toPx()))
                }
                AuroraHeroGlow.NotesCorner -> {
                    // right -50 / top -70 / 220×200
                    drawEllipticalGlow(light.heroGlowA, 220.dp.toPx(), 200.dp.toPx(), Offset(size.width - 60.dp.toPx(), 30.dp.toPx()))
                }
            }
        }
    }
}

/**
 * The crown's afterglow inside the card: three elliptical glows within a finger's width (≤16dp) of the top edge
 * plus a thin haze fading downward. It lifts the brightness only slightly; the text area stays a uniform base.
 */
private fun DrawScope.drawAuroraCrownWash(dark: AuroraDarkColors, washScale: Float) {
    val wash = dark.crownWash
    val scale = washScale * dark.glowK
    // 0dp 7.5% -> 38dp 3% -> 70dp 0; a card shorter than 70dp truncates proportionally
    val fadeEnd = 70.dp.toPx()
    drawRect(
        brush = Brush.verticalGradient(
            colorStops = arrayOf(
                0f to wash.copy(alpha = 0.075f * scale),
                (38.dp.toPx() / fadeEnd) to wash.copy(alpha = 0.03f * scale),
                1f to wash.copy(alpha = 0f),
            ),
            startY = 0f,
            endY = fadeEnd,
        ),
        size = Size(size.width, minOf(fadeEnd, size.height)),
    )
    // The design's three afterglows: radii 36% / 30% / 36% of the width × 16 / 14 / 16dp tall, centered on the top edge
    val w = size.width
    drawRect(brush = ellipticalGlowBrush(dark.crownLeft, 0.16f * scale, w * 0.72f, 32.dp.toPx(), Offset(w * 0.22f, 0f)))
    drawRect(brush = ellipticalGlowBrush(dark.crownMiddle, 0.12f * scale, w * 0.60f, 28.dp.toPx(), Offset(w * 0.52f, 0f)))
    drawRect(brush = ellipticalGlowBrush(dark.crownRight, 0.14f * scale, w * 0.72f, 32.dp.toPx(), Offset(w * 0.80f, 0f)))
}

/**
 * Aurora crown: a ring of light along the card's 1dp inner stroke. The top edge runs accent -> primary -> accent from
 * left to right (the hero adds a near-white hot core), fades out quickly past the top corners, and the remaining
 * edges stay the white rim, bright at the top and dark at the bottom.
 *
 * One stroke takes one brush, so the layers are drawn **bottom-up** in CSS order: white base -> right -> middle ->
 * left -> hot core.
 */
private fun DrawScope.drawAuroraCrown(
    dark: AuroraDarkColors,
    rimPath: Path,
    strokeWidth: Float,
    scale: Float,
    hotCore: Boolean,
    alpha: Float,
) {
    // The design's four edge glows: radii 40% / 32% / 40% of the width × 64 / 44 / 64dp tall, hot core 30% wide × 22dp tall, all centered on the top edge
    val w = size.width
    val glowScale = scale * dark.glowK
    val stroke = Stroke(width = strokeWidth)
    drawPath(path = rimPath, brush = auroraHeroRimBrush(isDark = true, height = size.height), alpha = alpha, style = stroke)
    listOf(
        ellipticalGlowBrush(dark.crownRight, 0.95f * glowScale, w * 0.80f, 128.dp.toPx(), Offset(w * 0.86f, 0f)),
        ellipticalGlowBrush(dark.crownMiddle, 0.80f * glowScale, w * 0.64f, 88.dp.toPx(), Offset(w * 0.52f, 0f)),
        ellipticalGlowBrush(dark.crownLeft, 1.0f * glowScale, w * 0.80f, 128.dp.toPx(), Offset(w * 0.16f, 0f)),
    ).forEach { drawPath(path = rimPath, brush = it, alpha = alpha, style = stroke) }
    if (hotCore) {
        val hot = ellipticalGlowBrush(AuroraTheme.Colors.crownHot, 0.95f, w * 0.60f, 44.dp.toPx(), Offset(w * 0.50f, 0f))
        drawPath(path = rimPath, brush = hot, alpha = alpha, style = stroke)
    }
}

/**
 * Elliptical glow brush: a near-Gaussian five-stop falloff (the design's 0 / .62 / .28 / .08 / 0), with a vertical
 * scale squashing the circle into an ellipse. [blockWidth] / [blockHeight] are the size of the whole glow block,
 * [center] is the light's center.
 */
private fun ellipticalGlowBrush(color: Color, alpha: Float, blockWidth: Float, blockHeight: Float, center: Offset): Brush {
    val radius = blockWidth / 2f
    val scaleY = blockHeight / blockWidth
    return object : ShaderBrush() {
        override fun createShader(size: Size): android.graphics.Shader =
            RadialGradientShader(
                center = center,
                radius = radius,
                colors = listOf(
                    color.copy(alpha = alpha),
                    color.copy(alpha = alpha * 0.62f),
                    color.copy(alpha = alpha * 0.28f),
                    color.copy(alpha = alpha * 0.08f),
                    color.copy(alpha = 0f),
                ),
                colorStops = listOf(0f, 0.26f, 0.52f, 0.78f, 1f),
            ).apply {
                setLocalMatrix(
                    AndroidMatrix().apply { setScale(1f, scaleY, center.x, center.y) },
                )
            }
    }
}

private fun DrawScope.drawEllipticalGlow(color: Color, blockWidth: Float, blockHeight: Float, center: Offset) {
    val radius = blockWidth / 2f
    val brush = Brush.radialGradient(
        colors = listOf(color, color.copy(alpha = 0f)),
        center = center,
        radius = radius,
    )
    withTransform({ scale(scaleX = 1f, scaleY = blockHeight / blockWidth, pivot = center) }) {
        drawRect(
            brush = brush,
            topLeft = Offset(center.x - radius, center.y - radius),
            size = Size(blockWidth, blockWidth),
        )
    }
}

/** Aurora halo outside the card: two gradient shadows hugging the card shape and lifted upward (a wide halo plus a hot core hugging the top edge), with intensity multiplied by the palette glowK. */
private fun auroraHaloBrush(dark: AuroraDarkColors): Brush {
    val k = dark.glowK
    return Brush.horizontalGradient(
        colorStops = arrayOf(
            0f to dark.crownLeft.copy(alpha = 0.20f * k),
            0.2f to dark.crownLeft.copy(alpha = 0.95f * k),
            0.5f to dark.crownMiddle.copy(alpha = 0.85f * k),
            0.8f to dark.crownRight.copy(alpha = 0.95f * k),
            1f to dark.crownRight.copy(alpha = 0.20f * k),
        ),
    )
}

/** 1dp inner stroke of the hero / Notes face: dark is bright at the top and dark at the bottom, light is a uniform `cardBorder`. */
internal fun auroraHeroRimBrush(isDark: Boolean, height: Float): Brush =
    if (isDark) {
        Brush.verticalGradient(
            colors = listOf(AuroraTheme.Colors.heroRimDarkTop, AuroraTheme.Colors.heroRimDarkBottom),
            startY = 0f,
            endY = height,
        )
    } else {
        SolidColor(AuroraTheme.Colors.cardBorderLight)
    }

internal fun auroraRoundRectPath(size: Size, cornerRadius: Float, inset: Float = 0f): Path = Path().apply {
    addRoundRect(
        RoundRect(
            left = inset,
            top = inset,
            right = size.width - inset,
            bottom = size.height - inset,
            cornerRadius = CornerRadius((cornerRadius - inset).coerceAtLeast(0f)),
        ),
    )
}

// ── Hero card appearance ──

/**
 * Hero card state → appearance (matches iOS AuroraHeroCardAppearance): idle is purely flat (face + 1dp stroke + two
 * glows, no aurora ring); focus adds the ring and hides the 1dp stroke. Shadows have two slots that cross-fade on
 * focus changes instead of rebuilding the shadow bitmap. Shadow numbers are the design's CSS (blur value, y
 * offset), converted at draw time through [auroraCssShadowRadius].
 */
internal data class AuroraHeroCardAppearance(
    val showsGlowBorder: Boolean,
    val showsHairlineBorder: Boolean,
    val contactShadow: CardShadow?,
    val ambientShadow: CardShadow,
) {
    data class CardShadow(val color: Color, val cssBlur: Dp, val y: Dp, val spread: Dp = 0.dp)

    companion object {
        /** [lightTint] = hue of the light shadow ([AuroraLightColors.shadowTint]; the home purple for the default palette). */
        fun resolve(
            isDark: Boolean,
            focused: Boolean,
            lightTint: Color = AuroraLightColors.Default.shadowTint,
        ): AuroraHeroCardAppearance {
            val contact: CardShadow?
            val ambient: CardShadow
            if (isDark) {
                // 0 12 28 -6 rgba(0,0,0,.36), unchanged on focus (the colored glow belongs to the crown / ring)
                contact = null
                ambient = CardShadow(Color.Black.copy(alpha = 0.36f), 28.dp, 12.dp, spread = (-6).dp)
            } else if (focused) {
                // 0 14 40 rgba(ink,.16)
                contact = null
                ambient = CardShadow(lightTint.copy(alpha = 0.16f), 40.dp, 14.dp)
            } else {
                // 0 1 2 rgba(15,23,42,.04) + 0 10 28 rgba(ink,.08)
                contact = CardShadow(Color(0xFF0F172A).copy(alpha = 0.04f), 2.dp, 1.dp)
                ambient = CardShadow(lightTint.copy(alpha = 0.08f), 28.dp, 10.dp)
            }
            return AuroraHeroCardAppearance(
                showsGlowBorder = focused,
                showsHairlineBorder = !focused,
                contactShadow = contact,
                ambientShadow = ambient,
            )
        }
    }
}


/**
 * The design uses `conic-gradient(from 200deg, …)`: CSS puts 0° at 12 o'clock, Android's SweepGradient at
 * 3 o'clock, both clockwise, so the start is 200 - 90 = 110° (the same 110° as the iOS AngularGradient).
 */
private const val AURORA_RING_START_DEGREES = 110f

private fun auroraRingBrush(center: Offset, colors: List<Color>): Brush = object : ShaderBrush() {
    override fun createShader(size: Size): android.graphics.Shader =
        SweepGradientShader(center = center, colors = colors).apply {
            setLocalMatrix(AndroidMatrix().apply { setRotate(AURORA_RING_START_DEGREES, center.x, center.y) })
        }
}

/**
 * Hero composer card: the AuroraHeroSurface material plus a state-driven appearance (see [AuroraHeroCardAppearance]).
 *
 * - Idle: face + 1dp `cardBorder` stroke (fully inside, like the iOS strokeBorder) + shadow, no aurora ring.
 * - Focused: the stroke is hidden and the ring sits entirely outside the card (ring path outset by 1dp, radius +1,
 *   so the 2dp sharp ring runs from the card edge to 2dp outside), plus a 4dp blurred glow.
 * - The transition (0.4s) only touches the decoration layer, never the input content; animated values are read
 *   in the draw phase and never recompose.
 * - The ring does **not** breathe (iOS breathes over 2.8s while focused): sitting focused while typing or idle is
 *   still an idle state, and an infinite animation would pin the whole page at the display refresh rate (measured
 *   at 97.6% CPU while focused and idle, see IdleRenderingPerformanceContractTest). This uses the static full
 *   brightness that iOS shows with animations turned off.
 */
@Composable
internal fun Modifier.auroraGlassCard(
    isDark: Boolean,
    cornerRadius: Dp = 26.dp,
    focused: Boolean = false,
): Modifier {
    val focusProgress = animateFloatAsState(
        targetValue = if (focused) 1f else 0f,
        animationSpec = tween(durationMillis = 400, easing = EaseInOut),
        label = "home-hero-focus",
    )

    val shape = remember(cornerRadius) { RoundedCornerShape(cornerRadius) }
    // Dark follows the current palette; isDark is still supplied by the caller (consistent with the outer theme)
    val palette = LocalOriveoColors.current
    val dark = remember(isDark, palette) { if (isDark) AuroraDarkColors.from(palette) else null }
    val light = AuroraTheme.lightColors()
    val idle = remember(isDark, light) { AuroraHeroCardAppearance.resolve(isDark, focused = false, lightTint = light.shadowTint) }
    val active = remember(isDark, light) { AuroraHeroCardAppearance.resolve(isDark, focused = true, lightTint = light.shadowTint) }
    val shadowContext = LocalGraphicsContext.current.shadowContext
    val idleContact = remember(shadowContext, shape, idle) {
        idle.contactShadow?.let { shadowContext.createDropShadowPainter(shape, it.toComposeShadow()) }
    }
    val idleAmbient = remember(shadowContext, shape, idle) {
        shadowContext.createDropShadowPainter(shape, idle.ambientShadow.toComposeShadow())
    }
    // Dark uses the same shadow in both states, so no second bitmap is needed
    val activeAmbient = remember(shadowContext, shape, idle, active) {
        if (active.ambientShadow == idle.ambientShadow) null
        else shadowContext.createDropShadowPainter(shape, active.ambientShadow.toComposeShadow())
    }
    // Dark idle aurora halo; fades out on focus in favor of the ring (both glows together look smeared)
    val halo = remember(shadowContext, shape, dark) {
        dark?.let { d -> auroraHaloShadows(d).map { shadowContext.createDropShadowPainter(shape, it) } } ?: emptyList()
    }
    // The OpenGL pipeline on API 26/27 ignores BlurMaskFilter under hardware acceleration (hard-edged color bands), so the blurred glow is only drawn on P and later
    val drawsBlurredGlow = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P

    return this.drawWithCache {
        val cr = cornerRadius.toPx()
        val cardPath = auroraRoundRectPath(size, cr)
        val hairlineWidth = 1.dp.toPx()
        val hairlinePath = auroraRoundRectPath(size, cr, inset = hairlineWidth / 2f)
        val hairline = auroraHeroRimBrush(isDark, size.height)
        // Ring: path outset by 1dp, radius +1, stroke centered → the 2dp sharp ring covers [card edge, 2dp outside]
        val ringOutset = 1.dp.toPx()
        val ringRect = RoundRect(
            left = -ringOutset,
            top = -ringOutset,
            right = size.width + ringOutset,
            bottom = size.height + ringOutset,
            cornerRadius = CornerRadius(cr + ringOutset),
        )
        val ringPath = Path().apply { addRoundRect(ringRect) }
        val ringBrush = auroraRingBrush(Offset(size.width / 2f, size.height / 2f), dark?.ringColors ?: light.ringColors)
        val glowPaint = if (drawsBlurredGlow) {
            AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
                style = AndroidPaint.Style.STROKE
                strokeWidth = 4.dp.toPx()
                shader = (ringBrush as ShaderBrush).createShader(size)
                maskFilter = BlurMaskFilter(6.dp.toPx(), BlurMaskFilter.Blur.NORMAL)
            }
        } else {
            null
        }
        val frameworkRingPath = ringPath.asAndroidPath()
        onDrawBehind {
            val p = focusProgress.value
            // Shadows attach to the card shape only; text and the ring cast none. The two states cross-fade on focus
            idleContact?.let { with(it) { draw(size, alpha = 1f - p) } }
            if (activeAmbient == null) {
                with(idleAmbient) { draw(size) }
            } else {
                with(idleAmbient) { draw(size, alpha = 1f - p) }
                with(activeAmbient) { draw(size, alpha = p) }
            }
            // The halo sits under the face: the face is opaque, so only the band outside the card shows
            if (p < 1f) halo.forEach { with(it) { draw(size, alpha = 1f - p) } }

            drawAuroraHeroSurface(dark, AuroraHeroGlow.HeroPair, cr, cardPath, light)

            if (p < 1f) {
                if (dark != null) {
                    drawAuroraCrown(dark, hairlinePath, hairlineWidth, scale = 1f, hotCore = true, alpha = 1f - p)
                } else {
                    drawPath(
                        path = hairlinePath,
                        brush = hairline,
                        alpha = 1f - p,
                        style = Stroke(width = hairlineWidth),
                    )
                }
            }
            if (p > 0f) {
                val ringAlpha = p
                glowPaint?.let { paint ->
                    paint.alpha = (0.7f * ringAlpha * 255f).toInt().coerceIn(0, 255)
                    drawIntoCanvas { it.nativeCanvas.drawPath(frameworkRingPath, paint) }
                }
                drawPath(
                    path = ringPath,
                    brush = ringBrush,
                    alpha = ringAlpha,
                    style = Stroke(width = 2.dp.toPx()),
                )
            }
        }
    }
}

private fun AuroraHeroCardAppearance.CardShadow.toComposeShadow(): Shadow = Shadow(
    radius = auroraCssShadowRadius(cssBlur),
    color = color,
    spread = spread,
    offset = DpOffset(0.dp, y),
)

/**
 * Aurora halo outside the card (dark only): two gradient shadows hugging the card shape and lifted upward. The wide
 * halo spreads the light beyond the card; the hot core hugging the top edge draws the bright line. A CSS
 * `filter: blur(σ)` is a box-shadow blur of 2σ, which then goes through [auroraCssShadowRadius].
 */
private fun auroraHaloShadows(dark: AuroraDarkColors): List<Shadow> = listOf(
    Shadow(
        radius = auroraCssShadowRadius(30.dp),
        brush = auroraHaloBrush(dark),
        spread = (-7).dp,
        offset = DpOffset(0.dp, (-11).dp),
        alpha = 0.56f,
    ),
    Shadow(
        radius = auroraCssShadowRadius(7.dp),
        brush = auroraHaloBrush(dark),
        spread = (-1).dp,
        offset = DpOffset(0.dp, (-2.5).dp),
        alpha = 0.65f,
    ),
)

/**
 * Face of the Notes entry card: the hero material with only the top-right glow plus the same 1dp inner stroke, no shadow, no ring.
 */
@Composable
internal fun Modifier.auroraNotesSurface(isDark: Boolean, cornerRadius: Dp): Modifier {
    val palette = LocalOriveoColors.current
    val dark = remember(isDark, palette) { if (isDark) AuroraDarkColors.from(palette) else null }
    return auroraNotesSurface(dark, AuroraTheme.lightColors(), cornerRadius)
}

private fun Modifier.auroraNotesSurface(dark: AuroraDarkColors?, light: AuroraLightColors, cornerRadius: Dp): Modifier = drawWithCache {
    val isDark = dark != null
    val cr = cornerRadius.toPx()
    val cardPath = auroraRoundRectPath(size, cr)
    val hairlineWidth = 1.dp.toPx()
    val borderPath = auroraRoundRectPath(size, cr, inset = hairlineWidth / 2f)
    val border = auroraHeroRimBrush(isDark, size.height)
    onDrawBehind {
        drawAuroraHeroSurface(dark, AuroraHeroGlow.NotesCorner, cr, cardPath, light)
        if (dark != null) {
            // The same crown one step weaker, without the hot core and without the outer halo: Notes does not compete with the hero
            drawAuroraCrown(dark, borderPath, hairlineWidth, scale = AURORA_CROWN_NOTES_SCALE, hotCore = false, alpha = 1f)
        } else {
            drawPath(path = borderPath, brush = border, style = Stroke(width = hairlineWidth))
        }
    }
}

// -- Title Count (a title with a mono count) --

/**
 * A title with a mono count beside it, shared by the Notes entry card and the conversation group
 * headers, following the same rule as iOS `AuroraTitleCount`: both are centered on their line boxes.
 * Baseline alignment drops the count below the visual middle of CJK titles, and no extra lift is
 * added either; on iOS, rendering shows the centered count already lines up and a lift puts it too high.
 */
@Composable
internal fun AuroraTitleCount(
    title: String,
    titleStyle: TextStyle,
    count: Int?,
    modifier: Modifier = Modifier,
    spacing: Dp = 8.dp,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(spacing),
    ) {
        Text(
            text = title,
            style = titleStyle,
            color = AuroraTheme.textPrimary(),
            maxLines = 1,
        )
        if (count != null && count > 0) {
            Text(
                text = count.toString(),
                style = AuroraTheme.Typography.countMono,
                color = AuroraTheme.accent(),
                maxLines = 1,
            )
        }
    }
}

// -- Section Rule (the glowing purple vertical bar) --

/**
 * The glowing bar on the left of a section title, 3×18. Dark: palette accent -> primary, outer glow 8px 55% primary;
 * light: [AuroraLightColors.sectionRuleStops], outer glow 6px 35% light brand purple (the default palette keeps the original fixed lavender -> purple).
 */
@Composable
internal fun AuroraSectionRule(modifier: Modifier = Modifier) {
    val dark = AuroraTheme.darkColors()
    val light = AuroraTheme.lightColors()
    val isDark = dark != null
    val shape = RoundedCornerShape(50)
    Box(
        modifier = modifier
            .size(width = 3.dp, height = 18.dp)
            .dropShadow(
                shape = shape,
                shadow = Shadow(
                    radius = if (isDark) 4.dp else 3.dp,
                    color = dark?.accent?.copy(alpha = 0.55f) ?: light.sectionRuleGlow,
                ),
            )
            .background(
                brush = Brush.verticalGradient(
                    dark?.let { listOf(it.accentGlow, it.accent) } ?: light.sectionRuleStops,
                ),
                shape = shape,
            ),
    )
}

// ── Glass look of the header capsule ("search | new folder") ──

/**
 * Header capsule: liquid glass on iOS 26. The capsule sits on the home content layer with only the near-solid
 * aurora background behind it, so a real blur would produce the same color anyway. This reproduces just the
 * visible traits of glass on a flat base: a translucent lifting fill, a 1dp rim bright at the top and dark at the
 * bottom, and a very faint two-layer shadow in light mode.
 */
internal fun Modifier.auroraChromeCapsule(isDark: Boolean, shape: Shape): Modifier {
    val fill = if (isDark) AuroraTheme.Colors.chromeFillDark else AuroraTheme.Colors.chromeFillLight
    val rimTop = if (isDark) Color.White.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.95f)
    val rimBottom = if (isDark) Color.White.copy(alpha = 0.05f) else Color.Black.copy(alpha = 0.05f)
    val shadowed = if (isDark) {
        this
    } else {
        // 0 1 2 rgba(15,23,42,.05) + 0 4 12 rgba(15,23,42,.04)
        this
            .dropShadow(shape, Shadow(radius = auroraCssShadowRadius(2.dp), color = Color(0xFF0F172A).copy(alpha = 0.05f), offset = DpOffset(0.dp, 1.dp)))
            .dropShadow(shape, Shadow(radius = auroraCssShadowRadius(12.dp), color = Color(0xFF0F172A).copy(alpha = 0.04f), offset = DpOffset(0.dp, 4.dp)))
    }
    return shadowed.drawBehind {
        val radius = size.height / 2f
        drawPath(auroraRoundRectPath(size, radius), fill)
        val stroke = 1.dp.toPx()
        drawPath(
            path = auroraRoundRectPath(size, radius, inset = stroke / 2f),
            brush = Brush.verticalGradient(listOf(rimTop, rimBottom)),
            style = Stroke(width = stroke),
        )
    }
}

// ── Greeting ──

internal object AuroraGreeting {

    enum class Bucket { MORNING, AFTERNOON, EVENING, NIGHT }

    fun current(now: Calendar = Calendar.getInstance()): Bucket {
        return when (now.get(Calendar.HOUR_OF_DAY)) {
            in 5..11 -> Bucket.MORNING
            in 12..17 -> Bucket.AFTERNOON
            in 18..22 -> Bucket.EVENING
            else -> Bucket.NIGHT
        }
    }

    /** Must match iOS `AuroraGreeting.greetingSalt` / `taglineSalt`. */
    const val GREETING_SALT = 17
    const val TAGLINE_SALT = 31

    fun dailyIndex(now: Calendar, salt: Int, count: Int): Int {
        val dayOfYear = now.get(Calendar.DAY_OF_YEAR)
        val year = now.get(Calendar.YEAR)
        return ((dayOfYear * salt + year) and 0x7FFFFFFF) % count
    }

    private val morningGreetings = intArrayOf(
        ai.oriveo.community.R.string.greeting_morning,
        ai.oriveo.community.R.string.greeting_morning_2,
        ai.oriveo.community.R.string.greeting_morning_3,
        ai.oriveo.community.R.string.greeting_morning_4,
        ai.oriveo.community.R.string.greeting_morning_5,
    )
    private val afternoonGreetings = intArrayOf(
        ai.oriveo.community.R.string.greeting_afternoon,
        ai.oriveo.community.R.string.greeting_afternoon_2,
        ai.oriveo.community.R.string.greeting_afternoon_3,
        ai.oriveo.community.R.string.greeting_afternoon_4,
        ai.oriveo.community.R.string.greeting_afternoon_5,
    )
    private val eveningGreetings = intArrayOf(
        ai.oriveo.community.R.string.greeting_evening,
        ai.oriveo.community.R.string.greeting_evening_2,
        ai.oriveo.community.R.string.greeting_evening_3,
        ai.oriveo.community.R.string.greeting_evening_4,
        ai.oriveo.community.R.string.greeting_evening_5,
    )
    private val nightGreetings = intArrayOf(
        ai.oriveo.community.R.string.greeting_still_up,
        ai.oriveo.community.R.string.greeting_night_2,
        ai.oriveo.community.R.string.greeting_night_3,
        ai.oriveo.community.R.string.greeting_night_4,
        ai.oriveo.community.R.string.greeting_night_5,
    )

    /** Matches iOS AuroraGreeting.currentKey(): nameless greeting, stable index within a day. */
    fun greetingResId(now: Calendar = Calendar.getInstance()): Int {
        val pool = when (current(now)) {
            Bucket.MORNING -> morningGreetings
            Bucket.AFTERNOON -> afternoonGreetings
            Bucket.EVENING -> eveningGreetings
            Bucket.NIGHT -> nightGreetings
        }
        return pool[dailyIndex(now, GREETING_SALT, pool.size)]
    }

    /**
     * Taglines across the four time-of-day buckets -- stable within a day (no flicker),
     * refreshed daily. Design philosophy: self-compassion / autonomy / companionship /
     * containment / validation / presence -- consistently avoiding toxic positivity ("you've got this!").
     */
    private val morningTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_morning_1,
        ai.oriveo.community.R.string.tagline_morning_2,
        ai.oriveo.community.R.string.tagline_morning_3,
        ai.oriveo.community.R.string.tagline_morning_4,
        ai.oriveo.community.R.string.tagline_morning_5,
        ai.oriveo.community.R.string.tagline_morning_6,
        ai.oriveo.community.R.string.tagline_morning_7,
        ai.oriveo.community.R.string.tagline_morning_8,
    )
    private val afternoonTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_afternoon_1,
        ai.oriveo.community.R.string.tagline_afternoon_2,
        ai.oriveo.community.R.string.tagline_afternoon_3,
        ai.oriveo.community.R.string.tagline_afternoon_4,
        ai.oriveo.community.R.string.tagline_afternoon_5,
        ai.oriveo.community.R.string.tagline_afternoon_6,
        ai.oriveo.community.R.string.tagline_afternoon_7,
        ai.oriveo.community.R.string.tagline_afternoon_8,
    )
    private val eveningTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_evening_1,
        ai.oriveo.community.R.string.tagline_evening_2,
        ai.oriveo.community.R.string.tagline_evening_3,
        ai.oriveo.community.R.string.tagline_evening_4,
        ai.oriveo.community.R.string.tagline_evening_5,
        ai.oriveo.community.R.string.tagline_evening_6,
        ai.oriveo.community.R.string.tagline_evening_7,
        ai.oriveo.community.R.string.tagline_evening_8,
    )
    private val nightTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_night_1,
        ai.oriveo.community.R.string.tagline_night_2,
        ai.oriveo.community.R.string.tagline_night_3,
        ai.oriveo.community.R.string.tagline_night_4,
        ai.oriveo.community.R.string.tagline_night_5,
        ai.oriveo.community.R.string.tagline_night_6,
        ai.oriveo.community.R.string.tagline_night_7,
        ai.oriveo.community.R.string.tagline_night_8,
    )

    fun taglineResId(now: Calendar = Calendar.getInstance()): Int {
        val pool = when (current(now)) {
            Bucket.MORNING -> morningTaglines
            Bucket.AFTERNOON -> afternoonTaglines
            Bucket.EVENING -> eveningTaglines
            Bucket.NIGHT -> nightTaglines
        }
        return pool[dailyIndex(now, TAGLINE_SALT, pool.size)]
    }

    /** Matches iOS placeholderKey() -- "What can I help with?" is used across every time bucket. */
    val placeholderResId: Int = ai.oriveo.community.R.string.aurora_placeholder_what_can_i_help
}

/**
 * Cleans up the hero model pill's display name -- matches iOS `pillModelName`.
 *
 * Catalogs like OpenRouter often write a model's name as `Vendor: Model` or `Model (free)`; the
 * home screen pill has limited space, so keeping just the model name reduces truncation on small screens.
 */
internal fun homeHeroPillModelName(rawName: String): String {
    var name = rawName.trim()
    val vendorSeparator = name.indexOf(": ")
    if (vendorSeparator >= 0 && vendorSeparator + 2 < name.length) {
        name = name.substring(vendorSeparator + 2)
    }
    if (name.endsWith(" (free)", ignoreCase = true)) {
        name = name.dropLast(" (free)".length).trimEnd()
    }
    return name
}
