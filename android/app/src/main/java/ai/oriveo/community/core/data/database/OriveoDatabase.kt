package ai.oriveo.community.core.data.database

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import ai.oriveo.community.core.data.mapper.ConversationMapper
import ai.oriveo.community.core.model.SkillSyncFields
import ai.oriveo.community.core.data.dao.ContextCheckpointDao
import ai.oriveo.community.core.data.dao.ContextLedgerDao
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.ConversationSearchDao
import ai.oriveo.community.core.data.dao.FolderDao
import ai.oriveo.community.core.data.dao.McpServerDao
import ai.oriveo.community.core.data.dao.MemoryCandidateDao
import ai.oriveo.community.core.data.dao.MemoryItemDao
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.MetadataCacheDao
import ai.oriveo.community.core.data.dao.NoteDao
import ai.oriveo.community.core.data.dao.NoteFolderDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.dao.SkillDao
import ai.oriveo.community.core.data.dao.StudioWorkDao
import ai.oriveo.community.core.data.entity.ContextCheckpointEntity
import ai.oriveo.community.core.data.entity.StudioRoundEntity
import ai.oriveo.community.core.data.entity.StudioRoundRefEntity
import ai.oriveo.community.core.data.entity.StudioVersionEntity
import ai.oriveo.community.core.data.entity.StudioWorkEntity
import ai.oriveo.community.core.data.entity.ContextManifestEntity
import ai.oriveo.community.core.data.entity.ContextRhoCalibrationEntity
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.data.entity.ConversationFtsEntity
import ai.oriveo.community.core.data.entity.ConversationMessageCountEntity
import ai.oriveo.community.core.data.entity.ConversationSearchDirtyEntity
import ai.oriveo.community.core.data.entity.FolderEntity
import ai.oriveo.community.core.data.entity.MemoryCandidateEntity
import ai.oriveo.community.core.data.entity.MemoryItemEntity
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
 *
 * v5: context and memory. `messages` gains nullable TEXT `stopReason` (why the answer ended; older messages
 *   stay null) and nullable TEXT `memoryItemIds` (ids of the memory items injected into the answer, a JSON
 *   array stored locally only); `conversations` gains `instructions TEXT NOT NULL DEFAULT ''` (conversation-level
 *   instructions, empty for existing rows) and nullable TEXT `contextCap` (stored text of the conversation input
 *   budget cap; null follows the global default). Five new tables: `context_rho_calibration` (rho calibration),
 *   `context_manifest` (request manifests, newest 50 kept per conversation), `context_checkpoint` (context
 *   checkpoints, cascade-deleted with the conversation, newest 8 kept per conversation), `memory_items` (memory
 *   item v2, primary key (accountId, id), with a local syncState) and `memory_candidates` (memory candidates,
 *   primary key (accountId, id), status plus the whole candidate as JSON). See [MIGRATION_4_5].
 *
 * v6: cost in more than one currency. `messages` gains the nullable `nonUsdCostCurrency`, `nonUsdCostAmount` and
 *   `nonUsdCostSource` columns (the non-USD part of a message's cost; `estimatedCost` / `costSource` keep describing
 *   the USD part only) and `conversations` gains the nullable `nonUsdCostTotals` (JSON totals per non-USD currency).
 *   Existing rows are not backfilled: a null currency means the message cost was USD. See [MIGRATION_5_6].
 *
 * v7: external web search. `messages` gains the nullable `searchErrorCardJson` (the search error card as JSON),
 *   `searchNotice` (a one-off notice key) and `searchSourcesLineJson` (the title line of the sources card, as JSON).
 *   All three are local only and are not backfilled. See [MIGRATION_6_7].
 *
 * v8 change: `skills` gains whenToUse / autoInvoke / iconKey and three `{locale: text}` JSON columns
 *   (skill_schema.v2), NOT NULL with defaults so existing rows read the contract defaults, see [MIGRATION_7_8].
 *
 * v9 change: `conversations` gains `skillIdsJson` / `disabledAutoSkillIdsJson`, `messages` gains
 *   `attachedSkillIdsJson` / `usedSkillsJson` (skill_sync_fields.v1), all nullable; skillIdsJson is backfilled
 *   from the legacy skillId, which keeps its value, see [MIGRATION_8_9].
 *
 * v10 change: `messages` gains nullable `skillManifestTokens` (local-only skill list overhead estimate), no backfill,
 *   see [MIGRATION_9_10].
 *
 * v11 change: new empty studio work tables `studio_works` / `studio_rounds` / `studio_versions` / `studio_round_refs`
 *   (studio_data_model.v1 localTables) with their indexes, no rows written, see [MIGRATION_10_11].
 *
 * `exportSchema = true`: the Room schema JSON is committed as an anchor, so future changes show up as a diff.
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
        ContextRhoCalibrationEntity::class,
        ContextManifestEntity::class,
        ContextCheckpointEntity::class,
        MemoryItemEntity::class,
        MemoryCandidateEntity::class,
        StudioWorkEntity::class,
        StudioRoundEntity::class,
        StudioVersionEntity::class,
        StudioRoundRefEntity::class,
    ],
    version = 11,
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
    abstract fun contextLedgerDao(): ContextLedgerDao
    abstract fun contextCheckpointDao(): ContextCheckpointDao
    abstract fun memoryItemDao(): MemoryItemDao
    abstract fun memoryCandidateDao(): MemoryCandidateDao
    abstract fun studioWorkDao(): StudioWorkDao

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

        // v3 to v4: relay columns on providers. All nullable, stored on this device only:
        // the address source, the setup field values and the relay key list (no key values).
        val MIGRATION_3_4: Migration = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `providers` ADD COLUMN `endpointSource` TEXT")
                db.execSQL("ALTER TABLE `providers` ADD COLUMN `setupValuesJson` TEXT")
                db.execSQL("ALTER TABLE `providers` ADD COLUMN `relayKeysJson` TEXT")
            }
        }

        /**
         * v4 to v5: context and memory. Adds the nullable `stopReason` and `memoryItemIds` columns on
         * `messages`, the `instructions` and nullable `contextCap` columns on `conversations`, and the
         * tables `context_rho_calibration`, `context_manifest`, `context_checkpoint`, `memory_items` and
         * `memory_candidates`. Existing rows are not backfilled: new columns read as null (or the empty
         * string for `instructions`). The DDL must match the generated schema exactly, since Room
         * validates every table when the database opens.
         */
        val MIGRATION_4_5: Migration = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `stopReason` TEXT")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `memoryItemIds` TEXT")
                db.execSQL("ALTER TABLE `conversations` ADD COLUMN `instructions` TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE `conversations` ADD COLUMN `contextCap` TEXT")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `context_rho_calibration` (`transportInstanceId` TEXT NOT NULL, " +
                        "`modelId` TEXT NOT NULL, `n` INTEGER NOT NULL, `rho` REAL NOT NULL, `seeds` TEXT NOT NULL, " +
                        "PRIMARY KEY(`transportInstanceId`, `modelId`))",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `context_manifest` (`conversationId` TEXT NOT NULL COLLATE NOCASE, " +
                        "`requestId` TEXT NOT NULL, `createdAt` INTEGER NOT NULL, `json` TEXT NOT NULL, " +
                        "PRIMARY KEY(`conversationId`, `requestId`))",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_context_manifest_conversationId_createdAt` " +
                        "ON `context_manifest` (`conversationId`, `createdAt`)",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `context_checkpoint` (`accountId` TEXT NOT NULL, " +
                        "`conversationId` TEXT NOT NULL COLLATE NOCASE, `checkpointId` TEXT NOT NULL, " +
                        "`kind` TEXT NOT NULL, `coversFrom` TEXT NOT NULL, `coversTo` TEXT NOT NULL, " +
                        "`coversDigest` TEXT NOT NULL, `messagesCovered` INTEGER NOT NULL, " +
                        "`userMessageIds` TEXT NOT NULL, `text` TEXT NOT NULL, `summary` TEXT, `language` TEXT, " +
                        "`model` TEXT NOT NULL, `packerVersion` TEXT NOT NULL, `createdAt` INTEGER NOT NULL, " +
                        "`cost` REAL, PRIMARY KEY(`accountId`, `conversationId`, `checkpointId`), " +
                        "FOREIGN KEY(`conversationId`, `accountId`) REFERENCES `conversations`(`id`, `accountId`) " +
                        "ON UPDATE NO ACTION ON DELETE CASCADE )",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_context_checkpoint_accountId_conversationId_createdAt` " +
                        "ON `context_checkpoint` (`accountId`, `conversationId`, `createdAt`)",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `memory_items` (`accountId` TEXT NOT NULL, `id` TEXT NOT NULL, " +
                        "`schemaVersion` INTEGER NOT NULL, `layer` TEXT NOT NULL, `kind` TEXT NOT NULL, " +
                        "`status` TEXT NOT NULL, `content` TEXT NOT NULL, `scopeType` TEXT NOT NULL, `scopeId` TEXT, " +
                        "`sourceType` TEXT NOT NULL, `sourceConversationId` TEXT, `sourceMessageIds` TEXT NOT NULL, " +
                        "`sourceObservedAt` TEXT, `sensitivity` TEXT NOT NULL, `confidence` REAL NOT NULL, " +
                        "`priority` INTEGER NOT NULL, `pinned` INTEGER NOT NULL, `revision` INTEGER NOT NULL, " +
                        "`baseRevision` INTEGER NOT NULL, `mutationId` TEXT NOT NULL, `deviceId` TEXT NOT NULL, " +
                        "`conflictGroupId` TEXT, `occurredAt` TEXT, `validFrom` TEXT, `lastConfirmedAt` TEXT, " +
                        "`createdAt` TEXT, `updatedAt` TEXT, `expiresAt` TEXT, `deletedAt` TEXT, " +
                        "`supersedes` TEXT NOT NULL, `syncState` TEXT NOT NULL, PRIMARY KEY(`accountId`, `id`))",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `memory_candidates` (`accountId` TEXT NOT NULL, `id` TEXT NOT NULL, " +
                        "`status` TEXT NOT NULL, `payload` TEXT NOT NULL, PRIMARY KEY(`accountId`, `id`))",
                )
            }
        }

        /**
         * v5 to v6: the non-USD part of a message's cost, and the per-currency totals of a conversation.
         * Four nullable columns without defaults; older rows keep null (the cost was USD) and are not rewritten.
         * Adding columns is enough: nothing here rebuilds `messages`, so the search triggers stay in place.
         */
        val MIGRATION_5_6: Migration = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `nonUsdCostCurrency` TEXT")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `nonUsdCostAmount` REAL")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `nonUsdCostSource` TEXT")
                db.execSQL("ALTER TABLE `conversations` ADD COLUMN `nonUsdCostTotals` TEXT")
            }
        }

        /**
         * v6 to v7: local diagnostics for external web search (error card JSON, one-off notice, sources line JSON).
         * Nullable columns without defaults; older rows read null.
         */
        val MIGRATION_6_7: Migration = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `searchErrorCardJson` TEXT")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `searchNotice` TEXT")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `searchSourcesLineJson` TEXT")
            }
        }

        /** v7 -> v8: skill_schema.v2 cache fields on `skills`; existing rows take the contract defaults. */
        val MIGRATION_7_8: Migration = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `skills` ADD COLUMN `whenToUse` TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE `skills` ADD COLUMN `autoInvoke` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `skills` ADD COLUMN `iconKey` TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE `skills` ADD COLUMN `whenToUseTranslationsJson` TEXT NOT NULL DEFAULT '{}'")
                db.execSQL("ALTER TABLE `skills` ADD COLUMN `previewUserJson` TEXT NOT NULL DEFAULT '{}'")
                db.execSQL("ALTER TABLE `skills` ADD COLUMN `previewAssistantJson` TEXT NOT NULL DEFAULT '{}'")
            }
        }

        /**
         * v8 -> v9: skill_sync_fields.v1 columns, nullable without defaults. Rows with a non-blank legacy
         * skillId get skillIdsJson = [skillId] (sync id); skillId itself is left untouched for old app versions.
         */
        val MIGRATION_8_9: Migration = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `conversations` ADD COLUMN `skillIdsJson` TEXT")
                db.execSQL("ALTER TABLE `conversations` ADD COLUMN `disabledAutoSkillIdsJson` TEXT")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `attachedSkillIdsJson` TEXT")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `usedSkillsJson` TEXT")
                val backfill = mutableListOf<Pair<Long, String>>()
                db.query("SELECT rowid, skillId FROM `conversations` WHERE skillId IS NOT NULL").use { cursor ->
                    while (cursor.moveToNext()) {
                        val ids = SkillSyncFields.resolveSkillIds(null, cursor.getString(1))
                        ConversationMapper.encodeIdList(ids)?.let { backfill += cursor.getLong(0) to it }
                    }
                }
                for ((rowId, json) in backfill) {
                    db.execSQL("UPDATE `conversations` SET `skillIdsJson` = ? WHERE rowid = ?", arrayOf<Any>(json, rowId))
                }
            }
        }

        /** v9 -> v10: local-only `messages.skillManifestTokens`, nullable, existing rows stay null. */
        val MIGRATION_9_10: Migration = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `skillManifestTokens` INTEGER")
            }
        }

        /**
         * v10 -> v11: creates the four empty studio work tables and their indexes, no rows written; the SQL matches
         * the `11.json` createSql verbatim.
         */
        val MIGRATION_10_11: Migration = object : Migration(10, 11) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `studio_works` (`id` TEXT NOT NULL COLLATE NOCASE, `title` TEXT NOT NULL, " +
                        "`currentVersionId` TEXT COLLATE NOCASE, `source` TEXT NOT NULL, `chatConversationId` TEXT, " +
                        "`chatMessageId` TEXT, `favorite` INTEGER NOT NULL, `selectedVersionIds` TEXT NOT NULL, " +
                        "`deletedVersionIds` TEXT NOT NULL, `createdAt` INTEGER NOT NULL, `updatedAt` INTEGER NOT NULL, " +
                        "`deletedAt` INTEGER, `revision` INTEGER NOT NULL, `baseRevision` INTEGER NOT NULL, " +
                        "`accountPartition` TEXT NOT NULL, `syncState` TEXT NOT NULL, PRIMARY KEY(`id`))",
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_studio_works_accountPartition_updatedAt` " +
                        "ON `studio_works` (`accountPartition`, `updatedAt`)",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `studio_rounds` (`id` TEXT NOT NULL COLLATE NOCASE, " +
                        "`workId` TEXT NOT NULL COLLATE NOCASE, `index` INTEGER NOT NULL, `baseVersionId` TEXT COLLATE NOCASE, " +
                        "`operation` TEXT NOT NULL, `prompt` TEXT NOT NULL, `composedPrompt` TEXT NOT NULL, " +
                        "`enhancedPrompt` TEXT, `presetIds` TEXT NOT NULL, `params` TEXT NOT NULL, `modelRef` TEXT, " +
                        "`status` TEXT NOT NULL, `errorKind` TEXT, `adjustments` TEXT NOT NULL, " +
                        "`nRequested` INTEGER NOT NULL, `nDelivered` INTEGER NOT NULL, `costEstimateUsd` REAL, " +
                        "`chargedUsd` REAL, `fundingSource` TEXT NOT NULL, `managedJobId` TEXT, `clientJobId` TEXT, " +
                        "`startedAt` INTEGER NOT NULL, `finishedAt` INTEGER, PRIMARY KEY(`id`))",
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_studio_rounds_workId` ON `studio_rounds` (`workId`)")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `studio_versions` (`id` TEXT NOT NULL COLLATE NOCASE, " +
                        "`roundId` TEXT NOT NULL COLLATE NOCASE, `workId` TEXT NOT NULL COLLATE NOCASE, " +
                        "`parentVersionId` TEXT COLLATE NOCASE, `assetId` TEXT NOT NULL COLLATE NOCASE, " +
                        "`width` INTEGER NOT NULL, `height` INTEGER NOT NULL, `mime` TEXT NOT NULL, " +
                        "`kept` INTEGER NOT NULL, `createdAt` INTEGER NOT NULL, PRIMARY KEY(`id`))",
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_studio_versions_workId` ON `studio_versions` (`workId`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_studio_versions_roundId` ON `studio_versions` (`roundId`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_studio_versions_assetId` ON `studio_versions` (`assetId`)")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `studio_round_refs` (`roundId` TEXT NOT NULL COLLATE NOCASE, " +
                        "`order` INTEGER NOT NULL, `assetId` TEXT NOT NULL COLLATE NOCASE, `role` TEXT NOT NULL, " +
                        "PRIMARY KEY(`roundId`, `order`))",
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_studio_round_refs_assetId` ON `studio_round_refs` (`assetId`)")
            }
        }

        /** Every registered migration, from v1 up to the current version. Production and tests both open the database through this list, so a new version is added in one place. */
        fun allMigrations(): Array<Migration> = arrayOf(
            MIGRATION_1_2,
            MIGRATION_2_3,
            MIGRATION_3_4,
            MIGRATION_4_5,
            MIGRATION_5_6,
            MIGRATION_6_7,
            // v7 -> v8: skills gains the skill_schema.v2 cache columns (defaults, no backfill).
            MIGRATION_7_8,
            // v8 -> v9: skill_sync_fields.v1 columns; skillIdsJson backfilled from the legacy skillId.
            MIGRATION_8_9,
            // v9 -> v10: messages gains the local-only skillManifestTokens (nullable, no backfill).
            MIGRATION_9_10,
            // v10 -> v11: four empty studio work tables and their indexes (studio_data_model.v1 localTables).
            MIGRATION_10_11,
        )
    }
}
