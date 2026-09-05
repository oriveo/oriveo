package ai.oriveo.community.ui.component

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isSpecified


val OriveoSystemBarFadeLength: Dp = 20.dp


val LocalRootTabTopInset = compositionLocalOf { Dp.Unspecified }


@Composable
fun rootTabTopInset(): Dp {
    val provided = LocalRootTabTopInset.current
    return if (provided.isSpecified) {
        provided
    } else {
        WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    }
}


fun Modifier.oriveoSystemBarFadingEdges(
    topInset: Dp,
    bottomInset: Dp,
    fadeLength: Dp = OriveoSystemBarFadeLength,
): Modifier = composed {
    val density = LocalDensity.current
    val topInsetPx = with(density) { topInset.toPx() }
    val bottomInsetPx = with(density) { bottomInset.toPx() }
    val fadePx = with(density) { fadeLength.toPx() }

    this
        .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
        .drawWithContent {
            drawContent()

            
            val topBandPx = topInsetPx + fadePx
            if (topBandPx > 0f) {
                drawRect(
                    brush = Brush.verticalGradient(
                        colorStops = arrayOf(
                            0f to Color.Transparent,
                            (topInsetPx / topBandPx).coerceIn(0f, 1f) to Color.Transparent,
                            1f to Color.Black,
                        ),
                        startY = 0f,
                        endY = topBandPx,
                    ),
                    size = Size(size.width, topBandPx),
                    blendMode = BlendMode.DstIn,
                )
            }

            
            
            val bottomBandPx = bottomInsetPx + fadePx
            if (bottomBandPx > 0f) {
                drawRect(
                    brush = Brush.verticalGradient(
                        colorStops = arrayOf(
                            0f to Color.Black,
                            (fadePx / bottomBandPx).coerceIn(0f, 1f) to Color.Transparent,
                            1f to Color.Transparent,
                        ),
                        startY = size.height - bottomBandPx,
                        endY = size.height,
                    ),
                    topLeft = Offset(0f, size.height - bottomBandPx),
                    size = Size(size.width, bottomBandPx),
                    blendMode = BlendMode.DstIn,
                )
            }
        }
}
