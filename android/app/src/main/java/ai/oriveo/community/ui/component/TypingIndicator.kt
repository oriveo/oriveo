package ai.oriveo.community.ui.component

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun TypingIndicator(
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val dotColor = colors.primary.copy(alpha = 0.75f)
    val shadowColor = colors.primary.copy(alpha = 0.30f)

    Row(
        modifier = modifier.padding(vertical = OriveoTheme.spacing.xs),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        repeat(3) { index ->
            AnimatedDot(
                index = index,
                dotColor = dotColor,
                shadowColor = shadowColor,
            )
        }

        Text(
            text = stringResource(R.string.generating),
            style = OriveoTheme.typography.footnote,
            color = colors.textSecondary,
        )
    }
}

@Composable
private fun AnimatedDot(
    index: Int,
    dotColor: androidx.compose.ui.graphics.Color,
    shadowColor: androidx.compose.ui.graphics.Color,
) {
    val transition = rememberInfiniteTransition(label = "dot$index")

    val scale by transition.animateFloat(
        initialValue = 0.72f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = 600,
                delayMillis = index * 150,
            ),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "dotScale$index",
    )

    val offsetY by transition.animateFloat(
        initialValue = -4f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = 600,
                delayMillis = index * 150,
            ),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "dotOffsetY$index",
    )

    Box(
        modifier = Modifier
            .size(6.dp)

            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                translationY = offsetY.dp.toPx()
            }
            .shadow(4.dp, CircleShape, ambientColor = shadowColor, spotColor = shadowColor)
            .background(dotColor, CircleShape),
    )
}
