package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment

object AttachmentImportLimiter {

    data class Result(
        val accepted: List<Attachment>,
        val rejectedCount: Int,
    )

    fun limit(
        existing: List<Attachment>,
        incoming: List<Attachment>,
        maxAttachments: Int,
    ): Result {
        if (maxAttachments <= 0) {
            return Result(accepted = emptyList(), rejectedCount = incoming.size)
        }

        val availableSlots = (maxAttachments - existing.size).coerceAtLeast(0)
        if (availableSlots == 0) {
            return Result(accepted = emptyList(), rejectedCount = incoming.size)
        }
        if (incoming.size <= availableSlots) {
            return Result(accepted = incoming, rejectedCount = 0)
        }
        return Result(
            accepted = incoming.take(availableSlots),
            rejectedCount = incoming.size - availableSlots,
        )
    }
}
