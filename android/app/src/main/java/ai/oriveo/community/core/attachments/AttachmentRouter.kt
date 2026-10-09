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

    /**
     * Size in bytes of the original file, compared against the per-file threshold.
     *
     * Derived from the length of the original bytes' base64 rather than [Attachment.extractedSizeBytes], which can
     * be missing on older messages and on attachments synced from another client; a missing value would skip the
     * threshold. An attachment that still has its original bytes on disk and carries only a placeholder (the
     * pre-send check) has no length to compute, and only then is the recorded field read. When both exist the
     * larger one wins.
     */
    internal fun originalByteCount(attachment: Attachment): Long {
        val recorded = (attachment.extractedSizeBytes ?: 0).toLong()
        val base64 = attachment.originalBase64Data
        if (base64.isNullOrEmpty() || base64 == AttachmentHydrator.PENDING_ORIGINAL_PLACEHOLDER) return recorded
        val padding = base64.takeLast(2).count { it == '=' }
        val decoded = base64.length.toLong() / 4L * 3L - padding
        return maxOf(recorded, decoded)
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

        if (originalByteCount(attachment) > maxNativeBytes(provider)) {
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
