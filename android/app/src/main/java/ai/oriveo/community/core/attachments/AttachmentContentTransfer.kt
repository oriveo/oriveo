package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import java.util.Base64

object AttachmentHydrator {

    suspend fun hydrate(
        messages: List<ChatMessage>,
        loadImageBase64: suspend (String) -> String?,
        loadBlobBase64: suspend (String) -> String?,
    ): List<ChatMessage> = messages.map { msg ->
        val attachments = msg.attachments
        if (attachments.isNullOrEmpty()) return@map msg
        val hydrated = attachments.map { hydrateOne(it, loadImageBase64, loadBlobBase64) }
        if (hydrated == attachments) msg else msg.copy(attachments = hydrated)
    }

    /**
     * For the pre-send check: looks at the attachment as if hydration succeeded at send time, without reading the disk.
     *
     * Routing only cares whether the original bytes exist, so a file that already has extracted text and whose original bytes are still on disk can be treated as hydrated;
     * for a file whose extracted text is not hydrated yet, the body size is unknown at this point, so it returns null.
     */
    fun assumeHydratedForRouting(attachment: Attachment): Attachment? {
        if (attachment.kind != AttachmentKind.File || attachment.rawContentRef.isNullOrBlank()) return attachment
        if (attachment.base64Data == null) return null
        if (!attachment.originalBase64Data.isNullOrEmpty()) return attachment
        return attachment.copy(originalBase64Data = PENDING_ORIGINAL_PLACEHOLDER)
    }

    /** Only means "the original bytes are on disk and will be hydrated at send time"; an attachment carrying it must not be used to build a request body. */
    internal const val PENDING_ORIGINAL_PLACEHOLDER = "pending"

    suspend fun hydrateOne(
        attachment: Attachment,
        loadImageBase64: suspend (String) -> String?,
        loadBlobBase64: suspend (String) -> String?,
    ): Attachment {
        if (attachment.kind == AttachmentKind.Image) {
            if (!attachment.base64Data.isNullOrEmpty()) return attachment
            val localImageId = attachment.localImageId ?: return attachment
            val base64 = loadImageBase64(localImageId) ?: return attachment
            return attachment.copy(base64Data = base64)
        }

        val ref = attachment.rawContentRef
        if (ref.isNullOrBlank()) return attachment

        return when (attachment.kind) {
            AttachmentKind.Video -> {
                if (!attachment.base64Data.isNullOrEmpty()) return attachment
                val base64 = loadBlobBase64(ref) ?: return attachment
                attachment.copy(base64Data = base64)
            }
            AttachmentKind.File -> {
                when {

                    attachment.base64Data == null -> {
                        val base64 = loadBlobBase64(ref) ?: return attachment
                        attachment.copy(base64Data = base64)
                    }
                    attachment.originalBase64Data.isNullOrEmpty() -> {
                        val base64 = loadBlobBase64(ref) ?: return attachment
                        attachment.copy(originalBase64Data = base64)
                    }
                    else -> attachment
                }
            }
            AttachmentKind.Image -> attachment
        }
    }
}

object AttachmentSlimmer {

    const val RAW_FILE_TEXT_THRESHOLD_CHARS = 400_000

    suspend fun slim(
        attachment: Attachment,
        saveImage: suspend (ByteArray) -> String,
        saveBlob: suspend (ByteArray) -> String,
    ): Attachment {
        return when (attachment.kind) {
            AttachmentKind.Image -> slimImage(attachment, saveImage)
            AttachmentKind.Video -> slimVideo(attachment, saveBlob)
            AttachmentKind.File -> slimFile(attachment, saveBlob)
        }
    }

    private fun decode(base64: String): ByteArray? =
        runCatching { Base64.getDecoder().decode(base64) }.getOrNull()

    private suspend fun slimImage(attachment: Attachment, saveImage: suspend (ByteArray) -> String): Attachment {
        val base64 = attachment.base64Data
        if (base64.isNullOrEmpty()) return attachment

        if (!attachment.localImageId.isNullOrBlank()) {
            return attachment.copy(base64Data = null)
        }
        val bytes = decode(base64) ?: return attachment.copy(base64Data = null)
        val localId = runCatching { saveImage(bytes) }.getOrNull() ?: return attachment
        return attachment.copy(base64Data = null, localImageId = localId)
    }

    private suspend fun slimVideo(attachment: Attachment, saveBlob: suspend (ByteArray) -> String): Attachment {
        val base64 = attachment.base64Data
        if (base64.isNullOrEmpty()) return attachment
        val bytes = decode(base64) ?: return attachment.copy(base64Data = null)
        val ref = runCatching { saveBlob(bytes) }.getOrNull() ?: return attachment
        return attachment.copy(base64Data = null, rawContentRef = ref)
    }

    private suspend fun slimFile(attachment: Attachment, saveBlob: suspend (ByteArray) -> String): Attachment {
        var result = attachment

        val original = result.originalBase64Data
        if (!original.isNullOrEmpty()) {
            val bytes = decode(original)
            result = if (bytes == null) {
                result.copy(originalBase64Data = null)
            } else {
                val ref = runCatching { saveBlob(bytes) }.getOrNull()
                if (ref != null) {
                    result.copy(originalBase64Data = null, rawContentRef = ref)
                } else {
                    result.copy(originalBase64Data = null)
                }
            }
        }

        val inline = result.base64Data
        if (!inline.isNullOrEmpty() && inline.length > RAW_FILE_TEXT_THRESHOLD_CHARS) {
            val bytes = decode(inline)
            result = if (bytes == null) {
                result.copy(base64Data = null)
            } else {
                val ref = runCatching { saveBlob(bytes) }.getOrNull()
                if (ref != null) {
                    result.copy(base64Data = null, rawContentRef = ref)
                } else {
                    result.copy(base64Data = null)
                }
            }
        }
        return result
    }
}
