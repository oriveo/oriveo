package ai.oriveo.community.feature.chat

import android.content.Context
import android.net.Uri
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.attachments.FileTextExtractor
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentExtractionLimits
import ai.oriveo.community.feature.chat.attachments.AttachmentImportOutcome
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** Which message the snackbar shows when a file import fails, and with which arguments. */
class ChatAttachmentCoordinatorErrorMessageTest {

    @Test
    fun `a password protected office document is reported as password protected not corrupted`() = runTest {
        val shown = showErrorFor(ExtractionErrorCode.PasswordProtectedOffice, "plan.docx")

        assertEquals(R.string.file_extraction_error_encrypted_pdf, shown.resId)
        assertEquals(listOf<Any>("plan.docx"), shown.args)
    }

    @Test
    fun `an encrypted docx goes from the real extractor to the password protected message`() = runTest {
        // An encrypted OOXML file is an OLE compound document, not a zip; only its 8-byte header is needed here.
        val oleHeader = byteArrayOf(
            0xD0.toByte(), 0xCF.toByte(), 0x11, 0xE0.toByte(), 0xA1.toByte(), 0xB1.toByte(), 0x1A, 0xE1.toByte(),
        )
        val error = runCatching {
            FileTextExtractor.extract(
                oleHeader + ByteArray(504),
                "plan.docx",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            )
        }.exceptionOrNull()
        val code = (error as ExtractionException).code

        val shown = showErrorFor(code, "plan.docx")

        assertEquals(R.string.file_extraction_error_encrypted_pdf, shown.resId)
    }

    @Test
    fun `a password protected pdf keeps the password protected message`() = runTest {
        val shown = showErrorFor(ExtractionErrorCode.EncryptedPdf, "scan.pdf")

        assertEquals(R.string.file_extraction_error_encrypted_pdf, shown.resId)
    }

    @Test
    fun `too large reports the extractor default limit`() = runTest {
        val shown = showErrorFor(ExtractionErrorCode.FileTooLarge, "big.pdf")

        assertEquals(R.string.file_extraction_error_too_large, shown.resId)
        assertEquals(listOf<Any>("big.pdf", 50), shown.args)
    }

    @Test
    fun `too large reports the limit the active model lowered it to`() = runTest {
        val model = AIModel(
            id = "m",
            name = "m",
            attachmentExtraction = AttachmentExtractionLimits(maxInputFileBytes = 10 * 1024 * 1024),
        )

        val shown = showErrorFor(ExtractionErrorCode.FileTooLarge, "big.pdf", model)

        assertEquals(listOf<Any>("big.pdf", 10), shown.args)
    }

    private suspend fun showErrorFor(
        code: ExtractionErrorCode,
        fileName: String,
        model: AIModel? = null,
    ): UiText.Resource {
        val processor = mockk<AttachmentProcessor>()
        coEvery { processor.processFile(any(), any(), any(), any(), any()) } returns
            AttachmentImportOutcome.FileExtractionError(code = code, fileName = fileName, partial = null)
        val snackbars = GlobalSnackbarManager()
        val coordinator = ChatAttachmentCoordinator(
            attachmentProcessor = processor,
            globalSnackbarManager = snackbars,
            activeProviderKind = { null },
            activeModel = { model },
            pendingAttachments = { emptyList() },
            addAttachment = { _, _ -> },
            presentAttachmentSizeLimitDialog = {},
        )

        coordinator.processFile(mockk<Context>(), mockk<Uri>())

        return snackbars.active.value?.message?.message as UiText.Resource
    }
}
