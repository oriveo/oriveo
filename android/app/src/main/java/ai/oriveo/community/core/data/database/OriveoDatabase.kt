package ai.oriveo.community.core.data.database

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.ConversationSearchDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.dao.NoteDao
import ai.oriveo.community.core.data.dao.NoteFolderDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.dao.SkillDao
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.ConversationFtsEntity
import ai.oriveo.community.core.data.entity.ConversationMessageCountEntity
import ai.oriveo.community.core.data.entity.ConversationSearchDirtyEntity
import ai.oriveo.community.core.data.entity.FolderEntity
import ai.oriveo.community.core.data.entity.MessageEntity
import ai.oriveo.community.core.data.entity.MetadataCacheEntity
import ai.oriveo.community.core.data.entity.NoteEntity
import ai.oriveo.community.core.data.entity.NoteFolderEntity
import ai.oriveo.community.core.data.entity.NoteFtsEntity
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.entity.SkillEntity

/**
 * Partition every row belongs to.
 *
 * Everything this app stores lives on the device in a single partition. The column exists so a
 * future profile feature can be added without rewriting every query and index, and so the
 * composite primary keys stay stable if it ever is.
 */
const val LOCAL_PARTITION_ID = "local"

/**
 * The on-device store: conversations, messages, notes, folders, skills, providers, preferences,
 * and the cached model catalog.
 *
 * Schemas are exported to `app/schemas` and checked in, so a change to an entity shows up as a
 * reviewable diff rather than a surprise at runtime.
 *
 * v2: conversation search moved to FTS4 and the message count moved out of the `messages` table.
 *   Adds `conversation_search_index` (FTS4, one row per message, docid = `messages.rowid`, CJK
 *   tokenised as bigrams), `conversation_search_dirty` (the pending-index queue) and
 *   `conversation_message_counts` (the local message count), plus five maintenance triggers on
 *   `messages` and `conversations` (see [ConversationSearchSchema]). Two goals: search no longer
 *   scans `messages.text` with `LIKE '%q%'`, and the conversation list queries no longer carry a
 *   correlated `COUNT(*) FROM messages` that a streaming checkpoint would re-run over the whole
 *   list. The migration only rebuilds the counts and enqueues the rowids; tokenising is done in
 *   batches afterwards by the background indexer.
 */
@Database(
    entities = [
        ProviderEntity::class,
        ConversationEntity::class,
        MessageEntity::class,
        PreferenceEntity::class,
        FolderEntity::class,
        SkillEntity::class,
        MetadataCacheEntity::class,
        NoteEntity::class,
        NoteFolderEntity::class,
        NoteFtsEntity::class,
        ConversationFtsEntity::class,
        ConversationSearchDirtyEntity::class,
        ConversationMessageCountEntity::class,
    ],
    version = 2,
    exportSchema = true,
)
abstract class OriveoDatabase : RoomDatabase() {
    abstract fun providerDao(): ProviderDao
    abstract fun conversationDao(): ConversationDao
    abstract fun conversationSearchDao(): ConversationSearchDao
    abstract fun messageDao(): MessageDao
    abstract fun preferenceDao(): PreferenceDao
    abstract fun folderDao(): FolderDao
    abstract fun skillDao(): SkillDao
    abstract fun metadataCacheDao(): MetadataCacheDao
    abstract fun noteDao(): NoteDao
    abstract fun noteFolderDao(): NoteFolderDao

    companion object {
        const val DATABASE_NAME = "oriveo.db"

        /**
         * v1 to v2: conversation search moves to FTS4 with CJK bigrams, and the message count
         * moves into a small table of its own.
         *
         * Three new tables and five triggers, with no change to any write path (see
         * [ConversationSearchSchema]).
         *
         * Building the index for an existing database deliberately does **not** happen here: the
         * migration rebuilds the counts and enqueues every `messages.rowid`, and the tokenising is
         * left to `ConversationSearchIndexer` to consume in batches once the process is up.
         * Tokenising tens of thousands of messages in one pass would stall the first open for tens
         * of seconds, whereas an index that has not caught up yet only means message bodies are
         * briefly not searchable — titles and preview text still use LIKE and are unaffected.
         *
         * Any future migration that rebuilds `messages` or `conversations` drops these triggers
         * along with the table, so it must call [ConversationSearchSchema.installTriggers] again
         * afterwards. `DatabaseModule`'s `onOpen` reinstalls them idempotently as a backstop.
         */
        val MIGRATION_1_2: Migration = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE VIRTUAL TABLE IF NOT EXISTS `conversation_search_index` USING FTS4(" +
                        "`conversationId` TEXT NOT NULL, `accountId` TEXT NOT NULL, `text` TEXT NOT NULL, " +
                        "notindexed=`conversationId`, notindexed=`accountId`)",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `conversation_search_dirty` " +
                        "(`messageRowId` INTEGER NOT NULL, PRIMARY KEY(`messageRowId`))",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `conversation_message_counts` " +
                        "(`accountId` TEXT NOT NULL, `conversationId` TEXT NOT NULL COLLATE NOCASE, " +
                        "`messageCount` INTEGER NOT NULL, PRIMARY KEY(`accountId`, `conversationId`))",
                )
                ConversationSearchSchema.rebuildDerivedState(db)
                ConversationSearchSchema.installTriggers(db)
            }
        }
    }
}
