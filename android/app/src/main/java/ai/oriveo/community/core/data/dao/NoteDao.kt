package ai.oriveo.community.core.data.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import ai.oriveo.community.core.data.entity.NoteEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface NoteDao {

    @Query("SELECT * FROM notes WHERE accountId = :accountId AND deletedAt IS NULL ORDER BY updatedAt DESC")
    fun observeActive(accountId: String): Flow<List<NoteEntity>>

    @Query("SELECT * FROM notes WHERE accountId = :accountId AND deletedAt IS NOT NULL ORDER BY deletedAt DESC")
    fun observeTrash(accountId: String): Flow<List<NoteEntity>>

    @Query("SELECT * FROM notes WHERE accountId = :accountId AND id = :id LIMIT 1")
    fun observeById(accountId: String, id: String): Flow<NoteEntity?>

    @Query("SELECT * FROM notes WHERE accountId = :accountId AND id = :id LIMIT 1")
    suspend fun getById(accountId: String, id: String): NoteEntity?

    @Query("SELECT * FROM notes WHERE accountId = :accountId AND id = :id LIMIT 1")
    suspend fun getByIdForAccount(accountId: String, id: String): NoteEntity?

    @Query("SELECT * FROM notes WHERE accountId = :accountId AND deletedAt IS NULL")
    suspend fun getAllActive(accountId: String): List<NoteEntity>

    @Query("SELECT * FROM notes WHERE accountId = :accountId AND deletedAt IS NOT NULL")
    suspend fun getAllTrashed(accountId: String): List<NoteEntity>

    @Query("SELECT * FROM notes WHERE accountId = :accountId")
    suspend fun getAll(accountId: String): List<NoteEntity>

    @Query("SELECT * FROM notes WHERE accountId = :accountId AND deletedAt IS NULL AND id IN (:ids)")
    suspend fun getActiveByIds(accountId: String, ids: List<String>): List<NoteEntity>

    @Query(
        """
        SELECT notes.* FROM notes
        JOIN note_search_index ON notes.accountId = note_search_index.accountId
          AND notes.id = note_search_index.noteId
        WHERE note_search_index MATCH :ftsQuery
          AND notes.accountId = :accountId
          AND notes.deletedAt IS NULL
        ORDER BY notes.updatedAt DESC
        """,
    )
    suspend fun searchActive(accountId: String, ftsQuery: String): List<NoteEntity>

    @Query(
        """
        SELECT notes.id FROM notes
        JOIN note_search_index ON notes.accountId = note_search_index.accountId
          AND notes.id = note_search_index.noteId
        WHERE note_search_index MATCH :ftsQuery
          AND notes.accountId = :accountId
          AND notes.deletedAt IS NULL
        ORDER BY notes.updatedAt DESC
        LIMIT :limit
        """,
    )
    suspend fun recallCandidateIds(accountId: String, ftsQuery: String, limit: Int): List<String>

    @Query(
        """
        SELECT * FROM notes
        WHERE accountId = :accountId AND deletedAt IS NULL
          AND (title LIKE :pattern ESCAPE '\'
            OR body LIKE :pattern ESCAPE '\'
            OR IFNULL(userNote, '') LIKE :pattern ESCAPE '\'
            OR tagsJson LIKE :pattern ESCAPE '\')
        ORDER BY updatedAt DESC
        """,
    )
    suspend fun searchActiveLike(accountId: String, pattern: String): List<NoteEntity>

    @Upsert
    suspend fun upsert(note: NoteEntity)

    @Upsert
    suspend fun upsertAll(notes: List<NoteEntity>)

    @Query("UPDATE notes SET deletedAt = :deletedAt, updatedAt = :updatedAt WHERE accountId = :accountId AND id = :id")
    suspend fun markDeleted(accountId: String, id: String, deletedAt: String, updatedAt: String)

    @Query("UPDATE notes SET deletedAt = NULL, updatedAt = :updatedAt WHERE accountId = :accountId AND id = :id")
    suspend fun markRestored(accountId: String, id: String, updatedAt: String)

    @Query("DELETE FROM notes WHERE accountId = :accountId AND id = :id")
    suspend fun hardDelete(accountId: String, id: String)

    @Query("DELETE FROM notes WHERE accountId = :accountId AND deletedAt IS NOT NULL")
    suspend fun hardDeleteTrash(accountId: String)

    @Query("DELETE FROM notes WHERE accountId = :accountId")
    suspend fun deleteByAccount(accountId: String)

    @Query(
        "UPDATE notes SET noteFolderID = NULL, updatedAt = :updatedAt " +
            "WHERE accountId = :accountId AND noteFolderID = :folderId",
    )
    suspend fun clearNoteFolder(accountId: String, folderId: String, updatedAt: String)

    @Query("DELETE FROM note_search_index WHERE accountId = :accountId AND noteId = :noteId")
    suspend fun deleteSearchIndex(accountId: String, noteId: String)

    @Query("DELETE FROM note_search_index")
    suspend fun clearSearchIndex()

    @Query(
        "INSERT INTO note_search_index(noteId, accountId, title, body, userNote, tagsText) " +
            "VALUES (:noteId, :accountId, :title, :body, :userNote, :tagsText)",
    )
    suspend fun insertSearchIndex(
        accountId: String,
        noteId: String,
        title: String,
        body: String,
        userNote: String,
        tagsText: String,
    )

    @Transaction
    suspend fun upsertWithIndex(
        note: NoteEntity,
        ftsTitle: String,
        ftsBody: String,
        ftsUserNote: String,
        ftsTagsText: String,
    ) {
        upsert(note)
        deleteSearchIndex(note.accountId, note.id)

        if (note.deletedAt == null) {
            insertSearchIndex(note.accountId, note.id, ftsTitle, ftsBody, ftsUserNote, ftsTagsText)
        }
    }

    @Transaction
    suspend fun softDeleteWithIndex(accountId: String, id: String, deletedAt: String, updatedAt: String) {
        markDeleted(accountId, id, deletedAt, updatedAt)
        deleteSearchIndex(accountId, id)
    }

    @Transaction
    suspend fun restoreWithIndex(
        accountId: String,
        id: String,
        updatedAt: String,
        ftsTitle: String,
        ftsBody: String,
        ftsUserNote: String,
        ftsTagsText: String,
    ) {
        markRestored(accountId, id, updatedAt)
        deleteSearchIndex(accountId, id)
        insertSearchIndex(accountId, id, ftsTitle, ftsBody, ftsUserNote, ftsTagsText)
    }

    @Transaction
    suspend fun hardDeleteWithIndex(accountId: String, id: String) {
        hardDelete(accountId, id)
        deleteSearchIndex(accountId, id)
    }
}
