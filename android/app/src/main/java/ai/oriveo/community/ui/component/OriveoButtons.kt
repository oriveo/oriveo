package ai.oriveo.community.ui.component

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.oriveoSurface

/**
 * Primary action button: 48dp tall, gradient fill, white label, and a 0.99 scale while pressed.
 */
@Composable
fun OriveoPrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    leadingIcon: (@Composable () -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(if (isPressed) 0.99f else 1f, label = "primaryBtnScale")
    val btnHeight = OriveoTheme.layout.buttonHeight
    val shape = RoundedCornerShape(OriveoRadius.md)
    // A dark surface swallows a shallow shadow, so the elevation is more than doubled there to keep
    // the button lifted off its background; pressing drops it far enough to read as depression.
    val shadowElevation = if (isPressed) 6.dp else if (isDark) 22.dp else 10.dp
    // The hairline is softened in light mode: at full strength it reads as a hard outline against a
    // light surface instead of as an edge highlight.
    val hairlineColor = if (isDark) colors.hairline
        else colors.hairline.opacity(0.65f)

    // Every graphicsLayer property is set on one layer. Chaining separate graphicsLayer calls would
    // create extra render nodes whose caches invalidate independently on each press.
    val effectiveAlpha = if (enabled && !loading) 1f else 0.6f

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(btnHeight)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                this.shadowElevation = shadowElevation.toPx()
                this.shape = shape
                clip = true
                ambientShadowColor = colors.primaryGlow
                spotShadowColor = colors.primaryGlow
                alpha = effectiveAlpha
            }
            .background(
                brush = if (isPressed) OriveoGradients.primaryPressed else OriveoGradients.primary,
            )
            .border(OriveoBorderWidth.standard, hairlineColor, shape)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled && !loading,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = Color.White,
                strokeWidth = 2.dp,
            )
        } else if (leadingIcon != null) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                leadingIcon()
                Text(
                    text = text,
                    style = OriveoTheme.typography.title3,
                    color = Color.White,
                    maxLines = 1,
                    // With a fixed height and maxLines = 1, Compose clips by default and slices an
                    // over-wide label through the middle of a glyph. Long compound words in Russian
                    // or German hit this on a 360dp screen showing two buttons side by side, so
                    // ellipsis is chosen to at least degrade readably.
                    overflow = TextOverflow.Ellipsis,
                )
            }
        } else {
            Text(
                text = text,
                style = OriveoTheme.typography.title3,
                color = Color.White,
                maxLines = 1,
                // With a fixed height and maxLines = 1, Compose clips by default and slices an
                // over-wide label through the middle of a glyph. Long compound words in Russian or
                // German hit this on a 360dp screen showing two buttons side by side, so ellipsis is
                // chosen to at least degrade readably.
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * Secondary action button: 48dp tall, surface fill with a border, primary-coloured label.
 */
@Composable
fun OriveoSecondaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    leadingIcon: (@Composable () -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val isDark = colors.backgroundBase == ai.oriveo.community.ui.theme.DarkOriveoColors.backgroundBase
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val alpha by animateFloatAsState(if (isPressed) 0.92f else 1f, label = "secondaryBtnAlpha")
    val scale by animateFloatAsState(if (isPressed) 0.99f else 1f, label = "secondaryBtnScale")

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(OriveoTheme.layout.buttonHeight)
            .scale(scale)
            .alpha(alpha)
            .oriveoSurface(
                colors = colors,
                isDark = isDark,
                fill = colors.surfaceChrome,
                borderColor = colors.borderStrong,
                shadowStyle = OriveoSurfaceStyle.Soft,
            )
            .alpha(if (enabled && !loading) 1f else 0.6f)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled && !loading,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (loading) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = colors.primary,
                strokeWidth = 2.dp,
            )
        } else if (leadingIcon != null) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                leadingIcon()
                Text(
                    text = text,
                    style = OriveoTheme.typography.title3,
                    color = colors.primary,
                    // Without maxLines a long label wraps and the second line is then cropped by the
                    // fixed button height, which reads worse than an ellipsis.
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        } else {
            Text(
                text = text,
                style = OriveoTheme.typography.title3,
                color = colors.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * Text button: caption type in the primary colour, fading to 0.7 alpha while pressed.
 */
@Composable
fun OriveoTextButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    color: Color = OriveoTheme.colors.primary,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val alpha by animateFloatAsState(if (isPressed) 0.7f else 1f, label = "textBtnAlpha")

    Text(
        text = text,
        style = OriveoTheme.typography.caption,
        color = color,
        modifier = modifier
            .alpha(if (enabled) alpha else 0.4f)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled,
                onClick = onClick,
            ),
    )
}

/**
 * Circular icon button: 36dp by default with a 16dp icon on a primary fill.
 */
@Composable
fun OriveoCircleIconButton(
    icon: ImageVector,
    contentDescription: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 36.dp,
    iconSize: Dp = 16.dp,
    fillColor: Color = OriveoTheme.colors.primary,
    iconColor: Color = Color.White,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    // As with the primary button, a dark surface needs roughly double the elevation before the lift
    // is visible at all.
    val shadowElevation = if (isDark) 18.dp else 9.dp
    // The hairline is softened in light mode so it reads as an edge highlight rather than an outline.
    val hairlineColor = if (isDark) colors.hairline
        else colors.hairline.opacity(0.65f)

    Box(
        modifier = modifier
            .size(size)
            .shadow(
                elevation = shadowElevation,
                shape = CircleShape,
                ambientColor = colors.primaryGlow,
                spotColor = colors.primaryGlow,
            )
            .clip(CircleShape)
            .background(fillColor)
            .border(OriveoBorderWidth.standard, hairlineColor, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            modifier = Modifier.size(iconSize),
            tint = iconColor,
        )
    }
}
