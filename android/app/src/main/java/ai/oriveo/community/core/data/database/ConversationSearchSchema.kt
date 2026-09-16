package ai.oriveo.community.core.data.database

import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * SQL triggers that maintain the conversation full-text index and the per-conversation message
 * count.
 *
 * These triggers are the foundation of the whole design: they keep index and count maintenance
 * **out of the business write paths** entirely. Writes to `messages` are spread across many
 * files — backup restore, import, streaming checkpoints, benchmark seeders — and hanging index
 * maintenance off each of them is both endless and easy to miss. A trigger is guaranteed by SQLite
 * to run whenever a row changes.
 *
 * Two SQLite behaviours this relies on, both verified against a real database rather than assumed:
 * 1. With `recursive_triggers` off (the default), a statement inside a trigger body **still** fires
 *    triggers on other tables. That is why Room's own invalidation trigger on
 *    `conversation_message_counts` still sees the change and the UI updates. What the setting
 *    disables is a trigger firing *itself*, directly or indirectly.
 * 2. Child rows removed by `ON DELETE CASCADE` **do** fire the child table's `AFTER DELETE`
 *    trigger, so deleting a conversation makes each cascaded message clean up its own index row
 *    instead of leaving orphans behind.
 *
 * There are two install points and both are required: the migration (so an upgraded database gets
 * them immediately) and `onOpen` (a fresh install goes through Room's `createAllTables` and runs no
 * migration at all, and a future migration that rebuilds a table would drop the triggers with it).
 * Everything is `IF NOT EXISTS`, so running it again costs nothing.
 */
internal object ConversationSearchSchema {

    /**
     * Message inserted: enqueue for indexing and bump the local count.
     *
     * The count is written as a "placeholder if absent, then UPDATE to increment" pair:
     * - not `ON CONFLICT ... DO UPDATE` (UPSERT), which needs SQLite 3.24 (API 28) while minSdk 26
     *   ships 3.18;
     * - and emphatically **not `INSERT OR IGNORE`**: when an IGNORE conflict happens inside a
     *   trigger body, SQLite **abandons the rest of that trigger program**. From the second message
     *   onwards the placeholder would be ignored and the increment skipped with it, leaving the
     *   count stuck at 1 forever. This is version-dependent — newer SQLite builds increment as
     *   expected — so it is exactly the kind of bug that passes on a development machine and fails
     *   on a device. `INSERT … SELECT … WHERE NOT EXISTS` never raises a conflict at all and
     *   behaves identically on every version.
     */
    private const val MESSAGE_INSERT = """
        CREATE TRIGGER IF NOT EXISTS `conversation_search_msg_insert`
        AFTER INSERT ON `messages`
        BEGIN
            INSERT INTO `conversation_search_dirty` (`messageRowId`)
                SELECT NEW.`rowid` WHERE NOT EXISTS (
                    SELECT 1 FROM `conversation_search_dirty` WHERE `messageRowId` = NEW.`rowid`);
            INSERT INTO `conversation_message_counts` (`accountId`, `conversationId`, `messageCount`)
                SELECT NEW.`accountId`, NEW.`conversationId`, 0 WHERE NOT EXISTS (
                    SELECT 1 FROM `conversation_message_counts`
                    WHERE `accountId` = NEW.`accountId` AND `conversationId` = NEW.`conversationId`);
            UPDATE `conversation_message_counts` SET `messageCount` = `messageCount` + 1
                WHERE `accountId` = NEW.`accountId` AND `conversationId` = NEW.`conversationId`;
        END
    """

    /** Body rewritten (streaming checkpoint, continuation): only the index needs rebuilding, the count is unchanged. */
    private const val MESSAGE_UPDATE_TEXT = """
        CREATE TRIGGER IF NOT EXISTS `conversation_search_msg_update_text`
        AFTER UPDATE OF `text` ON `messages`
        BEGIN
            INSERT INTO `conversation_search_dirty` (`messageRowId`)
                SELECT NEW.`rowid` WHERE NOT EXISTS (
                    SELECT 1 FROM `conversation_search_dirty` WHERE `messageRowId` = NEW.`rowid`);
        END
    """

    /** Message moved to another conversation: decrement the old one, increment the new one, reindex the row. */
    private const val MESSAGE_UPDATE_OWNER = """
        CREATE TRIGGER IF NOT EXISTS `conversation_search_msg_update_owner`
        AFTER UPDATE OF `conversationId`, `accountId` ON `messages`
        BEGIN
            INSERT INTO `conversation_search_dirty` (`messageRowId`)
                SELECT NEW.`rowid` WHERE NOT EXISTS (
                    SELECT 1 FROM `conversation_search_dirty` WHERE `messageRowId` = NEW.`rowid`);
            UPDATE `conversation_message_counts`
                SET `messageCount` = CASE WHEN `messageCount` > 0 THEN `messageCount` - 1 ELSE 0 END
                WHERE `accountId` = OLD.`accountId` AND `conversationId` = OLD.`conversationId`;
            INSERT INTO `conversation_message_counts` (`accountId`, `conversationId`, `messageCount`)
                SELECT NEW.`accountId`, NEW.`conversationId`, 0 WHERE NOT EXISTS (
                    SELECT 1 FROM `conversation_message_counts`
                    WHERE `accountId` = NEW.`accountId` AND `conversationId` = NEW.`conversationId`);
            UPDATE `conversation_message_counts` SET `messageCount` = `messageCount` + 1
                WHERE `accountId` = NEW.`accountId` AND `conversationId` = NEW.`conversationId`;
        END
    """

    /**
     * Message deleted, including the foreign-key cascade from deleting a conversation: drop the
     * index row, clear the queue entry, decrement the count.
     *
     * Deleting by `docid` is O(1). An FTS4 virtual table cannot carry an index, so deleting with
     * `WHERE conversationId = ...` would be a full scan.
     */
    private const val MESSAGE_DELETE = """
        CREATE TRIGGER IF NOT EXISTS `conversation_search_msg_delete`
        AFTER DELETE ON `messages`
        BEGIN
            DELETE FROM `conversation_search_index` WHERE `docid` = OLD.`rowid`;
            DELETE FROM `conversation_search_dirty` WHERE `messageRowId` = OLD.`rowid`;
            UPDATE `conversation_message_counts`
                SET `messageCount` = CASE WHEN `messageCount` > 0 THEN `messageCount` - 1 ELSE 0 END
                WHERE `accountId` = OLD.`accountId` AND `conversationId` = OLD.`conversationId`;
        END
    """

    /** Conversation deleted: drop its count row, so a reused rowid cannot read a stale count. */
    private const val CONVERSATION_DELETE = """
        CREATE TRIGGER IF NOT EXISTS `conversation_search_conv_delete`
        AFTER DELETE ON `conversations`
        BEGIN
            DELETE FROM `conversation_message_counts`
                WHERE `accountId` = OLD.`accountId` AND `conversationId` = OLD.`id`;
        END
    """

    private val ALL = listOf(
        MESSAGE_INSERT,
        MESSAGE_UPDATE_TEXT,
        MESSAGE_UPDATE_OWNER,
        MESSAGE_DELETE,
        CONVERSATION_DELETE,
    )

    fun installTriggers(db: SupportSQLiteDatabase) {
        ALL.forEach { db.execSQL(it.trimIndent()) }
    }

    /**
     * Rebuilds the counts and the pending queue from the current `messages` table.
     *
     * Only the `rowid`s are enqueued — a scan that never reads message bodies. The tokenising is
     * left to the background indexer: doing it here would hold the write transaction for a long
     * time on a database with tens of thousands of messages and stall the first open.
     */
    fun rebuildDerivedState(db: SupportSQLiteDatabase) {
        db.execSQL("DELETE FROM `conversation_message_counts`")
        db.execSQL(
            "INSERT INTO `conversation_message_counts` (`accountId`, `conversationId`, `messageCount`) " +
                "SELECT `accountId`, `conversationId`, COUNT(*) FROM `messages` GROUP BY `accountId`, `conversationId`",
        )
        db.execSQL("DELETE FROM `conversation_search_index`")
        db.execSQL("DELETE FROM `conversation_search_dirty`")
        db.execSQL(
            "INSERT INTO `conversation_search_dirty` (`messageRowId`) SELECT `rowid` FROM `messages`",
        )
    }
}
