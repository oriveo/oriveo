package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Fts4
import androidx.room.Index

/**
 * One note.
 *
 * Timestamps are UTC ISO 8601 strings rather than epoch numbers so that a note exported to a
 * backup file stays readable and unambiguous. Tags and provenance are JSON text for the same
 * reason: they are read whole and never queried by their contents.
 */
@Entity(
    tableName = "notes",
    primaryKeys = ["id", "accountId"],
    indices = [
        Index("accountId"),
        Index("updatedAt"),
        Index("noteFolderID"),
        Index("deletedAt"),
    ],
)
data class NoteEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    val title: String,
    /** `NoteTitleSource` raw value. */
    val titleSource: String,
    val body: String,
    val bodySnapshot: String? = null,
    val userNote: String? = null,
    /** `List<String>` as JSON. */
    val tagsJson: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val noteFolderID: String? = null,
    val sourceConversationId: String? = null,
    val sourceMessageId: String? = null,
    val sourceModelID: String? = null,
    val sourceModelName: String? = null,
    /** `ProviderKind` raw value. */
    val sourceProviderKind: String? = null,
    val sourceProviderName: String? = null,
    val sourcePrompt: String? = null,
    /** `NoteCaptureKind` raw value. */
    val captureKind: String,
    /** `List<ProvenanceEntry>` as JSON; null when the note has no recorded provenance. */
    val provenanceJson: String? = null,
    val isPinned: Boolean = false,
    val createdAt: String,
    val updatedAt: String,
    /** Soft delete, as a UTC ISO 8601 string. Null means the note is live. */
    val deletedAt: String? = null,
    /** See [ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID]. */
    val accountId: String = "local",
)

/**
 * A note folder. Unlike [FolderEntity] it carries a `deletedAt`, because a deleted note folder has
 * to keep existing long enough for its notes to be moved out of it.
 */
@Entity(
    tableName = "note_folders",
    primaryKeys = ["id", "accountId"],
    indices = [
        Index("accountId"),
        Index("sortOrder"),
        Index("deletedAt"),
    ],
)
data class NoteFolderEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    val name: String,
    val sortOrder: Int,
    val colorTag: String? = null,
    val createdAt: String,
    val updatedAt: String,
    val deletedAt: String? = null,
    /** See [ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID]. */
    val accountId: String = "local",
)

/**
 * Full-text search index over notes.
 *
 * Room offers no FTS5 mapping, and FTS4 already provides everything the search screen needs. The
 * table owns its own copy of the text instead of using `contentEntity`, because the indexed text
 * is a flattened projection (title, body, user note and tags concatenated) rather than a column
 * copy. `noteId` and `accountId` are stored but not indexed: they are join keys, never search
 * terms.
 */
@Fts4(notIndexed = ["noteId", "accountId"])
@Entity(tableName = "note_search_index")
data class NoteFtsEntity(
    val noteId: String,
    val accountId: String,
    val title: String,
    val body: String,
    val userNote: String,
    val tagsText: String,
)
