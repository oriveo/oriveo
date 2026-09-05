package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole


object OutboundAttachmentBudget {

    
    const val DEFAULT_BUDGET_BYTES = 10L * 1024L * 1024L

    
    private fun base64SizeOf(rawBytes: Long): Long = (rawBytes + 2L) / 3L * 4L

    suspend fun apply(
        messages: List<ChatMessage>,
        budgetBytes: Long = DEFAULT_BUDGET_BYTES,
        imageSizeOf: suspend (String) -> Long,
        blobSizeOf: suspend (String) -> Long,
    ): List<ChatMessage> {
        if (messages.none { !it.attachments.isNullOrEmpty() }) return messages

        val lastUserIndex = messages.indexOfLast { it.role == ChatRole.User }
        val result = arrayOfNulls<ChatMessage>(messages.size)
        var used = 0L

        
        for (index in messages.indices.reversed()) {
            val message = messages[index]
            val attachments = message.attachments
            if (attachments.isNullOrEmpty()) {
                result[index] = message
                continue
            }

            val kept = ArrayList<Attachment>(attachments.size)
            val omissions = ArrayList<String>()
            val exempt = index == lastUserIndex

            for (attachment in attachments) {
                val cost = costOf(attachment, imageSizeOf, blobSizeOf)
                if (exempt || used + cost <= budgetBytes) {
                    used += cost
                    kept += attachment
                    continue
                }
                val lightened = lighten(attachment)
                if (lightened != null) {
                    used += inlineCost(lightened)
                    kept += lightened
                } else {
                    omissions += placeholderFor(attachment)
                }
            }

            result[index] = if (omissions.isEmpty() && kept == attachments) {
                message
            } else {
                message.copy(
                    text = appendOmissions(message.text, omissions),
                    attachments = kept.takeIf { it.isNotEmpty() },
                )
            }
        }

        @Suppress("UNCHECKED_CAST")
        return (result as Array<ChatMessage>).toList()
    }

    
    private suspend fun costOf(
        attachment: Attachment,
        imageSizeOf: suspend (String) -> Long,
        blobSizeOf: suspend (String) -> Long,
    ): Long {
        val inline = inlineCost(attachment)
        val fromDisk = when (attachment.kind) {
            AttachmentKind.Image ->
                if (attachment.base64Data.isNullOrEmpty()) {
                    attachment.localImageId?.let { imageSizeOf(it) } ?: 0L
                } else {
                    0L
                }
            AttachmentKind.Video, AttachmentKind.File ->
                attachment.rawContentRef?.takeIf { it.isNotBlank() }?.let { blobSizeOf(it) } ?: 0L
        }
        return inline + base64SizeOf(fromDisk)
    }

    
    private fun inlineCost(attachment: Attachment): Long =
        (attachment.base64Data?.length ?: 0).toLong() +
            (attachment.thumbnailBase64?.length ?: 0).toLong()

    
    private fun lighten(attachment: Attachment): Attachment? {
        if (attachment.kind != AttachmentKind.File) return null
        if (attachment.rawContentRef.isNullOrBlank()) return null
        
        if (attachment.base64Data.isNullOrEmpty()) return null
        return attachment.copy(rawContentRef = null, originalBase64Data = null)
    }

    private fun placeholderFor(attachment: Attachment): String {
        val label = when (attachment.kind) {
            AttachmentKind.Image -> "Image"
            AttachmentKind.Video -> "Video"
            AttachmentKind.File -> "File"
        }
        return "[$label omitted: ${attachment.fileName} " +
            "(older attachment dropped to keep this request small)]"
    }

    private fun appendOmissions(text: String, omissions: List<String>): String {
        if (omissions.isEmpty()) return text
        return listOfNotNull(text.takeIf { it.isNotBlank() })
            .plus(omissions)
            .joinToString("\n\n")
    }
}
