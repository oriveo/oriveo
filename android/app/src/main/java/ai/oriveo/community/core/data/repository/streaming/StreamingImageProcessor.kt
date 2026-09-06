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
                    val localId = attachmentStore.saveImage(bytes, att.mimeType)
                    val thumbBase64 = attachmentStore.loadThumbnailBase64(localId)
                    att.copy(
                        base64Data = null,
                        localImageId = localId,
                        thumbnailBase64 = thumbBase64,
                    )
                }.getOrElse { att }
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
