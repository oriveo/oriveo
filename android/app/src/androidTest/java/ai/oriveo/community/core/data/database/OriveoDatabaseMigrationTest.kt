package ai.oriveo.community.core.data.database

import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OriveoDatabaseMigrationTest {

    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        OriveoDatabase::class.java,
    )

    @Test
    fun migrateFromV28PersistsLocalToolFallbackFields() {
        helper.createDatabase(TEST_DATABASE_NAME, 28).close()

        helper.runMigrationsAndValidate(
            TEST_DATABASE_NAME,
            29,
            true,
            OriveoDatabase.MIGRATION_28_29,
        ).use { db ->
            db.query("PRAGMA table_info(`messages`)").use { cursor ->
                val nameIndex = cursor.getColumnIndexOrThrow("name")
                val columns = buildSet {
                    while (cursor.moveToNext()) add(cursor.getString(nameIndex))
                }
                assertTrue("unhandledToolCallsJson" in columns)
                assertTrue("toolFallbackNotice" in columns)
            }
        }
    }

    @Test
    fun migrateFromV2ToLatest() {
        helper.createDatabase(TEST_DATABASE_NAME, 2).close()

        helper.runMigrationsAndValidate(
            TEST_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_2_3,
            OriveoDatabase.MIGRATION_3_4,
            OriveoDatabase.MIGRATION_4_5,
            OriveoDatabase.MIGRATION_5_6,
            OriveoDatabase.MIGRATION_6_7,
            OriveoDatabase.MIGRATION_7_8,
            OriveoDatabase.MIGRATION_8_9,
            OriveoDatabase.MIGRATION_9_10,
            OriveoDatabase.MIGRATION_10_11,
            OriveoDatabase.MIGRATION_11_12,
            OriveoDatabase.MIGRATION_12_13,
            OriveoDatabase.MIGRATION_13_14,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        )
    }

    @Test
    fun migrateFromOldV8IdentityHashToLatest() {
        helper.createDatabase(TEST_DATABASE_NAME, 8).use { db ->
            db.execSQL("CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT)")
            db.execSQL(
                "INSERT OR REPLACE INTO room_master_table (id,identity_hash) " +
                    "VALUES(42, 'd2e74220de868002b99b775e3b4b5232')",
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_8_9,
            OriveoDatabase.MIGRATION_9_10,
            OriveoDatabase.MIGRATION_10_11,
            OriveoDatabase.MIGRATION_11_12,
            OriveoDatabase.MIGRATION_12_13,
            OriveoDatabase.MIGRATION_13_14,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        )
    }

    @Test
    fun migrateFromV9AddsManagedMessageFields() {
        helper.createDatabase(TEST_DATABASE_NAME, 9).use { db ->
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS `messages` (" +
                    "`id` TEXT NOT NULL, `conversationId` TEXT NOT NULL, `role` TEXT NOT NULL, " +
                    "`text` TEXT NOT NULL, `providerID` TEXT, `providerKind` TEXT NOT NULL, " +
                    "`providerName` TEXT NOT NULL, `modelID` TEXT, `modelName` TEXT NOT NULL, " +
                    "`servedModelID` TEXT, `estimatedCost` REAL NOT NULL, `state` TEXT NOT NULL, " +
                    "`errorTitle` TEXT, `errorDetail` TEXT, `attachmentsJson` TEXT, `createdAt` INTEGER, " +
                    "`sortOrder` INTEGER NOT NULL, `deletedAt` INTEGER, `citationsJson` TEXT, " +
                    "`reasoningText` TEXT, `reasoningDurationMs` INTEGER, `cachedInputTokens` INTEGER, " +
                    "`cacheCreation5mTokens` INTEGER, `cacheCreation1hTokens` INTEGER, `costSource` TEXT, " +
                    "PRIMARY KEY(`id`))",
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_9_10,
            OriveoDatabase.MIGRATION_10_11,
            OriveoDatabase.MIGRATION_11_12,
            OriveoDatabase.MIGRATION_12_13,
            OriveoDatabase.MIGRATION_13_14,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        )
    }

    @Test
    fun migrateFromV10AddsManagedClientRequestId() {
        helper.createDatabase(TEST_DATABASE_NAME, 10).use { db ->
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS `messages` (" +
                    "`id` TEXT NOT NULL, `conversationId` TEXT NOT NULL, `role` TEXT NOT NULL, " +
                    "`text` TEXT NOT NULL, `providerID` TEXT, `providerKind` TEXT NOT NULL, " +
                    "`providerName` TEXT NOT NULL, `modelID` TEXT, `modelName` TEXT NOT NULL, " +
                    "`servedModelID` TEXT, `estimatedCost` REAL NOT NULL, `state` TEXT NOT NULL, " +
                    "`errorTitle` TEXT, `errorDetail` TEXT, `attachmentsJson` TEXT, `createdAt` INTEGER, " +
                    "`sortOrder` INTEGER NOT NULL, `deletedAt` INTEGER, `citationsJson` TEXT, " +
                    "`reasoningText` TEXT, `reasoningDurationMs` INTEGER, `cachedInputTokens` INTEGER, " +
                    "`cacheCreation5mTokens` INTEGER, `cacheCreation1hTokens` INTEGER, `costSource` TEXT, " +
                    "`providerMode` TEXT, `managedRequestId` TEXT, `lastSseSequence` INTEGER, " +
                    "PRIMARY KEY(`id`))",
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_10_11,
            OriveoDatabase.MIGRATION_11_12,
            OriveoDatabase.MIGRATION_12_13,
            OriveoDatabase.MIGRATION_13_14,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        )
    }

    @Test
    fun migrateFromV11AddsManagedRecoveryStateFields() {
        helper.createDatabase(TEST_DATABASE_NAME, 11).use { db ->
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS `messages` (" +
                    "`id` TEXT NOT NULL, `conversationId` TEXT NOT NULL, `role` TEXT NOT NULL, " +
                    "`text` TEXT NOT NULL, `providerID` TEXT, `providerKind` TEXT NOT NULL, " +
                    "`providerName` TEXT NOT NULL, `modelID` TEXT, `modelName` TEXT NOT NULL, " +
                    "`servedModelID` TEXT, `estimatedCost` REAL NOT NULL, `state` TEXT NOT NULL, " +
                    "`errorTitle` TEXT, `errorDetail` TEXT, `attachmentsJson` TEXT, `createdAt` INTEGER, " +
                    "`sortOrder` INTEGER NOT NULL, `deletedAt` INTEGER, `citationsJson` TEXT, " +
                    "`reasoningText` TEXT, `reasoningDurationMs` INTEGER, `cachedInputTokens` INTEGER, " +
                    "`cacheCreation5mTokens` INTEGER, `cacheCreation1hTokens` INTEGER, `costSource` TEXT, " +
                    "`providerMode` TEXT, `managedClientRequestId` TEXT, `managedRequestId` TEXT, " +
                    "`lastSseSequence` INTEGER, PRIMARY KEY(`id`))",
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_11_12,
            OriveoDatabase.MIGRATION_12_13,
            OriveoDatabase.MIGRATION_13_14,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        )
    }

    @Test
    fun migrateFromV13AddsPendingProviderDeletionQueue() {
        helper.createDatabase(TEST_DATABASE_NAME, 13).close()

        helper.runMigrationsAndValidate(
            TEST_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_13_14,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        ).use { db ->
            db.execSQL(
                "INSERT INTO pending_provider_deletions(providerId, accountId, operationId, enqueuedAt) " +
                    "VALUES('PROVIDER-1', 'user-a', 'op-a', 1)",
            )
            db.execSQL(
                "INSERT INTO pending_provider_deletions(providerId, accountId, operationId, enqueuedAt) " +
                    "VALUES('PROVIDER-1', 'user-b', 'op-b', 2)",
            )
            db.query(
                "SELECT COUNT(*) FROM pending_provider_deletions WHERE providerId = 'PROVIDER-1'",
            ).use { cursor ->
                cursor.moveToFirst()
                assertEquals(2, cursor.getInt(0))
            }

            fun insertProvider(accountId: String) {
                db.execSQL(
                    "INSERT INTO providers(id, kind, status, apiKeyPreview, modelsJson, catalogModelsJson, " +
                        "updatedAt, accountId, firestoreUpdatedAt) VALUES(" +
                        "'DETERMINISTIC-ID', 'OpenAI', '{}', '', '[]', '[]', 1, '$accountId', 0)",
                )
            }
            insertProvider("user-a")
            insertProvider("user-b")
            db.query("SELECT COUNT(*) FROM providers WHERE id = 'DETERMINISTIC-ID'").use { cursor ->
                cursor.moveToFirst()
                assertEquals(2, cursor.getInt(0))
            }
        }
    }

    @Test
    fun migrateFromLegacyV13ProviderSchemaFillsMissingColumns() {
        helper.createDatabase(LEGACY_PROVIDER_DATABASE_NAME, 13).use { db ->
            db.execSQL("DROP TABLE providers")
            db.execSQL(
                "CREATE TABLE providers (" +
                    "id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, " +
                    "apiKeyPreview TEXT NOT NULL, modelsJson TEXT NOT NULL, " +
                    "updatedAt INTEGER NOT NULL, accountId TEXT NOT NULL, PRIMARY KEY(id))",
            )
            db.execSQL(
                "INSERT INTO providers(id, kind, status, apiKeyPreview, modelsJson, updatedAt, accountId) " +
                    "VALUES('PROVIDER-LEGACY', 'OpenAI', '{\"type\":\"connected\"}', " +
                    "'sk-legacy', '[{\"id\":\"m1\"}]', 7, 'user-a')",
            )
        }

        helper.runMigrationsAndValidate(
            LEGACY_PROVIDER_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_13_14,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        ).use { db ->
            db.query(
                "SELECT id, accountId, catalogModelsJson, firestoreUpdatedAt, lastCheckedAt " +
                    "FROM providers WHERE id = 'PROVIDER-LEGACY'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("PROVIDER-LEGACY", cursor.getString(0))
                assertEquals("user-a", cursor.getString(1))
                assertEquals("[]", cursor.getString(2))
                assertEquals(0L, cursor.getLong(3))
                assertTrue(cursor.isNull(4))
            }
        }
    }

    @Test
    fun migrateFromInterimV14PreservesDataAndRepairsFinalSchema() {
        helper.createDatabase(TEST_DATABASE_NAME, 14).use { db ->
            db.execSQL("DROP TABLE providers")
            db.execSQL(
                "CREATE TABLE providers (" +
                    "id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, lastCheckedAt INTEGER, " +
                    "apiKeyPreview TEXT NOT NULL, lastError TEXT, baseUrlText TEXT, customName TEXT, " +
                    "relayKind TEXT, modelsJson TEXT NOT NULL, catalogModelsJson TEXT NOT NULL, " +
                    "relayRequestedJson TEXT, relayImageJson TEXT, updatedAt INTEGER NOT NULL, " +
                    "accountId TEXT NOT NULL, firestoreUpdatedAt INTEGER NOT NULL, " +
                    "cachedAvailableModelCount INTEGER, PRIMARY KEY(id))",
            )
            db.execSQL(
                "INSERT INTO providers(id, kind, status, apiKeyPreview, modelsJson, catalogModelsJson, " +
                    "updatedAt, accountId, firestoreUpdatedAt) VALUES(" +
                    "'PROVIDER-1', 'OpenAI', '{}', '', '[]', '[]', 1, 'user-a', 0)",
            )
            db.execSQL("DROP TABLE pending_provider_deletions")
            db.execSQL(
                "CREATE TABLE pending_provider_deletions (" +
                    "providerId TEXT NOT NULL, accountId TEXT NOT NULL, enqueuedAt INTEGER NOT NULL, " +
                    "PRIMARY KEY(providerId))",
            )
            db.execSQL(
                "INSERT INTO pending_provider_deletions(providerId, accountId, enqueuedAt) " +
                    "VALUES('PROVIDER-1', 'user-a', 2)",
            )
        }

        helper.runMigrationsAndValidate(
            TEST_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        ).use { db ->
            db.query("SELECT accountId FROM providers WHERE id = 'PROVIDER-1'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("user-a", cursor.getString(0))
            }
            db.query(
                "SELECT accountId, operationId FROM pending_provider_deletions WHERE providerId = 'PROVIDER-1'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("user-a", cursor.getString(0))
                assertTrue(cursor.getString(1).isNotBlank())
            }
        }
    }

    @Test
    fun migrateFromV14RepairsBlankOperationGeneration() {
        helper.createDatabase(BLANK_OPERATION_DATABASE_NAME, 14).use { db ->
            db.execSQL(
                "INSERT INTO pending_provider_deletions(providerId, accountId, operationId, enqueuedAt) " +
                    "VALUES('PROVIDER-EMPTY', 'user-a', '', 1)",
            )
        }

        helper.runMigrationsAndValidate(
            BLANK_OPERATION_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        ).use { db ->
            db.query(
                "SELECT operationId FROM pending_provider_deletions WHERE providerId = 'PROVIDER-EMPTY'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue(cursor.getString(0).isNotBlank())
            }
        }
    }

    @Test
    fun migrateFromFinalV14PreservesProviderAndOperationGeneration() {
        helper.createDatabase(FINAL_V14_DATABASE_NAME, 14).use { db ->
            db.execSQL(
                "INSERT INTO providers(id, kind, status, apiKeyPreview, modelsJson, catalogModelsJson, " +
                    "updatedAt, accountId, firestoreUpdatedAt) VALUES(" +
                    "'PROVIDER-FINAL', 'OpenAI', '{\"type\":\"connected\"}', '', '[]', '[]', " +
                    "7, 'user-a', 6)",
            )
            db.execSQL(
                "INSERT INTO pending_provider_deletions(providerId, accountId, operationId, enqueuedAt) " +
                    "VALUES('PROVIDER-FINAL', 'user-a', 'stable-operation', 8)",
            )
        }

        helper.runMigrationsAndValidate(
            FINAL_V14_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_14_15,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        ).use { db ->
            db.query(
                "SELECT accountId, firestoreUpdatedAt FROM providers WHERE id = 'PROVIDER-FINAL'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("user-a", cursor.getString(0))
                assertEquals(6L, cursor.getLong(1))
            }
            db.query(
                "SELECT operationId FROM pending_provider_deletions WHERE providerId = 'PROVIDER-FINAL'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("stable-operation", cursor.getString(0))
            }
        }
    }

    @Test
    fun migrateFromV15DedupesCaseVariantMessageIds() {
        val lowerId = "ca4b5067-834c-4729-8f8c-c133ca7fb0ea"
        val upperId = lowerId.uppercase()
        helper.createDatabase(CASE_VARIANT_DATABASE_NAME, 15).use { db ->
            db.execSQL(
                "INSERT INTO conversations(id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                    "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                    "accountId, firestoreUpdatedAt, firestoreMetadataUpdatedAt, remoteMessageCount, " +
                    "isConflictCopy) VALUES('CONV-1', 't', 0, 'P-1', 'OpenAI', 'm1', 0, '', 0.0, 0, '', " +
                    "1, 1, 'user-a', 0, 0, 0, 0)",
            )
            fun insertMessage(id: String, sortOrder: Int, createdAt: Long, text: String) {
                db.execSQL(
                    "INSERT INTO messages(id, conversationId, role, text, providerKind, providerName, " +
                        "modelName, estimatedCost, state, errorTitle, errorDetail, attachmentsJson, " +
                        "createdAt, sortOrder) VALUES('$id', 'CONV-1', 'Assistant', '$text', 'OpenAI', " +
                        "'OpenAI', 'm1', 0.0, 'Delivered', NULL, NULL, NULL, $createdAt, $sortOrder)",
                )
            }
            
            insertMessage(lowerId, sortOrder = 0, createdAt = 10, text = "stale")
            insertMessage(upperId, sortOrder = 1, createdAt = 20, text = "current")
            
            insertMessage("0e35d2bf-4a86-4dbf-9d67-6a6ff086c001", sortOrder = 2, createdAt = 30, text = "solo")
        }

        helper.runMigrationsAndValidate(
            CASE_VARIANT_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_15_16,
            OriveoDatabase.MIGRATION_16_17,
        ).use { db ->
            db.query("SELECT COUNT(*) FROM messages").use { cursor ->
                cursor.moveToFirst()
                assertEquals(2, cursor.getInt(0))
            }
            db.query("SELECT id, text FROM messages WHERE id = '$lowerId'").use { cursor ->
                assertTrue(cursor.moveToFirst())
                
                assertEquals(upperId, cursor.getString(0))
                assertEquals("current", cursor.getString(1))
            }
            
            db.execSQL(
                "INSERT OR REPLACE INTO messages(id, conversationId, role, text, providerKind, " +
                    "providerName, modelName, estimatedCost, state, sortOrder) VALUES('$lowerId', " +
                    "'CONV-1', 'Assistant', 'replaced', 'OpenAI', 'OpenAI', 'm1', 0.0, 'Delivered', 3)",
            )
            db.query("SELECT COUNT(*) FROM messages").use { cursor ->
                cursor.moveToFirst()
                assertEquals(2, cursor.getInt(0))
            }
        }
    }

    @Test
    fun migrateFromV16MergesCaseVariantRowsAcrossTables() {
        val lowerConv = "7d1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"
        val upperConv = lowerConv.uppercase()
        helper.createDatabase(V17_CASE_DATABASE_NAME, 16).use { db ->
            fun insertConversation(id: String, updatedAt: Long, title: String) {
                db.execSQL(
                    "INSERT INTO conversations(id, title, hasCustomTitle, providerID, providerKind, " +
                        "modelID, useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, " +
                        "updatedAt, accountId, firestoreUpdatedAt, firestoreMetadataUpdatedAt, " +
                        "remoteMessageCount, isConflictCopy) VALUES('$id', '$title', 0, 'P-1', 'OpenAI', " +
                        "'m1', 0, '', 0.0, 0, '', 1, $updatedAt, 'user-a', 0, 0, 0, 0)",
                )
            }
            
            insertConversation(lowerConv, updatedAt = 10, title = "stale")
            insertConversation(upperConv, updatedAt = 20, title = "current")
            
            fun insertMessage(id: String, convId: String, sortOrder: Int) {
                db.execSQL(
                    "INSERT INTO messages(id, conversationId, role, text, providerKind, providerName, " +
                        "modelName, estimatedCost, state, sortOrder) VALUES('$id', '$convId', 'User', 't', " +
                        "'OpenAI', 'OpenAI', 'm1', 0.0, 'Delivered', $sortOrder)",
                )
            }
            insertMessage("11111111-1111-4111-8111-111111111111", lowerConv, 0)
            insertMessage("22222222-2222-4222-8222-222222222222", upperConv, 1)
            
            db.execSQL(
                "INSERT INTO folders(id, name, sortOrder, createdAt, updatedAt, accountId, firestoreUpdatedAt) " +
                    "VALUES('aaaa1111-2222-4333-8444-555566667777', 'old', 0, 1, 10, 'user-a', 0)",
            )
            db.execSQL(
                "INSERT INTO folders(id, name, sortOrder, createdAt, updatedAt, accountId, firestoreUpdatedAt) " +
                    "VALUES('AAAA1111-2222-4333-8444-555566667777', 'new', 0, 1, 20, 'user-a', 0)",
            )
        }

        helper.runMigrationsAndValidate(
            V17_CASE_DATABASE_NAME,
            17,
            true,
            OriveoDatabase.MIGRATION_16_17,
        ).use { db ->
            db.query("SELECT COUNT(*), MAX(title) FROM conversations").use { cursor ->
                cursor.moveToFirst()
                assertEquals(1, cursor.getInt(0))
                assertEquals("current", cursor.getString(1))
            }
            
            db.query("SELECT COUNT(*) FROM messages WHERE conversationId = '$upperConv'").use { cursor ->
                cursor.moveToFirst()
                assertEquals(2, cursor.getInt(0))
            }
            db.query("SELECT COUNT(*), MAX(name) FROM folders").use { cursor ->
                cursor.moveToFirst()
                assertEquals(1, cursor.getInt(0))
                assertEquals("new", cursor.getString(1))
            }
        }
    }

    @Test
    fun migrateV16ToV18UsesDirectPathAndPreservesAccountScopedCaseVariants() {
        val lower = "abcd1111-2222-4333-8444-555566667777"
        val upper = lower.uppercase()
        val mixed = "AbCd1111-2222-4333-8444-555566667777"
        val splitConversationLower = "eeee1111-2222-4333-8444-555566667777"
        val splitConversationUpper = splitConversationLower.uppercase()
        helper.createDatabase(V18_DIRECT_DATABASE_NAME, 16).use { db ->
            fun insertConversation(id: String, accountId: String, title: String, updatedAt: Long) {
                db.execSQL(
                    "INSERT INTO conversations(id, title, hasCustomTitle, providerID, providerKind, " +
                        "modelID, useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, " +
                        "updatedAt, accountId, firestoreUpdatedAt, firestoreMetadataUpdatedAt, " +
                        "remoteMessageCount, isConflictCopy) VALUES('$id', '$title', 0, 'P-1', 'OpenAI', " +
                        "'m1', 0, '', 0.0, 0, '', 1, $updatedAt, '$accountId', 0, 0, 0, 0)",
                )
            }
            insertConversation(lower, "guest", "guest-row", 10)
            insertConversation(upper, "user-a", "a-row", 20)
            insertConversation(mixed, "user-b", "b-row", 30)
            insertConversation(splitConversationUpper, "user-c", "case-split-row", 40)

            fun insertMessage(id: String, parentId: String, text: String) {
                db.execSQL(
                    "INSERT INTO messages(id, conversationId, role, text, providerKind, providerName, " +
                        "modelName, estimatedCost, state, sortOrder) VALUES('$id', '$parentId', 'User', " +
                        "'$text', 'OpenAI', 'OpenAI', 'm1', 0.0, 'Delivered', 0)",
                )
            }
            insertMessage("11111111-1111-4111-8111-111111111111", lower, "guest-message")
            insertMessage("22222222-2222-4222-8222-222222222222", upper, "a-message")
            insertMessage("33333333-3333-4333-8333-333333333333", mixed, "b-message")
            
            insertMessage("44444444-4444-4444-8444-444444444444", splitConversationLower, "case-split-message")

            fun insertNote(id: String, accountId: String, updatedAt: String) {
                db.execSQL(
                    "INSERT INTO notes(id, title, titleSource, body, tagsJson, captureKind, isPinned, " +
                        "createdAt, updatedAt, accountId) VALUES('$id', 'shared note', 'manual', " +
                        "'shared body', '[]', 'blank', 0, '$updatedAt', '$updatedAt', '$accountId')",
                )
                repeat(2) {
                    db.execSQL(
                        "INSERT INTO note_search_index(noteId, title, body, userNote, tagsText) " +
                            "VALUES('$id', 'shared note', 'shared body', '', '')",
                    )
                }
            }
            insertNote(lower, "guest", "2026-07-20T00:00:01Z")
            insertNote(upper, "user-a", "2026-07-20T00:00:02Z")
            insertNote(mixed, "user-b", "2026-07-20T00:00:03Z")
        }

        helper.runMigrationsAndValidate(
            V18_DIRECT_DATABASE_NAME,
            18,
            true,
            OriveoDatabase.MIGRATION_16_17,
            OriveoDatabase.MIGRATION_16_18,
            OriveoDatabase.MIGRATION_17_18,
        ).use { db ->
            db.query("SELECT COUNT(*), COUNT(DISTINCT accountId) FROM conversations WHERE id = '$upper'").use {
                it.moveToFirst()
                assertEquals(3, it.getInt(0))
                assertEquals(3, it.getInt(1))
            }
            db.query("SELECT accountId, text FROM messages ORDER BY accountId").use { cursor ->
                val rows = buildList {
                    while (cursor.moveToNext()) add(cursor.getString(0) to cursor.getString(1))
                }
                assertEquals(
                    listOf(
                        "guest" to "guest-message",
                        "user-a" to "a-message",
                        "user-b" to "b-message",
                        "user-c" to "case-split-message",
                    ),
                    rows,
                )
            }
            db.query("SELECT conversationId FROM messages WHERE text = 'case-split-message'").use {
                assertTrue(it.moveToFirst())
                assertEquals(splitConversationUpper, it.getString(0))
            }
            db.query("SELECT COUNT(*) FROM note_search_index WHERE note_search_index MATCH 'shared'").use {
                it.moveToFirst()
                assertEquals(3, it.getInt(0))
            }
            db.query(
                "SELECT COUNT(*) FROM notes JOIN note_search_index " +
                    "ON notes.accountId = note_search_index.accountId AND notes.id = note_search_index.noteId " +
                    "WHERE notes.accountId = 'user-a' AND note_search_index MATCH 'shared'",
            ).use {
                it.moveToFirst()
                assertEquals(1, it.getInt(0))
            }
        }
    }

    @Test
    fun migrateV17ToV18AddsMessageAccountAndDeletionOperation() {
        val conversationId = "AAAAAAAA-2222-4333-8444-555566667777"
        helper.createDatabase(V18_FROM_V17_DATABASE_NAME, 17).use { db ->
            db.execSQL(
                "INSERT INTO conversations(id, title, hasCustomTitle, providerID, providerKind, modelID, " +
                    "useMemory, previewText, estimatedCost, isDraft, draftText, createdAt, updatedAt, " +
                    "accountId, firestoreUpdatedAt, firestoreMetadataUpdatedAt, remoteMessageCount, isConflictCopy) " +
                    "VALUES('$conversationId', 'v17', 0, 'P-1', 'OpenAI', 'm1', 0, '', 0.0, 0, '', " +
                    "1, 2, 'user-a', 0, 0, 1, 0)",
            )
            db.execSQL(
                "INSERT INTO messages(id, conversationId, role, text, providerKind, providerName, modelName, " +
                    "estimatedCost, state, sortOrder) VALUES('BBBBBBBB-2222-4333-8444-555566667777', " +
                    "'$conversationId', 'User', 'v17-message', 'OpenAI', 'OpenAI', 'm1', 0.0, 'Delivered', 0)",
            )
            db.execSQL(
                "INSERT INTO pending_conversation_deletions(conversationId, accountId, enqueuedAt) " +
                    "VALUES('$conversationId', 'user-a', 7)",
            )
        }

        helper.runMigrationsAndValidate(
            V18_FROM_V17_DATABASE_NAME,
            18,
            true,
            OriveoDatabase.MIGRATION_17_18,
        ).use { db ->
            db.query("SELECT accountId, conversationId FROM messages").use {
                it.moveToFirst()
                assertEquals("user-a", it.getString(0))
                assertEquals(conversationId, it.getString(1))
            }
            db.query("SELECT operationId FROM pending_conversation_deletions").use {
                it.moveToFirst()
                assertTrue(it.getString(0).isNotBlank())
            }
        }
    }

    @Test
    fun migrateV18ToV19AddsLibraryResearchMessageColumns() {
        helper.createDatabase(V19_FROM_V18_DATABASE_NAME, 18).close()

        helper.runMigrationsAndValidate(
            V19_FROM_V18_DATABASE_NAME,
            19,
            true,
            OriveoDatabase.MIGRATION_18_19,
        ).use { db ->
            db.query("PRAGMA table_info(messages)").use { cursor ->
                val columns = buildMap<String, Pair<Int, String?>> {
                    val nameIndex = cursor.getColumnIndexOrThrow("name")
                    val notNullIndex = cursor.getColumnIndexOrThrow("notnull")
                    val defaultIndex = cursor.getColumnIndexOrThrow("dflt_value")
                    while (cursor.moveToNext()) {
                        put(
                            cursor.getString(nameIndex),
                            cursor.getInt(notNullIndex) to cursor.getString(defaultIndex),
                        )
                    }
                }
                assertEquals(1 to "0", columns["libraryResearchEnabled"])
                assertEquals(0 to null, columns["libraryResearchStepsJson"])
            }
        }
    }

    @Test
    fun migrateV19ToV20AddsManagedErrorReasonCodeColumn() {
        helper.createDatabase(V20_FROM_V19_DATABASE_NAME, 19).close()

        helper.runMigrationsAndValidate(
            V20_FROM_V19_DATABASE_NAME,
            20,
            true,
            OriveoDatabase.MIGRATION_19_20,
        ).use { db ->
            db.query("PRAGMA table_info(messages)").use { cursor ->
                val columns = buildMap<String, Pair<Int, String?>> {
                    val nameIndex = cursor.getColumnIndexOrThrow("name")
                    val notNullIndex = cursor.getColumnIndexOrThrow("notnull")
                    val defaultIndex = cursor.getColumnIndexOrThrow("dflt_value")
                    while (cursor.moveToNext()) {
                        put(
                            cursor.getString(nameIndex),
                            cursor.getInt(notNullIndex) to cursor.getString(defaultIndex),
                        )
                    }
                }
                assertEquals(0 to null, columns["managedErrorReasonCode"])
            }
        }
    }

    @Test
    fun migrateV20ToV21AddsManagedRetryAtMillisColumn() {
        helper.createDatabase(V21_FROM_V20_DATABASE_NAME, 20).close()

        helper.runMigrationsAndValidate(
            V21_FROM_V20_DATABASE_NAME,
            21,
            true,
            OriveoDatabase.MIGRATION_20_21,
        ).use { db ->
            db.query("PRAGMA table_info(messages)").use { cursor ->
                val columns = buildMap<String, Pair<Int, String?>> {
                    val nameIndex = cursor.getColumnIndexOrThrow("name")
                    val notNullIndex = cursor.getColumnIndexOrThrow("notnull")
                    val defaultIndex = cursor.getColumnIndexOrThrow("dflt_value")
                    while (cursor.moveToNext()) {
                        put(
                            cursor.getString(nameIndex),
                            cursor.getInt(notNullIndex) to cursor.getString(defaultIndex),
                        )
                    }
                }
                
                assertEquals(0 to null, columns["managedRetryAtMillis"])
            }
        }
    }

    @Test
    fun migrateV21ToV22AddsQuoteContextJsonColumn() {
        helper.createDatabase(V22_FROM_V21_DATABASE_NAME, 21).close()

        helper.runMigrationsAndValidate(
            V22_FROM_V21_DATABASE_NAME,
            22,
            true,
            OriveoDatabase.MIGRATION_21_22,
        ).use { db ->
            db.query("PRAGMA table_info(messages)").use { cursor ->
                val columns = buildMap<String, Pair<Int, String?>> {
                    val nameIndex = cursor.getColumnIndexOrThrow("name")
                    val notNullIndex = cursor.getColumnIndexOrThrow("notnull")
                    val defaultIndex = cursor.getColumnIndexOrThrow("dflt_value")
                    while (cursor.moveToNext()) {
                        put(cursor.getString(nameIndex), cursor.getInt(notNullIndex) to cursor.getString(defaultIndex))
                    }
                }
                assertEquals(0 to null, columns["quoteContextJson"])
            }
        }
    }

    @Test
    fun migrateV22ToV23AddsMessageTokenUsageColumns() {
        helper.createDatabase(V23_FROM_V22_DATABASE_NAME, 22).close()

        helper.runMigrationsAndValidate(
            V23_FROM_V22_DATABASE_NAME,
            23,
            true,
            OriveoDatabase.MIGRATION_22_23,
        ).use { db ->
            db.query("PRAGMA table_info(messages)").use { cursor ->
                val columns = buildMap<String, Pair<Int, String?>> {
                    val nameIndex = cursor.getColumnIndexOrThrow("name")
                    val notNullIndex = cursor.getColumnIndexOrThrow("notnull")
                    val defaultIndex = cursor.getColumnIndexOrThrow("dflt_value")
                    while (cursor.moveToNext()) {
                        put(cursor.getString(nameIndex), cursor.getInt(notNullIndex) to cursor.getString(defaultIndex))
                    }
                }
                assertEquals(0 to null, columns["inputTokens"])
                assertEquals(0 to null, columns["outputTokens"])
                assertEquals(0 to null, columns["cacheCreationInputTokens"])
            }
        }
    }

    @Test
    fun migrateV23ToV26RemovesOpaqueContinuationPlaintextFromPrimaryDatabase() {
        helper.createDatabase(V26_FROM_V23_DATABASE_NAME, 23).close()
        helper.runMigrationsAndValidate(
            V26_FROM_V23_DATABASE_NAME,
            26,
            true,
            OriveoDatabase.MIGRATION_23_24,
            OriveoDatabase.MIGRATION_24_25,
            OriveoDatabase.MIGRATION_25_26,
        ).use { db ->
            db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='message_continuations'").use { cursor ->
                assertFalse("primary backup-eligible DB must not retain opaque state table", cursor.moveToFirst())
            }
        }
    }

    @Test
    fun migrateV26ToV27AddsOnlyCoarseExecutionFacts() {
        helper.createDatabase("oriveo-migration-v27-execution-facts.db", 26).close()
        helper.runMigrationsAndValidate(
            "oriveo-migration-v27-execution-facts.db",
            27,
            true,
            OriveoDatabase.MIGRATION_26_27,
        ).use { db ->
            db.query("PRAGMA table_info(messages)").use { cursor ->
                val nameIndex = cursor.getColumnIndexOrThrow("name")
                assertTrue(generateSequence { if (cursor.moveToNext()) cursor.getString(nameIndex) else null }
                    .toList()
                    .let { columns ->
                        columns.contains("capabilityExecutionResultsJson") &&
                            columns.contains("customRetryWithoutFieldsAvailable") &&
                            columns.contains("customRetryWithoutFieldsCode")
                    })
            }
        }
    }

    private companion object {
        const val TEST_DATABASE_NAME = "oriveo-migration-test.db"
        const val V17_CASE_DATABASE_NAME = "oriveo-migration-v17-case-test.db"
        const val V18_DIRECT_DATABASE_NAME = "oriveo-migration-v18-direct-test.db"
        const val V18_FROM_V17_DATABASE_NAME = "oriveo-migration-v18-from-v17-test.db"
        const val V19_FROM_V18_DATABASE_NAME = "oriveo-migration-v19-from-v18-test.db"
        const val V20_FROM_V19_DATABASE_NAME = "oriveo-migration-v20-from-v19-test.db"
        const val V21_FROM_V20_DATABASE_NAME = "oriveo-migration-v21-from-v20-test.db"
        const val V22_FROM_V21_DATABASE_NAME = "oriveo-migration-v22-from-v21-test.db"
        const val V23_FROM_V22_DATABASE_NAME = "oriveo-migration-v23-from-v22-test.db"
        const val V26_FROM_V23_DATABASE_NAME = "oriveo-migration-v26-from-v23-test.db"
        const val CASE_VARIANT_DATABASE_NAME = "oriveo-migration-case-variant-test.db"
        const val BLANK_OPERATION_DATABASE_NAME = "oriveo-migration-blank-operation-test.db"
        const val LEGACY_PROVIDER_DATABASE_NAME = "oriveo-migration-legacy-provider-test.db"
        const val FINAL_V14_DATABASE_NAME = "oriveo-migration-final-v14-test.db"
    }
}
