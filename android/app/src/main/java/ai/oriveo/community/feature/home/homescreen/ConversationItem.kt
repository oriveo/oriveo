package ai.oriveo.community.feature.home.homescreen

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.feature.home.resolveConversationModelName
import ai.oriveo.community.ui.component.ConversationRow
import ai.oriveo.community.ui.theme.OriveoTheme

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ConversationItem(
    conversation: Conversation,
    providersById: Map<String, ai.oriveo.community.core.model.Provider>,
    modelDisplayLookup: ModelDisplayLookup,
    skillsById: Map<String, Skill> = emptyMap(),
    isEditing: Boolean,
    isSelected: Boolean,
    isStreaming: Boolean = false,
    isPinned: Boolean = false,
    onToggleSelection: () -> Unit,
    onClick: () -> Unit,
    onRename: () -> Unit,
    onCopy: () -> Unit,
    onShare: () -> Unit,
    onSelect: () -> Unit,
    onDelete: () -> Unit,
    onTogglePin: () -> Unit = {},
    folderName: String? = null,
    onMove: (() -> Unit)? = null,
) {
    var showMenu by remember { mutableStateOf(false) }
    val colors = OriveoTheme.colors

    val provider = providersById[conversation.providerID]

    val providerKind = conversation.providerKind
    val providerName = provider?.displayName ?: providerKind.displayName
    val modelName = remember(conversation.modelID, provider, modelDisplayLookup) {
        resolveConversationModelName(
            conversation = conversation,
            provider = provider,
            displayLookup = modelDisplayLookup,
        )
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = if (isEditing) 14.dp else 0.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (isEditing) 10.dp else OriveoTheme.spacing.md),
    ) {

        if (isEditing) {
            Icon(
                imageVector = if (isSelected) Icons.Outlined.CheckCircle else Icons.Outlined.Circle,
                contentDescription = null,
                modifier = Modifier
                    .size(22.dp)
                    .clickable(onClick = onToggleSelection),
                tint = if (isSelected) colors.primary else colors.textTertiary,
            )
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .testTag("home_conversation_item")
                .combinedClickable(
                    onClick = {
                        if (isEditing) onToggleSelection() else onClick()
                    },
                    onLongClick = {
                        if (!isEditing) showMenu = true
                    },
                ),
        ) {
            ConversationRow(
                conversation = conversation,
                providerKind = providerKind,
                providerName = providerName,
                modelName = modelName,
                folderName = folderName,
                skillIcon = conversation.skillId?.let { skillsById[it]?.icon },
                isEditing = isEditing,
                relayKind = provider?.relayKind,
                isStreaming = isStreaming,
                isPinned = isPinned,
            )

            if (showMenu) {
                DropdownMenu(
                    expanded = true,
                    onDismissRequest = { showMenu = false },
                ) {

                    DropdownMenuItem(
                        text = {
                            Text(stringResource(
                                if (isPinned) R.string.unpin_conversation else R.string.pin_conversation,
                            ))
                        },
                        onClick = {
                            showMenu = false
                            onTogglePin()
                        },
                        leadingIcon = {

                            Icon(
                                imageVector = if (isPinned) Icons.Filled.PushPin else Icons.Outlined.PushPin,
                                contentDescription = null,
                            )
                        },
                    )
                    if (onMove != null) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.move_to_folder)) },
                            onClick = {
                                showMenu = false
                                onMove()
                            },
                            leadingIcon = { Icon(Icons.Outlined.Folder, contentDescription = null) },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.rename)) },
                        onClick = {
                            showMenu = false
                            onRename()
                        },
                        leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
                    )

                    if (conversation.messageCount > 0) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.copy_last_message)) },
                            onClick = {
                                showMenu = false
                                onCopy()
                            },
                            leadingIcon = { Icon(Icons.Outlined.ContentCopy, contentDescription = null) },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.share)) },
                        onClick = {
                            showMenu = false
                            onShare()
                        },
                        leadingIcon = { Icon(Icons.Outlined.Share, contentDescription = null) },
                    )

                    HorizontalDivider()
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.select_action)) },
                        onClick = {
                            showMenu = false
                            onSelect()
                        },
                        leadingIcon = { Icon(Icons.Outlined.CheckCircle, contentDescription = null) },
                    )
                    DropdownMenuItem(
                        text = {
                            Text(
                                stringResource(R.string.delete),
                                color = colors.danger,
                            )
                        },
                        onClick = {
                            showMenu = false
                            onDelete()
                        },
                        leadingIcon = {
                            Icon(
                                Icons.Outlined.Delete,
                                contentDescription = null,
                                tint = colors.danger,
                            )
                        },
                    )
                }
            }
        }
    }
}

@Composable
internal fun RenameDialog(
    currentTitle: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf(currentTitle) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.rename_conversation)) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(text) },
                enabled = text.isNotBlank(),
            ) {
                Text(stringResource(R.string.save))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}
