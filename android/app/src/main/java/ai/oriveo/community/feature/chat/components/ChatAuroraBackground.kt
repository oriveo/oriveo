package ai.oriveo.community.feature.chat.components

import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.CacheDrawScope
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Ambient background for the empty-chat state: a glow rising from the bottom plus a
 * halftone dot field that gathers at the top and bottom edges, leaving the middle
 * clear for the logo and greeting so content reads as floating on still light.
 * Each theme gets its own treatment:
 * - Dark: purple + magenta neon glow (screen blending makes it read as "lit") with
 *   bright lavender dust.
 * - Light: a quieter pass -- faint lavender + cool periwinkle haze + low-saturation
 *   purple flecks.
 *
 * Performance (steady-state zero frames, reworked after profiling on real devices):
 * - Dots and glow are computed once inside [drawWithCache], keyed only on size/theme,
 *   and cached onto a GPU layer.
 * - The whole layer uses `CompositingStrategy.Offscreen` so dark-mode `BlendMode.Screen`
 *   only affects this layer's own compositing.
 * - No perpetual breathing animation: only a one-time entrance settle (1.03 -> 1.0)
 *   plus a fade-in; once that finishes there are no further frame requests.
 *   An earlier `rememberInfiniteTransition` breathing effect looked like it only
 *   rescaled an already-cached layer, but an Offscreen layer has to recomposite a
 *   full-screen buffer and call `eglSwapBuffers` every single frame -- on device this
 *   pinned an idle chat screen at ~120fps and 79.7% of one CPU core (0.2% with it off).
 * - When reduce-motion is on, even the entrance settle is skipped.
 *
 * `Modifier.blur` requires API 31+ (minSdk here is 26), so no blur is used -- the
 * radial gradients and dot field are soft enough without it.
 *
 * @param prominent full intensity for the empty state vs. dimmed when messages are
 * present, so it stays ambient and doesn't compete with the content.
 */
@Composable
internal fun ChatAuroraBackground(
    prominent: Boolean,
    modifier: Modifier = Modifier,
) {
    val isDark = OriveoTheme.isDark
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }

    // Overall layer opacity: once appeared, 1.0 for the empty state or 0.4 otherwise, eased over ~0.6s.
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }
    val targetAlpha = if (!appeared) 0f else if (prominent) 1f else 0.4f
    val layerAlpha = animateFloatAsState(
        targetValue = targetAlpha,
        animationSpec = tween(durationMillis = 600, easing = EaseInOut),
        label = "auroraAlpha",
    )

    // Entrance settle: scales 1.03 -> 1.0 once, in sync with the fade-in, coming to rest
    // after ~0.7s -- not a perpetual breathing loop.
    // Only shrinks inward (starts >= 1.0): the layer is never smaller than full-bleed
    // mid-animation, so no blank edge shows above/below where the aurora hasn't reached.
    val layerScale = animateFloatAsState(
        targetValue = if (appeared || reduceMotion) 1f else 1.03f,
        animationSpec = tween(durationMillis = 700, easing = EaseInOut),
        label = "auroraSettle",
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .graphicsLayer {
                // Reading State inside the lambda invalidates only the draw/layer phase,
                // not recomposition, so the dot field isn't recomputed.
                val s = layerScale.value
                scaleX = s
                scaleY = s
                alpha = layerAlpha.value
                compositingStrategy = CompositingStrategy.Offscreen
            },
    ) {
        Spacer(
            modifier = Modifier
                .fillMaxSize()
                .drawWithCache {
                    // Recomputed only when size/theme change (and cached); the settle
                    // animation never re-enters this block.
                    val dots = computeAuroraDots(size, isDark)
                    onDrawBehind {
                        drawAuroraGlow(isDark)
                        dots.forEach { dot ->
                            drawCircle(color = dot.color, radius = dot.radius, center = dot.center)
                        }
                    }
                },
        )
    }
}

// Glow layer: primary glow at the bottom, secondary glow upper-left, faint echo at the top

private fun DrawScope.drawAuroraGlow(isDark: Boolean) {
    val w = size.width
    val h = size.height
    val maxDim = max(w, h)
    val purple = Color(0xFF8C5FF8)

    // Primary glow
    val primaryGlow = purple.copy(alpha = if (isDark) 0.30f else 0.11f)
    drawRect(
        brush = Brush.radialGradient(
            colors = listOf(primaryGlow, Color.Transparent),
            center = Offset(w * 0.5f, h * 0.86f),
            radius = maxDim * if (isDark) 0.95f else 0.82f,
        ),
    )

    // Secondary glow: magenta in dark mode (lit via screen blending), cool periwinkle in light mode
    val accentGlow = if (isDark) Color(0xFFC65BF0).copy(alpha = 0.22f) else Color(0xFF6366F1).copy(alpha = 0.075f)
    drawRect(
        brush = Brush.radialGradient(
            colors = listOf(accentGlow, Color.Transparent),
            center = Offset(w * 0.32f, h * 0.80f),
            radius = maxDim * if (isDark) 0.66f else 0.58f,
        ),
        blendMode = if (isDark) BlendMode.Screen else BlendMode.SrcOver,
    )

    // Faint top glow so the dots gathered near the top edge have something to sit on
    val topGlow = if (isDark) Color(0xFF7C5BEE).copy(alpha = 0.16f) else purple.copy(alpha = 0.05f)
    drawRect(
        brush = Brush.radialGradient(
            colors = listOf(topGlow, Color.Transparent),
            center = Offset(w * 0.5f, h * 0.06f),
            radius = maxDim * 0.55f,
        ),
        blendMode = if (isDark) BlendMode.Screen else BlendMode.SrcOver,
    )
}

// Halftone dot field (static: gathers at top and bottom, clear in the middle)

private class AuroraDot(val center: Offset, val radius: Float, val color: Color)

private fun CacheDrawScope.computeAuroraDots(size: Size, isDark: Boolean): List<AuroraDot> {
    if (size.width <= 0f || size.height <= 0f) return emptyList()

    val spacing = 15.dp.toPx()
    val dotMaxRadius = (if (isDark) 2.7f else 2.3f).dp.toPx()
    val dotMaxAlpha = if (isDark) 0.55f else 0.26f
    val verticalScale = 1.4f // vertical compression flattens the dot field into arcs hugging the top/bottom edges
    val maxDim = max(size.width, size.height)
    val base = if (isDark) Color(0xFFC9B6FF) else Color(0xFF8C5FF8)

    // Two focal points: bottom is dominant (near the input area), top is a faint echo;
    // the middle (text area) sits far from both, so it stays naturally clear.
    val bottomFocal = Offset(size.width * 0.5f, size.height * 0.90f)
    val topFocal = Offset(size.width * 0.5f, size.height * 0.07f)
    val bottomEnvelopeR = maxDim * 0.72f
    val topEnvelopeR = maxDim * 0.58f
    val topWeight = 0.85f // slightly weaker than the bottom focal point, but still clearly visible

    val dots = ArrayList<AuroraDot>()
    var y = 0f
    var rowIndex = 0
    while (y <= size.height) {
        val xOffset = if (rowIndex % 2 == 0) 0f else spacing / 2f // staggered like a hex grid
        var x = xOffset
        while (x <= size.width) {
            val bIntensity = auroraEnvelope(x, y, bottomFocal, bottomEnvelopeR, verticalScale)
            val tIntensity = auroraEnvelope(x, y, topFocal, topEnvelopeR, verticalScale) * topWeight
            val intensity = max(bIntensity, tIntensity)
            if (intensity > 0.02f) {
                val radius = dotMaxRadius * intensity
                dots.add(AuroraDot(Offset(x, y), radius, base.copy(alpha = intensity * dotMaxAlpha)))
            }
            x += spacing
        }
        y += spacing
        rowIndex++
    }
    return dots
}

/** Elliptical distance falloff from a focal point, squared for a softer edge; returns 0..1. */
private fun auroraEnvelope(x: Float, y: Float, focal: Offset, radius: Float, verticalScale: Float): Float {
    val dx = x - focal.x
    val dy = (y - focal.y) * verticalScale
    val distance = sqrt(dx * dx + dy * dy)
    val t = max(0f, 1f - distance / radius)
    return t * t
}
