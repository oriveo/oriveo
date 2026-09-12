package ai.oriveo.community.feature.home

import android.os.Build
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
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
import ai.oriveo.community.ui.theme.OriveoTheme
import java.util.Calendar
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
        val accentLight = Color(0xFF8B5CF6)
        val accentDark = Color(0xFFA78BFA)

        val accentGlowLight = Color(0xFF8B5CF6)
        val accentGlowDark = Color(0xFFC4B5FD)

        val auroraBlueLight = Color(0xFF60A5FA)
        val auroraBlueDark = Color(0xFF93C5FD)

        val textPrimaryLight = Color(0xFF0A0612)
        val textPrimaryDark = Color(0xFFFAFAFB)

        val textSecondaryLight = Color(0xFF6B6378)
        val textSecondaryDark = Color(0xFFC4BFD3)

        val textTertiaryLight = Color(0xFF9C95AA)
        val textTertiaryDark = Color(0xFF8C8499)

        val cardFillLight = Color(0xFFFFFFFF).copy(alpha = 0.72f)
        val cardFillDark = Color(0xFF1A1530).copy(alpha = 0.55f)
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

        // Conversation group card fill (dark #221F35 / light pure white) and stroke (dark 5.5% white / light 5% black)
        val groupCardFillLight = Color(0xFFFFFFFF)
        val groupCardFillDark = Color(0xFF221F35)
        val groupCardBorderLight = Color(0xFF000000).copy(alpha = 0.05f)
        val groupCardBorderDark = Color(0xFFFFFFFF).copy(alpha = 0.055f)

        // Model pill fill: tonal, no stroke (light #F3F0FA). Dark uses an opaque tone of the same hue, because a translucent white over the card fades into a grey patch
        val pillFillLight = Color(0xFFF3F0FA)
        val pillFillDark = Color(0xFF2F2D3F)

        // Send button: the same solid purple in dark and light, no gradient, no shadow
        val sendFill = Color(0xFF8B5CF6)

        // Screen background gradient endpoints (same as iOS AuroraScreenBackground)
        val bgDarkTop = Color(0xFF1B1A2A)
        val bgDarkBottom = Color(0xFF131019)
        val bgLightTop = Color(0xFFF7F5FB)
        val bgLightBottom = Color(0xFFF2EEF7)

        // hero / Notes card face. Light: pure white with two soft glows. Dark: an "aurora rising" treatment where
        // the face itself is a deep base from the same family as the list cards and the aurora only shows from
        // behind the card's top edge (see [drawAuroraCrown]). The face stays uniform and gets monotonically darker
        // from top to bottom; high saturation appears only on the very bright edge light, which is what makes it
        // read as light rather than paint.
        val heroSurfaceDarkTop = Color(0xFF242235)
        val heroSurfaceDarkBottom = Color(0xFF201F31)

        // Afterglow a finger's width below the top edge (fades downward: 40% at 38dp, gone at 70dp)
        val heroCrownWash = Color(0xFFC8BCFF)

        // Light-mode in-card glows: A = top-left purple (also the Notes glow), B = top-right pink
        val heroGlowALight = Color(0xFF8B5CF6).copy(alpha = 0.10f)
        val heroGlowBLight = Color(0xFFEC8FEA).copy(alpha = 0.08f)

        // Aurora crown: lavender / pink / sky, the same trio as the Notes line glyph; the near-white hot core is hero-only
        val crownLavender = Color(0xFFC4B5FD)
        val crownPink = Color(0xFFEC8FEA)
        val crownSky = Color(0xFF8DB4FF)
        val crownHot = Color(0xFFECE6FF)

        // Base of the dark card's 1dp inner stroke: outside the aurora crown the rim is still white, bright at the top and dark at the bottom
        val heroRimDarkTop = Color(0xFFFFFFFF).copy(alpha = 0.07f)
        val heroRimDarkBottom = Color(0xFFFFFFFF).copy(alpha = 0.035f)

        // Tertiary grey text inside the hero (placeholder, provider name, chevrons): same hue as the card face, cooler
        // than the global t3. The global t3 #8C8499 is a warm grey-purple (h 302); over a card face at h 288 the hue
        // mismatch is one of the things that makes the card look muddy
        val heroTextTertiaryDark = Color(0xFF9493A8)

        val auroraPink = Color(0xFFEC8FEA)
        val auroraLavender = Color(0xFFC4B5FD)
        val auroraSoftBlue = Color(0xFF8DB4FF)
        val auroraSoftCyan = Color(0xFF86D2E6)
    }

    /** The primary accent purple for the current mode. */
    @Composable
    fun accent(): Color = if (OriveoTheme.isDark) Colors.accentDark else Colors.accentLight

    @Composable
    fun accentGlow(): Color = if (OriveoTheme.isDark) Colors.accentGlowDark else Colors.accentGlowLight

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
    fun cardFill(): Color = if (OriveoTheme.isDark) Colors.cardFillDark else Colors.cardFillLight

    @Composable
    fun cardBorder(): Color = if (OriveoTheme.isDark) Colors.cardBorderDark else Colors.cardBorderLight

    @Composable
    fun hairline(): Color = if (OriveoTheme.isDark) Colors.hairlineDark else Colors.hairlineLight

    @Composable
    fun chromeFill(): Color = if (OriveoTheme.isDark) Colors.chromeFillDark else Colors.chromeFillLight

    @Composable
    fun chromeDivider(): Color = if (OriveoTheme.isDark) Colors.chromeDividerDark else Colors.chromeDividerLight

    @Composable
    fun groupCardFill(): Color = if (OriveoTheme.isDark) Colors.groupCardFillDark else Colors.groupCardFillLight

    @Composable
    fun groupCardBorder(): Color = if (OriveoTheme.isDark) Colors.groupCardBorderDark else Colors.groupCardBorderLight

    @Composable
    fun pillFill(): Color = if (OriveoTheme.isDark) Colors.pillFillDark else Colors.pillFillLight

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
 * CSS `box-shadow` blur value → Compose [Shadow] radius.
 * A CSS blur B is a Gaussian sigma of B/2; Compose shadows go through BlurMaskFilter, where
 * sigma = 0.57735·r + 0.5px, hence r ≈ 0.866·B (the 0.5px constant is negligible at dp scale).
 * iOS `.shadow(radius:)` takes B/2.
 */
internal fun auroraCssShadowRadius(blur: Dp): Dp = blur * 0.866f

@Composable
internal fun AuroraScreenBackground(modifier: Modifier = Modifier) {
    val isDark = OriveoTheme.isDark
    val brush = remember(isDark) {
        Brush.verticalGradient(
            colors = if (isDark) {
                listOf(AuroraTheme.Colors.bgDarkTop, AuroraTheme.Colors.bgDarkBottom)
            } else {
                listOf(AuroraTheme.Colors.bgLightTop, AuroraTheme.Colors.bgLightBottom)
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
    isDark: Boolean,
    glow: AuroraHeroGlow,
    cornerRadius: Float,
    clip: Path,
) {
    clipPath(clip) {
        if (isDark) {
            drawRect(
                brush = Brush.verticalGradient(
                    colors = listOf(AuroraTheme.Colors.heroSurfaceDarkTop, AuroraTheme.Colors.heroSurfaceDarkBottom),
                    startY = 0f,
                    endY = size.height,
                ),
            )
            drawAuroraCrownWash(if (glow == AuroraHeroGlow.HeroPair) 1f else AURORA_CROWN_NOTES_WASH_SCALE)
        } else {
            drawRoundRect(color = Color.White, cornerRadius = CornerRadius(cornerRadius, cornerRadius))
            when (glow) {
                AuroraHeroGlow.HeroPair -> {
                    // left -60 / top -80 / 260×220; right -70 / top -90 / 240×210
                    drawEllipticalGlow(AuroraTheme.Colors.heroGlowALight, 260.dp.toPx(), 220.dp.toPx(), Offset(70.dp.toPx(), 30.dp.toPx()))
                    drawEllipticalGlow(AuroraTheme.Colors.heroGlowBLight, 240.dp.toPx(), 210.dp.toPx(), Offset(size.width - 50.dp.toPx(), 15.dp.toPx()))
                }
                AuroraHeroGlow.NotesCorner -> {
                    // right -50 / top -70 / 220×200
                    drawEllipticalGlow(AuroraTheme.Colors.heroGlowALight, 220.dp.toPx(), 200.dp.toPx(), Offset(size.width - 60.dp.toPx(), 30.dp.toPx()))
                }
            }
        }
    }
}

/**
 * The crown's afterglow inside the card: three elliptical glows within a finger's width (≤16dp) of the top edge
 * plus a thin haze fading downward. It lifts the brightness only slightly; the text area stays a uniform base.
 */
private fun DrawScope.drawAuroraCrownWash(scale: Float) {
    val wash = AuroraTheme.Colors.heroCrownWash
    // 0dp 7.5% → 38dp 3% → 70dp 0; a card shorter than 70dp truncates proportionally
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
    drawRect(brush = ellipticalGlowBrush(AuroraTheme.Colors.crownLavender, 0.16f * scale, w * 0.72f, 32.dp.toPx(), Offset(w * 0.22f, 0f)))
    drawRect(brush = ellipticalGlowBrush(AuroraTheme.Colors.crownPink, 0.12f * scale, w * 0.60f, 28.dp.toPx(), Offset(w * 0.52f, 0f)))
    drawRect(brush = ellipticalGlowBrush(AuroraTheme.Colors.crownSky, 0.14f * scale, w * 0.72f, 32.dp.toPx(), Offset(w * 0.80f, 0f)))
}

/**
 * Aurora crown: a ring of light along the card's 1dp inner stroke. The top edge runs lavender → pink → sky from
 * left to right (the hero adds a near-white hot core), fades out quickly past the top corners, and the remaining
 * edges stay the white rim, bright at the top and dark at the bottom.
 *
 * One stroke takes one brush, so the layers are drawn **bottom-up** in CSS order: white base → sky → pink →
 * lavender → hot core.
 */
private fun DrawScope.drawAuroraCrown(rimPath: Path, strokeWidth: Float, scale: Float, hotCore: Boolean, alpha: Float) {
    // The design's four edge glows: radii 40% / 32% / 40% of the width × 64 / 44 / 64dp tall, hot core 30% wide × 22dp tall, all centered on the top edge
    val w = size.width
    val stroke = Stroke(width = strokeWidth)
    drawPath(path = rimPath, brush = auroraHeroRimBrush(isDark = true, height = size.height), alpha = alpha, style = stroke)
    listOf(
        ellipticalGlowBrush(AuroraTheme.Colors.crownSky, 0.95f * scale, w * 0.80f, 128.dp.toPx(), Offset(w * 0.86f, 0f)),
        ellipticalGlowBrush(AuroraTheme.Colors.crownPink, 0.80f * scale, w * 0.64f, 88.dp.toPx(), Offset(w * 0.52f, 0f)),
        ellipticalGlowBrush(AuroraTheme.Colors.crownLavender, 1.0f * scale, w * 0.80f, 128.dp.toPx(), Offset(w * 0.16f, 0f)),
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

/** Aurora halo outside the card: two gradient shadows hugging the card shape and lifted upward (a wide halo plus a hot core hugging the top edge). */
private val auroraHaloBrushStops = arrayOf(
    0f to AuroraTheme.Colors.crownLavender.copy(alpha = 0.20f),
    0.2f to AuroraTheme.Colors.crownLavender.copy(alpha = 0.95f),
    0.5f to AuroraTheme.Colors.crownPink.copy(alpha = 0.85f),
    0.8f to AuroraTheme.Colors.crownSky.copy(alpha = 0.95f),
    1f to AuroraTheme.Colors.crownSky.copy(alpha = 0.20f),
)

private val auroraHaloBrush: Brush = Brush.horizontalGradient(colorStops = auroraHaloBrushStops)

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
        fun resolve(isDark: Boolean, focused: Boolean): AuroraHeroCardAppearance {
            val contact: CardShadow?
            val ambient: CardShadow
            if (isDark) {
                // 0 12 28 -6 rgba(0,0,0,.36), unchanged on focus (the colored glow belongs to the crown / ring)
                contact = null
                ambient = CardShadow(Color.Black.copy(alpha = 0.36f), 28.dp, 12.dp, spread = (-6).dp)
            } else if (focused) {
                // 0 14 40 rgba(139,92,246,.16)
                contact = null
                ambient = CardShadow(Color(0xFF8B5CF6).copy(alpha = 0.16f), 40.dp, 14.dp)
            } else {
                // 0 1 2 rgba(15,23,42,.04) + 0 10 28 rgba(139,92,246,.08)
                contact = CardShadow(Color(0xFF0F172A).copy(alpha = 0.04f), 2.dp, 1.dp)
                ambient = CardShadow(Color(0xFF8B5CF6).copy(alpha = 0.08f), 28.dp, 10.dp)
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

/** The fixed color order of iOS `auroraGlowColors`: purple → lavender → pink → blue → soft teal → pale purple → purple. */
private val auroraGlowColors = listOf(
    AuroraTheme.Colors.accentLight,
    AuroraTheme.Colors.accentDark,
    AuroraTheme.Colors.auroraPink,
    AuroraTheme.Colors.auroraSoftBlue,
    AuroraTheme.Colors.auroraSoftCyan,
    AuroraTheme.Colors.auroraLavender,
    AuroraTheme.Colors.accentLight,
)

/**
 * The design uses `conic-gradient(from 200deg, …)`: CSS puts 0° at 12 o'clock, Android's SweepGradient at
 * 3 o'clock, both clockwise, so the start is 200 - 90 = 110° (the same 110° as the iOS AngularGradient).
 */
private const val AURORA_RING_START_DEGREES = 110f

private fun auroraRingBrush(center: Offset): Brush = object : ShaderBrush() {
    override fun createShader(size: Size): android.graphics.Shader =
        SweepGradientShader(center = center, colors = auroraGlowColors).apply {
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
    val idle = remember(isDark) { AuroraHeroCardAppearance.resolve(isDark, focused = false) }
    val active = remember(isDark) { AuroraHeroCardAppearance.resolve(isDark, focused = true) }
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
    val halo = remember(shadowContext, shape, isDark) {
        if (isDark) auroraHaloShadows().map { shadowContext.createDropShadowPainter(shape, it) } else emptyList()
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
        val ringBrush = auroraRingBrush(Offset(size.width / 2f, size.height / 2f))
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

            drawAuroraHeroSurface(isDark, AuroraHeroGlow.HeroPair, cr, cardPath)

            if (p < 1f) {
                if (isDark) {
                    drawAuroraCrown(hairlinePath, hairlineWidth, scale = 1f, hotCore = true, alpha = 1f - p)
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
private fun auroraHaloShadows(): List<Shadow> = listOf(
    Shadow(
        radius = auroraCssShadowRadius(30.dp),
        brush = auroraHaloBrush,
        spread = (-7).dp,
        offset = DpOffset(0.dp, (-11).dp),
        alpha = 0.56f,
    ),
    Shadow(
        radius = auroraCssShadowRadius(7.dp),
        brush = auroraHaloBrush,
        spread = (-1).dp,
        offset = DpOffset(0.dp, (-2.5).dp),
        alpha = 0.65f,
    ),
)

/**
 * Face of the Notes entry card: the hero material with only the top-right glow plus the same 1dp inner stroke, no shadow, no ring.
 */
internal fun Modifier.auroraNotesSurface(isDark: Boolean, cornerRadius: Dp): Modifier = drawWithCache {
    val cr = cornerRadius.toPx()
    val cardPath = auroraRoundRectPath(size, cr)
    val hairlineWidth = 1.dp.toPx()
    val borderPath = auroraRoundRectPath(size, cr, inset = hairlineWidth / 2f)
    val border = auroraHeroRimBrush(isDark, size.height)
    onDrawBehind {
        drawAuroraHeroSurface(isDark, AuroraHeroGlow.NotesCorner, cr, cardPath)
        if (isDark) {
            // The same crown one step weaker, without the hot core and without the outer halo: Notes does not compete with the hero
            drawAuroraCrown(borderPath, hairlineWidth, scale = AURORA_CROWN_NOTES_SCALE, hotCore = false, alpha = 1f)
        } else {
            drawPath(path = borderPath, brush = border, style = Stroke(width = hairlineWidth))
        }
    }
}

// -- Section Rule (the glowing purple vertical bar) --

/** The glowing purple bar on the left of a section title: 3×18, #C4B5FD → #8B5CF6, outer glow dark 8px 55% #A78BFA / light 6px 35% #8B5CF6. */
@Composable
internal fun AuroraSectionRule(modifier: Modifier = Modifier) {
    val isDark = OriveoTheme.isDark
    val shape = RoundedCornerShape(50)
    Box(
        modifier = modifier
            .size(width = 3.dp, height = 18.dp)
            .dropShadow(
                shape = shape,
                shadow = Shadow(
                    radius = if (isDark) 4.dp else 3.dp,
                    color = if (isDark) Color(0xFFA78BFA).copy(alpha = 0.55f) else Color(0xFF8B5CF6).copy(alpha = 0.35f),
                ),
            )
            .background(
                brush = Brush.verticalGradient(listOf(Color(0xFFC4B5FD), Color(0xFF8B5CF6))),
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

    /** Matches iOS AuroraGreeting.currentKey() exactly: the nameless greeting. */
    fun greetingResId(now: Calendar = Calendar.getInstance()): Int {
        return when (current(now)) {
            Bucket.MORNING -> ai.oriveo.community.R.string.greeting_morning
            Bucket.AFTERNOON -> ai.oriveo.community.R.string.greeting_afternoon
            Bucket.EVENING -> ai.oriveo.community.R.string.greeting_evening
            Bucket.NIGHT -> ai.oriveo.community.R.string.greeting_still_up
        }
    }

    /**
     * Sixteen taglines across the four time-of-day buckets -- stable within a day (no flicker),
     * refreshed daily. Design philosophy: self-compassion / autonomy / companionship /
     * containment / validation / presence -- consistently avoiding toxic positivity ("you've got this!").
     */
    private val morningTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_morning_1,
        ai.oriveo.community.R.string.tagline_morning_2,
        ai.oriveo.community.R.string.tagline_morning_3,
        ai.oriveo.community.R.string.tagline_morning_4,
    )
    private val afternoonTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_afternoon_1,
        ai.oriveo.community.R.string.tagline_afternoon_2,
        ai.oriveo.community.R.string.tagline_afternoon_3,
        ai.oriveo.community.R.string.tagline_afternoon_4,
    )
    private val eveningTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_evening_1,
        ai.oriveo.community.R.string.tagline_evening_2,
        ai.oriveo.community.R.string.tagline_evening_3,
        ai.oriveo.community.R.string.tagline_evening_4,
    )
    private val nightTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_night_1,
        ai.oriveo.community.R.string.tagline_night_2,
        ai.oriveo.community.R.string.tagline_night_3,
        ai.oriveo.community.R.string.tagline_night_4,
    )

    fun taglineResId(now: Calendar = Calendar.getInstance()): Int {
        val pool = when (current(now)) {
            Bucket.MORNING -> morningTaglines
            Bucket.AFTERNOON -> afternoonTaglines
            Bucket.EVENING -> eveningTaglines
            Bucket.NIGHT -> nightTaglines
        }
        val dayOfYear = now.get(Calendar.DAY_OF_YEAR)
        val year = now.get(Calendar.YEAR)
        val index = ((dayOfYear * 31 + year) and 0x7FFFFFFF) % pool.size
        return pool[index]
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
