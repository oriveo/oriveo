package ai.oriveo.community.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.ui.component.StatusPill
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.ui.theme.oriveoSurface

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ProviderEndpointSelector(
    kind: ProviderKind,
    selectedOptionId: String?,
    onSelect: (RegionOption) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = OriveoTheme.colors
    val isDark = colors.backgroundBase == DarkOriveoColors.backgroundBase
    val options = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy.regionOptions(kind)

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = stringResource(
                    ai.oriveo.community.feature.providers.setup.ProviderSetupCopy.endpointTitle(kind)
                ),
                style = OriveoTheme.typography.caption.copy(fontWeight = FontWeight.Medium),
                color = colors.textSecondary,
            )

            ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
                .endpointDescription(kind)?.let { descriptionRes ->
                Text(
                    text = stringResource(descriptionRes),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textTertiary,
                )
            }
        }

        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            maxItemsInEachRow = 2,
        ) {
            options.forEach { option ->
                ProviderEndpointOptionCard(
                    kind = kind,
                    option = option,
                    isSelected = selectedOptionId == option.id,
                    isDark = isDark,
                    enabled = enabled,
                    onClick = { onSelect(option) },
                    modifier = Modifier.weight(1f),
                )
            }

            val remainder = (2 - options.size % 2) % 2
            repeat(remainder) {
                Spacer(modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
fun localizedProviderEndpointLabel(kind: ProviderKind, option: RegionOption): String {
    val labelRes = ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
        .regionOptionLabel(kind, option.id)
    return if (labelRes != null) {
        stringResource(labelRes)
    } else {
        option.label
    }
}

@Composable
private fun ProviderEndpointOptionCard(
    kind: ProviderKind,
    option: RegionOption,
    isSelected: Boolean,
    isDark: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors

    Column(
        modifier = modifier
            .heightIn(min = 118.dp)
            .oriveoSurface(
                colors = colors,
                isDark = isDark,
                fill = if (isSelected) {
                    colors.primarySoft.opacity(0.92f)
                } else {
                    colors.surfaceElevated
                },
                borderColor = if (isSelected) {
                    colors.primary.copy(alpha = 0.28f)
                } else {
                    colors.border
                },
                radius = 16.dp,
                shadowStyle = OriveoSurfaceStyle.Soft,
            )
            .clip(RoundedCornerShape(16.dp))
            .alpha(if (enabled) 1f else 0.64f)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.Top,
        ) {
            StatusPill(
                text = option.id.uppercase(),
                tone = if (isSelected) StatusTone.Primary else StatusTone.Neutral,
                compact = true,
            )

            Spacer(modifier = Modifier.weight(1f))

            if (isSelected) {
                Icon(
                    imageVector = Icons.Filled.Check,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = colors.primary,
                )
            }
        }

        Text(
            text = localizedProviderEndpointLabel(kind, option),
            style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
            color = if (isSelected) colors.primary else colors.textPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )

        Text(
            text = option.baseURL.removePrefix("https://").removePrefix("http://"),
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
