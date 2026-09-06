package ai.oriveo.community.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun ProvidersScreenBackground(modifier: Modifier = Modifier) {
    val isDark = OriveoTheme.isDark
    val colors = OriveoTheme.colors
    val density = LocalDensity.current

    val baseBrush = if (isDark) {
        Brush.verticalGradient(
            colors = listOf(
                colors.backgroundBase,
                colors.background,
                colors.backgroundSecondary,
            ),
        )
    } else {

        Brush.verticalGradient(
            colors = listOf(
                Color(0xFFFDFCFF),
                Color(0xFFFAF7FE),
                Color(0xFFF5EFFA),
            ),
        )
    }

    val topGlowAlpha = if (isDark) 0.06f else 0.10f
    val topGlowSize = if (isDark) 600.dp else 580.dp
    val topGlowRadius = if (isDark) 400.dp else 440.dp
    val topGlowOffsetY = if (isDark) (-400).dp else (-360).dp

    val bottomGlowAlpha = if (isDark) 0.05f else 0.08f
    val bottomGlowSize = if (isDark) 560.dp else 540.dp
    val bottomGlowRadius = if (isDark) 380.dp else 420.dp
    val bottomGlowOffsetY = if (isDark) 360.dp else 330.dp

    Box(modifier = modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(baseBrush),
        )

        Box(
            modifier = Modifier
                .size(topGlowSize)
                .offset(y = topGlowOffsetY)
                .align(Alignment.TopCenter)
                .background(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            colors.primary.copy(alpha = topGlowAlpha),
                            Color.Transparent,
                        ),
                        radius = with(density) { topGlowRadius.toPx() },
                    ),
                    shape = CircleShape,
                ),
        )

        Box(
            modifier = Modifier
                .size(bottomGlowSize)
                .offset(y = bottomGlowOffsetY)
                .align(Alignment.BottomCenter)
                .background(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            colors.primary.copy(alpha = bottomGlowAlpha),
                            Color.Transparent,
                        ),
                        radius = with(density) { bottomGlowRadius.toPx() },
                    ),
                    shape = CircleShape,
                ),
        )
    }
}
