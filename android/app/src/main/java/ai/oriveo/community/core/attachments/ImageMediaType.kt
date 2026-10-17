package ai.oriveo.community.core.attachments

import java.util.Base64

/**
 * The MIME sent upstream for an image follows its actual bytes; the attachment's declared MIME is only a fallback.
 *
 * Anthropic rejects images whose media_type doesn't match the bytes (400 "Image does not match the provided
 * media type"), and so does a relay that forwards a data URL to Claude. Stored attachments can be mislabeled:
 * older builds compressed PNG screenshots / HEIC photos to JPEG but kept the original MIME, and the thumbnail
 * fallback (`base64Data ?: thumbnailBase64`) is always JPEG. Only the first 12 bytes are decoded.
 */
object ImageMediaType {

    fun resolve(base64: String, declared: String): String = sniff(base64) ?: declared

    fun sniff(base64: String): String? {
        val head = runCatching { Base64.getMimeDecoder().decode(base64.take(HEAD_BASE64_CHARS)) }.getOrNull()
            ?: return null
        fun at(index: Int) = head.getOrNull(index)?.toInt()?.and(0xFF)
        fun ascii(from: Int, text: String) = text.indices.all { at(from + it) == text[it].code }
        return when {
            at(0) == 0xFF && at(1) == 0xD8 && at(2) == 0xFF -> "image/jpeg"
            at(0) == 0x89 && ascii(1, "PNG") -> "image/png"
            ascii(0, "GIF8") -> "image/gif"
            ascii(0, "RIFF") && ascii(8, "WEBP") -> "image/webp"
            else -> null
        }
    }

    // 16 base64 characters decode to exactly 12 bytes, enough to see WebP (bytes 8-11)
    private const val HEAD_BASE64_CHARS = 16
}
