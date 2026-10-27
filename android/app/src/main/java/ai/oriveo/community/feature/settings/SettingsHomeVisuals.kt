package ai.oriveo.community.feature.settings

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoTheme

/** Elliptical radial glow: solid at the center, transparent at [fadeStop] (CSS `radial-gradient(ellipse rx ry at ...)`). */
internal fun DrawScope.drawEllipticalGlow(
    color: Color,
    center: Offset,
    radiusX: Float,
    radiusY: Float,
    fadeStop: Float,
) {
    if (radiusX <= 0f || radiusY <= 0f) return
    scale(scaleX = 1f, scaleY = radiusY / radiusX, pivot = center) {
        drawCircle(
            brush = Brush.radialGradient(
                0f to color,
                fadeStop to color.copy(alpha = 0f),
                center = center,
                radius = radiusX,
            ),
            radius = radiusX,
            center = center,
        )
    }
}

/**
 * Dark top glow of the settings home: two stacked radial layers, with intensity multiplied by the palette glowK; light draws nothing.
 * Used by the settings home only; the shared OriveoScreenBackground is untouched.
 */
@Composable
internal fun SettingsHomeTopGlow(modifier: Modifier = Modifier) {
    if (!OriveoTheme.isDark) return
    val colors = OriveoTheme.colors
    val primary = colors.primary.copy(alpha = (0.22f * colors.glowK).coerceIn(0f, 1f))
    val accent = colors.accent.copy(alpha = (0.13f * colors.glowK).coerceIn(0f, 1f))
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(440.dp)
            .drawBehind {
                drawEllipticalGlow(
                    color = primary,
                    center = Offset(size.width * 0.12f, 0f),
                    radiusX = size.width * 0.75f,
                    radiusY = size.height * 0.55f,
                    fadeStop = 0.70f,
                )
                drawEllipticalGlow(
                    color = accent,
                    center = Offset(size.width * 0.95f, size.height * 0.04f),
                    radiusX = size.width * 0.60f,
                    radiusY = size.height * 0.45f,
                    fadeStop = 0.70f,
                )
            },
    )
}
