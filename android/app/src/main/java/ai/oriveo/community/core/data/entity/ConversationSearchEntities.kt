package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Fts4
import androidx.room.PrimaryKey

/**
 * Room FTS4 virtual table holding the full-text index of chat messages.
 *
 * Room 2.7.1 has no `@Fts5` annotation, and the system SQLite behind minSdk 26 (3.18) has no FTS5
 * either, so this is plain `@Fts4`. The table is maintained independently (no `contentEntity`):
 * **one row per message**, where `docid` is the implicit `rowid` of the `messages` table.
 *
 * Why one row per message rather than per conversation: with one row per conversation, every new
 * message means reading *all* of that conversation's history back out and re-tokenising it, which
 * is O(n²) over a long thread. Per message, each message is tokenised exactly once and deletion
 * addresses the row directly by `docid`, in O(1).
 *
 * Why titles and preview text stay out of this table: `conversations` has few rows with short
 * fields, so `LIKE '%q%'` over it is not a bottleneck, and it keeps substring semantics. Users
 * expect a title search to match substrings, and token matching would be a regression there.
 *
 * The index contents are maintained by SQL triggers on `messages` plus
 * [ai.oriveo.community.core.data.search.ConversationSearchIndexer], so no write path — streaming
 * checkpoints, backup restore, importers — has to know this table exists.
 */
@Fts4(notIndexed = ["conversationId", "accountId"])
@Entity(tableName = "conversation_search_index")
data class ConversationFtsEntity(
    val conversationId: String,
    val accountId: String,
    /** Tokens produced by [ai.oriveo.community.core.data.search.ConversationFtsQuery.indexText]. */
    val text: String,
)

/**
 * Queue of messages whose index rows need rebuilding.
 *
 * The triggers on `messages` only insert a `rowid` here. A trigger cannot tokenise CJK text, but it
 * can capture **every** write path without exception, which is exactly what takes index maintenance
 * out of the write-path code. The tokenising and the actual index write are done by the background
 * indexer that consumes this queue.
 */
@Entity(tableName = "conversation_search_dirty")
data class ConversationSearchDirtyEntity(
    @PrimaryKey
    @ColumnInfo(name = "messageRowId")
    val messageRowId: Long,
)

/**
 * Per-conversation message count, kept here so the conversation list queries no longer depend on
 * invalidation of the `messages` table.
 *
 * Each of those queries used to carry a correlated `COUNT(*) FROM messages`, so a streaming
 * checkpoint that only rewrites `text` still made SQLite re-run a full count for the entire
 * conversation list. `distinctUntilChanged` hides that from the UI; it does not stop the work.
 * Joining this small table, keyed by (accountId, conversationId), means the list queries depend on
 * `conversations` and this table only, and partial writes never touch either.
 *
 * **Why the count is not a column on `conversations`**: rows in `conversations` are replaced
 * wholesale by `@Upsert` on restore and import paths, which would write a stale count (typically 0,
 * so the list would show "0 messages"). A separate table is owned exclusively by the triggers, and
 * no business write path can reach it.
 */
@Entity(
    tableName = "conversation_message_counts",
    primaryKeys = ["accountId", "conversationId"],
)
data class ConversationMessageCountEntity(
    val accountId: String,
    /**
     * Same collation as `conversations.id` and `messages.conversationId`; otherwise the join is
     * split apart by case variants of the same id.
     */
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val conversationId: String,
    val messageCount: Int,
)
