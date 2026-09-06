package ai.oriveo.community.feature.chat

import android.content.Context
import android.net.Uri
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.attachments.AttachmentImportLimiter
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.FileExtractionLimits
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.chat.attachments.AttachmentImportOutcome
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor

internal class ChatAttachmentCoordinator(
    private val attachmentProcessor: AttachmentProcessor,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val activeProviderKind: () -> ProviderKind?,
    private val activeModel: () -> AIModel?,
    private val pendingAttachments: () -> List<Attachment>,
    private val addAttachment: (Attachment, String) -> Unit,
    private val presentAttachmentSizeLimitDialog: () -> Unit,
) {
    /**
     * Hard cap on how many attachments one message may carry.
     *
     * The limit is a total across kinds: images, videos and files share one budget rather than
     * getting one each. Images used to have no limit at all, and adding a couple of hundred of them
     * made a single message row large enough to break the writes it took part in.
     *
     * When the attachment does not fit, this shows the limit message and returns false; the caller
     * ([ChatViewModel.addAttachment]) simply drops it.
     */
    fun accepts(attachment: Attachment): Boolean {
        val maxAttachments = FileExtractionLimits.resolve(activeModel()).maxFiles
        val limited = AttachmentImportLimiter.limit(
            existing = pendingAttachments(),
            incoming = listOf(attachment),
            maxAttachments = maxAttachments,
        )
        if (limited.rejectedCount > 0) {
            showCountLimitReached(maxAttachments)
            return false
        }
        return true
    }

    private fun showCountLimitReached(maxAttachments: Int) {
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = UiText.Resource(
                    R.string.file_attachment_count_limit_reached,
                    listOf(maxAttachments),
                ),
            ),
        )
    }

    suspend fun processImage(context: Context, uri: Uri) {
        when (val outcome = attachmentProcessor.processImage(context, uri)) {
            is AttachmentImportOutcome.Success -> addAttachment(outcome.attachment, outcome.source)
            AttachmentImportOutcome.Oversized -> presentAttachmentSizeLimitDialog()
            else -> Unit
        }
    }

    suspend fun processFile(context: Context, uri: Uri) {
        val currentFileCount = pendingAttachments().count { it.kind == AttachmentKind.File }
        when (val outcome = attachmentProcessor.processFile(
            context = context,
            uri = uri,
            activeProviderKind = activeProviderKind(),
            activeModel = activeModel(),
            currentFileCount = currentFileCount,
        )) {
            is AttachmentImportOutcome.Success -> addAttachment(outcome.attachment, outcome.source)
            AttachmentImportOutcome.Oversized -> presentAttachmentSizeLimitDialog()
            AttachmentImportOutcome.UnsupportedFile ->
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(message = UiText.Resource(R.string.import_failed)),
                )
            AttachmentImportOutcome.AttachmentConflict ->
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(message = UiText.Resource(R.string.attachment_conflict_message)),
                )
            is AttachmentImportOutcome.FileCountLimitExceeded ->

                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(
                            R.string.file_attachment_count_limit_reached,
                            listOf(FileExtractionLimits.resolve(activeModel()).maxFiles),
                        ),
                    ),
                )
            is AttachmentImportOutcome.FileExtractionError -> {
                outcome.partial?.let { addAttachment(it, "file") }
                globalSnackbarManager.show(
                    GlobalSnackbarMessage(
                        message = UiText.Resource(errorMessageResFor(outcome.code), listOf(outcome.fileName)),
                    ),
                )
            }
            AttachmentImportOutcome.Silent -> Unit
        }
    }

    private fun errorMessageResFor(code: ExtractionErrorCode): Int = when (code) {
        ExtractionErrorCode.ScannedPdf -> R.string.file_extraction_error_scanned_pdf
        ExtractionErrorCode.EncryptedPdf -> R.string.file_extraction_error_encrypted_pdf
        ExtractionErrorCode.PasswordProtectedOffice -> R.string.file_extraction_error_corrupted
        ExtractionErrorCode.CorruptedFile -> R.string.file_extraction_error_corrupted
        ExtractionErrorCode.UnsupportedFormat -> R.string.file_extraction_error_unsupported
        ExtractionErrorCode.FileTooLarge -> R.string.file_extraction_error_too_large
        ExtractionErrorCode.ExtractionTimeout -> R.string.file_extraction_error_generic
        ExtractionErrorCode.ExtractionError -> R.string.file_extraction_error_generic
    }
}
