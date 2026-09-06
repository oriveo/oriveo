package ai.oriveo.community.core.attachments.extractors

import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper

object PdfTextExtractor {
    fun extract(data: ByteArray): String {
        val doc: PDDocument
        try {
            doc = PDDocument.load(data.inputStream())
        } catch (e: com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException) {

            throw ExtractionException(ExtractionErrorCode.EncryptedPdf, e.message)
        } catch (e: Exception) {
            throw ExtractionException(ExtractionErrorCode.CorruptedFile, e.message)
        }

        doc.use { document ->
            if (document.isEncrypted) {
                throw ExtractionException(ExtractionErrorCode.EncryptedPdf)
            }
            val stripper = PDFTextStripper()
            stripper.sortByPosition = true
            val text = stripper.getText(document).trim()
            if (text.isEmpty()) {

                throw ExtractionException(ExtractionErrorCode.ScannedPdf)
            }
            return text
        }
    }
}
