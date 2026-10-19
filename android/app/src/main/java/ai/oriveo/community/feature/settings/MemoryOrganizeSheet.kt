package ai.oriveo.community.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryOrganizedItem
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import ai.oriveo.community.ui.theme.OriveoTheme

/** Organize flow phases (P5·U6 contract rule 6). */
enum class MemoryOrganizePhase {
    Loading,
    Failed,
    Empty,
    NoModel,
    Ready,
}

/** Organize sheet state: proposals all selected by default, keep-original off by default. */
data class MemoryOrganizeState(
    val item: MemoryItem,
    val phase: MemoryOrganizePhase,
    val proposals: List<MemoryOrganizedItem> = emptyList(),
    val selected: Set<Int> = proposals.indices.toSet(),
    val keepOriginal: Boolean = false,
) {
    val canSave: Boolean get() = phase == MemoryOrganizePhase.Ready && selected.isNotEmpty()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MemoryOrganizeSheet(
    state: MemoryOrganizeState,
    onToggle: (Int) -> Unit,
    onKeepOriginalChange: (Boolean) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = OriveoTheme.colors
    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        dragHandle = { OriveoSheetDragHandle() },
        containerColor = colors.surface,
        contentColor = colors.textPrimary,
        scrimColor = colors.overlay,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = OriveoTheme.layout.screenH)
                .padding(bottom = OriveoTheme.spacing.xxl),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.lg),
        ) {
            Text(
                text = stringResource(R.string.memory_action_organize),
                style = OriveoTheme.typography.title2,
                color = colors.textPrimary,
            )
            when (state.phase) {
                MemoryOrganizePhase.Loading -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.primary)
                    Text(stringResource(R.string.memory_organize_loading), color = colors.textSecondary)
                }
                MemoryOrganizePhase.Failed -> OrganizeNotice(stringResource(R.string.memory_organize_failed))
                MemoryOrganizePhase.Empty -> OrganizeNotice(stringResource(R.string.memory_organize_empty))
                MemoryOrganizePhase.NoModel -> OrganizeNotice(stringResource(R.string.memory_organize_no_model))
                MemoryOrganizePhase.Ready -> OrganizeProposals(state, onToggle, onKeepOriginalChange)
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDismiss, modifier = Modifier) {
                    Text(stringResource(R.string.cancel))
                }
                if (state.phase == MemoryOrganizePhase.Ready) {
                    OriveoPrimaryButton(
                        text = stringResource(R.string.memory_organize_save),
                        onClick = onSave,
                        enabled = state.canSave,
                        modifier = Modifier,
                    )
                }
            }
        }
    }
}

@Composable
private fun OrganizeNotice(text: String) {
    Text(text = text, style = OriveoTheme.typography.body, color = OriveoTheme.colors.textSecondary)
}

@Composable
private fun OrganizeProposals(
    state: MemoryOrganizeState,
    onToggle: (Int) -> Unit,
    onKeepOriginalChange: (Boolean) -> Unit,
) {
    val colors = OriveoTheme.colors
    Column(
        modifier = Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        state.proposals.forEachIndexed { index, proposal ->
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Checkbox(
                    checked = index in state.selected,
                    onCheckedChange = { onToggle(index) },
                    modifier = Modifier,
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = memoryItemGroupTitle(MemoryItemGroup.of(proposal.kind) ?: MemoryItemGroup.About),
                        style = OriveoTheme.typography.footnote,
                        color = colors.textSecondary,
                    )
                    Text(text = proposal.content, style = OriveoTheme.typography.body, color = colors.textPrimary)
                }
            }
        }
    }
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = stringResource(R.string.memory_organize_keep_original),
            style = OriveoTheme.typography.body,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = state.keepOriginal,
            onCheckedChange = onKeepOriginalChange,
            modifier = Modifier,
        )
    }
}
