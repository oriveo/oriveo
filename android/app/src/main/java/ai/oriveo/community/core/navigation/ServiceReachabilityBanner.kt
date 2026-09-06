package ai.oriveo.community.core.navigation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.SignalWifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.RowScope
import ai.oriveo.community.R
import ai.oriveo.community.core.reachability.ServiceReachabilityMonitor
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun ServiceReachabilityBanner(
    state: ServiceReachabilityMonitor.State,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = state.toBannerModel()
    AnimatedVisibility(
        visible = model != null,
        modifier = modifier,
        enter = fadeIn(animationSpec = tween(220)) + slideInVertically(initialOffsetY = { -it }),
        exit = fadeOut(animationSpec = tween(180)) + slideOutVertically(targetOffsetY = { -it }),
    ) {
        if (model != null) {
            ServiceReachabilityBannerContent(model, onDismiss)
        }
    }
}

@Composable
private fun ServiceReachabilityBannerContent(model: BannerModel, onDismiss: () -> Unit) {
    val shape = RoundedCornerShape(bottomStart = 12.dp, bottomEnd = 12.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(color = model.background, shape = shape)
            .padding(
                start = OriveoTheme.spacing.lg,
                end = OriveoTheme.spacing.sm,
                top = OriveoTheme.spacing.sm,
                bottom = OriveoTheme.spacing.sm,
            )
            .testTag("service_reachability_banner"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Icon(
            imageVector = model.icon,
            contentDescription = null,
            tint = model.foreground,
            modifier = Modifier.size(14.dp),
        )
        Text(
            text = stringResource(model.textRes),
            style = OriveoTheme.typography.caption,
            color = OriveoTheme.colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (model.dismissible) {
            val closeLabel = stringResource(R.string.close)
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .clickable(
                        onClick = onDismiss,
                        role = Role.Button,
                        onClickLabel = closeLabel,
                    )
                    .testTag("service_reachability_banner_dismiss"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Close,
                    contentDescription = closeLabel,
                    tint = model.foreground.copy(alpha = 0.75f),
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

@Composable
private fun ServiceReachabilityMonitor.State.toBannerModel(): BannerModel? {
    val colors = OriveoTheme.colors
    return when (this) {
        is ServiceReachabilityMonitor.State.Online -> null
        is ServiceReachabilityMonitor.State.NoNetwork -> BannerModel(
            icon = Icons.Outlined.SignalWifiOff,
            textRes = R.string.no_internet_connection,
            foreground = colors.danger,
            background = colors.dangerSoft,
            dismissible = true,
        )
        is ServiceReachabilityMonitor.State.ServicesUnreachable -> null
    }
}

private data class BannerModel(
    val icon: ImageVector,
    val textRes: Int,
    val foreground: Color,
    val background: Color,
    val dismissible: Boolean,
)
