package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionDeadline
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException

// Extract text from Office files (docx/xlsx/pptx): dispatch to the Docx / Xlsx / Pptx extractors
object OfficeTextExtractor {

    val supportedExtensions: Set<String> = setOf("docx", "xlsx", "pptx")

    fun isOfficeFile(extension: String): Boolean =
        supportedExtensions.contains(extension.lowercase())

    /**
     * Returns null for unsupported formats. Attachment extraction spec sections 4A-7, 15, 16.
     * [deadline] is the 30-second deadline of section 14, checked at zip entries, worksheets, slides and every 1000 rows.
     */
    @Throws(ExtractionException::class)
    fun extractText(
        data: ByteArray,
        fileExtension: String,
        deadline: ExtractionDeadline = ExtractionDeadline(),
    ): String? {
        val kind = fileExtension.lowercase()
        if (kind !in supportedExtensions) return null
        // A password-protected docx/xlsx/pptx is not a zip; its ciphertext is wrapped in an OLE compound document (section 16, decided before opening the zip).
        // Only checked for these three extensions: legacy .doc/.xls/.ppt are OLE themselves and must not be called encrypted.
        if (hasOleCompoundHeader(data)) {
            throw ExtractionException(ExtractionErrorCode.PasswordProtectedOffice)
        }
        val zip = ZipPackage.open(data, deadline, "Office")
        return when (kind) {
            "docx" -> DocxTextExtractor.extract(zip, deadline)
            "xlsx" -> XlsxTextExtractor.extract(zip, deadline)
            else -> PptxTextExtractor.extract(zip, deadline)
        }
    }

    private val OLE_COMPOUND_HEADER = byteArrayOf(
        0xD0.toByte(), 0xCF.toByte(), 0x11, 0xE0.toByte(), 0xA1.toByte(), 0xB1.toByte(), 0x1A, 0xE1.toByte(),
    )

    private fun hasOleCompoundHeader(data: ByteArray): Boolean =
        data.size >= OLE_COMPOUND_HEADER.size &&
            OLE_COMPOUND_HEADER.indices.all { data[it] == OLE_COMPOUND_HEADER[it] }
}
