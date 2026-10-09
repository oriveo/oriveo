package ai.oriveo.community.ui.component

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
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

/**
 * Not built with `Modifier.composed {}` on purpose: `composed` allocates a new modifier that captures a
 * lambda and has no `equals`, so two recompositions never produce equal chains. The full-screen
 * `LazyColumn` this modifier is attached to could then never skip recomposition, and the modifier node
 * diff lost its reuse fast path. Returning the same remembered instance while the inputs are unchanged
 * keeps the chain structurally equal.
 */
@Composable
fun Modifier.oriveoSystemBarFadingEdges(
    topInset: Dp,
    bottomInset: Dp,
    fadeLength: Dp = OriveoSystemBarFadeLength,
): Modifier {
    val density = LocalDensity.current
    val topInsetPx = with(density) { topInset.toPx() }
    val bottomInsetPx = with(density) { bottomInset.toPx() }
    val fadePx = with(density) { fadeLength.toPx() }

    // The key is the three pixel values, which cover every input: the three Dp parameters and the
    // density. A change in any of them rebuilds the modifier.
    val fadingEdges = remember(topInsetPx, bottomInsetPx, fadePx) {
        Modifier
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

    return this.then(fadingEdges)
}
