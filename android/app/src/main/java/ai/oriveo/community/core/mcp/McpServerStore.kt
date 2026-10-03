package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.dao.McpServerAdditionOutcome
import ai.oriveo.community.core.data.dao.McpServerDao
import ai.oriveo.community.core.data.dao.McpServerInsertOutcome
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.McpConnectionStateEntity
import ai.oriveo.community.core.data.entity.McpConversationSwitchEntity
import ai.oriveo.community.core.data.entity.McpServerEntity
import ai.oriveo.community.core.data.entity.McpStepPayloadEntity
import ai.oriveo.community.core.data.entity.McpToolPermissionEntity
import ai.oriveo.community.core.data.entity.McpToolSnapshotEntity
import kotlinx.serialization.json.JsonObject

/**
 * Local persistence of server records, the server limit, removal cleanup, and the other device-local tables
 * (connection state, tool snapshots, permissions, per-conversation switches and per-step payloads).
 *
 * **Credentials do not go through Room**, but removing a server has to clear them too, which is why this class holds
 * a [McpCredentialStore].
 */
class McpServerStore(
    private val dao: McpServerDao,
    private val credentials: McpCredentialStore,
    private val now: () -> Long = System::currentTimeMillis,
    /**
     * In-memory record of "allow for the rest of this conversation". Revocation lives in the storage layer: a
     * permission change, a tool catalog change or a server going away all pass through here, whoever wrote to the
     * database (management screen, chat screen, the refresh after re-authorization).
     */
    private val grants: McpConversationGrants? = null,
) {
    private val accountId: String get() = LOCAL_PARTITION_ID

    // ── Server records ─────────────────────────────────────

    /**
     * Rows whose `authKind` is not recognized (a value written by a newer client version) are skipped entirely
     * rather than guessed to be `auto`.
     *
     * For a `localOnly` record, [McpServerRecord.url] is the **display URL**; the address requests are sent to is
     * always obtained through
     * [McpServerEndpoint.resolve].
     */
    suspend fun fetchAllServers(): List<McpServerRecord> =
        // An addition the user has not finished yet does not count as a server: it stays out of the list, the
        // tool panel and batch probing.
        dao.getAll(accountId).filterNot { it.pendingAdd }.mapNotNull { it.toRecord() }

    suspend fun fetchServer(id: String): McpServerRecord? = dao.getById(accountId, id)?.toRecord()

    /** Same definition as [fetchAllServers]: unreadable rows are not counted, otherwise invisible rows would push the user over the limit. */
    suspend fun serverCount(): Int = dao.countReadable(accountId, KNOWN_AUTH_KINDS)

    /**
     * Inserts a new server record. The limit and slug uniqueness are checked in the same write transaction.
     *
     * Throws [McpStoreError.LimitReached] over the limit (the fallback value 20 applies when no runtime config is
     * available) and
     * [McpStoreError.SlugConflict] on a slug collision: the slug is the prefix of the tool names sent to the model,
     * so a collision would mean two servers competing for the same namespace.
     */
    suspend fun insertServer(
        record: McpServerRecord,
        maxServers: Int = McpRuntimeConfig.fallback.maxServers,
    ) {
        val outcome = dao.insertWithinLimit(
            entity = record.toEntity(accountId),
            maxServers = maxServers,
            knownAuthKinds = KNOWN_AUTH_KINDS,
        )
        when (outcome) {
            McpServerInsertOutcome.Inserted -> Unit
            McpServerInsertOutcome.LimitReached -> throw McpStoreError.LimitReached(maxServers)
            McpServerInsertOutcome.SlugConflict -> throw McpStoreError.SlugConflict(record.slug)
        }
    }

    /** Whether this id already belongs to a stored server (including unreadable rows: they occupy the primary key all the same). */
    suspend fun serverExists(id: String): Boolean = dao.serverExists(accountId, id)

    /**
     * Atomic write for the add flow: the record, tool snapshots, default permissions and connection state are
     * written in one write transaction and rolled back together on failure.
     *
     * The slug is generated from the name and de-duplicated inside the transaction. Throws
     * [McpStoreError.LimitReached] at the limit, and when the primary key already exists throws
     * [McpStoreError.ServerExists] **without touching the existing row**.
     */
    suspend fun addServer(addition: McpServerAddition, maxServers: Int): McpServerRecord {
        val account = accountId
        val record = McpServerRecord(
            id = addition.id,
            name = addition.name,
            slug = "",
            url = addition.url,
            authKind = addition.authKind,
            localOnly = addition.localOnly,
            iconURL = addition.iconURL,
            createdAt = addition.createdAt,
            updatedAt = addition.createdAt,
        )
        val outcome = dao.insertAddition(
            server = record.toEntity(account).copy(pendingAdd = addition.pendingAdd),
            snapshots = addition.snapshots.map { it.toEntity(account, addition.id) },
            permissions = addition.permissions.map { (toolName, permission) ->
                McpToolPermissionEntity(addition.id, toolName, account, permission.wireValue)
            },
            connectionState = addition.connectionState.copy(serverId = addition.id).toEntity(account),
            maxServers = maxServers,
            knownAuthKinds = KNOWN_AUTH_KINDS,
            slugFor = { existing -> McpSlug.unique(addition.name, existing) },
        )
        return when (outcome) {
            is McpServerAdditionOutcome.Inserted -> record.copy(slug = outcome.slug)
            McpServerAdditionOutcome.LimitReached -> throw McpStoreError.LimitReached(maxServers)
            McpServerAdditionOutcome.ServerExists -> throw McpStoreError.ServerExists(addition.id)
        }
    }

    /**
     * Done on the "confirm default permissions" page: releases the tools from quarantine, writes the permissions
     * and clears the "pending" flag in one transaction. Until that point the server is not listed.
     * Returns false when the record is gone.
     */
    suspend fun confirmAddition(
        serverId: String,
        snapshots: List<McpToolSnapshot>,
        permissions: Map<String, McpToolPermission>,
    ): Boolean {
        val account = accountId
        return dao.confirmAddition(
            accountId = account,
            serverId = serverId,
            snapshots = snapshots.map { it.toEntity(account, serverId) },
            permissions = permissions.map { (toolName, permission) ->
                McpToolPermissionEntity(serverId, toolName, account, permission.wireValue)
            },
        )
    }

    /**
     * Clears only the "pending" flag and leaves the tools quarantined: the fallback when [confirmAddition] cannot
     * write. The user already tapped Done, so the server must not
     * be swept as a half-finished addition on the next launch just because the permissions failed to save. The
     * detail page will later show "tools updated" and ask for confirmation once more.
     */
    suspend fun markAdditionConfirmed(serverId: String): Boolean = dao.clearPendingAdd(accountId, serverId) > 0

    /**
     * Startup sweep (a failed addition must not leave half a server behind): when the process died before the
     * user tapped Done, the stored "pending" record is removed together with its tool snapshots and credentials.
     * Only rows stored before [createdBefore] (the moment this process started) are swept, so additions in progress
     * in this process are left alone.
     *
     * @return the number of records removed.
     */
    suspend fun sweepUnconfirmedAdditions(createdBefore: Long): Int {
        var swept = 0
        for (row in dao.getPendingAdds(createdBefore)) {
            dao.deleteServerCascade(accountId = row.accountId, id = row.id)
            grants?.revoke(row.id)
            // Failing to delete the credentials does not block removing the record: credentials without a record
            // are never attached to a request again.
            runCatching { credentials.delete(serverId = row.id, uid = row.accountId) }
            swept += 1
        }
        return swept
    }

    /**
     * Updates the user-editable fields. `slug` never changes after creation, so it is not written: a differing
     * [McpServerRecord.slug] passed in is ignored.
     */
    suspend fun updateServer(record: McpServerRecord) {
        val account = accountId
        if (record.localOnly) {
            // A full URL was passed in (the user changed the address): store it in the credential store first; if
            // that fails, throw and leave the database untouched.
            // A display URL was passed in (only the name etc. changed): the full URL stays in the credential store.
            if (McpLocalOnly.displayUrl(record.url) != record.url) credentials.saveEndpoint(record.url, record.id, account)
        } else {
            // No longer secret-bearing: the address itself lives in the record and the credential store's copy is
            // obsolete. Failing to delete it is harmless (address resolution no longer reads it).
            runCatching { credentials.deleteEndpoint(record.id, account) }
        }
        dao.updateEditableFields(
            accountId = account,
            id = record.id,
            name = record.name,
            url = storedUrl(record.url, record.localOnly),
            authKind = record.authKind.wireValue,
            localOnly = record.localOnly,
            iconURL = record.iconURL,
            updatedAt = record.updatedAt,
        )
    }

    /**
     * Removes a server: the record and its local state are deleted in one transaction, and the credentials are
     * cleared. The server's per-step payloads are deleted with it; the step summaries on messages are kept.
     */
    suspend fun deleteServer(id: String) {
        val account = accountId
        dao.deleteServerCascade(accountId = account, id = id)
        grants?.revoke(id)
        // Clear them even when the record is gone: the credentials may be left over from a removal that stopped halfway.
        credentials.delete(serverId = id, uid = account)
    }

    /** Revokes "allow for the rest of this conversation" for every tool of a server (called by the caller in cases the storage layer cannot see itself, such as the address moving to another origin). */
    fun revokeConversationGrants(serverId: String) {
        grants?.revoke(serverId)
    }

    /** Returns a slug that does not collide with a stored one. The insert still re-checks inside its transaction; this only gives the UI a candidate. */
    suspend fun uniqueSlug(name: String): String = McpSlug.unique(name, dao.allSlugs(accountId).toSet())

    // ── Connection state ───────────────────────────────────

    suspend fun saveConnectionState(state: McpConnectionState) {
        dao.upsertConnectionState(state.toEntity(accountId))
    }

    suspend fun fetchConnectionState(serverId: String): McpConnectionState? {
        val entity = dao.getConnectionState(accountId, serverId) ?: return null
        val status = McpConnectionStatus.fromWireValue(entity.status) ?: return null
        return McpConnectionState(
            serverId = entity.serverId,
            status = status,
            lastSuccessAt = entity.lastSuccessAt,
            negotiatedVersion = entity.negotiatedVersion,
            generation = entity.generation?.let(McpProtocolGeneration::fromWireValue),
            sessionId = entity.sessionId,
        )
    }

    // ── Tool snapshots ─────────────────────────────────────

    suspend fun fetchToolSnapshots(serverId: String): List<McpToolSnapshot> =
        dao.getToolSnapshots(accountId, serverId).map { entity ->
            McpToolSnapshot(
                serverId = entity.serverId,
                toolName = entity.toolName,
                title = entity.title,
                description = entity.description,
                inputSchema = McpJson.parseOrNull(entity.inputSchema) ?: JsonObject(emptyMap()),
                annotations = McpJson.parseOrNull(entity.annotations) ?: JsonObject(emptyMap()),
                contentHash = entity.contentHash,
                readOnly = entity.readOnly,
                pendingReview = entity.pendingReview,
                oversized = entity.oversized,
                updatedAt = entity.updatedAt,
            )
        }

    /** Replaces a server's tool snapshots wholesale. The `serverId` parameter overrides whatever the [snapshots] carry. */
    suspend fun replaceToolSnapshots(serverId: String, snapshots: List<McpToolSnapshot>) {
        val account = accountId
        dao.replaceToolSnapshots(
            accountId = account,
            serverId = serverId,
            entities = snapshots.map { it.toEntity(account, serverId) },
        )
    }

    /**
     * Persists one catalog result ([McpToolCatalog.confirm] / a refetch) as a whole: the snapshots are replaced
     * wholesale and [permissions] are written over the existing ones, in one transaction.
     * Confirming a change may lower a permission (permissions are only lowered, never raised), and the
     * intermediate state "released but still run automatically" must never be observable.
     */
    suspend fun saveToolCatalog(
        serverId: String,
        snapshots: List<McpToolSnapshot>,
        permissions: Map<String, McpToolPermission>,
    ) {
        val account = accountId
        val before = grants?.let { dao.getToolSnapshots(account, serverId) }.orEmpty()
        val permissionsBefore = grants?.let { dao.getToolPermissions(account, serverId) }.orEmpty().associate { it.toolName to it.permission }
        dao.saveToolCatalog(
            accountId = account,
            serverId = serverId,
            snapshots = snapshots.map { it.toEntity(account, serverId) },
            permissions = permissions.map { (toolName, permission) ->
                McpToolPermissionEntity(serverId, toolName, account, permission.wireValue)
            },
        )
        // A tool that was removed, went back into quarantine, changed its content hash or display title, or had
        // its permission changed loses its "allow for the rest of this conversation" grant.
        val after = snapshots.associateBy { it.toolName }
        for (old in before) {
            val current = after[old.toolName]
            val permissionChanged = permissions[old.toolName]?.let { it.wireValue != permissionsBefore[old.toolName] } == true
            if (current == null || current.pendingReview || current.contentHash != old.contentHash ||
                current.title != old.title || permissionChanged
            ) {
                grants?.revoke(serverId, old.toolName)
            }
        }
    }

    /** Changes only one tool's quarantine flag (cleared after the user confirms a change). */
    suspend fun setToolPendingReview(serverId: String, toolName: String, pendingReview: Boolean) {
        dao.setToolPendingReview(accountId, serverId, toolName, pendingReview)
    }

    // ── Tool permissions ───────────────────────────────────

    /** Unrecognized permission values are left out of the result: callers apply the default permission to a missing tool, so it is never relaxed to "run automatically". */
    suspend fun fetchToolPermissions(serverId: String): Map<String, McpToolPermission> =
        dao.getToolPermissions(accountId, serverId).mapNotNull { entity ->
            McpToolPermission.fromWireValue(entity.permission)?.let { entity.toolName to it }
        }.toMap()

    suspend fun setToolPermission(permission: McpToolPermission, serverId: String, toolName: String) {
        dao.upsertToolPermission(
            McpToolPermissionEntity(
                serverId = serverId,
                toolName = toolName,
                accountId = accountId,
                permission = permission.wireValue,
            ),
        )
        // Any new value counts: the user has just expressed a new intent for this tool, so the earlier
        // "allow all" no longer holds.
        grants?.revoke(serverId, toolName)
    }

    // ── Conversation switches ──────────────────────────────

    suspend fun fetchEnabledServerIds(conversationId: String): List<String> =
        dao.getEnabledServerIds(accountId, conversationId)

    suspend fun setServerEnabled(enabled: Boolean, conversationId: String, serverId: String) {
        val account = accountId
        if (enabled) {
            dao.insertConversationSwitch(
                McpConversationSwitchEntity(
                    conversationId = conversationId,
                    serverId = serverId,
                    accountId = account,
                    enabledAt = now(),
                ),
            )
        } else {
            dao.deleteConversationSwitch(account, conversationId, serverId)
        }
    }

    /** "Pause this server": turns its switch off in every conversation. The record, credentials and tools all stay. */
    suspend fun disableServerEverywhere(serverId: String) {
        dao.deleteConversationSwitches(accountId, serverId)
    }

    /** After a draft conversation sends its first message, moves the switches stored under the draft id to the real conversation id (switches are remembered per conversation). */
    suspend fun moveConversationSwitches(fromConversationId: String, toConversationId: String) {
        if (fromConversationId.equals(toConversationId, ignoreCase = true)) return
        dao.moveConversationSwitchesToConversation(accountId, fromConversationId, toConversationId)
    }

    /** Clears every switch stored under a conversation (or an unsent draft). */
    suspend fun clearConversationSwitches(conversationId: String) {
        dao.deleteSwitchesOfConversation(accountId, conversationId)
    }

    // ── Per-step payloads ──────────────────────────────────

    /**
     * A step's payload arrives in two parts: the arguments with the first callback and the result with the
     * terminal state. A column passed as null keeps its stored value, so the later write does not wipe
     * the earlier one.
     */
    suspend fun saveStepPayload(
        messageId: String,
        stepId: String,
        arguments: String?,
        resultPrefix: String?,
        /** Which server this step belongs to: removing the server cascades the deletion by it. */
        serverId: String? = null,
    ) {
        val account = accountId
        val existing = dao.getStepPayload(account, messageId, stepId)
        dao.upsertStepPayload(
            McpStepPayloadEntity(
                messageId = existing?.messageId ?: messageId,
                stepId = stepId,
                accountId = account,
                arguments = arguments?.let { cappedUtf8(it, MAX_STEP_ARGUMENTS_BYTES) } ?: existing?.arguments,
                resultPrefix = resultPrefix?.let { cappedUtf8(it, MAX_STEP_RESULT_PREFIX_BYTES) } ?: existing?.resultPrefix,
                createdAt = existing?.createdAt ?: now(),
                serverId = serverId ?: existing?.serverId,
            ),
        )
    }

    suspend fun fetchStepPayload(messageId: String, stepId: String): McpStepPayload? =
        dao.getStepPayload(accountId, messageId, stepId)?.let { McpStepPayload(it.arguments, it.resultPrefix) }

    private fun McpServerEntity.toRecord(): McpServerRecord? {
        val kind = McpAuthKind.fromWireValue(authKind) ?: return null
        return McpServerRecord(
            id = id,
            name = name,
            slug = slug,
            url = url,
            authKind = kind,
            localOnly = localOnly,
            iconURL = iconURL,
            createdAt = createdAt,
            updatedAt = updatedAt,
        )
    }

    private fun McpToolSnapshot.toEntity(accountId: String, serverId: String) = McpToolSnapshotEntity(
        serverId = serverId,
        toolName = toolName,
        accountId = accountId,
        title = title,
        description = description,
        // Keep the source property order (the argument summary depends on it) instead of storing canonical JSON.
        inputSchema = McpJson.ordered(inputSchema),
        annotations = McpJson.ordered(annotations),
        contentHash = contentHash,
        readOnly = readOnly,
        pendingReview = pendingReview,
        oversized = oversized,
        updatedAt = updatedAt,
    )

    private fun McpConnectionState.toEntity(accountId: String) = McpConnectionStateEntity(
        serverId = serverId,
        accountId = accountId,
        status = status.wireValue,
        lastSuccessAt = lastSuccessAt,
        negotiatedVersion = negotiatedVersion,
        generation = generation?.wireValue,
        sessionId = sessionId,
    )

    private fun McpServerRecord.toEntity(accountId: String): McpServerEntity = McpServerEntity(
        id = id,
        accountId = accountId,
        name = name,
        slug = slug,
        url = storedUrl(url, localOnly),
        authKind = authKind.wireValue,
        localOnly = localOnly,
        iconURL = iconURL,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )

    companion object {
        /** Per-step payload limits: raw arguments <= 16 KB, and the first 2 KB of the returned result. */
        const val MAX_STEP_ARGUMENTS_BYTES = 16 * 1024
        const val MAX_STEP_RESULT_PREFIX_BYTES = 2 * 1024

        private val KNOWN_AUTH_KINDS = McpAuthKind.entries.map { it.wireValue }

        /**
         * The URL that gets stored: a `localOnly` record only ever stores the display URL, and the caller puts the
         * full URL into the credential store. Enforcing it at the write exit means
         * that no caller passing a full URL by mistake can write a secret into the main database, which is
         * included in system backups.
         */
        internal fun storedUrl(url: String, localOnly: Boolean): String = if (localOnly) McpLocalOnly.displayUrl(url) else url

        /** Truncates to the limit in UTF-8 bytes without splitting a multi-byte character (walks by code point, so surrogate pairs stay intact). */
        internal fun cappedUtf8(text: String, maxBytes: Int): String {
            var used = 0
            var index = 0
            while (index < text.length) {
                val codePoint = text.codePointAt(index)
                val size = when {
                    codePoint < 0x80 -> 1
                    codePoint < 0x800 -> 2
                    codePoint < 0x10000 -> 3
                    else -> 4
                }
                if (used + size > maxBytes) return text.substring(0, index)
                used += size
                index += Character.charCount(codePoint)
            }
            return text
        }
    }
}
