package ai.oriveo.community.feature.chat

import android.content.Context
import android.net.Uri
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.attachments.AttachmentImportLimiter
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.FileExtractionLimits
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AttachmentSendPreflight
import ai.oriveo.community.feature.chat.attachments.AttachmentImportOutcome
import ai.oriveo.community.feature.chat.attachments.AttachmentImportPolicy
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class ChatAttachmentCoordinator(
    private val attachmentProcessor: AttachmentProcessor,
    private val globalSnackbarManager: GlobalSnackbarManager,
    /** The current connection; the text-budget gate at add time needs it to resolve the route. When it is unavailable the gate is skipped and left to the send-time check. */
    private val activeProvider: () -> Provider? = { null },
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

    /**
     * Editing a message that has attachments: the original attachments return to the composer together with the text,
     * so changing one word does not lose the files. Returns the ones to put back.
     *
     * They pass through the same gates as newly added ones: kinds the current model does not accept are not put back,
     * and anything beyond the count limit is dropped with a single notice. The original message is deleted by the
     * edit, so the restored copies get fresh ids and are stored as new attachments when sent; the local references to
     * the original image or raw bytes are unaffected by the deletion and are kept as they are.
     */
    fun restoredForEdit(
        original: List<Attachment>,
        supportsImage: () -> Boolean,
        supportsFile: () -> Boolean,
        supportsVideo: () -> Boolean,
    ): List<Attachment> {
        if (original.isEmpty()) return emptyList()
        val supported = original.filter { attachment ->
            when (attachment.kind) {
                AttachmentKind.Image -> supportsImage()
                AttachmentKind.Video -> supportsVideo()
                AttachmentKind.File -> supportsFile()
            }
        }
        val maxAttachments = FileExtractionLimits.resolve(activeModel()).maxFiles
        val limited = AttachmentImportLimiter.limit(
            existing = pendingAttachments(),
            incoming = supported,
            maxAttachments = maxAttachments,
        )
        if (limited.rejectedCount > 0) showCountLimitReached(maxAttachments)
        return limited.accepted.map {
            it.copy(id = ai.oriveo.community.core.util.generateUuidString())
        }
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

    /**
     * Imports one attachment at a time.
     *
     * The picker is multi-select and the caller starts one coroutine per URI. Without a queue, N
     * files are read into the heap in full at the same moment and handed to the parsers together,
     * so peak memory is N files rather than one; a handful of large PDFs is enough to fill a
     * 256 MB heap within seconds of the picker closing. Queueing also fixes two other things: the
     * count limit is checked before the file is read, against how many are already attached, and
     * concurrent imports all saw zero, which made the limit meaningless; and the order
     * attachments land in no longer depends on which one finishes parsing first.
     *
     * The mutex is fair (first come, first served), so attachments reach the composer in the
     * order they were picked.
     */
    private val importMutex = Mutex()

    suspend fun processImage(context: Context, uri: Uri): Unit = importMutex.withLock {
        when (val outcome = attachmentProcessor.processImage(context, uri)) {
            is AttachmentImportOutcome.Success -> addAttachment(outcome.attachment, outcome.source)
            AttachmentImportOutcome.Oversized -> presentAttachmentSizeLimitDialog()
            else -> Unit
        }
    }

    /**
     * The number of files queued or being imported. The N files from one picker callback each start a coroutine on the same tick, and each
     * counts itself here before waiting on [importMutex]; when the count returns to 0 the batch is done. Read and written on the main thread only.
     */
    private var queuedFileImports = 0

    /** Notices collected during this batch (truncation, text budget full), merged into one at the end of the batch. */
    private val pendingImportNotices = mutableListOf<UiText>()

    suspend fun processFile(context: Context, uri: Uri) {
        queuedFileImports += 1
        try {
            importMutex.withLock { importFile(context, uri) }
        } finally {
            queuedFileImports -= 1
            if (queuedFileImports == 0) flushTruncationNotices()
        }
    }

    private suspend fun importFile(context: Context, uri: Uri) {
        val currentFileCount = pendingAttachments().count { it.kind == AttachmentKind.File }
        when (val outcome = attachmentProcessor.processFile(
            context = context,
            uri = uri,
            activeProviderKind = activeProviderKind(),
            activeModel = activeModel(),
            currentFileCount = currentFileCount,
        )) {
            is AttachmentImportOutcome.Success -> {
                if (exceedsTextBudget(outcome.attachment)) {
                    // Adding it would put this message's attached text over the limit: say so now instead of waiting for the send to block.
                    pendingImportNotices += UiText.Resource(
                        R.string.file_extraction_text_budget_exceeded,
                        listOf(outcome.attachment.fileName),
                    )
                } else {
                    addAttachment(outcome.attachment, outcome.source)
                    outcome.truncation?.let { showTruncatedNotice(outcome.attachment, it) }
                }
            }
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
                        message = UiText.Resource(errorMessageResFor(outcome.code), errorMessageArgsFor(outcome)),
                    ),
                )
            }
            AttachmentImportOutcome.Silent -> Unit
        }
    }

    private fun exceedsTextBudget(attachment: Attachment): Boolean {
        val provider = activeProvider() ?: return false
        val model = activeModel() ?: return false
        return AttachmentSendPreflight.exceedsTextBudgetOnAdd(provider, model, pendingAttachments(), attachment)
    }

    // Only say "the first N lines were added" when the attachment really entered the composer: a file turned away by
    // the count limit already got the limit message, and must not be followed by a statement that contradicts it.
    private fun showTruncatedNotice(attachment: Attachment, truncation: AttachmentImportOutcome.Truncation) {
        if (pendingAttachments().none { it.id == attachment.id }) return
        pendingImportNotices += UiText.Resource(
            R.string.file_extraction_truncated_notice,
            listOf(attachment.fileName, truncation.shownLines, truncation.totalLines),
        )
    }

    // The notices of one import batch are merged into a single multi-line message: the snackbar shows one message at a
    // time, so showing them one by one would leave only the last file's notice visible.
    private fun flushTruncationNotices() {
        if (pendingImportNotices.isEmpty()) return
        val notices = pendingImportNotices.toList()
        pendingImportNotices.clear()
        globalSnackbarManager.show(
            GlobalSnackbarMessage(
                message = notices.singleOrNull() ?: UiText.Lines(notices),
                style = GlobalToastStyle.Warning,
            ),
        )
    }

    // "File too large" states the limit the extractor actually used this time: a model override
    // can lower it below the 50 MB default.
    private fun errorMessageArgsFor(outcome: AttachmentImportOutcome.FileExtractionError): List<Any> =
        if (outcome.code == ExtractionErrorCode.FileTooLarge) {
            listOf(
                outcome.fileName,
                AttachmentImportPolicy.sizeLimitMegabytes(FileExtractionLimits.resolve(activeModel()).maxInputFileBytes),
            )
        } else {
            listOf(outcome.fileName)
        }

    private fun errorMessageResFor(code: ExtractionErrorCode): Int = when (code) {
        ExtractionErrorCode.ScannedPdf -> R.string.file_extraction_error_scanned_pdf
        ExtractionErrorCode.EncryptedPdf -> R.string.file_extraction_error_encrypted_pdf
        ExtractionErrorCode.PasswordProtectedOffice -> R.string.file_extraction_error_encrypted_pdf
        ExtractionErrorCode.CorruptedFile -> R.string.file_extraction_error_corrupted
        ExtractionErrorCode.UnsupportedFormat -> R.string.file_extraction_error_unsupported
        ExtractionErrorCode.FileTooLarge -> R.string.file_extraction_error_too_large
        ExtractionErrorCode.ExtractionTimeout -> R.string.file_extraction_error_generic
        ExtractionErrorCode.ExtractionError -> R.string.file_extraction_error_generic
    }
}
