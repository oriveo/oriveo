package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ProviderKind

enum class AttachmentRoute {
    Native,
    ClientExtract,
}

object AttachmentRouter {

    private const val PDF_MIME = "application/pdf"
    private const val SCANNED_PDF_CODE = "scanned_pdf"

    fun maxNativeBytes(provider: ProviderKind): Int = when (provider) {
        ProviderKind.OpenAI -> 25 * 1024 * 1024
        ProviderKind.Anthropic -> 25 * 1024 * 1024
        ProviderKind.Gemini -> 20 * 1024 * 1024
        else -> 25 * 1024 * 1024
    }

    fun decide(
        attachment: Attachment,
        provider: ProviderKind,
        model: AIModel,
    ): AttachmentRoute {
        if (attachment.kind != AttachmentKind.File) return AttachmentRoute.ClientExtract

        val mime = attachment.mimeType.lowercase()
        if (!model.nativeFileMimes.contains(mime)) return AttachmentRoute.ClientExtract

        val base64 = attachment.originalBase64Data
        if (base64.isNullOrEmpty()) return AttachmentRoute.ClientExtract

        val bytes = attachment.extractedSizeBytes ?: 0
        if (bytes > 0 && bytes > maxNativeBytes(provider)) {
            return AttachmentRoute.ClientExtract
        }

        if (mime == PDF_MIME) {
            if (attachment.extractionErrorCode == SCANNED_PDF_CODE) {
                return AttachmentRoute.Native
            }
            if (model.pdfNativeDefault) {
                return AttachmentRoute.Native
            }
            return AttachmentRoute.ClientExtract
        }

        return AttachmentRoute.Native
    }
}
