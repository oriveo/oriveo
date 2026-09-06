package ai.oriveo.community.feature.backup

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.Message
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.app.resolve
import ai.oriveo.community.core.util.readBytesLimited
import ai.oriveo.community.core.util.backupMemoryBudgetBytes
import ai.oriveo.community.core.util.launchExternalActivityOrNotify
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoDataRow
import ai.oriveo.community.ui.component.OriveoErrorCard
import ai.oriveo.community.ui.component.OriveoLabeledField
import ai.oriveo.community.ui.component.OriveoPrimaryButton
import ai.oriveo.community.ui.component.OriveoSecondaryButton
import ai.oriveo.community.ui.component.OriveoSectionHeader
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.OriveoErrorSeverity
import org.koin.androidx.compose.koinViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackupScreen(
    onBack: () -> Unit,
    viewModel: BackupViewModel = koinViewModel(),
) {
    val context = LocalContext.current
    val resources = LocalResources.current
    val colors = OriveoTheme.colors
    val spacing = OriveoTheme.spacing
    val layout = OriveoTheme.layout

    val exportSaveLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri: Uri? ->

        viewModel.handleExportSaveTarget(uri) { targetUri, sourceFile ->
            context.contentResolver.openOutputStream(targetUri)?.use { out ->
                sourceFile.inputStream().use { input -> input.copyTo(out, DEFAULT_BUFFER_SIZE) }
            } ?: throw IllegalStateException("openOutputStream returned null")
        }
    }

    androidx.compose.runtime.LaunchedEffect(viewModel.shouldTriggerSave) {
        if (viewModel.shouldTriggerSave) {
            val fileName = "Oriveo-Backup-${
                java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                    .format(java.util.Date())
            }.oriveo"
            launchExternalActivityOrNotify(context) { exportSaveLauncher.launch(fileName) }
        }
    }

    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        uri?.let {
            viewModel.handleFileSelected(it) { selectedUri ->
                context.contentResolver.openInputStream(selectedUri)?.use { stream ->
                    stream.readBytesLimited(backupMemoryBudgetBytes())
                } ?: throw IllegalStateException(resources.getString(R.string.backup_error_read_failed))
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.backup_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = layout.screenH, vertical = spacing.xl),
        ) {

            OriveoSectionHeader(title = stringResource(R.string.export_backup_title))
            Spacer(modifier = Modifier.height(spacing.md))

            OriveoCard {
                Column(verticalArrangement = Arrangement.spacedBy(layout.cardRowGap)) {

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = stringResource(R.string.include_api_keys),
                            style = OriveoTheme.typography.body,
                            color = colors.textPrimary,
                        )
                        Switch(
                            checked = viewModel.includeKeys,
                            onCheckedChange = { viewModel.includeKeys = it },
                            colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
                        )
                    }

                    if (viewModel.includeKeys) {
                        OriveoLabeledField(
                            label = stringResource(R.string.encryption_password),
                            value = viewModel.exportPassword,
                            onValueChange = { viewModel.exportPassword = it },
                            placeholder = stringResource(R.string.encryption_password_placeholder),
                            isSecure = true,
                            footnote = stringResource(R.string.encryption_password_footnote),
                        )

                        OriveoLabeledField(
                            label = stringResource(R.string.confirm_password),
                            value = viewModel.exportPasswordConfirm,
                            onValueChange = { viewModel.exportPasswordConfirm = it },
                            placeholder = stringResource(R.string.confirm_password_placeholder),
                            isSecure = true,
                        )

                        if (viewModel.passwordMismatch) {
                            Text(
                                text = stringResource(R.string.passwords_do_not_match),
                                style = OriveoTheme.typography.caption,
                                color = colors.danger,
                            )
                        }
                    }

                    viewModel.exportError?.let { error ->
                        Text(
                            text = error.resolve(context),
                            style = OriveoTheme.typography.caption,
                            color = colors.danger,
                        )
                    }

                    OriveoPrimaryButton(
                        text = if (viewModel.isExporting) {
                            stringResource(R.string.preparing)
                        } else {
                            stringResource(R.string.export_backup_action)
                        },
                        onClick = { viewModel.performExport() },
                        enabled = viewModel.canExport && !viewModel.isExporting,
                        loading = viewModel.isExporting,
                    )
                }
            }

            Spacer(modifier = Modifier.height(spacing.md))

            OriveoCard {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.sm)) {
                    Text(
                        text = stringResource(R.string.your_data),
                        style = OriveoTheme.typography.title3,
                        color = colors.textPrimary,
                    )
                    OriveoDataRow(
                        icon = Icons.AutoMirrored.Filled.Chat,
                        label = stringResource(R.string.conversations),
                        value = viewModel.conversationCount.toString(),
                    )
                    OriveoDataRow(
                        icon = Icons.Filled.AutoAwesome,
                        label = stringResource(R.string.tab_providers),
                        value = viewModel.providerCount.toString(),
                    )
                    OriveoDataRow(
                        icon = Icons.AutoMirrored.Filled.Message,
                        label = stringResource(R.string.messages),
                        value = viewModel.totalMessageCount.toString(),
                    )
                }
            }

            Spacer(modifier = Modifier.height(layout.sectionGap))
            OriveoSectionHeader(title = stringResource(R.string.import_section_title))
            Spacer(modifier = Modifier.height(spacing.md))

            OriveoCard {
                Column(verticalArrangement = Arrangement.spacedBy(layout.cardRowGap)) {
                    Text(
                        text = stringResource(R.string.import_description),
                        style = OriveoTheme.typography.caption,
                        color = colors.textSecondary,
                    )

                    OriveoSecondaryButton(
                        text = stringResource(R.string.import_backup),
                        onClick = {
                            launchExternalActivityOrNotify(context) {
                                filePickerLauncher.launch(
                                    arrayOf("application/zip", "application/json", "application/octet-stream"),
                                )
                            }
                        },
                    )
                }
            }

            viewModel.importError?.let { error ->
                Spacer(modifier = Modifier.height(spacing.md))
                OriveoErrorCard(
                    error = OriveoError(
                        title = stringResource(R.string.import_failed),
                        message = error.resolve(context),
                        detail = viewModel.importErrorDetail ?: error.resolve(context),
                        actionTitle = stringResource(R.string.choose_another_backup),
                        severity = OriveoErrorSeverity.Critical,
                    ),
                    onAction = {
                        viewModel.clearImportError()
                        launchExternalActivityOrNotify(context) {
                            filePickerLauncher.launch(
                                arrayOf("application/zip", "application/json", "application/octet-stream"),
                            )
                        }
                    },
                )
            }

            Spacer(modifier = Modifier.height(spacing.xxl))
        }
    }

    // ── Sheets ──

    if (viewModel.showImportPreview) {
        viewModel.importPreview?.let { preview ->
            ImportPreviewSheet(
                preview = preview,
                selectedMode = viewModel.selectedImportMode,
                onModeSelected = { viewModel.selectedImportMode = it },
                checksumWarning = viewModel.checksumWarning,
                attachmentWarning = viewModel.attachmentWarning,
                isImporting = viewModel.isImporting,
                onImport = { viewModel.confirmImport() },
                onDismiss = { viewModel.dismissImportPreview() },
            )
        }
    }

    if (viewModel.showPasswordPrompt) {
        PasswordPromptSheet(
            password = viewModel.importPassword,
            onPasswordChange = { viewModel.importPassword = it },
            onUnlock = { viewModel.unlockAndImport() },
            onSkip = { viewModel.skipApiKeys() },
            onDismiss = { viewModel.dismissPasswordPrompt() },
            errorMessage = viewModel.passwordError?.resolve(context),
        )
    }

    if (viewModel.showImportResult) {
        viewModel.importResult?.let { result ->
            ImportResultSheet(
                result = result,
                onDone = { viewModel.dismissImportResult() },
            )
        }
    }

    if (viewModel.showReplaceConfirmation) {
        AlertDialog(
            onDismissRequest = { viewModel.showReplaceConfirmation = false },
            title = {
                Text(
                    text = stringResource(R.string.replace_all_title),
                    style = OriveoTheme.typography.title3,
                )
            },
            text = {
                Text(
                    text = stringResource(R.string.replace_all_message),
                    style = OriveoTheme.typography.body,
                )
            },
            confirmButton = {
                TextButton(onClick = { viewModel.confirmReplace() }) {
                    Text(
                        text = stringResource(R.string.replace),
                        color = colors.danger,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.showReplaceConfirmation = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    if (viewModel.exportSuccess) {
        AlertDialog(
            onDismissRequest = { viewModel.dismissExportSuccess() },
            title = {
                Text(
                    text = stringResource(R.string.export_complete),
                    style = OriveoTheme.typography.title3,
                )
            },
            text = {
                Text(
                    text = stringResource(R.string.backup_exported_success),
                    style = OriveoTheme.typography.body,
                )
            },
            confirmButton = {
                TextButton(onClick = { viewModel.dismissExportSuccess() }) {
                    Text(stringResource(R.string.ok))
                }
            },
        )
    }
}
