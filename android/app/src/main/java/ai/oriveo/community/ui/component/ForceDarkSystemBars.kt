package ai.oriveo.community.ui.component

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import ai.oriveo.community.ui.util.findActivity


@Composable
fun ForceDarkSystemBars(windowBackground: Color = DarkSurfaceBackground) {
    val view = LocalView.current
    val isSystemDark = isSystemInDarkTheme()
    val hostWindow = remember(view) {
        (view.parent as? DialogWindowProvider)?.window ?: view.context.findActivity()?.window
    }

    if (view.isInEditMode || hostWindow == null) return

    DisposableEffect(view, isSystemDark, hostWindow, windowBackground) {
        val controller = WindowCompat.getInsetsController(hostWindow, view)
        val previousLightStatusBars = controller.isAppearanceLightStatusBars
        val previousLightNavigationBars = controller.isAppearanceLightNavigationBars

        controller.isAppearanceLightStatusBars = false
        controller.isAppearanceLightNavigationBars = false
        hostWindow.decorView.setBackgroundColor(windowBackground.toArgb())

        onDispose {
            controller.isAppearanceLightStatusBars = previousLightStatusBars
            controller.isAppearanceLightNavigationBars = previousLightNavigationBars
            hostWindow.decorView.setBackgroundColor(
                if (isSystemDark) ThemeWindowBackgroundDark.toArgb()
                else ThemeWindowBackgroundLight.toArgb(),
            )
        }
    }
}


val DarkSurfaceBackground = Color(0xFF0B0A14)


private val ThemeWindowBackgroundDark = Color(0xFF090E1B)
private val ThemeWindowBackgroundLight = Color(0xFFF6F5FA)
