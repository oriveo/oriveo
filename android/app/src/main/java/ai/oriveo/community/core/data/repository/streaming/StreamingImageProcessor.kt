package ai.oriveo.community.core.data.repository.streaming

import android.util.Base64
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.attachments.MAX_MOBILE_ATTACHMENT_BYTES
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.readBytesLimited
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal class StreamingImageProcessor(
    private val attachmentStore: AttachmentStore,
) {

    suspend fun downloadHttpUrls(attachments: List<Attachment>): List<Attachment> {
        val resolved = mutableListOf<Attachment>()
        for (att in attachments) {
            if (att.kind == AttachmentKind.Image &&
                att.base64Data?.startsWith("http") == true
            ) {
                val downloaded = downloadImageUrl(att.base64Data)
                if (downloaded != null) {
                    resolved.add(att.copy(base64Data = downloaded))
                } else {
                    resolved.add(att)
                }
            } else {
                resolved.add(att)
            }
        }
        return resolved
    }

    fun extractInlineImages(finalText: String): Pair<String, List<Attachment>> {
        val (cleanedText, inlineImages) = MessageBuilder.extractInlineImages(finalText)
        val attachments = inlineImages.map { (mime, data) ->
            Attachment(
                id = generateUuidString(),
                kind = AttachmentKind.Image,
                fileName = "inline_image",
                mimeType = mime,
                base64Data = data,
            )
        }
        return cleanedText to attachments
    }

    suspend fun persistInlineBase64(attachments: List<Attachment>): List<Attachment> =
        withContext(Dispatchers.IO) {
            attachments.map { att ->
                if (att.kind != AttachmentKind.Image ||
                    att.localImageId != null ||
                    att.base64Data.isNullOrEmpty()
                ) return@map att
                runCatching {
                    val bytes = Base64.decode(att.base64Data, Base64.NO_WRAP)
                    // Generated images are finished output and are stored as-is; compression is only for images the user sends
                    val stored = attachmentStore.saveOriginalImage(bytes) ?: return@map att
                    val thumbBase64 = attachmentStore.loadThumbnailBase64(stored.id)
                    att.copy(
                        mimeType = stored.mimeType,
                        base64Data = null,
                        localImageId = stored.id,
                        thumbnailBase64 = thumbBase64,
                    )
                }.getOrElse { att }
            }
        }

    /**
     * Inline-image handling before a cancelled or failed message is persisted, with the same semantics
     * as the success path: inline images in the text become saved attachments, and base64 in the
     * streaming attachments is saved too. An unfinished stream may leave half a data URI in the text
     * (not decodable); it is stripped as well — left in the text it would push the messages row past
     * the 2MB CursorWindow, after which every whole-row read of it fails.
     */
    suspend fun localizeInlineImages(text: String, attachments: List<Attachment>): Pair<String, List<Attachment>> {
        val (cleanedText, inlineImages) = if (text.contains(INLINE_IMAGE_DATA_MARKER)) {
            extractInlineImages(text).let { (cleaned, images) -> stripInlineImageData(cleaned) to images }
        } else {
            text to emptyList()
        }
        return cleanedText to persistInlineBase64(attachments + inlineImages)
    }

    companion object {
        private const val INLINE_IMAGE_DATA_MARKER = "](data:image/"
        private val COMPLETE_INLINE_IMAGE = Regex("""!\[[^\]\n]*]\(data:image/[^;)]+;base64,[A-Za-z0-9+/=\s]*\)""")
        private val UNCLOSED_INLINE_IMAGE_TAIL = Regex("""!\[[^\]\n]*]\(data:image/[^)]*$""")

        /**
         * For mid-stream persistence: removes inline data:image images from the text (including a
         * not-yet-closed tail) and leaves the rest as-is. The UI renders the in-memory streamingText
         * and completion extracts images from the full in-memory text, so the stored copy loses
         * nothing by omitting them; storing them would let a single 2MB generated image make the row
         * unreadable.
         */
        internal fun stripInlineImageData(text: String): String {
            if (!text.contains(INLINE_IMAGE_DATA_MARKER)) return text
            return text.replace(COMPLETE_INLINE_IMAGE, "").replace(UNCLOSED_INLINE_IMAGE_TAIL, "")
        }
    }

    private suspend fun downloadImageUrl(url: String): String? = withContext(Dispatchers.IO) {
        try {
            val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
            try {
                connection.connectTimeout = 30_000
                connection.readTimeout = 30_000
                connection.requestMethod = "GET"
                val bytes = connection.inputStream.use {
                    it.readBytesLimited(MAX_MOBILE_ATTACHMENT_BYTES)
                }
                Base64.encodeToString(bytes, Base64.NO_WRAP)
            } finally {
                connection.disconnect()
            }
        } catch (_: Exception) {
            null
        }
    }
}
