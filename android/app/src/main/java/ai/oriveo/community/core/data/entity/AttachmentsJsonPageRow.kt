package ai.oriveo.community.core.data.entity

/**
 * Room query result DTO: attachmentsJson read page by page by `messages.rowid` (all accounts).
 * Used only to collect the reference set for attachment file cleanup; rows over the threshold are not in this
 * projection and go through [ai.oriveo.community.core.data.dao.MessageDao.findOversizedAttachmentsJsonRows] plus chunked reads.
 */
data class AttachmentsJsonPageRow(
    val rowId: Long,
    val attachmentsJson: String,
)
