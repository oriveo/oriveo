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
