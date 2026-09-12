package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.feature.home.AuroraSectionRule
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Section header (matches iOS v2SectionHeader): a 3×18 glowing bar + 17/bold title (-0.3 letter spacing) + 13 mono
 * count in accent, 10 apart. Title and count merge into one heading node ("Today, 3") so TalkBack heading
 * navigation can jump by section.
 */
@Composable
internal fun V2SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    count: Int? = null,
) {
    Row(
        modifier = modifier.semantics(mergeDescendants = true) { heading() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        AuroraSectionRule()
        Text(
            text = title,
            style = AuroraTheme.Typography.section,
            color = AuroraTheme.textPrimary(),
            maxLines = 1,
        )
        if (count != null && count > 0) {
            Text(
                text = count.toString(),
                style = AuroraTheme.Typography.countMono,
                color = AuroraTheme.accent(),
                maxLines = 1,
                // iOS baselineOffset(1): the mono count sits 1pt above the centered position
                modifier = Modifier.offset(y = (-1).dp),
            )
        }
    }
}

/** Section header insets: 4 on each side, 10 above the card (the design's `padding: 0 4px 10px`). */
internal fun Modifier.homeSectionHeaderInsets(): Modifier = padding(start = 4.dp, end = 4.dp, bottom = 10.dp)

/** Section header in edit mode: title + count + a trailing Select / Deselect (hit area extended to about 44). */
@Composable
internal fun SectionHeaderWithSelection(
    title: String,
    count: Int,
    allSelected: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        V2SectionHeader(title = title, count = count)
        Spacer(modifier = Modifier.weight(1f))
        Box(
            modifier = Modifier
                .heightIn(min = 22.dp)
                .clickable(role = Role.Button, onClick = onToggle)
                .padding(horizontal = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = stringResource(if (allSelected) R.string.deselect else R.string.select_action),
                fontSize = 13.sp,
                lineHeight = 16.sp,
                color = OriveoTheme.colors.primary,
                maxLines = 1,
            )
        }
    }
}

/**
 * Bottom toolbar in edit mode (matches iOS editingToolbar): select all / selected count / move to / delete.
 *
 * The root consumes every touch: the toolbar covers the list, and taps on empty space or between buttons must not
 * fall through to the hidden conversation rows underneath (that would silently change the selection, and the next
 * delete would remove one row too many). The buttons themselves get a full 48dp tap height.
 */
@Composable
internal fun HomeEditingToolbar(
    selectedCount: Int,
    allSelected: Boolean,
    onToggleAll: () -> Unit,
    onMove: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = OriveoTheme.colors

    Column(
        modifier = Modifier.pointerInput(Unit) {
            awaitEachGesture { awaitFirstDown(requireUnconsumed = false) }
        },
    ) {
        HorizontalDivider(color = colors.border)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(colors.surfaceElevated)
                .padding(horizontal = 20.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ToolbarAction(onClick = onToggleAll) {
                Text(
                    text = stringResource(if (allSelected) R.string.deselect_all else R.string.select_all),
                    style = OriveoTheme.typography.body,
                    color = colors.primary,
                )
            }
            Spacer(modifier = Modifier.weight(1f))
            if (selectedCount > 0) {
                Text(
                    text = stringResource(R.string.selected_count, selectedCount),
                    style = OriveoTheme.typography.footnote,
                    color = colors.textSecondary,
                )
                Spacer(modifier = Modifier.weight(1f))
            }
            ToolbarAction(enabled = selectedCount > 0, onClick = onMove) {
                Text(
                    text = stringResource(R.string.move_to),
                    style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                    color = if (selectedCount > 0) colors.primary else colors.textTertiary,
                )
            }
            Spacer(modifier = Modifier.size(OriveoTheme.spacing.sm))
            ToolbarAction(enabled = selectedCount > 0, onClick = onDelete) {
                Icon(
                    imageVector = Icons.Outlined.Delete,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = if (selectedCount > 0) colors.danger else colors.textTertiary,
                )
                Text(
                    text = stringResource(R.string.delete),
                    style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                    color = if (selectedCount > 0) colors.danger else colors.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun ToolbarAction(
    onClick: () -> Unit,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    Row(
        modifier = Modifier
            .heightIn(min = 48.dp)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        content()
    }
}
