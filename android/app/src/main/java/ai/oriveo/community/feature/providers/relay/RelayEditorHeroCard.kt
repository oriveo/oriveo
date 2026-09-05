package ai.oriveo.community.feature.providers.relay

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.theme.OriveoBorderWidth
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity


@Composable
internal fun RelayEditorHeroCard(
    displayName: String,
    endpointText: String?,
    relayKind: RelayKind,
    status: ProviderConnectionState,
    onChangeKind: () -> Unit,
    onEditName: (() -> Unit)? = null,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val spacing = OriveoTheme.spacing
    val meta = relayKindMeta(relayKind)
    val brandColor = meta.tint

    
    
    val heroFill = if (isDark) {
        lerp(brandColor, colors.surfaceElevated, 0.82f)
    } else {
        lerp(brandColor, Color.White, 0.88f)
    }

    val cardShape = RoundedCornerShape(OriveoTheme.radius.lg)
    val borderAlpha = if (isDark) 0.22f else 0.16f
    val shadowAlpha = if (isDark) 0.18f else 0.10f

    Box(
        modifier = Modifier
            .fillMaxWidth()
            
            .shadow(
                elevation = 22.dp,
                shape = cardShape,
                ambientColor = brandColor.copy(alpha = shadowAlpha),
                spotColor = brandColor.copy(alpha = shadowAlpha),
            )
            .clip(cardShape)
            
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(heroFill, colors.surfaceElevated),
                ),
                shape = cardShape,
            )
            
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        brandColor.copy(alpha = if (isDark) 0.18f else 0.12f),
                        Color.Transparent,
                    ),
                ),
                shape = cardShape,
            )
            
            .background(
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.White.copy(alpha = if (isDark) 0.04f else 0.24f),
                        Color.Transparent,
                    ),
                ),
                shape = cardShape,
            )
            .border(OriveoBorderWidth.standard, brandColor.copy(alpha = borderAlpha), cardShape),
    ) {
        Column(
            modifier = Modifier.padding(spacing.xl),
            verticalArrangement = Arrangement.spacedBy(spacing.lg),
        ) {
            HeaderRow(
                displayName = displayName,
                metaTitle = stringResource(meta.titleRes),
                brandColor = brandColor,
                relayKind = relayKind,
                onEditName = onEditName,
            )
            MetaRow(
                meta = meta,
                relayKind = relayKind,
                status = status,
                onChangeKind = onChangeKind,
            )
            if (endpointText.isNullOrBlank()) {
                EndpointPlaceholder()
            } else {
                EndpointPreview(text = endpointText, brandColor = brandColor)
            }
        }
    }
}

@Composable
private fun HeaderRow(
    displayName: String,
    metaTitle: String,
    brandColor: Color,
    relayKind: RelayKind,
    onEditName: (() -> Unit)?,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Box(
            modifier = Modifier.size(72.dp),
            contentAlignment = Alignment.Center,
        ) {
            ProviderBadgeIcon(
                kind = ProviderKind.Relay,
                size = 56.dp,
                relayKind = relayKind,
            )
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                text = displayName,
                style = OriveoTheme.typography.title1,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = metaTitle,
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = brandColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        
        if (onEditName != null) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(colors.surfaceElevated.copy(alpha = if (isDark) 0.72f else 0.86f))
                    .border(OriveoBorderWidth.fine, brandColor.copy(alpha = 0.16f), CircleShape)
                    .clickable(onClick = onEditName),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Edit,
                    contentDescription = stringResource(R.string.edit),
                    tint = colors.textSecondary,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

@Composable
private fun MetaRow(
    meta: RelayKindMeta,
    relayKind: RelayKind,
    status: ProviderConnectionState,
    onChangeKind: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val brandColor = meta.tint

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
        modifier = Modifier.fillMaxWidth(),
    ) {
        
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(brandColor.copy(alpha = if (isDark) 0.18f else 0.12f))
                .border(
                    OriveoBorderWidth.fine,
                    brandColor.copy(alpha = 0.22f),
                    RoundedCornerShape(50),
                )
                .clickable(onClick = onChangeKind)
                .padding(horizontal = 9.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(
                imageVector = meta.systemIcon,
                contentDescription = null,
                tint = brandColor,
                modifier = Modifier.size(10.dp),
            )
            Text(
                text = stringResource(meta.titleRes),
                style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = brandColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Icon(
                imageVector = Icons.Filled.UnfoldMore,
                contentDescription = null,
                tint = brandColor.copy(alpha = 0.7f),
                modifier = Modifier.size(9.dp),
            )
        }

        // Status pill — connected / syncing / issue
        StatusPill(status = status)
    }
}

@Composable
private fun StatusPill(status: ProviderConnectionState) {
    val colors = OriveoTheme.colors
    val (label, tint, icon) = when (status) {
        is ProviderConnectionState.Connected -> Triple(
            stringResource(R.string.status_connected),
            colors.success,
            Icons.Filled.CheckCircle,
        )
        is ProviderConnectionState.Syncing -> Triple(
            stringResource(R.string.status_syncing),
            colors.primary,
            Icons.Filled.Autorenew,
        )
        is ProviderConnectionState.Issue -> Triple(
            stringResource(R.string.status_issue),
            colors.warning,
            Icons.Filled.Warning,
        )
    }
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(10.dp),
        )
        Text(
            text = label,
            style = OriveoTheme.typography.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun EndpointPreview(text: String, brandColor: Color) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.surfaceElevated.copy(alpha = if (isDark) 0.62f else 0.78f))
            .border(
                OriveoBorderWidth.fine,
                brandColor.copy(alpha = 0.10f),
                RoundedCornerShape(10.dp),
            )
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(7.dp))
                .background(brandColor.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.Link,
                contentDescription = null,
                tint = brandColor,
                modifier = Modifier.size(11.dp),
            )
        }
        Text(
            text = text,
            style = OriveoTheme.typography.footnote.copy(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Medium,
            ),
            color = colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Start,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun EndpointPlaceholder() {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.surfaceInset.copy(alpha = if (isDark) 0.62f else 0.78f))
            .border(
                OriveoBorderWidth.fine,
                colors.border.opacity(0.5f),
                RoundedCornerShape(10.dp),
            )
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
    ) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(7.dp))
                .background(colors.surfaceInset),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.Link,
                contentDescription = null,
                tint = colors.textTertiary,
                modifier = Modifier.size(11.dp),
            )
        }
        Text(
            text = stringResource(R.string.relay_no_endpoint_set),
            style = OriveoTheme.typography.caption,
            color = colors.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}
