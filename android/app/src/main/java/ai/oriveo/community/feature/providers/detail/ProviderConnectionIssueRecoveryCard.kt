package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyOff
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderEffectiveStatusKind
import ai.oriveo.community.core.model.effectiveStatusKind
import ai.oriveo.community.ui.component.localizedProviderError
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun ProviderConnectionIssueRecoveryCard(
    provider: Provider,
    onUpdateAPIKey: () -> Unit,
    onRetryConnection: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    onCheckEndpoint: (() -> Unit)? = null,
    endpointTitleRes: Int = R.string.official_endpoint,
) {
    val colors = OriveoTheme.colors
    val needsKey = provider.effectiveStatusKind == ProviderEffectiveStatusKind.NeedsKey
    val headlineRes = if (needsKey) {
        R.string.provider_api_key_not_saved
    } else {
        R.string.provider_health_banner_message
    }
    val statusIcon: ImageVector = if (needsKey) Icons.Filled.KeyOff else Icons.Filled.Warning

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.warningSoft)
            .border(1.dp, colors.warning.copy(alpha = 0.20f), RoundedCornerShape(12.dp))
            .padding(OriveoTheme.spacing.lg),
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        ) {
            Box(
                modifier = Modifier
                    .size(30.dp)
                    .clip(CircleShape)
                    .background(colors.surfaceElevated.copy(alpha = 0.82f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = statusIcon,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = colors.warning,
                )
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = stringResource(headlineRes),
                    style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                if (!needsKey) {
                    val lastError = provider.lastError?.trim().orEmpty()
                    if (lastError.isNotEmpty()) {
                        Text(
                            text = localizedProviderError(lastError),
                            style = OriveoTheme.typography.footnote,
                            color = colors.textSecondary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = stringResource(R.string.close),
                    modifier = Modifier.size(11.dp),
                    tint = colors.textTertiary,
                )
            }
        }

        RecoveryActions(
            onUpdateAPIKey = onUpdateAPIKey,
            onRetryConnection = onRetryConnection,
            onCheckEndpoint = onCheckEndpoint,
            endpointTitleRes = endpointTitleRes,
        )
    }
}

@Composable
private fun RecoveryActions(
    onUpdateAPIKey: () -> Unit,
    onRetryConnection: () -> Unit,
    onCheckEndpoint: (() -> Unit)?,
    endpointTitleRes: Int,
) {
    BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
        val buttonCount = 2 + (if (onCheckEndpoint != null) 1 else 0)

        val isCompact = maxWidth < (buttonCount * 75).dp

        if (isCompact) {
            Column(verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                RecoveryPrimary(onClick = onUpdateAPIKey, modifier = Modifier.fillMaxWidth())
                if (onCheckEndpoint != null) {
                    RecoverySecondary(
                        text = stringResource(endpointTitleRes),
                        icon = Icons.Filled.Language,
                        onClick = onCheckEndpoint,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                RecoverySecondary(
                    text = stringResource(R.string.retry),
                    icon = Icons.Filled.Refresh,
                    onClick = onRetryConnection,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm)) {
                RecoveryPrimary(onClick = onUpdateAPIKey, modifier = Modifier.weight(1f))
                if (onCheckEndpoint != null) {
                    RecoverySecondary(
                        text = stringResource(endpointTitleRes),
                        icon = Icons.Filled.Language,
                        onClick = onCheckEndpoint,
                        modifier = Modifier.weight(1f),
                    )
                }
                RecoverySecondary(
                    text = stringResource(R.string.retry),
                    icon = Icons.Filled.Refresh,
                    onClick = onRetryConnection,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun RecoveryPrimary(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Box(
        modifier = modifier
            .heightIn(min = 38.dp)
            .clip(CircleShape)
            .background(colors.warning)
            .clickable(onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.md, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Key,
                contentDescription = null,
                modifier = Modifier.size(13.dp),
                tint = Color.White,
            )
            Text(
                text = stringResource(R.string.edit_api_key),
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun RecoverySecondary(
    text: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    Box(
        modifier = modifier
            .heightIn(min = 38.dp)
            .clip(CircleShape)
            .background(colors.surfaceElevated.copy(alpha = 0.82f))
            .border(1.dp, colors.warning.copy(alpha = 0.18f), CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.md, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(13.dp),
                tint = colors.warning,
            )
            Text(
                text = text,
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = colors.warning,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
