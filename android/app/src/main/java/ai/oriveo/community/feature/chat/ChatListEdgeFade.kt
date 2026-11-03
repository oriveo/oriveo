package ai.oriveo.community.feature.chat

import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer

/**
 * Edge fade mask for the chat message list: instead of painting the page background over the list, it fades the list content itself by alpha (DstIn),
 * so the page background (shared background / aurora / stage base color) runs continuously to the bottom of the screen. Only the list is masked, not the composer, capsules or stage.
 *
 * Two tiers:
 * - composer tier (always on): fully visible at >= [ComposerFadeEndDp] above the composer top, fully hidden at <= [ComposerFadeStartDp], smoothstep in between;
 * - stage tier (blended in by the stage entrance progress [stage]): within the top [StageTopFraction] of the visible area (minus the bottom overlay), smoothstep from 0 to 1.
 */
internal object ChatListEdgeFade {
    const val ComposerFadeStartDp = 4f
    const val ComposerFadeEndDp = 40f
    const val StageTopFraction = 0.3f

    /** Samples per gradient segment: smoothstep is approximated piecewise-linearly; 8 segments differ from the exact curve by under 1%. */
    private const val SEGMENTS = 8

    fun smoothstep(edge0: Float, edge1: Float, x: Float): Float {
        val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
        return t * t * (3f - 2f * t)
    }

    /** composer tier: [distanceAboveComposerTopDp] is the distance from the content point to the composer top (dp, positive above the top). */
    fun composerAlpha(distanceAboveComposerTopDp: Float): Float =
        smoothstep(ComposerFadeStartDp, ComposerFadeEndDp, distanceAboveComposerTopDp)

    /** Stage tier: [fractionOfVisible] is the content point's top-to-bottom proportion within the visible area. */
    fun stageTopAlpha(fractionOfVisible: Float): Float = smoothstep(0f, StageTopFraction, fractionOfVisible)

    /**
     * Mask opacity at [y] (px) within the list. [heightPx] is the list height, [overlayPx] the bottom overlay (composer / stage) height,
     * [density] px/dp, and [stage] the stage entrance progress, 0..1.
     */
    fun maskAlphaAt(y: Float, heightPx: Float, overlayPx: Float, density: Float, stage: Float): Float {
        val visible = (heightPx - overlayPx).coerceAtLeast(1f)
        val bottom = composerAlpha((visible - y) / density)
        val s = stage.coerceIn(0f, 1f)
        val top = if (s <= 0f) 1f else 1f + (stageTopAlpha(y / visible) - 1f) * s
        return bottom * top
    }

    /** Vertical gradient color stops of the mask: each transition zone of the two tiers is sampled at [SEGMENTS] segments; the rest are flat segments. */
    internal fun maskStops(heightPx: Float, overlayPx: Float, density: Float, stage: Float): Array<Pair<Float, Color>> {
        val h = heightPx.coerceAtLeast(1f)
        val visible = (h - overlayPx).coerceAtLeast(1f)
        val ys = ArrayList<Float>(2 * SEGMENTS + 4)
        ys += 0f
        if (stage > 0f) {
            val end = visible * StageTopFraction
            for (i in 1..SEGMENTS) ys += end * i / SEGMENTS
        }
        val fadeTop = visible - ComposerFadeEndDp * density
        val fadeBottom = visible - ComposerFadeStartDp * density
        for (i in 0..SEGMENTS) ys += fadeTop + (fadeBottom - fadeTop) * i / SEGMENTS
        ys += h
        return ys.asSequence()
            .map { it.coerceIn(0f, h) }
            .distinct()
            .sorted()
            .map { y -> (y / h) to Color.Black.copy(alpha = maskAlphaAt(y, h, overlayPx, density, stage)) }
            .toList()
            .toTypedArray()
    }
}

/**
 * Attaches the edge fade mask to the message list: after offscreen compositing, multiplies by the vertical gradient from [ChatListEdgeFade.maskStops] using DstIn.
 * Overlay height and stage progress are read in the draw phase (lambdas), so scrolling and stage animation do not trigger recomposition.
 */
internal fun Modifier.chatListEdgeFade(overlayHeightPx: () -> Int, stage: () -> Float): Modifier = this
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithCache {
        val stops = ChatListEdgeFade.maskStops(size.height, overlayHeightPx().toFloat(), density, stage())
        val brush = Brush.verticalGradient(colorStops = stops, startY = 0f, endY = size.height)
        onDrawWithContent {
            drawContent()
            drawRect(brush = brush, blendMode = BlendMode.DstIn)
        }
    }
