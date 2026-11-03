package ai.oriveo.community.feature.chat.voice

import android.os.Build
import androidx.annotation.VisibleForTesting
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.animation.core.withInfiniteAnimationFrameNanos
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.DefaultLightBrandTuned
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.flow.StateFlow
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin

/**
 * Liquid-aurora orb and aurora haze for the voice stage (orb and aurora spec, items 1-6).
 * The caller maps state to [VoiceOrbMode] (awaiting approval / error fall into the [VoiceOrbMode.Muted] group).
 */
internal enum class VoiceOrbMode { Idle, Listen, User, Think, Ai, Muted }

/** Blur path: API >= 31 uses RenderEffect blur; older APIs use a radial gradient (center color to transparent, radius x1.35). */
internal enum class VoiceOrbBlur { RenderEffect, RadialFallback }

internal fun voiceOrbBlur(sdkInt: Int = Build.VERSION.SDK_INT): VoiceOrbBlur =
    if (sdkInt >= Build.VERSION_CODES.S) VoiceOrbBlur.RenderEffect else VoiceOrbBlur.RadialFallback

/** Orb box edge = 200 canvas units (includes glow margin); visible orb r78, i.e. 148 x 0.78 ~= 115 dp. */
internal val VoiceAuroraOrbSize: Dp = 148.dp

/** Canvas edge length (SVG viewBox 0 0 200 200). */
internal const val ORB_CANVAS = 200f
internal const val ORB_CANVAS_RADIUS = 78f
private const val CANVAS_RADIUS = ORB_CANVAS_RADIUS
private const val CANVAS_DIAMETER = CANVAS_RADIUS * 2f
private const val FALLBACK_RADIUS_SCALE = 1.35f

/** Canvas Gaussian blur sigma (200 canvas units): color blobs and bottom reflection 14, outer glow 22. */
internal const val ORB_BLOB_SIGMA = 14f
internal const val ORB_GLOW_SIGMA = 22f

/** hwui derives sigma = 0.57735·r + 0.5 from the blur radius (libs/hwui/utils/Blur.cpp). */
private const val HWUI_BLUR_SIGMA_SCALE = 0.57735f
private const val HWUI_BLUR_SIGMA_OFFSET = 0.5f

/** Target sigma (px) to RenderEffect blur radius (px): sigma <= 0.5 means no blur. */
internal fun blurRadiusPx(sigmaPx: Float): Float =
    if (sigmaPx <= HWUI_BLUR_SIGMA_OFFSET) 0f else (sigmaPx - HWUI_BLUR_SIGMA_OFFSET) / HWUI_BLUR_SIGMA_SCALE

/** Outward extension of the glow draw area beyond the orb box: 3 sigma (sigma 22 scaled to the orb box), so the blurred glow is not clipped to a square by the layer bounds. */
internal fun orbGlowOutset(box: Dp): Dp = box * (3f * ORB_GLOW_SIGMA / ORB_CANVAS)

/** Canvas ellipse (200 canvas units): center [cx]/[cy], radii [rx]/[ry]. */
internal data class OrbEllipse(val cx: Float, val cy: Float, val rx: Float, val ry: Float)

internal val OrbHighlight = OrbEllipse(82f, 58f, 52f, 32f)
internal val OrbReflection = OrbEllipse(100f, 152f, 56f, 26f)

/** Minimum interval between orb frame loops: <= 60 fps (leaves margin for vsync jitter). */
internal const val ORB_FRAME_INTERVAL_NANOS = 16_000_000L

/** Minimum interval between fog frame loops: <= 30 fps. */
internal const val FOG_FRAME_INTERVAL_NANOS = 33_000_000L

/** Duration of the AI / user palette switch (linear interpolation, aligned with iOS). */
private const val PALETTE_SWITCH_MS = 200f

// ── Pure functions (for tests) ──

/** breathe = .5 + .5·sin(t / 1100 ms). */
internal fun orbBreathe(tMs: Double): Float = (0.5 + 0.5 * sin(tMs / 1100.0)).toFloat()

/** Envelope first-order filter: rise 40 ms, fall 200 ms. */
internal fun envelopeStep(current: Float, target: Float, dtMs: Float): Float {
    if (dtMs <= 0f) return current
    val tau = if (target > current) 40f else 200f
    val k = 1f - exp(-dtMs / tau)
    return current + (target - current) * k
}

/** Envelope second-stage smoothing: apply a symmetric first-order filter with a 24 ms time constant to the first-stage envelope, flattening the corners of the 15 Hz level steps. */
internal fun envelopeSmoothStep(current: Float, target: Float, dtMs: Float): Float {
    if (dtMs <= 0f) return current
    val k = 1f - exp(-dtMs / ENVELOPE_SMOOTH_TAU_MS)
    return current + (target - current) * k
}

/** Second-stage smoothing time constant (ms). */
private const val ENVELOPE_SMOOTH_TAU_MS = 24f

/** Easing duration (ms) for scale / energy when switching modes; the curve matches the palette ease-in-out. */
private const val MODE_SWITCH_MS = 200f

/** Energy E: user = envelope, ai = 0.9 x envelope, think .45, listen .15·breathe, others .05. */
internal fun orbEnergy(mode: VoiceOrbMode, envelope: Float, breathe: Float): Float = when (mode) {
    VoiceOrbMode.User -> envelope.coerceIn(0f, 1f)
    VoiceOrbMode.Ai -> 0.9f * envelope.coerceIn(0f, 1f)
    VoiceOrbMode.Think -> 0.45f
    VoiceOrbMode.Listen -> 0.15f * breathe
    VoiceOrbMode.Idle, VoiceOrbMode.Muted -> 0.05f
}

/** Scale: user 1+.16E, ai 1+.08E, listen 1+.025·breathe, think .95, others 1; reduced motion does not scale. */
internal fun orbScale(mode: VoiceOrbMode, energy: Float, breathe: Float, reduceMotion: Boolean = false): Float {
    if (reduceMotion) return 1f
    return when (mode) {
        VoiceOrbMode.User -> 1f + 0.16f * energy
        VoiceOrbMode.Ai -> 1f + 0.08f * energy
        VoiceOrbMode.Listen -> 1f + 0.025f * breathe
        VoiceOrbMode.Think -> 0.95f
        VoiceOrbMode.Idle, VoiceOrbMode.Muted -> 1f
    }
}

/** Phase speed (per second); phase does not advance under reduced motion. */
internal fun orbPhaseSpeed(mode: VoiceOrbMode, energy: Float, reduceMotion: Boolean = false): Float {
    if (reduceMotion) return 0f
    return when (mode) {
        VoiceOrbMode.Listen -> 0.22f
        VoiceOrbMode.User -> 0.45f + 0.9f * energy
        VoiceOrbMode.Think -> 1.25f
        VoiceOrbMode.Ai -> 0.4f + 0.6f * energy
        VoiceOrbMode.Muted -> 0.05f
        VoiceOrbMode.Idle -> 0.10f
    }
}

/** Overall orb look: alpha, saturation, and the group alpha of the glow. */
internal data class OrbLook(val alpha: Float, val saturation: Float, val glowAlpha: Float)

/** Reduced motion: alpha = .6 + .4 x raw level (not through the envelope), E recorded as 0, glow fixed at the base value. */
internal fun orbLook(mode: VoiceOrbMode, energy: Float, level: Float, dark: Boolean, reduceMotion: Boolean): OrbLook {
    if (mode == VoiceOrbMode.Muted) return OrbLook(alpha = 0.55f, saturation = 0.15f, glowAlpha = 0.1f)
    val alpha = if (reduceMotion) 0.6f + 0.4f * level.coerceIn(0f, 1f) else 1f
    val e = if (reduceMotion) 0f else energy
    val glow = ((if (dark) 0.55f else 0.38f) + 0.45f * e).coerceAtMost(1f)
    return OrbLook(alpha = alpha, saturation = 1f, glowAlpha = glow)
}

/** Alpha of fog circle [index] (0-based): light .32 / dark .55; user speaking .30+.35E, AI speaking .45+.30E; circle 3 fixed at light .18 / dark .35, not level-driven. */
internal fun fogAlpha(mode: VoiceOrbMode, energy: Float, dark: Boolean, index: Int): Float {
    val base = if (dark) 0.55f else 0.32f
    val base3 = if (dark) 0.35f else 0.18f
    val main = when (mode) {
        VoiceOrbMode.User -> 0.30f + 0.35f * energy
        VoiceOrbMode.Ai -> 0.45f + 0.30f * energy
        else -> base
    }
    return if (index >= 2) base3 else main
}

/**
 * Spec for one fog circle. Center [centerX] is relative to the panel's left edge, [centerY] relative to the top edge of the fog container (excluding horizontal drift);
 * [blur] is the Gaussian sigma;
 * [drift] is the horizontal drift direction (+1 / -1 / 0); actual offset = drift x 20 dp x sin(t / 2600 ms).
 */
internal data class FogCircle(
    val color: Color,
    val alpha: Float,
    val diameter: Dp,
    val blur: Dp,
    val centerX: Dp,
    val centerY: Dp,
    val drift: Float,
)

/** Base panel width for the canvas; other widths scale circle x by panel width / 390, y unchanged. */
private val FogReferenceWidth = 390.dp

/** Fog container (canvas left/right -40, bottom -120, height 520): 40 bleed on each side, height 520, bottom edge extends 120 past the panel. */
internal val FogBleedX = 40.dp
internal val FogHeight = 520.dp
internal val FogBelow = 120.dp

/** Test marker for the fog container node (measures the actual container span). */
internal const val VOICE_FOG_TAG = "voice_aurora_fog"

/** Edge length of one fog blob's draw area: 3 sigma margin on each side, so the blurred result is not clipped to a rectangle by the layer bounds. */
internal fun fogLayerSize(circle: FogCircle): Dp = circle.diameter + circle.blur * 6f

private val Amber = Color(0xFFF59E0B)

/**
 * Three fog blobs. [noticeMix] is the interpolation for the hint state (0 = normal, 1 = hint state: circle 1 alpha .40, circle 2 amber, circle 3 alpha 0 to fill in),
 * by default taken from the two ends by [notice].
 */
internal fun fogCircles(
    mode: VoiceOrbMode,
    energy: Float,
    dark: Boolean,
    notice: Boolean,
    panelWidth: Dp = FogReferenceWidth,
    aiMix: Float = if (usesAiPalette(mode)) 1f else 0f,
    noticeMix: Float = if (notice) 1f else 0f,
): List<FogCircle> = List(FOG_CIRCLES) { i ->
    val (x, y) = fogCenter(i, panelWidth)
    FogCircle(
        color = fogCircleColor(i, aiMix, noticeMix),
        alpha = fogCircleAlpha(mode, energy, dark, i, noticeMix),
        diameter = FogDiameters[i],
        blur = fogCircleSigma(i, noticeMix),
        centerX = x,
        centerY = y,
        drift = FogDrifts[i],
    )
}

private const val FOG_CIRCLES = 3
private val FogDiameters = listOf(300.dp, 280.dp, 220.dp)
private val FogSigmas = listOf(70.dp, 70.dp, 60.dp)
private val FogDrifts = floatArrayOf(1f, -1f, 0f)
private val FogCenterX = listOf(150.dp, 290.dp, 220.dp)
private val FogCenterY = listOf(260.dp, 310.dp, 340.dp)

/** Center of blob [index]: x scaled by panel width / 390, y unchanged. */
internal fun fogCenter(index: Int, panelWidth: Dp = FogReferenceWidth): Pair<Dp, Dp> =
    FogCenterX[index] * (panelWidth / FogReferenceWidth) to FogCenterY[index]

/** Color of blob [index]: user / AI palette interpolated by [aiMix], then toward the hint state (circle 2 amber) by [noticeMix]. */
internal fun fogCircleColor(index: Int, aiMix: Float, noticeMix: Float): Color {
    val plain = when {
        aiMix <= 0f -> UserFogColors[index]
        aiMix >= 1f -> AiFogColors[index]
        else -> lerp(UserFogColors[index], AiFogColors[index], aiMix)
    }
    if (noticeMix <= 0f) return plain
    val amber = if (index == 1) Amber else plain
    return if (noticeMix >= 1f) amber else lerp(plain, amber, noticeMix)
}

/** Alpha of blob [index]: normal uses [fogAlpha]; hint state circle 1 .40, circle 2 .20, circle 3 0, interpolated by [noticeMix]. */
internal fun fogCircleAlpha(mode: VoiceOrbMode, energy: Float, dark: Boolean, index: Int, noticeMix: Float): Float {
    val plain = fogAlpha(mode, energy, dark, index)
    if (noticeMix <= 0f) return plain
    val amber = when (index) {
        0 -> 0.40f
        1 -> 0.20f
        else -> 0f
    }
    return if (noticeMix >= 1f) amber else plain + (amber - plain) * noticeMix
}

/** Sigma of blob [index]: in the hint state circle 2 interpolates continuously from 70 to 80. */
internal fun fogCircleSigma(index: Int, noticeMix: Float): Dp {
    val plain = FogSigmas[index]
    if (index != 1 || noticeMix <= 0f) return plain
    return if (noticeMix >= 1f) 80.dp else androidx.compose.ui.unit.lerp(plain, 80.dp, noticeMix)
}

/** Fog draw method: both sdks draw a radial gradient from a precomputed profile (no per-frame blur), independent of the orb's [VoiceOrbBlur]. */
internal enum class VoiceFogPaint { DiscGradient }

/** Number of profile stops: evenly covers [0, R+4σ]. */
internal const val FOG_PROFILE_STOPS = 41

/** Exponentially scaled zero-order modified Bessel function e^(−|x|)·I0(x) (A&S 9.8.1 / 9.8.2). */
private fun besselI0e(x: Double): Double {
    val ax = kotlin.math.abs(x)
    if (ax <= 3.75) {
        val t = (x / 3.75) * (x / 3.75)
        val i0 = 1.0 + t * (3.5156229 + t * (3.0899424 + t * (1.2067492 + t * (0.2659732 + t * (0.0360768 + t * 0.0045813)))))
        return exp(-ax) * i0
    }
    val t = 3.75 / ax
    val poly = 0.39894228 + t * (0.01328592 + t * (0.00225319 + t * (-0.00157565 + t * (0.00916281 +
        t * (-0.02057706 + t * (0.02635537 + t * (-0.01647633 + t * 0.00392377)))))))
    return poly / kotlin.math.sqrt(ax)
}

/**
 * Coverage (0 to 1) at distance [rho] from the center, after convolving a solid disc of radius [radius] with a 2D Gaussian of sigma = [sigma]:
 * P(ρ) = ∫₀ᴿ (t/σ²)·e^(−(ρ−t)²/2σ²)·I0e(ρt/σ²) dt, Simpson with 256 segments.
 */
internal fun fogDiscProfile(rho: Double, radius: Double, sigma: Double): Double {
    val n = 256
    val h = radius / n
    val s2 = sigma * sigma
    var sum = 0.0
    for (k in 0..n) {
        val t = k * h
        val d = rho - t
        val f = t / s2 * exp(-d * d / (2.0 * s2)) * besselI0e(rho * t / s2)
        sum += f * (if (k == 0 || k == n) 1.0 else if (k % 2 == 1) 4.0 else 2.0)
    }
    return sum * h / 3.0
}

private val fogProfileCache = HashMap<Long, FloatArray>()

/** Profile of one fog blob: [FOG_PROFILE_STOPS] evenly spaced stops covering [0, diameter/2 + 4σ], last stop set to 0; cached by (diameter, sigma rounded to 0.5). */
internal fun fogProfile(diameter: Float, sigma: Float): FloatArray {
    val d2 = kotlin.math.round(diameter * 2f).toLong()
    val s2 = kotlin.math.round(sigma * 2f).toLong()
    val key = (d2 shl 32) or (s2 and 0xFFFFFFFFL)
    synchronized(fogProfileCache) {
        fogProfileCache[key]?.let { return it }
        val radius = d2 / 4.0
        val s = s2 / 2.0
        val extent = radius + 4.0 * s
        val stops = FloatArray(FOG_PROFILE_STOPS) { i ->
            if (i == FOG_PROFILE_STOPS - 1) 0f else fogDiscProfile(extent * i / (FOG_PROFILE_STOPS - 1), radius, s).toFloat()
        }
        fogProfileCache[key] = stops
        return stops
    }
}

/** Alpha quantization levels when merging fog alpha into gradient stops: alpha is rounded to 1/256 (257 levels, 0 to 256). */
private const val FOG_ALPHA_STEPS = 256

/**
 * Gradient table for one fog layer: a lazily loaded, bounded [Brush] table (257 slots) indexed by alpha level; each level is built on first use, no per-frame allocation.
 * Discarded whole when color / profile / pixel radius changes. Alpha is multiplied into each stop color (not via Paint's 8-bit alpha); draw alpha is fixed at 1.
 */
internal class FogBrushCache {
    private var color: Color = Color.Unspecified
    private var profile: FloatArray? = null
    private var radiusPx = -1f
    private val brushes = arrayOfNulls<Brush>(FOG_ALPHA_STEPS + 1)

    fun brush(color: Color, alpha: Float, profile: FloatArray, radiusPx: Float): Brush {
        if (color != this.color || profile !== this.profile || radiusPx != this.radiusPx) {
            brushes.fill(null)
            this.color = color
            this.profile = profile
            this.radiusPx = radiusPx
        }
        val index = kotlin.math.round(alpha.coerceIn(0f, 1f) * FOG_ALPHA_STEPS).toInt()
        brushes[index]?.let { return it }
        val a = index / FOG_ALPHA_STEPS.toFloat()
        val stops = Array(profile.size) { i -> i / (profile.size - 1f) to color.copy(alpha = color.alpha * a * profile[i]) }
        return Brush.radialGradient(colorStops = stops, center = Offset.Unspecified, radius = radiusPx).also { brushes[index] = it }
    }
}

/** Draw one fog blob at the center of the draw area: disc convolved with Gaussian profile x [alpha] (merged into stops), source-over; gradient radius diameter/2 + 4σ. */
internal fun DrawScope.drawFogDisc(cache: FogBrushCache, color: Color, alpha: Float, diameter: Dp, sigma: Dp) {
    val r = (diameter / 2 + sigma * 4f).toPx()
    drawCircle(brush = cache.brush(color, alpha, fogProfile(diameter.value, sigma.value), r), radius = r, center = center)
}

/** Horizontal jitter offset (dp): three back-and-forth moves of ±4 dp; progress 0 to 1 maps to 240 ms. */
internal fun shakeOffsetDp(progress: Float): Float =
    if (progress <= 0f || progress >= 1f) 0f else 4f * sin(2.0 * PI * 3.0 * progress).toFloat()

/** Under reduced motion the jitter becomes an alpha flash instead. */
internal fun shakeAlpha(progress: Float): Float =
    if (progress <= 0f || progress >= 1f) 1f else 1f - 0.4f * sin(PI * progress).toFloat()

private val UserFogColors = listOf(DefaultLightBrandTuned.homeViolet, Color(0xFF4F7BFF), Color(0xFFE04FC0))
private val AiFogColors = listOf(Color(0xFF22D3EE), Color(0xFF4F7BFF), Color(0xFF7C5CFF))

/** Interpolate two color sets item by item by [mix] (0 = [from], 1 = [to]); both ends return the original table directly, no per-frame allocation. */
private fun mixColors(from: List<Color>, to: List<Color>, mix: Float): List<Color> = when {
    mix <= 0f -> from
    mix >= 1f -> to
    else -> List(from.size) { lerp(from[it], to[it], mix) }
}

/** One step of palette-switch progress: move linearly toward the target by dt / 200 ms; under reduced motion, snap directly to the target. */
internal fun paletteMixStep(current: Float, toAi: Boolean, dtMs: Float, reduceMotion: Boolean = false): Float {
    if (reduceMotion) return if (toAi) 1f else 0f
    val delta = dtMs / PALETTE_SWITCH_MS
    return if (toAi) (current + delta).coerceAtMost(1f) else (current - delta).coerceAtLeast(0f)
}

/** Switch progress to palette interpolation: ease-in-out, exact 0 / 1 at the ends. */
internal fun paletteMixEased(progress: Float): Float = when {
    progress <= 0f -> 0f
    progress >= 1f -> 1f
    else -> EaseInOut.transform(progress)
}

/** Only switch to the AI color when AI is speaking; while thinking keep the user color and change only speed, scale and energy. */
internal fun usesAiPalette(mode: VoiceOrbMode) = mode == VoiceOrbMode.Ai

private class OrbPalette(val base: List<Color>, val blobs: List<Color>, val reflection: Color)

/** Orb palette interpolated by [aiMix]; the ends return constants, no per-frame allocation. */
private fun orbPalette(aiMix: Float): OrbPalette = when {
    aiMix <= 0f -> UserPalette
    aiMix >= 1f -> AiPalette
    else -> OrbPalette(
        base = mixColors(UserPalette.base, AiPalette.base, aiMix),
        blobs = mixColors(UserPalette.blobs, AiPalette.blobs, aiMix),
        reflection = lerp(UserPalette.reflection, AiPalette.reflection, aiMix),
    )
}

private val UserPalette = OrbPalette(
    base = listOf(Color(0xFFD9CCFF), Color(0xFF8B6CFF), Color(0xFF4A2FC9)),
    blobs = listOf(Color(0xFF38D6E8), Color(0xFFE04FC0), Color(0xFF4F7BFF), Color(0xFFB79CFF)),
    reflection = Color(0xFF7DD3FC),
)
private val AiPalette = OrbPalette(
    base = listOf(Color(0xFFBAE6FD), Color(0xFF5B8CFF), Color(0xFF3249C9)),
    blobs = listOf(Color(0xFF5EEAD4), Color(0xFF38BDF8), Color(0xFF4F7BFF), Color(0xFFA5F3FC)),
    reflection = Color(0xFFA5F3FC),
)

// ── Frame clock: read only in the draw phase, no per-frame recomposition ──

/**
 * Frame clock: frames less than [minFrameNanos] after the last advance are skipped (orb <= 60 fps, fog <= 30 fps);
 * [aiMix] is the palette interpolation (0 = user color, 1 = AI color), completed over 200 ms ease-in-out. When muted, phase freezes, energy takes .05, and only the palette finishes its transition.
 */
internal class AuroraClock(private val minFrameNanos: Long, initialMode: VoiceOrbMode) {
    val frame = mutableLongStateOf(0L)
    private var lastNanos = -1L
    var tMs = 0.0
        private set
    var phase = 0f
        private set
    var envelope = 0f
        private set

    /** Envelope after second-stage smoothing: energy is derived from it. */
    var smoothed = 0f
        private set
    var breathe = 0.5f
        private set
    var energy = 0.05f
        private set

    /** Energy without the switch easing (second-stage envelope used directly): fog reads this, orb reads the eased [energy]. */
    var targetEnergy = 0.05f
        private set

    /** Display scale: on mode change, eases from the current displayed value to the new mode's per-frame target over 200 ms; graphicsLayer reads it. */
    var scale = 1f
        private set
    private var easeMode = initialMode
    private var easeProgress = 1f
    private var easeFromScale = 1f
    private var easeFromEnergy = 0.05f
    private var paletteProgress = if (usesAiPalette(initialMode)) 1f else 0f
    var aiMix = paletteProgress
        private set
    private var noticeProgress = 0f

    /** Amber interpolation for the hint state (0 = normal, 1 = hint state), same 200 ms ease-in-out as the palette. */
    var noticeMix = 0f
        private set

    /** Raw level (not through the envelope); orb alpha uses it under reduced motion. */
    var level = 0f
        private set

    /** Frame loop restart (e.g. mute released): the next frame does not catch up on the time elapsed while stopped. */
    fun restart() {
        lastNanos = -1L
    }

    /**
     * Whether the frame loop still needs to run: never under reduced motion (level changes redraw once via [hold]); when muted and both palette and amber interpolation have arrived, it stops
     * and the last frame stays static.
     */
    fun needsFrames(mode: VoiceOrbMode, notice: Boolean = false, reduceMotion: Boolean = false): Boolean = when {
        reduceMotion -> false
        mode != VoiceOrbMode.Muted -> true
        else -> aiMix != (if (usesAiPalette(mode)) 1f else 0f) || noticeMix != (if (notice) 1f else 0f)
    }

    /** Advance one frame; returns false when skipped by frame limiting. */
    fun step(now: Long, target: Float, mode: VoiceOrbMode, reduceMotion: Boolean, notice: Boolean = false): Boolean {
        if (lastNanos >= 0 && now - lastNanos < minFrameNanos) return false
        val dtMs = if (lastNanos < 0) 0f else ((now - lastNanos) / 1_000_000f).coerceIn(0f, 100f)
        lastNanos = now
        paletteProgress = paletteMixStep(paletteProgress, usesAiPalette(mode), dtMs, reduceMotion)
        aiMix = paletteMixEased(paletteProgress)
        noticeProgress = paletteMixStep(noticeProgress, notice, dtMs, reduceMotion)
        noticeMix = paletteMixEased(noticeProgress)
        if (mode != VoiceOrbMode.Muted) {
            level = target.coerceIn(0f, 1f)
            envelope = envelopeStep(envelope, level, dtMs)
            smoothed = envelopeSmoothStep(smoothed, envelope, dtMs)
            if (!reduceMotion) tMs += dtMs
            breathe = orbBreathe(tMs)
            targetEnergy = if (reduceMotion) 0f else orbEnergy(mode, smoothed, breathe)
            val targetScale = orbScale(mode, targetEnergy, breathe, reduceMotion)
            if (mode != easeMode) {
                // Coming out of the muted group snaps directly; otherwise start from the current displayed value (re-triggering mid-transition also restarts from here).
                easeProgress = if (easeMode == VoiceOrbMode.Muted) 1f else 0f
                easeMode = mode
                easeFromScale = scale
                easeFromEnergy = energy
            }
            easeProgress = if (reduceMotion) 1f else (easeProgress + dtMs / MODE_SWITCH_MS).coerceAtMost(1f)
            val k = paletteMixEased(easeProgress)
            energy = easeFromEnergy + (targetEnergy - easeFromEnergy) * k
            scale = easeFromScale + (targetScale - easeFromScale) * k
            phase += dtMs / 1000f * orbPhaseSpeed(mode, energy, reduceMotion)
        } else {
            // Muted group snaps directly: phase frozen, energy set to the muted value (.05; recorded as 0 under reduced motion), scale set to the muted value immediately.
            easeMode = mode
            easeProgress = 1f
            targetEnergy = if (reduceMotion) 0f else orbEnergy(mode, smoothed, breathe)
            energy = targetEnergy
            scale = orbScale(mode, energy, breathe, reduceMotion)
        }
        frame.longValue = now
        return true
    }

    /** Reduced motion: no frame loop; palette / amber snap into place, E recorded as 0, redraw once with the raw level. */
    fun hold(target: Float, mode: VoiceOrbMode, notice: Boolean) {
        paletteProgress = if (usesAiPalette(mode)) 1f else 0f
        aiMix = paletteProgress
        noticeProgress = if (notice) 1f else 0f
        noticeMix = noticeProgress
        if (mode != VoiceOrbMode.Muted) {
            level = target.coerceIn(0f, 1f)
            envelope = level
            smoothed = level
        }
        energy = 0f
        targetEnergy = 0f
        easeMode = mode
        easeProgress = 1f
        scale = 1f
        frame.longValue += 1
    }

    /**
     * Frozen sample frame: no frame loop; draws the usual (non-reduced-motion) look at [atMs] ms after the stage appears:
     * palette / amber in place, envelope = level, tMs = [atMs], phase derived from the phase speed at that time.
     */
    fun freeze(atMs: Long, target: Float, mode: VoiceOrbMode, notice: Boolean) {
        paletteProgress = if (usesAiPalette(mode)) 1f else 0f
        aiMix = paletteProgress
        noticeProgress = if (notice) 1f else 0f
        noticeMix = noticeProgress
        tMs = atMs.toDouble()
        level = target.coerceIn(0f, 1f)
        envelope = level
        smoothed = level
        breathe = orbBreathe(tMs)
        energy = orbEnergy(mode, smoothed, breathe)
        targetEnergy = energy
        easeMode = mode
        easeProgress = 1f
        scale = orbScale(mode, energy, breathe)
        phase = (atMs / 1000.0 * orbPhaseSpeed(mode, energy)).toFloat()
        frame.longValue += 1
    }
}

/**
 * Fixed animation clock (ms) for the sample stage: when non-null the stage freezes at that time and draws the usual look (no frame loop; reduced motion treated as off).
 * Provided only by the debug sample-frame entry point; production default is null, behavior unchanged.
 */
internal val LocalVoiceStageClockOverride = staticCompositionLocalOf<Long?> { null }

/** Whether the stage draws with reduced motion: with a sample clock override it is always false (samples use the usual look); otherwise follows the system setting. */
internal fun stageReduceMotion(clockOverride: Long?, systemReduceMotion: Boolean): Boolean =
    clockOverride == null && systemReduceMotion

/**
 * [followsLevel] only controls reduced motion: false (fog) means E=0 and the picture does not change with level; it does not subscribe to level and redraws only on mode / hint change;
 * true (orb) means alpha follows level, redrawing on each level change.
 */
@Composable
@VisibleForTesting
internal fun rememberAuroraClock(
    mode: VoiceOrbMode,
    level: StateFlow<Float>?,
    reduceMotion: Boolean,
    minFrameNanos: Long,
    notice: Boolean = false,
    followsLevel: Boolean = true,
): AuroraClock {
    val clock = remember { AuroraClock(minFrameNanos, mode) }
    val stageClock = LocalVoiceStageClockOverride.current
    if (stageClock != null) {
        // Sample freeze: draw at composition time (the first frame is already frozen), no frame loop started.
        fun follows(m: VoiceOrbMode) = m == VoiceOrbMode.User || m == VoiceOrbMode.Ai || m == VoiceOrbMode.Listen
        val target = if (follows(mode)) level?.value ?: 0f else 0f
        remember(clock, stageClock, mode, notice, target) { clock.freeze(stageClock, target, mode, notice) }
        return clock
    }
    val currentMode = rememberUpdatedState(mode)
    val muted = mode == VoiceOrbMode.Muted
    fun follows(m: VoiceOrbMode) = m == VoiceOrbMode.User || m == VoiceOrbMode.Ai || m == VoiceOrbMode.Listen
    // Under reduced motion and not following level, switching the level source does not restart (no redraw).
    val levelKey = if (reduceMotion && !followsLevel) null else level
    // Restart only under reduced motion on mode change (snaps palette); in normal mode the mode is read per frame, no loop restart.
    LaunchedEffect(clock, levelKey, reduceMotion, muted, notice, if (reduceMotion) mode else null) {
        if (reduceMotion) {
            // No frame loop: redraw once per mode / hint change; level-driven (orb) redraws again on each level change.
            val m = currentMode.value
            when {
                level == null || !follows(m) -> clock.hold(0f, m, notice)
                !followsLevel -> clock.hold(level.value, m, notice)
                else -> level.collect { clock.hold(it, m, notice) }
            }
            return@LaunchedEffect
        }
        clock.restart()
        while (clock.needsFrames(currentMode.value, notice)) {
            // Infinite-animation strategy: tests and accessibility environments may pause it without blocking idle detection.
            withInfiniteAnimationFrameNanos { now ->
                val m = currentMode.value
                val target = if (follows(m)) level?.value ?: 0f else 0f
                clock.step(now, target, m, reduceMotion = false, notice = notice)
            }
        }
    }
    return clock
}

private fun desaturate(saturation: Float): ColorFilter? =
    if (saturation >= 1f) null else ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(saturation) })

/** Blur by canvas sigma: convert sigma to px then back to the hwui radius; does not clip content bounds, so the draw area must leave 3 sigma of margin. The on-device probe (VoiceOrbBlurProbeTest) measures it directly. */
@VisibleForTesting
internal fun Modifier.softBlur(blur: VoiceOrbBlur, sigma: Dp, density: Density): Modifier {
    if (blur != VoiceOrbBlur.RenderEffect) return this
    val radius = with(density) { blurRadiusPx(sigma.toPx()).toDp() }
    return this.blur(radius, BlurredEdgeTreatment.Unbounded)
}

/** Canvas coordinates (200 canvas) to px; [box] is the orb box edge (pass it when the draw area is larger than the orb box), centered. */
internal class OrbSpace(size: Size, box: Float = size.minDimension) {
    val u = box / ORB_CANVAS
    private val cx = size.width / 2f
    private val cy = size.height / 2f
    fun at(x: Float, y: Float) = Offset(cx + (x - 100f) * u, cy + (y - 100f) * u)
}

/** Visible orb clip shape (canvas clipPath r78): circle centered in the orb box with radius 78u, so blurred blobs do not overflow the visible orb. */
internal object OrbBodyShape : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val space = OrbSpace(size)
        val r = CANVAS_RADIUS * space.u
        val c = space.at(100f, 100f)
        return Outline.Rounded(RoundRect(c.x - r, c.y - r, c.x + r, c.y + r, CornerRadius(r)))
    }
}

/** Glass stroke: centerline at r78 (same as iOS stroke(body)), width 1.2 canvas units. */
internal data class OrbRim(val radius: Float, val width: Float)

internal fun orbRim(u: Float): OrbRim = OrbRim(radius = CANVAS_RADIUS * u, width = 1.2f * u)

/** Soft circle: the blur branch draws a solid circle (blurred by the layer); the fallback branch draws a radial gradient from center color to transparent (radius x1.35). */
private fun DrawScope.softCircle(
    color: Color,
    alpha: Float,
    center: Offset,
    radius: Float,
    blur: VoiceOrbBlur,
    filter: ColorFilter?,
) {
    if (blur == VoiceOrbBlur.RenderEffect) {
        drawCircle(color = color, radius = radius, center = center, alpha = alpha, colorFilter = filter)
    } else {
        val r = radius * FALLBACK_RADIUS_SCALE
        drawCircle(
            brush = Brush.radialGradient(listOf(color, color.copy(alpha = 0f)), center = center, radius = r),
            radius = r,
            center = center,
            alpha = alpha,
            colorFilter = filter,
        )
    }
}

/** Ellipse: radii [rx]/[ry], scaled vertically on a circle of radius rx. */
private fun DrawScope.ellipse(center: Offset, rx: Float, ry: Float, block: DrawScope.(radius: Float) -> Unit) {
    scale(scaleX = 1f, scaleY = ry / rx, pivot = center) { block(rx) }
}

/**
 * Liquid-aurora orb (148 dp). Level is read only in the frame clock; animation is read only in the draw phase, no per-frame recomposition;
 * each change of [nudges] triggers one jitter (under reduced motion it becomes an alpha flash).
 */
@Composable
internal fun VoiceAuroraOrb(
    mode: VoiceOrbMode,
    level: StateFlow<Float>?,
    nudges: Int,
    modifier: Modifier = Modifier,
    @VisibleForTesting onComposed: ((VoiceOrbBlur) -> Unit)? = null,
    @VisibleForTesting onShake: (() -> Unit)? = null,
) {
    val blur = remember { voiceOrbBlur() }
    if (onComposed != null) SideEffect { onComposed(blur) }
    val context = LocalContext.current
    val stageClock = LocalVoiceStageClockOverride.current
    val reduceMotion = remember(context, stageClock) { stageReduceMotion(stageClock, isReduceMotionEnabled(context)) }
    val dark = OriveoTheme.isDark
    val clock = rememberAuroraClock(mode, level, reduceMotion, ORB_FRAME_INTERVAL_NANOS)
    val shake = remember { Animatable(1f) }
    val seenNudges = remember { intArrayOf(nudges) }
    LaunchedEffect(nudges) {
        if (nudges == seenNudges[0]) return@LaunchedEffect
        seenNudges[0] = nudges
        onShake?.invoke()
        shake.snapTo(0f)
        shake.animateTo(1f, tween(240, easing = LinearEasing))
    }
    val geometryMoves = !reduceMotion
    val blurDensity = LocalDensity.current
    val blurUnit = VoiceAuroraOrbSize / ORB_CANVAS
    val glowOutset = orbGlowOutset(VoiceAuroraOrbSize)

    Box(
        modifier = modifier
            .size(VoiceAuroraOrbSize)
            .graphicsLayer {
                clock.frame.longValue
                val e = clock.energy
                val s = clock.scale
                scaleX = s
                scaleY = s
                val look = orbLook(mode, e, clock.level, dark, reduceMotion)
                val p = shake.value
                if (reduceMotion) {
                    alpha = look.alpha * shakeAlpha(p)
                } else {
                    alpha = look.alpha
                    translationX = shakeOffsetDp(p) * density
                }
            },
    ) {
        // Outer glow: three circles, first three colors, sigma 22, group alpha; the draw area extends 3 sigma beyond the box, parent does not clip.
        Canvas(
            modifier = Modifier
                .matchParentSize()
                .outset(glowOutset)
                .graphicsLayer {
                    clock.frame.longValue
                    alpha = orbLook(mode, clock.energy, clock.level, dark, reduceMotion).glowAlpha
                }
                .softBlur(blur, blurUnit * ORB_GLOW_SIGMA, blurDensity),
        ) {
            clock.frame.longValue
            val space = OrbSpace(size, box = size.minDimension - 2f * glowOutset.toPx())
            val palette = orbPalette(clock.aiMix)
            val e = if (geometryMoves) clock.energy else 0f
            val p = clock.phase
            val filter = desaturate(orbLook(mode, e, clock.level, dark, reduceMotion).saturation)
            for (i in 0 until 3) {
                val a = 0.7f * p + 2.1f * i
                val c = space.at(100f + 18f * cos(a), 108f + 14f * sin(a))
                softCircle(palette.blobs[i], 1f, c, (58f + 16f * e) * space.u, blur, filter)
            }
        }
        // Base color: radial (36%,30%) r78%, clipped to the circle.
        Canvas(modifier = Modifier.matchParentSize().clip(OrbBodyShape)) {
            clock.frame.longValue
            val space = OrbSpace(size)
            val palette = orbPalette(clock.aiMix)
            val filter = if (mode == VoiceOrbMode.Muted) desaturate(0.15f) else null
            val box = 100f - CANVAS_RADIUS
            drawCircle(
                brush = Brush.radialGradient(
                    0f to palette.base[0],
                    0.55f to palette.base[1],
                    1f to palette.base[2],
                    center = space.at(box + 0.36f * CANVAS_DIAMETER, box + 0.30f * CANVAS_DIAMETER),
                    radius = 0.78f * CANVAS_DIAMETER * space.u,
                ),
                radius = CANVAS_RADIUS * space.u,
                center = space.at(100f, 100f),
                colorFilter = filter,
            )
        }
        // Four color blobs + bottom reflection: sigma 14, clipped to the circle.
        Canvas(
            modifier = Modifier
                .matchParentSize()
                .clip(OrbBodyShape)
                .softBlur(blur, blurUnit * ORB_BLOB_SIGMA, blurDensity),
        ) {
            clock.frame.longValue
            val space = OrbSpace(size)
            val palette = orbPalette(clock.aiMix)
            val e = if (geometryMoves) clock.energy else 0f
            val p = clock.phase
            val filter = desaturate(orbLook(mode, e, clock.level, dark, reduceMotion).saturation)
            for (i in 0 until 4) {
                val a = p * (0.9f + 0.25f * i) + i * (PI.toFloat() / 2f)
                val spread = 1f + 0.25f * e
                val c = space.at(100f + 30f * cos(a) * spread, 100f + 25.5f * sin(1.3f * a) * spread)
                val r = (40f + 12f * e + 3f * sin(2f * p + i)) * space.u
                softCircle(palette.blobs[i], 0.85f, c, r, blur, filter)
            }
            val reflection = space.at(OrbReflection.cx, OrbReflection.cy)
            ellipse(reflection, OrbReflection.rx * space.u, OrbReflection.ry * space.u) { radius ->
                softCircle(palette.reflection, 0.45f, reflection, radius, blur, filter)
            }
        }
        // Highlight and stroke (not blurred).
        Canvas(modifier = Modifier.matchParentSize()) {
            val space = OrbSpace(size)
            val highlight = space.at(OrbHighlight.cx, OrbHighlight.cy)
            ellipse(highlight, OrbHighlight.rx * space.u, OrbHighlight.ry * space.u) { radius ->
                drawCircle(
                    brush = Brush.radialGradient(
                        listOf(Color.White.copy(alpha = 0.42f), Color.White.copy(alpha = 0f)),
                        center = highlight,
                        radius = radius,
                    ),
                    radius = radius,
                    center = highlight,
                )
            }
            val rim = orbRim(space.u)
            val r = rim.radius
            val c = space.at(100f, 100f)
            drawCircle(
                brush = Brush.linearGradient(
                    0f to Color.White.copy(alpha = 0.55f),
                    0.5f to Color.White.copy(alpha = 0.05f),
                    1f to Color.White.copy(alpha = 0.18f),
                    start = Offset(c.x - r, c.y - r),
                    end = Offset(c.x + r, c.y + r),
                ),
                radius = r,
                center = c,
                style = Stroke(width = rim.width),
            )
        }
    }
}

/** Extend the draw area by [by] on each side (measured against the parent constraint, centered with overflow); it itself still occupies the parent-constraint size. */
private fun Modifier.outset(by: Dp): Modifier = layout { measurable, constraints ->
    val px = by.roundToPx()
    val w = constraints.minWidth
    val h = constraints.minHeight
    val placeable = measurable.measure(Constraints.fixed(w + 2 * px, h + 2 * px))
    layout(w, h) { placeable.place(-px, -px) }
}

/** Vertical span of the fog container (relative to panel top): bottom = panel height + distance from panel bottom to window bottom + [FogBelow], top = bottom − [FogHeight]. */
internal data class FogSpan(val top: Dp, val bottom: Dp)

internal fun fogFrame(panelH: Dp, bottomGap: Dp): FogSpan {
    val bottom = panelH + bottomGap + FogBelow
    return FogSpan(top = bottom - FogHeight, bottom = bottom)
}

/**
 * Fog container: width = panel + 2 x [FogBleedX] (shifted left by [FogBleedX]), height [FogHeight], bottom edge anchored at the window bottom plus [FogBelow] (see [fogFrame]);
 * [bottomGap] is the pixel distance from panel bottom to window bottom, read at layout time; the container itself still occupies the panel size, and the whole container overflows without clipping.
 */
private fun Modifier.fogFrame(bottomGap: () -> Int): Modifier = layout { measurable, constraints ->
    val panelW = constraints.maxWidth
    val panelH = if (constraints.hasBoundedHeight) constraints.maxHeight else constraints.minHeight
    val bleed = FogBleedX.roundToPx()
    val height = FogHeight.roundToPx()
    val placeable = measurable.measure(Constraints.fixed(panelW + 2 * bleed, height))
    val span = fogFrame(panelH.toDp(), bottomGap().coerceAtLeast(0).toDp())
    layout(panelW, panelH) { placeable.place(-bleed, span.bottom.roundToPx() - height) }
}

/** Draw area of one fog blob: edge length [extent], centered in the container ([centerX] relative to panel left edge, [centerY]), scaled from container width to panel width. */
private fun Modifier.fogLayer(extent: Dp, center: (panelWidth: Dp) -> Pair<Dp, Dp>): Modifier =
    layout { measurable, constraints ->
        val side = extent.roundToPx()
        val placeable = measurable.measure(Constraints.fixed(side, side))
        val panelWidth = (constraints.maxWidth - 2 * FogBleedX.roundToPx()).coerceAtLeast(0).toDp()
        val (x, y) = center(panelWidth)
        layout(constraints.minWidth, constraints.minHeight) {
            placeable.place((FogBleedX + x).roundToPx() - side / 2, y.roundToPx() - side / 2)
        }
    }

/**
 * Aurora fog: see [fogFrame] for the container; circle centers use canvas coordinates for a 390 dp panel, x scaled with panel width; circles 1 and 2 drift horizontally ±20 dp in opposite directions.
 * Each blob has its own layer, with draw area = diameter plus 3 sigma margin on each side ([fogLayerSize]); each blob draws a radial gradient of a precomputed "disc ⊛ Gaussian" profile
 * ([drawFogDisc]), no per-frame blur, same drawing in both sdks. Blobs are stacked with source-over after forming independently, equivalent to blurring each blob.
 * [notice] (didn't catch / language hint) keeps only circle 1 plus amber circle 2.
 */
@Composable
internal fun VoiceAuroraFog(
    mode: VoiceOrbMode,
    level: StateFlow<Float>?,
    notice: Boolean,
    modifier: Modifier = Modifier,
    /** Pixel distance from panel bottom to window bottom (read at layout); 0 = panel bottom is the window bottom. */
    bottomGap: () -> Int = { 0 },
    @VisibleForTesting onComposed: ((VoiceFogPaint) -> Unit)? = null,
) {
    if (onComposed != null) SideEffect { onComposed(VoiceFogPaint.DiscGradient) }
    val context = LocalContext.current
    val stageClock = LocalVoiceStageClockOverride.current
    val reduceMotion = remember(context, stageClock) { stageReduceMotion(stageClock, isReduceMotionEnabled(context)) }
    val dark = OriveoTheme.isDark
    val clock = rememberAuroraClock(mode, level, reduceMotion, FOG_FRAME_INTERVAL_NANOS, notice, followsLevel = false)
    // Structure (number of circles, sizes, positions) changes only with notice / mode; alpha, color, sigma and drift are read per frame during draw, no per-frame list allocation.
    val layers = remember(mode, dark, notice) { fogCircles(mode, 0f, dark, notice) }

    Box(modifier = modifier.fogFrame(bottomGap).testTag(VOICE_FOG_TAG)) {
        layers.forEachIndexed { index, layer ->
            val brushes = remember { FogBrushCache() }
            Canvas(
                modifier = Modifier
                    .matchParentSize()
                    .fogLayer(fogLayerSize(layer)) { panelWidth -> fogCenter(index, panelWidth) }
                    .graphicsLayer {
                        clock.frame.longValue
                        translationX = layer.drift * 20.dp.toPx() * sin(clock.tMs / 2600.0).toFloat()
                    },
            ) {
                clock.frame.longValue
                val noticeMix = clock.noticeMix
                drawFogDisc(
                    cache = brushes,
                    color = fogCircleColor(index, clock.aiMix, noticeMix),
                    alpha = fogCircleAlpha(mode, clock.targetEnergy, dark, index, noticeMix).coerceIn(0f, 1f),
                    diameter = layer.diameter,
                    sigma = fogCircleSigma(index, noticeMix),
                )
            }
        }
    }
}
