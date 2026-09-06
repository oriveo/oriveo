package ai.oriveo.community.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun OriveoFadeHairline(
    modifier: Modifier = Modifier,
    insetLeading: Dp = 0.dp,
    insetTrailing: Dp = 0.dp,
) {
    val isDark = OriveoTheme.isDark
    val lineColor = if (isDark) {
        Color.White.copy(alpha = 0.08f)
    } else {
        OriveoTheme.colors.textPrimary.copy(alpha = 0.08f)
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = insetLeading, end = insetTrailing)
            .height(1.dp)
            .background(
                brush = Brush.horizontalGradient(
                    colors = listOf(
                        Color.Transparent,
                        lineColor,
                        lineColor,
                        Color.Transparent,
                    ),
                ),
            ),
    )
}
