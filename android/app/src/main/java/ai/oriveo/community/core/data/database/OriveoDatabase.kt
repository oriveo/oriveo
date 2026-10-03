package ai.oriveo.community.core.data.database

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.ConversationSearchDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.dao.McpServerDao
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
import ai.oriveo.community.core.data.entity.McpConnectionStateEntity
import ai.oriveo.community.core.data.entity.McpConversationSwitchEntity
import ai.oriveo.community.core.data.entity.McpServerEntity
import ai.oriveo.community.core.data.entity.McpStepPayloadEntity
import ai.oriveo.community.core.data.entity.McpToolPermissionEntity
import ai.oriveo.community.core.data.entity.McpToolSnapshotEntity
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
 *
 * v3: remote MCP servers. Six tables (`mcp_server`, `mcp_connection_state`, `mcp_tool_snapshot`,
 *   `mcp_tool_permission`, `mcp_conversation_switch`, `mcp_step_payload`) and one nullable column
 *   on `messages` (`toolStepsJson`, the summaries of the tool steps an answer went through). No
 *   credential is stored in any of them; tokens go to `McpCredentialStore`.
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
        McpServerEntity::class,
        McpConnectionStateEntity::class,
        McpToolSnapshotEntity::class,
        McpToolPermissionEntity::class,
        McpConversationSwitchEntity::class,
        McpStepPayloadEntity::class,
    ],
    version = 3,
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
    abstract fun mcpServerDao(): McpServerDao

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

        /**
         * v2 to v3: the tables behind remote MCP servers, and `messages.toolStepsJson`.
         *
         * Only additions: six new tables and one nullable column, so nothing that existed before
         * is rewritten and older messages simply read the new column as null.
         *
         * These tables travel with `oriveo.db` in system backups, which is why none of them may
         * ever hold a credential. Tokens, and the full address of a server whose address looks
         * like it carries a secret, live in `McpCredentialStore`, whose prefs file is excluded
         * from backups; `mcp_server.url` then holds a display address only.
         *
         * The DDL must match what `McpEntities.kt` generates character for character: when the
         * database opens, Room validates the real schema (types, NOT NULL, primary keys, index
         * names and uniqueness) and refuses to open on any difference. `McpMigrationTest` runs
         * this migration on a real v2 database to pin that down.
         */
        val MIGRATION_2_3: Migration = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `mcp_server` (" +
                        "`id` TEXT NOT NULL COLLATE NOCASE, `accountId` TEXT NOT NULL, `name` TEXT NOT NULL, " +
                        "`slug` TEXT NOT NULL, `url` TEXT NOT NULL, `authKind` TEXT NOT NULL, " +
                        "`localOnly` INTEGER NOT NULL, `iconURL` TEXT, `createdAt` INTEGER NOT NULL, " +
                        "`updatedAt` INTEGER NOT NULL, `pendingAdd` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`id`, `accountId`))",
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_mcp_server_accountId` ON `mcp_server` (`accountId`)")
                db.execSQL(
                    "CREATE UNIQUE INDEX IF NOT EXISTS `index_mcp_server_accountId_slug` " +
                        "ON `mcp_server` (`accountId`, `slug`)",
                )

                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `mcp_connection_state` (" +
                        "`serverId` TEXT NOT NULL COLLATE NOCASE, `accountId` TEXT NOT NULL, " +
                        "`status` TEXT NOT NULL, `lastSuccessAt` INTEGER, `negotiatedVersion` TEXT, " +
                        "`generation` TEXT, `sessionId` TEXT, PRIMARY KEY(`serverId`, `accountId`))",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_mcp_connection_state_accountId` " +
                        "ON `mcp_connection_state` (`accountId`)",
                )

                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `mcp_tool_snapshot` (" +
                        "`serverId` TEXT NOT NULL COLLATE NOCASE, `toolName` TEXT NOT NULL, " +
                        "`accountId` TEXT NOT NULL, `title` TEXT NOT NULL, `description` TEXT, " +
                        "`inputSchema` TEXT NOT NULL, `annotations` TEXT NOT NULL, `contentHash` TEXT NOT NULL, " +
                        "`readOnly` INTEGER NOT NULL, `pendingReview` INTEGER NOT NULL, " +
                        "`oversized` INTEGER NOT NULL, `updatedAt` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`serverId`, `toolName`, `accountId`))",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_mcp_tool_snapshot_accountId` " +
                        "ON `mcp_tool_snapshot` (`accountId`)",
                )

                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `mcp_tool_permission` (" +
                        "`serverId` TEXT NOT NULL COLLATE NOCASE, `toolName` TEXT NOT NULL, " +
                        "`accountId` TEXT NOT NULL, `permission` TEXT NOT NULL, " +
                        "PRIMARY KEY(`serverId`, `toolName`, `accountId`))",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_mcp_tool_permission_accountId` " +
                        "ON `mcp_tool_permission` (`accountId`)",
                )

                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `mcp_conversation_switch` (" +
                        "`conversationId` TEXT NOT NULL COLLATE NOCASE, " +
                        "`serverId` TEXT NOT NULL COLLATE NOCASE, `accountId` TEXT NOT NULL, " +
                        "`enabledAt` INTEGER NOT NULL, PRIMARY KEY(`conversationId`, `serverId`, `accountId`))",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_mcp_conversation_switch_accountId` " +
                        "ON `mcp_conversation_switch` (`accountId`)",
                )

                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `mcp_step_payload` (" +
                        "`messageId` TEXT NOT NULL COLLATE NOCASE, `stepId` TEXT NOT NULL, " +
                        "`accountId` TEXT NOT NULL, `arguments` TEXT, `resultPrefix` TEXT, " +
                        "`createdAt` INTEGER NOT NULL, `serverId` TEXT COLLATE NOCASE, " +
                        "PRIMARY KEY(`messageId`, `stepId`, `accountId`))",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_mcp_step_payload_accountId` " +
                        "ON `mcp_step_payload` (`accountId`)",
                )

                db.execSQL("ALTER TABLE `messages` ADD COLUMN `toolStepsJson` TEXT")
            }
        }
    }
}
