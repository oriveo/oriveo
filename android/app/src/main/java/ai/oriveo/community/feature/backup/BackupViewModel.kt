package ai.oriveo.community.feature.backup

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.backup.BackupService

import ai.oriveo.community.core.model.BackupError
import ai.oriveo.community.core.model.ImportMode
import ai.oriveo.community.core.model.ImportPreview
import ai.oriveo.community.core.model.ImportResult
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File


class BackupViewModel(
    private val backupService: BackupService,
    private val appPreferencesRepository: ai.oriveo.community.core.app.AppPreferencesRepository,
    private val exportScratchDir: File,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {

    

    var includeKeys: Boolean by mutableStateOf(false)
    var exportPassword: String by mutableStateOf("")
    var exportPasswordConfirm: String by mutableStateOf("")
    var isExporting: Boolean by mutableStateOf(false)
        private set
    var exportSuccess: Boolean by mutableStateOf(false)
        private set
    var exportError: UiText? by mutableStateOf(null)
        private set

    val canExport: Boolean
        get() = if (includeKeys) {
            exportPassword.length >= 8 && exportPassword == exportPasswordConfirm
        } else {
            true
        }

    val passwordMismatch: Boolean
        get() = includeKeys && exportPassword.isNotEmpty() &&
            exportPasswordConfirm.isNotEmpty() &&
            exportPassword != exportPasswordConfirm

    

    var conversationCount: Int by mutableStateOf(0)
        private set
    var providerCount: Int by mutableStateOf(0)
        private set
    var totalMessageCount: Int by mutableStateOf(0)
        private set

    

    var showImportPreview: Boolean by mutableStateOf(false)
        private set
    var importPreview: ImportPreview? by mutableStateOf(null)
        private set
    var selectedImportMode: ImportMode by mutableStateOf(ImportMode.ImportNewOnly)
    var checksumWarning: Boolean by mutableStateOf(false)
        private set
    var attachmentWarning: Boolean by mutableStateOf(false)
        private set

    var showPasswordPrompt: Boolean by mutableStateOf(false)
        private set
    var importPassword: String by mutableStateOf("")

    var isImporting: Boolean by mutableStateOf(false)
        private set
    var showImportResult: Boolean by mutableStateOf(false)
        private set
    var importResult: ImportResult? by mutableStateOf(null)
        private set

    var showReplaceConfirmation: Boolean by mutableStateOf(false)

    var importError: UiText? by mutableStateOf(null)
        private set
    var importErrorDetail: String? by mutableStateOf(null)
        private set
    var passwordError: UiText? by mutableStateOf(null)
        private set

    private var parsedFileUri: Uri? = null
    private var parsedFileBytes: ByteArray? = null
    private var parsedRequiresKeyPassword: Boolean = false

    init {
        loadDataSummary()
    }

    private fun loadDataSummary() {
        viewModelScope.launch {
            try {
                val summary = backupService.getDataSummary()
                conversationCount = summary.conversations
                providerCount = summary.providers
                totalMessageCount = summary.messages
            } catch (_: Exception) {
                
            }
        }
    }

    
    var exportedFile: File? by mutableStateOf(null)
        private set

    
    var shouldTriggerSave: Boolean by mutableStateOf(false)
        private set

    

    fun performExport() {
        if (!canExport) return
        viewModelScope.launch {
            isExporting = true
            exportError = null
            exportSuccess = false
            
            discardExportedFile()
            var target: File? = null
            try {
                val written = withContext(ioDispatcher) {
                    val file = createExportScratchFile()
                    target = file
                    backupService.exportBackupToFile(
                        target = file,
                        includeKeys = includeKeys,
                        password = if (includeKeys) exportPassword else null,
                    )
                    file
                }
                exportedFile = written
                shouldTriggerSave = true
            } catch (e: Exception) {
                target?.delete()
                exportError = mapError(e)
            } catch (e: OutOfMemoryError) {
                
                
                
                
                target?.delete()
                exportError = mapError(e)
            } finally {
                isExporting = false
            }
        }
    }

    
    fun handleExportSaveTarget(uri: Uri?, writeFile: suspend (Uri, File) -> Unit) {
        val file = exportedFile
        if (uri == null || file == null) {
            onExportFileFailed()
            return
        }
        viewModelScope.launch {
            try {
                
                
                withContext(NonCancellable + ioDispatcher) { writeFile(uri, file) }
                onExportFileSaved()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                onExportFileFailed()
            }
        }
    }

    fun onExportFileSaved() {
        shouldTriggerSave = false
        
        
        discardExportedFile()
        exportSuccess = true
    }

    fun onExportFileFailed() {
        shouldTriggerSave = false
        discardExportedFile()
        exportError = UiText.Resource(R.string.backup_error_save_failed)
    }

    override fun onCleared() {
        super.onCleared()
        
        discardExportedFile()
    }

    private fun createExportScratchFile(): File {
        if (!exportScratchDir.exists()) exportScratchDir.mkdirs()
        return File(exportScratchDir, "$EXPORT_SCRATCH_PREFIX${System.currentTimeMillis()}$EXPORT_SCRATCH_SUFFIX")
    }

    private fun discardExportedFile() {
        exportedFile?.delete()
        exportedFile = null
    }

    fun dismissExportSuccess() {
        exportSuccess = false
    }

    

    fun handleFileSelected(uri: Uri, readBytes: suspend (Uri) -> ByteArray) {
        viewModelScope.launch {
            importError = null
            importErrorDetail = null
            try {
                
                val bytes = withContext(ioDispatcher) { readBytes(uri) }
                val inspection = withContext(ioDispatcher) { backupService.inspectBackup(bytes) }
                parsedFileUri = uri
                parsedFileBytes = bytes
                parsedRequiresKeyPassword = inspection.requiresKeyPassword
                importPreview = inspection.preview
                checksumWarning = inspection.checksumWarning
                attachmentWarning = inspection.attachmentWarning
                showImportPreview = true
            } catch (e: Exception) {
                importError = mapError(e)
                importErrorDetail = e.stackTraceToString().take(500)
            }
        }
    }

    fun confirmImport() {
        if (selectedImportMode == ImportMode.ReplaceAll) {
            showReplaceConfirmation = true
            return
        }
        proceedAfterModeSelection()
    }

    fun confirmReplace() {
        showReplaceConfirmation = false
        proceedAfterModeSelection()
    }

    private fun proceedAfterModeSelection() {
        if (parsedRequiresKeyPassword) {
            showImportPreview = false
            showPasswordPrompt = true
        } else {
            startImport()
        }
    }

    fun unlockAndImport() {
        passwordError = null
        showPasswordPrompt = false
        startImport()
    }

    fun skipApiKeys() {
        importPassword = ""
        showPasswordPrompt = false
        startImport()
    }

    private fun startImport() {
        showImportPreview = false
        viewModelScope.launch {
            isImporting = true
            importError = null
            try {
                val bytes = parsedFileBytes
                    ?: throw IllegalStateException("No backup file loaded")
                val result = withContext(ioDispatcher) {
                    
                    
                    
                    val replaceAllSnapshot = if (selectedImportMode == ImportMode.ReplaceAll) {
                        null
                    } else {
                        null
                    }
                    try {
                        val imported = backupService.executeImport(
                            mode = selectedImportMode,
                            password = importPassword.takeIf { it.isNotEmpty() },
                            bytes = bytes,
                            targetAccountIdOverride = null,
                        )
                        Unit
                        imported
                    } catch (e: Throwable) {
                        
                        Unit
                        throw e
                    }
                }
                importResult = result
                showImportResult = true
                
                appPreferencesRepository.completeOnboarding()
                loadDataSummary()
            } catch (e: BackupError.WrongPassword) {
                
                importPassword = ""
                passwordError = UiText.Resource(R.string.backup_error_wrong_password)
                showPasswordPrompt = true
            } catch (e: Exception) {
                importError = mapError(e)
                importErrorDetail = e.stackTraceToString().take(500)
            } finally {
                isImporting = false
            }
        }
    }

    fun dismissImportPreview() {
        showImportPreview = false
        resetImportState()
    }

    fun dismissPasswordPrompt() {
        showPasswordPrompt = false
        resetImportState()
    }

    fun dismissImportResult() {
        showImportResult = false
        resetImportState()
    }

    fun clearImportError() {
        importError = null
        importErrorDetail = null
    }

    private fun resetImportState() {
        parsedFileUri = null
        parsedFileBytes = null
        parsedRequiresKeyPassword = false
        importPreview = null
        importPassword = ""
        passwordError = null
        checksumWarning = false
        attachmentWarning = false
        selectedImportMode = ImportMode.ImportNewOnly
        importResult = null
    }

    companion object {
        private const val EXPORT_SCRATCH_PREFIX = "oriveo-backup-export-"
        private const val EXPORT_SCRATCH_SUFFIX = ".oriveo"
    }

    private fun mapError(error: Throwable): UiText = when (error) {
        is BackupError.NoDataToExport -> UiText.Resource(R.string.backup_error_no_data_to_export)
        
        is InputSizeLimitExceededException -> UiText.Resource(R.string.backup_error_too_large)
        is BackupError.ResourceLimitExceeded -> UiText.Resource(R.string.backup_error_too_large)
        is BackupError.UnrecognizedFormat -> UiText.Resource(R.string.backup_error_invalid_format)
        is BackupError.VersionTooNew -> UiText.Resource(
            R.string.backup_error_version_too_new,
            listOf(error.version),
        )
        is BackupError.WrongPassword -> UiText.Resource(R.string.backup_error_wrong_password)
        is BackupError.AccountChanged -> UiText.Resource(R.string.backup_error_account_changed)
        else -> error.message?.let(UiText::Dynamic)
            ?: UiText.Resource(R.string.backup_error_unknown)
    }
}
