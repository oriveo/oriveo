package ai.oriveo.community.ui.component

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.resolve
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow

private const val TOAST_DURATION_MS = 3000L


@Composable
fun GlobalToastHost(
    messages: Flow<GlobalSnackbarMessage>,
    modifier: Modifier = Modifier,
) {
    var current by remember { mutableStateOf<GlobalSnackbarMessage?>(null) }
    
    var rendered by remember { mutableStateOf<GlobalSnackbarMessage?>(null) }

    LaunchedEffect(messages) {
        messages.collect { msg -> current = msg }
    }
    LaunchedEffect(current) {
        val shown = current ?: return@LaunchedEffect
        rendered = shown
        delay(shown.durationMs ?: TOAST_DURATION_MS)
        
        if (current === shown) current = null
    }

    AnimatedVisibility(
        visible = current != null,
        modifier = modifier,
        enter = fadeIn(animationSpec = tween(220)) + slideInVertically(initialOffsetY = { -it }),
        exit = fadeOut(animationSpec = tween(180)) + slideOutVertically(targetOffsetY = { -it }),
    ) {
        rendered?.let { msg ->
            ToastCard(
                message = msg,
                onActionClick = {
                    msg.action?.onClick?.invoke()
                    current = null
                },
            )
        }
    }
}

@Composable
private fun ToastCard(
    message: GlobalSnackbarMessage,
    onActionClick: () -> Unit = {},
) {
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val accent = when (message.style) {
        GlobalToastStyle.Success -> colors.success
        GlobalToastStyle.Error -> colors.danger
        GlobalToastStyle.Warning -> colors.warning
        GlobalToastStyle.Neutral -> colors.textPrimary
    }
    val tint = when (message.style) {
        GlobalToastStyle.Success -> colors.successSoft
        GlobalToastStyle.Error -> colors.dangerSoft
        GlobalToastStyle.Warning -> colors.warningSoft
        GlobalToastStyle.Neutral -> Color.Transparent
    }
    val icon: ImageVector? = when (message.style) {
        GlobalToastStyle.Success -> Icons.Filled.CheckCircle
        GlobalToastStyle.Error -> Icons.Filled.Error
        GlobalToastStyle.Warning -> Icons.Filled.Warning
        GlobalToastStyle.Neutral -> null
    }
    val isSemantic = message.style != GlobalToastStyle.Neutral
    val shape = RoundedCornerShape(14.dp)

    Row(
        modifier = Modifier
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.sm)
            .widthIn(max = 480.dp)
            .shadow(elevation = 8.dp, shape = shape, ambientColor = colors.shadow, spotColor = colors.shadow)
            .clip(shape)
            .background(colors.surfaceElevated)
            .then(if (isSemantic) Modifier.background(tint) else Modifier)
            .then(if (isSemantic) Modifier.border(1.dp, accent.copy(alpha = 0.28f), shape) else Modifier)
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(16.dp),
            )
        }
        Text(
            text = message.message.resolve(context),
            style = OriveoTheme.typography.caption,
            color = colors.textPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = if (message.action != null) Modifier.weight(1f, fill = false) else Modifier,
        )
        message.action?.let { action ->
            Text(
                text = action.label.resolve(context),
                style = OriveoTheme.typography.caption,
                color = colors.primary,
                maxLines = 1,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { onActionClick() }
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
    }
}
