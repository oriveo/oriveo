package ai.oriveo.community.feature.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.History
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.context.ConversationInstructions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.theme.OriveoTheme

/** Pure rules behind the chat settings sheet (contract P4·U3 rules 2–4). */
object ConversationSettings {
    /**
     * Value to write when the sheet closes: normalized, or null when it equals [opened] — the snapshot taken
     * when the sheet opened — so a remote change synced in while the sheet was open is not overwritten.
     */
    fun instructionsToSave(opened: String, edited: String): String? {
        val normalized = ConversationInstructions.normalize(edited)
        return normalized.takeIf { it != ConversationInstructions.normalize(opened) }
    }

    /** Draft (no row yet): the in-memory pending value goes through the same normalization. */
    fun draftInstructions(edited: String): String = ConversationInstructions.normalize(edited)

    /**
     * Carry-over shortcut: only when [currentInstructions] is empty, taken from the most recently updated
     * non-deleted conversation other than the current one; hidden when that conversation has no instructions.
     */
    fun carryOverSource(
        conversations: List<Conversation>,
        currentConversationId: String?,
        currentInstructions: String,
    ): String? {
        if (currentInstructions.isNotEmpty()) return null
        val latest = conversations
            .filter { it.id != currentConversationId }
            .maxByOrNull { it.updatedAt }
            ?: return null
        return latest.instructions.takeIf { it.isNotEmpty() }
    }

    /** The shortcut follows the editor: shown only while it normalizes to "" and a source exists. */
    fun visibleCarryOver(editorText: String, source: String?): String? =
        source?.takeIf { ConversationInstructions.normalize(editorText).isEmpty() }

    /** Draft (no conversation id yet) hides the memory toggle: flipping it would write nothing; also hidden without active semantic items. */
    fun memoryToggleVisible(conversationId: String?, memoryItems: List<ai.oriveo.community.core.context.MemoryItem>): Boolean =
        conversationId != null && MemoryUsed.hasActiveSemantic(memoryItems)
}

/**
 * Chat settings sheet (contract P4·U3 rule 2): instructions editor, carry-over shortcut, memory toggle
 * and an optional usage row. Closing (swipe, scrim or Done) hands the snapshot taken on opening and the
 * edited text to [onClose].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationSettingsSheet(
    initialInstructions: String,
    carryOverInstructions: String?,
    showMemoryToggle: Boolean,
    memoryEnabled: Boolean,
    onToggleUseMemory: () -> Unit,
    onOpenUsage: (() -> Unit)?,
    onClose: (opened: String, edited: String) -> Unit,
    /** P4·U4 rule 5: value of the usage row ("N%", about N%, or unavailable). */
    usageValue: String? = null,
) {
    val colors = OriveoTheme.colors
    val opened = remember { initialInstructions }
    var text by remember { mutableStateOf(initialInstructions) }
    val latestText by rememberUpdatedState(text)
    val close = { onClose(opened, latestText) }
    OriveoModalBottomSheet(
        onDismissRequest = close,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = { ai.oriveo.community.ui.component.OriveoSheetDragHandle() },
        containerColor = colors.backgroundBase,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(R.string.conversation_settings_title),
                    style = OriveoTheme.typography.title3,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = close,
                    modifier = Modifier,
                ) {
                    Text(stringResource(R.string.done))
                }
            }
            Text(
                text = stringResource(R.string.conversation_settings_instructions_header),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text(stringResource(R.string.conversation_settings_instructions_placeholder)) },
                minLines = 4,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 280.dp)
                    ,
            )
            Text(
                text = stringResource(R.string.conversation_settings_instructions_footer),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
            // Rule 4: tapping only fills the editor; nothing is written until the sheet closes.
            val carryOver = ConversationSettings.visibleCarryOver(text, carryOverInstructions)
            if (carryOver != null) {
                SettingsRow(
                    label = stringResource(R.string.conversation_settings_carry_over),
                    onClick = { text = carryOver },
                    leading = { Icon(Icons.Outlined.History, contentDescription = null, tint = colors.primary) },
                )
            }
            if (showMemoryToggle || onOpenUsage != null) {
                HorizontalDivider(color = colors.hairline)
            }
            if (showMemoryToggle) {
                val useMemoryLabel = stringResource(R.string.memory_use_toggle)
                SettingsRow(
                    label = useMemoryLabel,
                    onClick = onToggleUseMemory,
                    trailing = {
                        Switch(
                            checked = memoryEnabled,
                            onCheckedChange = { onToggleUseMemory() },
                            modifier = Modifier
                                .semantics { contentDescription = useMemoryLabel }
                                ,
                        )
                    },
                )
            }
            if (onOpenUsage != null) {
                SettingsRow(
                    label = stringResource(R.string.conversation_settings_usage),
                    // P4·U4 rule 5: close this sheet (saving instructions) first, then open the panel.
                    onClick = {
                        close()
                        onOpenUsage()
                    },
                    trailing = {
                        usageValue?.let {
                            Text(text = it, style = OriveoTheme.typography.footnote, color = colors.textSecondary)
                        }
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = colors.textSecondary,
                        )
                    },
                )
            }
        }
    }
}

@Composable
private fun SettingsRow(
    label: String,
    onClick: () -> Unit,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        leading?.invoke()
        Text(
            text = label,
            style = OriveoTheme.typography.body,
            color = OriveoTheme.colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        trailing?.invoke()
    }
}
