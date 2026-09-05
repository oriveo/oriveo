package ai.oriveo.community.feature.chat.composer

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme


@Composable
internal fun ComposerActionCluster(
    isGenerating: Boolean,
    isPrimed: Boolean,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()

    
    val baseScale by animateFloatAsState(if (isPrimed || isGenerating) 1f else 0.96f, label = "sendBaseScale")
    val pressScale by animateFloatAsState(if (pressed) 0.97f else 1f, label = "sendPressScale")

    
    val flatFill = if (isDark) Color.White.copy(alpha = 0.10f) else Color(0xFF8C5FF8).copy(alpha = 0.12f)
    val background: Brush = when {
        isGenerating -> SolidColor(colors.danger)
        isPrimed -> OriveoGradients.primary
        else -> SolidColor(flatFill)
    }
    val iconTint = if (isGenerating || isPrimed) Color.White else colors.textTertiary
    val borderColor = if (isPrimed || isGenerating) colors.hairline else Color.Transparent
    val glowColor = when {
        isGenerating -> colors.danger.copy(alpha = 0.22f)
        isPrimed -> colors.primaryGlow
        else -> Color.Transparent
    }
    val elevation = if (isPrimed || isGenerating) 10.dp else 0.dp

    Box(
        modifier = modifier
            .size(40.dp)
            .graphicsLayer {
                val s = baseScale * pressScale
                scaleX = s
                scaleY = s
            }
            .shadow(elevation = elevation, shape = CircleShape, ambientColor = glowColor, spotColor = glowColor)
            .clip(CircleShape)
            .background(background, CircleShape)
            .then(
                if (borderColor != Color.Transparent) {
                    Modifier.border(OriveoBorderWidth.standard, borderColor, CircleShape)
                } else {
                    Modifier
                },
            )
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = if (isGenerating) Icons.Filled.Stop else Icons.Filled.ArrowUpward,
            contentDescription = stringResource(if (isGenerating) R.string.stop else R.string.send),
            modifier = Modifier.size(if (isGenerating) 15.dp else 16.dp),
            tint = iconTint,
        )
    }
}
