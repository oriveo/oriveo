package ai.oriveo.community.feature.chat.composer

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp


@Composable
internal fun ComposerAnimatedAiBorder(
    cornerRadius: Dp,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier.drawWithCache {
            
            val center = Offset(size.width / 2f, size.height / 2f)
            val brush = Brush.sweepGradient(*rotatedSweepStops(STATIC_PHASE), center = center)
            val strokeWidthPx = 1.8.dp.toPx()
            val crPx = cornerRadius.toPx()
            onDrawBehind {
                
                
                
                strokeRing(brush = brush, strokeWidthPx = strokeWidthPx, cornerRadiusPx = crPx, layerAlpha = 1f)
            }
        },
    )
}


private const val STATIC_PHASE = 24f / 360f


private fun DrawScope.strokeRing(brush: Brush, strokeWidthPx: Float, cornerRadiusPx: Float, layerAlpha: Float) {
    val inset = strokeWidthPx / 2f
    drawRoundRect(
        brush = brush,
        topLeft = Offset(inset, inset),
        size = Size(size.width - strokeWidthPx, size.height - strokeWidthPx),
        cornerRadius = CornerRadius((cornerRadiusPx - inset).coerceAtLeast(0f)),
        style = Stroke(width = strokeWidthPx),
        alpha = layerAlpha,
    )
}


private fun rotatedSweepStops(phase: Float): Array<Pair<Float, Color>> {
    val steps = 18
    return Array(steps + 1) { j ->
        val t = j.toFloat() / steps
        t to baseColorAt(t - phase)
    }
}


private fun baseColorAt(x: Float): Color {
    val segments = AI_BORDER_COLORS.size - 1
    val pos = x.mod(1f) * segments
    val i = pos.toInt().coerceIn(0, segments - 1)
    val frac = pos - i
    return lerp(AI_BORDER_COLORS[i], AI_BORDER_COLORS[i + 1], frac)
}


private val AI_BORDER_COLORS = listOf(
    Color(0xFF6E8BFF),
    Color(0xFF9B6BFF),
    Color(0xFFE06BC4),
    Color(0xFFFFB36B),
    Color(0xFF66E0B8),
    Color(0xFF6E8BFF),
)
