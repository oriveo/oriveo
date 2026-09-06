package ai.oriveo.community.feature.backup

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import ai.oriveo.community.ui.component.OriveoSheetDragHandle
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ImportMode
import ai.oriveo.community.core.model.ImportPreview
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoDataRow
import ai.oriveo.community.ui.component.StatusPill
import ai.oriveo.community.ui.component.StatusTone
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoTheme
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportPreviewSheet(
    preview: ImportPreview,
    selectedMode: ImportMode,
    onModeSelected: (ImportMode) -> Unit,
    checksumWarning: Boolean,
    attachmentWarning: Boolean,
    isImporting: Boolean,
    onImport: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = colors.backgroundBase,
        dragHandle = { OriveoSheetDragHandle() },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = layout.screenH),
        ) {

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.import_preview_title),
                    style = OriveoTheme.typography.title2,
                    color = colors.textPrimary,
                )
                Row {
                    TextButton(onClick = onDismiss) {
                        Text(stringResource(R.string.cancel), color = colors.textSecondary)
                    }
                    TextButton(
                        onClick = onImport,
                        enabled = !isImporting,
                    ) {
                        if (isImporting) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = colors.primary,
                            )
                        } else {
                            Text(
                                text = stringResource(R.string.import_action),
                                color = colors.primary,
                                style = OriveoTheme.typography.title3,
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(spacing.lg))

            OriveoCard {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    Text(
                        text = stringResource(R.string.backup_info),
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                    )
                    InfoRow(
                        label = stringResource(R.string.created),
                        value = formatBackupDate(preview.backupCreatedAt),
                    )
                    InfoRow(
                        label = stringResource(R.string.platform),
                        value = preview.backupPlatform,
                    )
                    InfoRow(
                        label = stringResource(R.string.app_version),
                        value = preview.backupAppVersion,
                    )
                    InfoRow(
                        label = stringResource(R.string.contains_api_keys),
                        value = if (preview.containsKeys) {
                            stringResource(R.string.yes)
                        } else {
                            stringResource(R.string.no)
                        },
                    )
                }
            }

            Spacer(modifier = Modifier.height(spacing.lg))

            OriveoCard {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    Text(
                        text = stringResource(R.string.contents),
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                    )
                    OriveoDataRow(
                        icon = Icons.AutoMirrored.Filled.Chat,
                        label = stringResource(R.string.conversations),
                        value = if (preview.existingConversations > 0) {
                            "${preview.totalConversations} (${preview.existingConversations} ${stringResource(R.string.already_exist)})"
                        } else {
                            preview.totalConversations.toString()
                        },
                    )
                    OriveoDataRow(
                        icon = Icons.Filled.AutoAwesome,
                        label = stringResource(R.string.tab_providers),
                        value = if (preview.existingProviders > 0) {
                            "${preview.totalProviders} (${preview.existingProviders} ${stringResource(R.string.already_exists)})"
                        } else {
                            preview.totalProviders.toString()
                        },
                    )
                    OriveoDataRow(
                        icon = Icons.AutoMirrored.Filled.Message,
                        label = stringResource(R.string.messages),
                        value = preview.totalMessages.toString(),
                    )
                    if (preview.totalImages > 0) {
                        OriveoDataRow(
                            icon = Icons.Filled.Image,
                            label = stringResource(R.string.images),
                            value = preview.totalImages.toString(),
                        )
                    }
                }
            }

            if (checksumWarning) {
                Spacer(modifier = Modifier.height(spacing.lg))
                WarningCard(text = stringResource(R.string.checksum_warning))
            }

            if (attachmentWarning) {
                Spacer(modifier = Modifier.height(spacing.lg))
                WarningCard(text = stringResource(R.string.attachment_checksum_warning))
            }

            Spacer(modifier = Modifier.height(spacing.lg))

            OriveoCard {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.md)) {
                    Text(
                        text = stringResource(R.string.import_mode),
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                    )

                    ImportMode.entries.forEach { mode ->
                        ImportModeRow(
                            mode = mode,
                            isSelected = selectedMode == mode,
                            onClick = { onModeSelected(mode) },
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(spacing.xxl))
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    val colors = OriveoTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = label,
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
        )
        Text(
            text = value,
            style = OriveoTheme.typography.body,
            color = colors.textPrimary,
        )
    }
}

@Composable
private fun WarningCard(text: String) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val warningShape = RoundedCornerShape(OriveoRadius.md)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(warningShape)
            .background(colors.warningSoft)
            .border(1.dp, colors.warning.copy(alpha = 0.25f), warningShape)
            .padding(spacing.md),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Filled.Warning,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = colors.warning,
        )
        Spacer(modifier = Modifier.width(spacing.sm))
        Text(
            text = text,
            style = OriveoTheme.typography.caption,
            color = colors.textPrimary,
        )
    }
}

private fun formatBackupDate(isoDate: String): String {
    return runCatching {
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(Locale.getDefault())
            .withZone(ZoneId.systemDefault())
            .format(Instant.parse(isoDate))
    }.getOrElse { isoDate }
}

@Composable
private fun ImportModeRow(
    mode: ImportMode,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = spacing.sm),
        verticalAlignment = Alignment.Top,
    ) {
        // Radio indicator
        Icon(
            imageVector = if (isSelected) {
                Icons.Outlined.CheckCircle
            } else {
                Icons.Outlined.RadioButtonUnchecked
            },
            contentDescription = null,
            modifier = Modifier.size(22.dp),
            tint = if (isSelected) colors.primary else colors.textTertiary,
        )
        Spacer(modifier = Modifier.width(spacing.md))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(mode.titleResId),
                    style = OriveoTheme.typography.title3,
                    color = colors.textPrimary,
                )
                if (mode.isDefault) {
                    Spacer(modifier = Modifier.width(spacing.sm))
                    StatusPill(
                        text = stringResource(R.string.recommended),
                        tone = StatusTone.Primary,
                    )
                }
            }
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = stringResource(mode.descriptionResId),
                style = OriveoTheme.typography.footnote,
                color = colors.textSecondary,
            )
        }
    }
}
