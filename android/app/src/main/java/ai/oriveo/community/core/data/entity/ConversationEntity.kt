package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/**
 * One conversation.
 *
 * Ids compare case-insensitively. UUIDs reach this table from more than one place and not every
 * writer agrees on letter case, so a binary comparison would happily store the same conversation
 * twice and then render it twice in the list.
 */
@Entity(
    tableName = "conversations",
    primaryKeys = ["id", "accountId"],
    indices = [
        Index("accountId"),
        Index(value = ["accountId", "updatedAt"]),
        Index("folderID"),
    ],
)
data class ConversationEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    val title: String,
    val hasCustomTitle: Boolean,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val providerID: String,
    /** `ProviderKind.name`. */
    val providerKind: String,
    val modelID: String,
    val useMemory: Boolean = true,
    val previewText: String,
    val estimatedCost: Double,
    val isDraft: Boolean,
    val draftText: String,
    val createdAt: Long,
    val updatedAt: Long,
    /** Folder this conversation sits in; null means it is unfiled. */
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val folderID: String? = null,
    /** Skill the conversation was started from, if any. */
    val skillId: String? = null,
    /** See [ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID]. */
    val accountId: String = "local",
    /** Up to three notes pinned into this conversation's prompt, as a JSON id array. */
    val pinnedNoteIdsJson: String? = null,
)
