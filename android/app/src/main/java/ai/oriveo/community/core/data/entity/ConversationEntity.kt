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
    /** Since v40: conversation-level instructions (normalized, at most 8000 code points); an empty string means none. */
    @ColumnInfo(defaultValue = "")
    val instructions: String = "",
    /** Since v5: stored text of the conversation input budget cap ("auto", "unlimited" or a decimal token count); null follows the global default. */
    val contextCap: String? = null,
    /** Since v6: JSON totals per non-USD currency ({"CNY": 3.5}); null means no non-USD cost. [estimatedCost] stays the USD total. */
    val nonUsdCostTotals: String? = null,
    /**
     * Since v49: local-only "thread complete" flag (E-634), never synced to the cloud. Set to true when a
     * local conversation is created or a full backfill of the thread succeeds; set to false while messages
     * are written piecemeal by window, fragment or backfill. Legacy rows default to false. The cost total
     * uses it to decide between a full recompute and an incremental update.
     */
    @ColumnInfo(defaultValue = "0")
    val localThreadComplete: Boolean = false,
    /** Since v9: selected skill ids as a JSON array (at most 3, sync ids); null means none. Legacy [skillId] is the first one, dual written. */
    val skillIdsJson: String? = null,
    /** Since v9: skills turned off for automatic use in this conversation, as a JSON array (at most 30); null means none. */
    val disabledAutoSkillIdsJson: String? = null,
)
