package ai.oriveo.community.feature.providers.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayAvatar
import ai.oriveo.community.core.model.RelayAvatarPickerCell
import ai.oriveo.community.core.model.RelayAvatarResolver
import ai.oriveo.community.core.model.rememberRelayAvatarChoice
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity

internal const val RelayAvatarPickerColumns = 4

/**
 * The "Change icon" picker (opened from the relay detail header avatar): title + trailing "Done", a 4-column grid (brand? -> ten icons -> letter?).
 * Tapping a cell writes the on-device choice right away and every avatar subscribed to the store redraws; the sheet does not close itself, "Done" or swiping down closes it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RelayAvatarPickerSheet(provider: Provider, onDismiss: () -> Unit) {
    val colors = OriveoTheme.colors
    val name = provider.customName.orEmpty()
    val url = provider.baseUrlText.orEmpty()
    val cells = remember(name, url) { RelayAvatarResolver.pickerCells(name, url) }
    val choice = rememberRelayAvatarChoice(provider.id)
    val current = remember(provider.id, name, url, choice) { RelayAvatarResolver.resolve(provider, choice) }
    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = OriveoTheme.spacing.lg, end = OriveoTheme.spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(R.string.relay_avatar_change_icon),
                modifier = Modifier.weight(1f),
                style = OriveoTheme.typography.title3.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = stringResource(R.string.done),
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(role = Role.Button, onClick = onDismiss)
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                style = OriveoTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.primary,
            )
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.spacing.md, vertical = OriveoTheme.spacing.md),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
        ) {
            cells.chunked(RelayAvatarPickerColumns).forEach { row ->
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs)) {
                    row.forEach { cell ->
                        PickerCell(
                            cell = cell,
                            selected = cell.preview == current,
                            onClick = { RelayDetailBoardModel.pickAvatar(provider, cell) },
                            modifier = Modifier.weight(1f),
                        )
                    }
                    repeat(RelayAvatarPickerColumns - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun PickerCell(cell: RelayAvatarPickerCell, selected: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val colors = OriveoTheme.colors
    val label = when (cell) {
        // The brand cell label is the brand display name, untranslated.
        is RelayAvatarPickerCell.Brand -> cell.brand.kind.displayName
        is RelayAvatarPickerCell.Icon -> stringResource(cell.icon.labelRes)
        is RelayAvatarPickerCell.Letter -> stringResource(R.string.relay_avatar_letter)
    }
    val shape = RoundedCornerShape(12.dp)
    Column(
        modifier = modifier
            .clip(shape)
            // The light fill marks only the selected state; it is not an avatar backing plate.
            .then(if (selected) Modifier.background(colors.primary.opacity(0.12f), shape) else Modifier)
            .clickable(role = Role.Button, onClick = onClick)
            .clearAndSetSemantics {
                contentDescription = label
                this.selected = selected
            }
            .padding(vertical = 10.dp, horizontal = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            RelayAvatar(result = cell.preview, size = 32.dp)
        }
        Text(
            text = label,
            fontSize = 12.sp,
            color = if (selected) colors.textPrimary else colors.textSecondary,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
