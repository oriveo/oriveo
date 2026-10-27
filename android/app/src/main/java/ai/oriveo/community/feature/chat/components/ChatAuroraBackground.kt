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
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.aurora
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Ambient background for the empty-chat state: a glow rising from the bottom plus a
 * halftone dot field that gathers at the top and bottom edges, leaving the middle
 * clear for the logo and greeting so content reads as floating on still light.
 * Each theme gets its own treatment:
 * - Dark: the current palette's primary + accent glow (the aurora formula times glowK; screen
 *   blending makes it read as "lit") with accent dust.
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
    val colors = OriveoTheme.colors
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
                    val dots = computeAuroraDots(size, isDark, colors.accent)
                    val glowLayers = chatAuroraGlowLayers(colors, isDark)
                    onDrawBehind {
                        drawAuroraGlow(glowLayers)
                        dots.forEach { dot ->
                            drawCircle(color = dot.color, radius = dot.radius, center = dot.center)
                        }
                    }
                },
        )
    }
}

// Glow layers
//
// In dark the layers follow the current palette via the aurora formula (alpha already multiplied by glowK):
// primary at the bottom, accent at the bottom-left, primary at the bottom-right, accent at the top, so
// switching palettes takes effect immediately. Light keeps the original three layers (main glow / cool
// periwinkle secondary / faint top glow), pixel for pixel unchanged.

/** One radial glow layer: center and radius are given as canvas fractions and converted to pixels at draw time. */
internal data class AuroraGlowLayer(
    val color: Color,
    val centerX: Float,
    val centerY: Float,
    val radiusFraction: Float,
    val blendMode: BlendMode,
)

internal fun chatAuroraGlowLayers(colors: OriveoColors, isDark: Boolean): List<AuroraGlowLayer> {
    if (isDark) {
        val aurora = colors.aurora
        return listOf(
            AuroraGlowLayer(aurora.bottom, 0.5f, 0.86f, 0.95f, BlendMode.SrcOver),
            AuroraGlowLayer(aurora.bottomLeft, 0.28f, 0.82f, 0.66f, BlendMode.Screen),
            AuroraGlowLayer(aurora.bottomRight, 0.74f, 0.84f, 0.62f, BlendMode.Screen),
            AuroraGlowLayer(aurora.top, 0.5f, 0.06f, 0.55f, BlendMode.Screen),
        )
    }
    // dark-palette-guard: keep (d) light branch
    val purple = Color(0xFF8C5FF8)
    return listOf(
        AuroraGlowLayer(purple.copy(alpha = 0.11f), 0.5f, 0.86f, 0.82f, BlendMode.SrcOver),
        AuroraGlowLayer(Color(0xFF6366F1).copy(alpha = 0.075f), 0.32f, 0.80f, 0.58f, BlendMode.SrcOver),
        AuroraGlowLayer(purple.copy(alpha = 0.05f), 0.5f, 0.06f, 0.55f, BlendMode.SrcOver),
    )
}

private fun DrawScope.drawAuroraGlow(layers: List<AuroraGlowLayer>) {
    val w = size.width
    val h = size.height
    val maxDim = max(w, h)
    layers.forEach { layer ->
        drawRect(
            brush = Brush.radialGradient(
                colors = listOf(layer.color, Color.Transparent),
                center = Offset(w * layer.centerX, h * layer.centerY),
                radius = maxDim * layer.radiusFraction,
            ),
            blendMode = layer.blendMode,
        )
    }
}

// Halftone dot field (static: gathers at top and bottom, clear in the middle)

private class AuroraDot(val center: Offset, val radius: Float, val color: Color)

private fun CacheDrawScope.computeAuroraDots(size: Size, isDark: Boolean, darkDotColor: Color): List<AuroraDot> {
    if (size.width <= 0f || size.height <= 0f) return emptyList()

    val spacing = 15.dp.toPx()
    val dotMaxRadius = (if (isDark) 2.7f else 2.3f).dp.toPx()
    val dotMaxAlpha = if (isDark) 0.55f else 0.26f
    val verticalScale = 1.4f // vertical compression flattens the dot field into arcs hugging the top/bottom edges
    val maxDim = max(size.width, size.height)
    // dark-palette-guard: keep (d) light branch
    val base = if (isDark) darkDotColor else Color(0xFF8C5FF8)

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
