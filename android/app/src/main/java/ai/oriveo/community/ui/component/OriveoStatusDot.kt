package ai.oriveo.community.ui.component

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

@Composable
fun OriveoStatusDot(
    color: Color,
    modifier: Modifier = Modifier,
    size: Dp = 7.dp,
    pulsing: Boolean = false,
) {
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }

    val (alpha, scale) = if (pulsing && !reduceMotion) {
        val transition = rememberInfiniteTransition(label = "status-dot-pulse")
        val a = transition.animateFloat(
            initialValue = 1f,
            targetValue = 0.4f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 700, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "alpha",
        ).value
        val s = transition.animateFloat(
            initialValue = 1f,
            targetValue = 0.8f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 700, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "scale",
        ).value
        a to s
    } else {
        1f to 1f
    }

    val totalSize = size + 2.dp

    Box(
        modifier = modifier
            .size(totalSize)
            .graphicsLayer {
                this.alpha = alpha
                scaleX = scale
                scaleY = scale
            },
        contentAlignment = Alignment.Center,
    ) {

        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .blur(0.4.dp),
        ) {
            val cx = this.size.width / 2f
            val cy = this.size.height / 2f
            drawCircle(
                color = color.copy(alpha = 0.18f),
                radius = size.toPx() / 2f,
                center = Offset(cx, cy),
                style = Stroke(width = 2.dp.toPx()),
            )
        }

        Canvas(modifier = Modifier.fillMaxSize()) {
            val cx = this.size.width / 2f
            val cy = this.size.height / 2f
            drawCircle(
                color = color,
                radius = size.toPx() / 2f,
                center = Offset(cx, cy),
            )
        }
    }
}
