package ai.oriveo.community.ui.component

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun OriveoIconPlate(
    modifier: Modifier = Modifier,
    size: Dp = 40.dp,
    cornerRadius: Dp = 11.dp,
    content: @Composable BoxScope.() -> Unit,
) {
    val isDark = OriveoTheme.isDark
    val colors = OriveoTheme.colors
    val shape = RoundedCornerShape(cornerRadius)

    val fillColors = if (isDark) {
        listOf(blend(Color.White, colors.surface, 0.06f), colors.surface)
    } else {
        listOf(blend(Color.White, colors.surface, 0.35f), colors.surface)
    }
    val borderBrush = if (isDark) {
        Brush.verticalGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.14f),
                Color.White.copy(alpha = 0.05f),
                Color.Black.copy(alpha = 0.30f),
            ),
        )
    } else {
        Brush.verticalGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.85f),
                colors.textPrimary.copy(alpha = 0.06f),
                colors.textPrimary.copy(alpha = 0.12f),
            ),
        )
    }
    val highlightAlpha = if (isDark) 0.08f else 0.7f
    val shadowAlpha = if (isDark) 0.7f else 0.12f
    val shadowElevation = if (isDark) 1.5.dp else 0.8.dp
    val shadowColor = colors.shadow.copy(alpha = colors.shadow.alpha * shadowAlpha)

    Box(
        modifier = modifier
            .size(size)
            .shadow(
                elevation = shadowElevation,
                shape = shape,
                clip = false,
                ambientColor = shadowColor,
                spotColor = shadowColor,
            )
            .clip(shape)
            .background(brush = Brush.verticalGradient(fillColors), shape = shape)
            .border(border = BorderStroke(1.dp, borderBrush), shape = shape),
        contentAlignment = Alignment.Center,
    ) {

        Canvas(modifier = Modifier.fillMaxSize()) {
            val inset = 1.dp.toPx()
            drawRect(
                color = Color.White.copy(alpha = highlightAlpha),
                topLeft = Offset(inset, 0f),
                size = Size(this.size.width - inset * 2, 1.dp.toPx()),
            )
        }
        content()
    }
}

internal fun blend(a: Color, b: Color, ratio: Float): Color = lerp(b, a, ratio)
