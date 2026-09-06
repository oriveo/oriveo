package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.feature.home.AuroraSectionRule
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
internal fun V2SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    count: Int? = null,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        AuroraSectionRule()
        Text(
            text = title,
            style = AuroraTheme.Typography.section,
            color = AuroraTheme.textPrimary(),
        )
        if (count != null && count > 0) {
            Text(
                text = count.toString(),
                style = AuroraTheme.Typography.countMono.copy(
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                ),
                color = AuroraTheme.accent(),
            )
        }
    }
}

@Composable
internal fun SectionHeaderWithSelection(
    title: String,
    allSelected: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = OriveoTheme.spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        V2SectionHeader(title = title)
        Spacer(modifier = Modifier.weight(1f))

        Text(
            text = stringResource(if (allSelected) R.string.deselect else R.string.select_action),
            style = OriveoTheme.typography.footnote,
            color = OriveoTheme.colors.primary,
            modifier = Modifier.clickable(onClick = onToggle),
        )
    }
}

@Composable
internal fun HomeEditingToolbar(
    selectedCount: Int,
    allSelected: Boolean,
    onToggleAll: () -> Unit,
    onMove: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = OriveoTheme.colors

    Column {
        HorizontalDivider(color = colors.border)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(colors.surface.copy(alpha = 0.85f))
                .padding(horizontal = OriveoTheme.layout.screenH, vertical = OriveoTheme.spacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {

            Text(
                text = stringResource(if (allSelected) R.string.deselect_all else R.string.select_all),
                style = OriveoTheme.typography.body,
                color = colors.primary,
                modifier = Modifier.clickable(onClick = onToggleAll),
            )
            Spacer(modifier = Modifier.weight(1f))
            if (selectedCount > 0) {
                Text(
                    text = stringResource(R.string.selected_count, selectedCount),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
                Spacer(modifier = Modifier.weight(1f))
            }
            Row(
                modifier = Modifier.clickable(enabled = selectedCount > 0, onClick = onMove),
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.move_to),
                    style = OriveoTheme.typography.body.copy(
                        fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                    ),
                    color = if (selectedCount > 0) colors.primary else colors.textTertiary,
                )
            }
            Spacer(modifier = Modifier.size(OriveoTheme.spacing.lg))

            Row(
                modifier = Modifier.clickable(enabled = selectedCount > 0, onClick = onDelete),
                horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Delete,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = if (selectedCount > 0) colors.danger else colors.textTertiary,
                )
                Text(
                    text = stringResource(R.string.delete),
                    style = OriveoTheme.typography.body.copy(
                        fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                    ),
                    color = if (selectedCount > 0) colors.danger else colors.textTertiary,
                )
            }
        }
    }
}
