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
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.LocalIsDarkTheme
import ai.oriveo.community.ui.theme.LocalOriveoColors
import ai.oriveo.community.ui.util.findActivity

@Composable
fun ForceDarkSystemBars(windowBackground: Color = DarkSurfaceBackground) {
    val view = LocalView.current
    val isSystemDark = isSystemInDarkTheme()
    // The dark restore value = the OriveoTheme window background (current palette bg); when the app is in light it takes the bg of the default dark palette
    val themeWindowBackgroundDark = if (LocalIsDarkTheme.current) {
        LocalOriveoColors.current.backgroundBase
    } else {
        DarkPaletteId.Default.colors.backgroundBase
    }
    val hostWindow = remember(view) {
        (view.parent as? DialogWindowProvider)?.window ?: view.context.findActivity()?.window
    }

    if (view.isInEditMode || hostWindow == null) return

    DisposableEffect(view, isSystemDark, hostWindow, windowBackground, themeWindowBackgroundDark) {
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
                if (isSystemDark) themeWindowBackgroundDark.toArgb()
                else ThemeWindowBackgroundLight.toArgb(),
            )
        }
    }
}

val DarkSurfaceBackground = Color(0xFF0B0A14)

// The light restore value matches the light window background in OriveoTheme; keep them in sync.
private val ThemeWindowBackgroundLight = Color(0xFFF6F5FA)
