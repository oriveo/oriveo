package ai.oriveo.community.ui.theme

import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

object OriveoSpacing {
    val xs: Dp = 4.dp
    val s6: Dp = 6.dp
    val sm: Dp = 8.dp
    val md: Dp = 12.dp
    val lg: Dp = 16.dp
    val s20: Dp = 20.dp
    val xl: Dp = 24.dp
    val xxl: Dp = 32.dp
}

internal fun densityScaleFactor(screenWidthDp: Int): Float {
    if (screenWidthDp >= 393) return 1f
    return (screenWidthDp / 393f).coerceAtLeast(0.92f)
}

object OriveoLayout {

    private val adjustedWidthDp: Int
        @Composable get() {
            val raw = LocalConfiguration.current.screenWidthDp
            val factor = densityScaleFactor(raw)
            return if (factor < 1f) (raw / factor).toInt() else raw
        }

    val isCompact: Boolean
        @Composable get() = adjustedWidthDp < 380

    val screenH: Dp
        @Composable get() = when {
            adjustedWidthDp < 380 -> 16.dp
            adjustedWidthDp < 412 -> 20.dp
            else -> 24.dp
        }

    val screenTop: Dp
        @Composable get() = screenH

    val sectionGap: Dp
        @Composable get() = if (isCompact) 20.dp else 24.dp

    val cardPadding: Dp
        @Composable get() = if (isCompact) 14.dp else 16.dp

    val cardRowGap: Dp
        @Composable get() = if (isCompact) 14.dp else 16.dp

    val tabBarOverlay: Dp
        @Composable get() = if (isCompact) 68.dp else 80.dp

    val buttonHeight: Dp
        @Composable get() = if (isCompact) 44.dp else 48.dp
}

object OriveoRadius {
    val sm: Dp = 8.dp
    val md: Dp = 12.dp
    val lg: Dp = 16.dp
    val full: Dp = 999.dp

    val hero: Dp = 24.dp
    val card: Dp = 20.dp
    val inset: Dp = 16.dp
    val chip: Dp = 10.dp

    val smShape: Shape = RoundedCornerShape(sm)
    val mdShape: Shape = RoundedCornerShape(md)
    val lgShape: Shape = RoundedCornerShape(lg)
    val fullShape: Shape = CircleShape
}

object OriveoBorderWidth {

    val standard: Dp = 0.5.dp

    val fine: Dp = 0.33.dp
}
