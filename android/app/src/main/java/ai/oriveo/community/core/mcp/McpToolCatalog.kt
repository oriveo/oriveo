package ai.oriveo.community.core.mcp

// Tool catalog.
//
// Consumes the output of `McpClient.listTools()` and produces tool snapshots, default permissions and the change
// list. Pagination of `tools/list` is handled in `McpClient`; this file is only the pure logic that runs once the
// definitions are in hand.
//
// `annotations` (including `readOnlyHint`) are hints self-reported by a third party and are treated as untrusted:
// a read-only claim is used only to relax a tool to "run automatically", and a tool without the claim is always
// treated as one that modifies data.

object McpToolCatalog {
    /** Whether a single tool's description + input schema exceeds `maxToolDefinitionBytes`. Oversized tools are never sent to the model. */
    fun isOversized(definition: McpToolDefinition, runtimeConfig: McpRuntimeConfig): Boolean =
        definitionSizeBytes(definition) > runtimeConfig.maxToolDefinitionBytes

    /** UTF-8 byte count of the description (0 when missing) plus the canonical JSON of the input schema. */
    fun definitionSizeBytes(definition: McpToolDefinition): Int =
        definition.description.orEmpty().toByteArray(Charsets.UTF_8).size +
            McpJson.canonical(definition.inputSchema).toByteArray(Charsets.UTF_8).size

    /** Content hash of one tool. */
    fun contentHash(definition: McpToolDefinition): String =
        McpToolHash.contentHash(definition.name, definition.description, definition.inputSchema, definition.annotations)

    // ── Change detection rule ───────────────────────────────

    /**
     * "This tool changed": its content hash changed, **or** its display title changed. The hash input does not
     * include the top-level `title` (the fixtures are frozen), yet the title is exactly what the confirmation
     * dialog shows. Comparing hashes alone would let a server rename an already approved tool from "Search" to
     * "Delete everything" without triggering a confirmation.
     */
    fun isChanged(snapshot: McpToolSnapshot, definition: McpToolDefinition): Boolean =
        snapshot.contentHash != contentHash(definition) || snapshot.title != definition.displayTitle

    /**
     * When the server returns tools with duplicate names, only the first is kept (order preserved). The snapshot
     * primary key is "server + original tool name", so without de-duplication the whole write would fail on a
     * primary key conflict; the model can only have one tool per name anyway.
     */
    fun deduplicated(definitions: List<McpToolDefinition>): List<McpToolDefinition> = definitions.distinctBy { it.name }

    // ── Snapshots ───────────────────────────────────────────

    /**
     * Builds tool snapshots from the `tools/list` output. **New or changed tools get `pendingReview = true`** and
     * stay quarantined until the user confirms them;
     * unchanged tools keep their existing quarantine flag (a tool the user never confirmed stays quarantined and
     * is not quietly released by a refetch).
     */
    fun snapshots(
        serverId: String,
        definitions: List<McpToolDefinition>,
        runtimeConfig: McpRuntimeConfig,
        existing: List<McpToolSnapshot> = emptyList(),
        now: Long = System.currentTimeMillis(),
    ): List<McpToolSnapshot> {
        val existingByName = existing.associateByFirst { it.toolName }
        return deduplicated(definitions).map { definition ->
            val previous = existingByName[definition.name]
            val changed = previous?.let { isChanged(it, definition) } ?: true
            McpToolSnapshot(
                serverId = serverId,
                toolName = definition.name,
                title = definition.displayTitle,
                description = definition.description,
                inputSchema = definition.inputSchema,
                annotations = definition.annotations,
                contentHash = contentHash(definition),
                readOnly = definition.readOnly,
                pendingReview = if (changed) true else previous?.pendingReview ?: true,
                oversized = isOversized(definition, runtimeConfig),
                updatedAt = now,
            )
        }
    }

    // ── Change detection ────────────────────────────────────

    /** Compares the existing snapshots with the new ones and yields added / changed / removed entries. "Changed" is defined by [isChanged]. */
    fun changes(existing: List<McpToolSnapshot>, incoming: List<McpToolSnapshot>): List<McpToolChange> {
        val existingByName = existing.associateByFirst { it.toolName }
        val incomingNames = incoming.map { it.toolName }.toSet()
        val result = mutableListOf<McpToolChange>()
        incoming.filter { existingByName[it.toolName] == null }
            .forEach { result += McpToolChange(McpToolChangeKind.Added, it.toolName, it.title) }
        incoming.forEach { snapshot ->
            val previous = existingByName[snapshot.toolName] ?: return@forEach
            if (previous.contentHash != snapshot.contentHash || previous.title != snapshot.title) {
                result += McpToolChange(McpToolChangeKind.Changed, snapshot.toolName, snapshot.title)
            }
        }
        existing.filter { it.toolName !in incomingNames }
            .forEach { result += McpToolChange(McpToolChangeKind.Removed, it.toolName, it.title) }
        return result
    }

    // ── Default permissions ─────────────────────────────────

    /** Tools that declare themselves read-only "run automatically"; everything else (including tools with no declaration) is "ask every time". */
    fun defaultPermissions(snapshots: List<McpToolSnapshot>): Map<String, McpToolPermission> =
        snapshots.associate { it.toolName to McpToolPermission.defaultFor(it.readOnly) }

    // ── Outbound filtering ──────────────────────────────────

    /**
     * Tools sent to the model: quarantined (`pendingReview`) tools, tools whose permission is "do not use" and
     * oversized tools never appear.
     * A missing permission falls back to the default permission (which is never "do not use").
     */
    fun outboundSnapshots(snapshots: List<McpToolSnapshot>, permissions: Map<String, McpToolPermission>): List<McpToolSnapshot> =
        snapshots.filter { snapshot ->
            if (snapshot.pendingReview || snapshot.oversized) return@filter false
            val permission = permissions[snapshot.toolName] ?: McpToolPermission.defaultFor(snapshot.readOnly)
            permission != McpToolPermission.Off
        }

    // ── Confirming and releasing from quarantine ────────────

    /**
     * The user confirms a change: the tool is released from quarantine, and the updated snapshot returned, only
     * when **the server's current definition still matches the snapshot the user saw** (neither the content hash
     * nor the display title changed). Null means the server changed the tool again while the user was confirming,
     * so it must stay quarantined.
     */
    fun confirmed(
        snapshot: McpToolSnapshot,
        definition: McpToolDefinition,
        runtimeConfig: McpRuntimeConfig,
        now: Long = System.currentTimeMillis(),
    ): McpToolSnapshot? {
        if (isChanged(snapshot, definition)) return null
        return snapshot.copy(pendingReview = false, oversized = isOversized(definition, runtimeConfig), updatedAt = now)
    }

    /**
     * Permission after confirming (it may only be lowered, never raised): a tool with no permission record (a
     * newly added tool) gets the default; for a tool with a record, when the read-only claim is no longer true
     * after confirming and the current permission is "run automatically", it drops to "ask every time", and
     * nothing else changes. The user confirmed "I know it changed",
     * not "it may write data without asking me from now on". Confirming never relaxes a permission.
     */
    fun permissionAfterConfirming(snapshot: McpToolSnapshot, current: McpToolPermission?): McpToolPermission {
        if (current == null) return McpToolPermission.defaultFor(snapshot.readOnly)
        if (current == McpToolPermission.Auto && !snapshot.readOnly) return McpToolPermission.Ask
        return current
    }

    /**
     * Batch confirmation. [permissions] are the permissions before confirming; the result carries the snapshots
     * and permissions after confirming, plus the names of tools that changed again meanwhile and stay quarantined.
     * Tools the server has removed are kept as is (removal is reported by [changes], not silently applied here).
     * Permissions are recomputed only for tools that **actually went from quarantined to released this time**.
     * The result goes to `McpServerStore.saveToolCatalog`, which persists it in a single transaction.
     */
    fun confirm(
        snapshots: List<McpToolSnapshot>,
        definitions: List<McpToolDefinition>,
        permissions: Map<String, McpToolPermission>,
        runtimeConfig: McpRuntimeConfig,
        now: Long = System.currentTimeMillis(),
    ): McpToolConfirmation {
        val definitionsByName = definitions.associateByFirst { it.name }
        val resultSnapshots = mutableListOf<McpToolSnapshot>()
        val resultPermissions = permissions.toMutableMap()
        val stillPending = mutableListOf<String>()
        for (snapshot in snapshots) {
            val definition = definitionsByName[snapshot.toolName]
            if (definition == null) {
                resultSnapshots += snapshot
                continue
            }
            val confirmed = confirmed(snapshot, definition, runtimeConfig, now)
            if (confirmed == null) {
                stillPending += snapshot.toolName
                resultSnapshots += snapshot
                continue
            }
            resultSnapshots += confirmed
            if (snapshot.pendingReview) {
                resultPermissions[snapshot.toolName] = permissionAfterConfirming(confirmed, permissions[snapshot.toolName])
            }
        }
        return McpToolConfirmation(resultSnapshots, resultPermissions, stillPending)
    }

    private inline fun <T> List<T>.associateByFirst(key: (T) -> String): Map<String, T> {
        val result = LinkedHashMap<String, T>()
        for (item in this) result.putIfAbsent(key(item), item)
        return result
    }
}

/** Result of one batch confirmation ([McpToolCatalog.confirm]). */
data class McpToolConfirmation(
    val snapshots: List<McpToolSnapshot>,
    /** All permissions after confirming (the permissions before confirming plus those recomputed this time). */
    val permissions: Map<String, McpToolPermission>,
    /** Names of tools the server changed again during confirmation; they stay quarantined. */
    val stillPending: List<String>,
)
