package ai.oriveo.community.feature.backup

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MergeType
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ImportResult
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.theme.OriveoTheme


@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportResultSheet(
    result: ImportResult,
    onDone: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout

    ModalBottomSheet(
        onDismissRequest = onDone,
        sheetState = sheetState,
        containerColor = colors.backgroundBase,
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = layout.screenH)
                .padding(bottom = spacing.xxl),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(modifier = Modifier.height(spacing.lg))

            
            Icon(
                imageVector = Icons.Filled.CheckCircle,
                contentDescription = null,
                modifier = Modifier.size(56.dp),
                tint = colors.success,
            )

            Spacer(modifier = Modifier.height(spacing.lg))

            
            Text(
                text = stringResource(R.string.import_complete),
                style = OriveoTheme.typography.title1,
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
            )

            Spacer(modifier = Modifier.height(layout.sectionGap))

            
            OriveoCard {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    // Conversations
                    if (result.newConversations > 0) {
                        ResultRow(
                            icon = Icons.Filled.AddCircle,
                            color = colors.success,
                            text = stringResource(R.string.result_new_conversations, result.newConversations),
                        )
                    }
                    if (result.mergedConversations > 0) {
                        ResultRow(
                            icon = Icons.AutoMirrored.Filled.MergeType,
                            color = colors.primary,
                            text = stringResource(R.string.result_merged_conversations, result.mergedConversations),
                        )
                    }
                    if (result.skippedConversations > 0) {
                        ResultRow(
                            icon = Icons.Outlined.RemoveCircleOutline,
                            color = colors.textTertiary,
                            text = stringResource(R.string.result_skipped_conversations, result.skippedConversations),
                        )
                    }

                    // Providers
                    if (result.newProviders > 0) {
                        ResultRow(
                            icon = Icons.Filled.AddCircle,
                            color = colors.success,
                            text = stringResource(R.string.result_new_providers, result.newProviders),
                        )
                    }
                    if (result.skippedProviders > 0) {
                        ResultRow(
                            icon = Icons.Outlined.RemoveCircleOutline,
                            color = colors.textTertiary,
                            text = stringResource(R.string.result_skipped_providers, result.skippedProviders),
                        )
                    }

                    // Skills
                    if (result.newSkills > 0) {
                        ResultRow(
                            icon = Icons.Filled.AddCircle,
                            color = colors.success,
                            text = stringResource(R.string.result_new_skills, result.newSkills),
                        )
                    }
                    if (result.mergedSkills > 0) {
                        ResultRow(
                            icon = Icons.AutoMirrored.Filled.MergeType,
                            color = colors.primary,
                            text = stringResource(R.string.result_merged_skills, result.mergedSkills),
                        )
                    }
                    if (result.skippedSkills > 0) {
                        ResultRow(
                            icon = Icons.Outlined.RemoveCircleOutline,
                            color = colors.textTertiary,
                            text = stringResource(R.string.result_skipped_skills, result.skippedSkills),
                        )
                    }

                    // Notes
                    if (result.newNotes > 0) {
                        ResultRow(
                            icon = Icons.Filled.AddCircle,
                            color = colors.success,
                            text = stringResource(R.string.result_new_notes, result.newNotes),
                        )
                    }
                    if (result.mergedNotes > 0) {
                        ResultRow(
                            icon = Icons.AutoMirrored.Filled.MergeType,
                            color = colors.primary,
                            text = stringResource(R.string.result_merged_notes, result.mergedNotes),
                        )
                    }
                    if (result.skippedNotes > 0) {
                        ResultRow(
                            icon = Icons.Outlined.RemoveCircleOutline,
                            color = colors.textTertiary,
                            text = stringResource(R.string.result_skipped_notes, result.skippedNotes),
                        )
                    }

                    // Note folders
                    if (result.newNoteFolders > 0) {
                        ResultRow(
                            icon = Icons.Filled.AddCircle,
                            color = colors.success,
                            text = stringResource(R.string.result_new_note_folders, result.newNoteFolders),
                        )
                    }
                    if (result.mergedNoteFolders > 0) {
                        ResultRow(
                            icon = Icons.AutoMirrored.Filled.MergeType,
                            color = colors.primary,
                            text = stringResource(R.string.result_merged_note_folders, result.mergedNoteFolders),
                        )
                    }
                    if (result.skippedNoteFolders > 0) {
                        ResultRow(
                            icon = Icons.Outlined.RemoveCircleOutline,
                            color = colors.textTertiary,
                            text = stringResource(R.string.result_skipped_note_folders, result.skippedNoteFolders),
                        )
                    }

                    // Keys
                    if (result.restoredKeys > 0) {
                        ResultRow(
                            icon = Icons.Filled.Key,
                            color = colors.success,
                            text = stringResource(R.string.result_restored_keys, result.restoredKeys),
                        )
                    }

                    // Images
                    if (result.restoredImages > 0) {
                        ResultRow(
                            icon = Icons.Filled.Image,
                            color = colors.success,
                            text = stringResource(R.string.result_restored_images, result.restoredImages),
                        )
                    }
                    if (result.skippedImages > 0) {
                        ResultRow(
                            icon = Icons.Filled.Image,
                            color = colors.warning,
                            text = stringResource(R.string.result_skipped_images, result.skippedImages),
                        )
                    }
                    if (result.restoredPreferences) {
                        ResultRow(
                            icon = Icons.Filled.AutoAwesome,
                            color = colors.primary,
                            text = stringResource(R.string.result_restored_preferences),
                        )
                    }
                    if (result.restoredMemory) {
                        ResultRow(
                            icon = Icons.Filled.AutoAwesome,
                            color = colors.primary,
                            text = stringResource(R.string.result_restored_memory),
                        )
                    }
                    if (result.restoredLastUsedModel) {
                        ResultRow(
                            icon = Icons.Filled.AutoAwesome,
                            color = colors.primary,
                            text = stringResource(R.string.result_restored_last_used_model),
                        )
                    }
                    if (result.skillsRequiringKnowledgeReupload > 0) {
                        ResultRow(
                            icon = Icons.Filled.Warning,
                            color = colors.warning,
                            text = stringResource(R.string.knowledge_reupload_notice),
                        )
                    }
                    if (!result.hasChanges &&
                        result.skippedConversations == 0 &&
                        result.skippedProviders == 0 &&
                        result.skippedSkills == 0 &&
                        result.skippedNotes == 0 &&
                        result.skippedNoteFolders == 0 &&
                        result.skippedImages == 0
                    ) {
                        Text(
                            text = stringResource(R.string.import_result_no_changes),
                            style = OriveoTheme.typography.body,
                            color = colors.textSecondary,
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(layout.sectionGap))

            
            OriveoPrimaryButton(
                text = stringResource(R.string.done),
                onClick = onDone,
            )
        }
    }
}

@Composable
private fun ResultRow(
    icon: ImageVector,
    color: Color,
    text: String,
) {
    val spacing = OriveoTheme.spacing
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = color,
        )
        Spacer(modifier = Modifier.width(spacing.md))
        Text(
            text = text,
            style = OriveoTheme.typography.body,
            color = OriveoTheme.colors.textPrimary,
        )
    }
}
