package ai.oriveo.community.core.data.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

// Local tables for remote MCP servers.
//
// Every table carries `accountId` in its primary key, like the rest of this database (see
// [ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID]).
//
// Every entity's column order, types, NOT NULL constraints, primary key and indices must match, character for
// character, the hand-written DDL in `OriveoDatabase.MIGRATION_2_3`; `McpMigrationTest` runs the migration on a real
// v2 database and lets Room validate the result.

/**
 * Server record. **Holds no credential fields**: tokens, and the full address when it looks like it carries a secret,
 * live in `McpCredentialStore`, outside this database and outside system backups.
 */
@Entity(
    tableName = "mcp_server",
    primaryKeys = ["id", "accountId"],
    indices = [
        Index("accountId"),
        // The slug is the tool-name prefix sent to the model; it must be unique across all servers on this device.
        Index(value = ["accountId", "slug"], unique = true),
    ],
)
data class McpServerEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val id: String,
    /** See [ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID]. */
    val accountId: String,
    val name: String,
    val slug: String,
    val url: String,
    /** Wire value of `McpAuthKind`. A row with an unrecognized value is skipped on read and never rewritten. */
    val authKind: String,
    /** The address looks like it carries a secret: [url] is then only a display address (see `McpLocalOnly`). */
    val localOnly: Boolean,
    val iconURL: String?,
    val createdAt: Long,
    val updatedAt: Long,
    /**
     * Pending-confirmation flag: set when the add flow stores the record after reading the tool list, and cleared only
     * when the user taps "Done" on the default-permissions review. Records carrying it do not appear in the list; if
     * the process dies before that point they are swept at the next launch.
     */
    val pendingAdd: Boolean = false,
)

/** Connection state. The legacy-protocol session id lives only here and in memory; it is never logged. */
@Entity(
    tableName = "mcp_connection_state",
    primaryKeys = ["serverId", "accountId"],
    indices = [Index("accountId")],
)
data class McpConnectionStateEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val serverId: String,
    val accountId: String,
    val status: String,
    val lastSuccessAt: Long?,
    val negotiatedVersion: String?,
    val generation: String?,
    val sessionId: String?,
)

/** Tool snapshot: `serverId` + original tool name. `inputSchema` / `annotations` are canonical JSON text. */
@Entity(
    tableName = "mcp_tool_snapshot",
    primaryKeys = ["serverId", "toolName", "accountId"],
    indices = [Index("accountId")],
)
data class McpToolSnapshotEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val serverId: String,
    val toolName: String,
    val accountId: String,
    val title: String,
    val description: String?,
    val inputSchema: String,
    val annotations: String,
    val contentHash: String,
    val readOnly: Boolean,
    val pendingReview: Boolean,
    val oversized: Boolean,
    val updatedAt: Long,
)

/**
 * Tool permission: `serverId` + original tool name → `auto` / `ask` / `off`.
 */
@Entity(
    tableName = "mcp_tool_permission",
    primaryKeys = ["serverId", "toolName", "accountId"],
    indices = [Index("accountId")],
)
data class McpToolPermissionEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val serverId: String,
    val toolName: String,
    val accountId: String,
    val permission: String,
)

/** Conversation switch: `conversationId` → the set of enabled `serverId`s. */
@Entity(
    tableName = "mcp_conversation_switch",
    primaryKeys = ["conversationId", "serverId", "accountId"],
    indices = [Index("accountId")],
)
data class McpConversationSwitchEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val conversationId: String,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val serverId: String,
    val accountId: String,
    val enabledAt: Long,
)

/**
 * Step payload: message id + step id → raw arguments (≤ 16 KB) and the first 2 KB of the result.
 *
 * [serverId] exists only for cascading deletes (removing a server deletes its payloads too). Deleting a message or a
 * conversation deletes by `messageId`, so the conversation does not need to be recorded separately.
 */
@Entity(
    tableName = "mcp_step_payload",
    primaryKeys = ["messageId", "stepId", "accountId"],
    indices = [Index("accountId")],
)
data class McpStepPayloadEntity(
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val messageId: String,
    val stepId: String,
    val accountId: String,
    val arguments: String?,
    val resultPrefix: String?,
    val createdAt: Long,
    @ColumnInfo(collate = ColumnInfo.NOCASE)
    val serverId: String? = null,
)
