package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import kotlinx.coroutines.CancellationException

// Operations on an already saved server:
// re-read tools, confirm tool changes, re-authorize, replace the access token, re-enter the address, remove.
// Re-authorize on the management screen, the tool panel and step blocks all go through here; the UI never touches
// the protocol client or the authorizer directly.
//
// Every operation writes the connection state back to local storage when it ends (connected / needsAuth /
// unreachable); the status pills and the tool panel's row status read it from there.

/** Result of connecting once with the locally stored credentials. */
sealed class McpServerProbe {
    data object Connected : McpServerProbe()
    data object NeedsAuth : McpServerProbe()
    data object Unreachable : McpServerProbe()

    /** The full URL of a `localOnly` server is not on this device: no request is sent. */
    data object NeedsAddress : McpServerProbe()

    /** The server is no longer stored (it was removed while the operation ran). */
    data object Gone : McpServerProbe()
}

sealed class McpRefreshResult {
    /** [previous] holds the snapshots from before this read ("view changes" shows the earlier description); it is not persisted. */
    data class Connected(val changes: List<McpToolChange>, val previous: List<McpToolSnapshot>) : McpRefreshResult()
    data object NeedsAuth : McpRefreshResult()
    data object Unreachable : McpRefreshResult()
    data object NeedsAddress : McpRefreshResult()
    data object Gone : McpRefreshResult()
}

    /** A tool waiting for the user's confirmation (quarantined in the local snapshots). */
data class McpPendingToolChange(
    /** A quarantined tool with no permission record is newly added; one with a record had its description / input schema / title changed. */
    val kind: McpToolChangeKind,
    val snapshot: McpToolSnapshot,
    /** Permission that takes effect after confirming (the default for added tools; for changed tools it may only be lowered, never raised). */
    val permissionAfter: McpToolPermission,
)

sealed class McpConfirmChangesResult {
    /** [stillPending]: tools the server changed again during confirmation; they stay quarantined and the UI must have the user look again. */
    data class Confirmed(val stillPending: List<String>) : McpConfirmChangesResult()
    data object NeedsAuth : McpConfirmChangesResult()
    data object Unreachable : McpConfirmChangesResult()
    data object NeedsAddress : McpConfirmChangesResult()
    data object Gone : McpConfirmChangesResult()
}

sealed class McpReauthPreparation {
    /** Browser sign-in is possible: the UI first shows the pre-sign-in notice and calls `completeReauthorization` once the user agrees. */
    data class Ready(val plan: McpAuthorizationPlan, val authorizationHost: String, val serverHost: String) : McpReauthPreparation()

    /** This server uses an access token, or does not support automatic sign-in: the UI shows the token input. */
    data object NeedsToken : McpReauthPreparation()

    /** It is reachable after all (the token refresh succeeded). */
    data object Connected : McpReauthPreparation()
    data object Unreachable : McpReauthPreparation()
    data object NeedsAddress : McpReauthPreparation()
    data object Gone : McpReauthPreparation()
}

enum class McpReauthOutcome {
    Connected,
    Cancelled,
    Unreachable,
    Failed,

    /** The server is no longer stored. */
    Gone,
}

enum class McpTokenSubmission { Connected, Rejected, Unreachable, Gone }

sealed class McpAddressUpdate {
    data class Invalid(val reason: McpInvalidUrlReason) : McpAddressUpdate()

    /** The address was saved; [refresh] is the result of reading the tools once with the new address right after. */
    data class Saved(val refresh: McpRefreshResult) : McpAddressUpdate()

    /** Could not be written locally. The record and the original address are left untouched. */
    data object Failed : McpAddressUpdate()
    data object Gone : McpAddressUpdate()
}

class McpServerActions(
    private val store: McpServerStore,
    private val credentialStore: McpCredentialStore,
    private val runtimeConfig: () -> McpRuntimeConfig,
    /** Must be the single app-wide instance: token refreshes are serialized per authorizer instance. */
    private val authorizer: McpAuthorizer,
    private val makeClient: (endpoint: String, runtimeConfig: McpRuntimeConfig) -> McpClient,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private class Target(val record: McpServerRecord, val endpoint: McpServerEndpointResolution)

    private val uid: String get() = LOCAL_PARTITION_ID

    private suspend fun target(serverId: String): Target? {
        val record = store.fetchServer(serverId) ?: return null
        return Target(record, McpServerEndpoint.resolve(record, uid, credentialStore))
    }

    private suspend fun saveStatus(serverId: String, status: McpConnectionStatus, session: McpSession? = null) {
        try {
            val current = store.fetchConnectionState(serverId)
            store.saveConnectionState(
                McpConnectionState(
                    serverId = serverId,
                    status = status,
                    lastSuccessAt = if (status == McpConnectionStatus.Connected) now() else current?.lastSuccessAt,
                    negotiatedVersion = session?.protocolVersion ?: current?.negotiatedVersion,
                    generation = session?.generation ?: current?.generation,
                    sessionId = if (status == McpConnectionStatus.Connected) session?.sessionId else null,
                ),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            // Failing to write the state does not affect this operation's result; the next probe writes it again.
        }
    }

    private sealed class Connection {
        class Connected(val client: McpClient, val session: McpSession) : Connection()
        class NeedsAuth(val client: McpClient, val endpoint: String) : Connection()
        data object Unreachable : Connection()
        data object NeedsAddress : Connection()
        data object Gone : Connection()
    }

    /** Connects once with the locally stored token (refreshing it first when it is about to expire). Never signs in again. */
    private suspend fun connectSaved(serverId: String): Connection {
        val target = target(serverId) ?: return Connection.Gone
        val endpoint = target.endpoint.urlOrNull ?: return Connection.NeedsAddress
        val client = makeClient(endpoint, runtimeConfig())
        val token = try {
            authorizer.validAccessToken(serverId, uid)
        } catch (error: McpAuthorizerException) {
            // A transient error (network / 5xx) does not prove that a new sign-in is needed.
            return if (error.isTransient) Connection.Unreachable else Connection.NeedsAuth(client, endpoint)
        }
        return when (val outcome = client.connect(bearerToken = token)) {
            is McpConnectOutcome.Connected -> Connection.Connected(client, outcome.session)
            McpConnectOutcome.NeedsAuth -> Connection.NeedsAuth(client, endpoint)
            McpConnectOutcome.NotMcp, McpConnectOutcome.Unreachable, is McpConnectOutcome.Failed -> Connection.Unreachable
        }
    }

    // ── Probing and re-reading tools (pull to refresh, "Re-read tools") ──

    /** Probes the connection state only: does not read the tool list and leaves the catalog alone. */
    suspend fun probe(serverId: String): McpServerProbe = when (val connection = connectSaved(serverId)) {
        is Connection.Connected -> {
            saveStatus(serverId, McpConnectionStatus.Connected, connection.session)
            McpServerProbe.Connected
        }
        is Connection.NeedsAuth -> {
            saveStatus(serverId, McpConnectionStatus.NeedsAuth)
            McpServerProbe.NeedsAuth
        }
        Connection.Unreachable -> {
            saveStatus(serverId, McpConnectionStatus.Unreachable)
            McpServerProbe.Unreachable
        }
        Connection.NeedsAddress -> McpServerProbe.NeedsAddress
        Connection.Gone -> McpServerProbe.Gone
    }

    /** Pull to refresh on the list screen: re-probes the connection state of every server. */
    suspend fun probeAll() {
        for (record in store.fetchAllServers()) probe(record.id)
    }

    /**
     * Re-reads the tools. New / changed tools go back into quarantine ([McpToolCatalog.snapshots]) and are not
     * offered to the model until the user confirms them.
     * Permissions for new tools are **not written ahead of time**: the default is applied only on confirmation, so
     * the UI can tell "newly added" (no permission record) from "description changed".
     */
    suspend fun refreshTools(serverId: String): McpRefreshResult {
        val connection = when (val connection = connectSaved(serverId)) {
            is Connection.Connected -> connection
            is Connection.NeedsAuth -> {
                saveStatus(serverId, McpConnectionStatus.NeedsAuth)
                return McpRefreshResult.NeedsAuth
            }
            Connection.Unreachable -> {
                saveStatus(serverId, McpConnectionStatus.Unreachable)
                return McpRefreshResult.Unreachable
            }
            Connection.NeedsAddress -> return McpRefreshResult.NeedsAddress
            Connection.Gone -> return McpRefreshResult.Gone
        }
        val definitions = when (val listed = listTools(serverId, connection.client)) {
            is Listed.Tools -> listed.definitions
            Listed.NeedsAuth -> return McpRefreshResult.NeedsAuth
            Listed.Unreachable -> return McpRefreshResult.Unreachable
        }
        if (store.fetchServer(serverId) == null) return McpRefreshResult.Gone
        val existing = store.fetchToolSnapshots(serverId)
        val incoming = McpToolCatalog.snapshots(serverId, definitions, runtimeConfig(), existing, now())
        val changes = McpToolCatalog.changes(existing, incoming)
        store.saveToolCatalog(serverId, incoming, emptyMap())
        saveStatus(serverId, McpConnectionStatus.Connected, connection.session)
        adoptServerIcon(serverId, connection.session)
        return McpRefreshResult.Connected(changes, existing)
    }

    /** The server reported an icon this time and it differs from the recorded one: store it. An existing icon is not cleared when none is reported. */
    private suspend fun adoptServerIcon(serverId: String, session: McpSession) {
        val icon = session.serverIconUrl ?: return
        try {
            val record = store.fetchServer(serverId) ?: return
            if (record.iconURL == icon) return
            store.updateServer(record.copy(iconURL = icon, updatedAt = now()))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            // If the icon could not be stored, the initial-letter tile simply keeps showing.
        }
    }

    private sealed class Listed {
        class Tools(val definitions: List<McpToolDefinition>) : Listed()
        data object NeedsAuth : Listed()
        data object Unreachable : Listed()
    }

    private suspend fun listTools(serverId: String, client: McpClient): Listed = try {
        Listed.Tools(client.listTools())
    } catch (error: CancellationException) {
        throw error
    } catch (error: McpClientException) {
        if (error.code == McpErrorCode.NeedsAuth) {
            saveStatus(serverId, McpConnectionStatus.NeedsAuth)
            Listed.NeedsAuth
        } else {
            saveStatus(serverId, McpConnectionStatus.Unreachable)
            Listed.Unreachable
        }
    } catch (error: Exception) {
        saveStatus(serverId, McpConnectionStatus.Unreachable)
        Listed.Unreachable
    }

    // ── Confirming tool changes ─────────────────────────────

    /**
     * The user confirms the changes. **What is confirmed is the snapshot the user saw**: the definitions are
     * fetched from the server again, and only tools whose content hash and title both still match what the user
     * saw are released from quarantine; mismatching ones stay quarantined, and the server's current definition is
     * stored as a new snapshot awaiting confirmation. Permissions may only be lowered, never raised.
     */
    suspend fun confirmChanges(serverId: String): McpConfirmChangesResult {
        val connection = when (val connection = connectSaved(serverId)) {
            is Connection.Connected -> connection
            is Connection.NeedsAuth -> {
                saveStatus(serverId, McpConnectionStatus.NeedsAuth)
                return McpConfirmChangesResult.NeedsAuth
            }
            Connection.Unreachable -> {
                saveStatus(serverId, McpConnectionStatus.Unreachable)
                return McpConfirmChangesResult.Unreachable
            }
            Connection.NeedsAddress -> return McpConfirmChangesResult.NeedsAddress
            Connection.Gone -> return McpConfirmChangesResult.Gone
        }
        val definitions = when (val listed = listTools(serverId, connection.client)) {
            is Listed.Tools -> listed.definitions
            Listed.NeedsAuth -> return McpConfirmChangesResult.NeedsAuth
            Listed.Unreachable -> return McpConfirmChangesResult.Unreachable
        }
        if (store.fetchServer(serverId) == null) return McpConfirmChangesResult.Gone
        val config = runtimeConfig()
        val seen = store.fetchToolSnapshots(serverId)
        val confirmation = McpToolCatalog.confirm(seen, definitions, store.fetchToolPermissions(serverId), config, now())
        // The server's full current set: tools the user confirmed stay released; tools that changed again during
        // confirmation, and ones that newly appeared meanwhile, are quarantined with their latest definitions.
        val confirmed = confirmation.snapshots.filterNot { it.pendingReview }
        val next = McpToolCatalog.snapshots(serverId, definitions, config, confirmed, now())
        val names = next.map { it.toolName }.toSet()
        store.saveToolCatalog(serverId, next, confirmation.permissions.filterKeys { it in names })
        saveStatus(serverId, McpConnectionStatus.Connected, connection.session)
        return McpConfirmChangesResult.Confirmed(next.filter { it.pendingReview }.map { it.toolName })
    }

    /** "Pause this server": turns it off in every conversation. Quarantined tools stay quarantined; it can be turned back on from the tool panel later. */
    suspend fun pause(serverId: String) {
        store.disableServerEverywhere(serverId)
    }

    // ── Per-tool permission ─────────────────────────────────

    suspend fun setPermission(serverId: String, toolName: String, permission: McpToolPermission) {
        store.setToolPermission(permission, serverId, toolName)
    }

    // ── Re-authorization ────────────────────────────────────

    /** First step of re-authorization: reads metadata only (GET); no client registration, no browser. */
    suspend fun prepareReauthorization(serverId: String): McpReauthPreparation {
        val target = target(serverId) ?: return McpReauthPreparation.Gone
        val connection = when (val connection = connectSaved(serverId)) {
            is Connection.Connected -> {
                saveStatus(serverId, McpConnectionStatus.Connected, connection.session)
                return McpReauthPreparation.Connected
            }
            Connection.Unreachable -> return McpReauthPreparation.Unreachable
            Connection.NeedsAddress -> return McpReauthPreparation.NeedsAddress
            Connection.Gone -> return McpReauthPreparation.Gone
            is Connection.NeedsAuth -> connection
        }
        if (target.record.authKind == McpAuthKind.Token) return McpReauthPreparation.NeedsToken
        return when (val discovery = authorizer.discover(connection.client.authChallenge, connection.endpoint)) {
            McpAuthDiscoveryOutcome.TemporarilyUnavailable -> McpReauthPreparation.Unreachable
            McpAuthDiscoveryOutcome.NeedsToken -> McpReauthPreparation.NeedsToken
            is McpAuthDiscoveryOutcome.Ready -> McpReauthPreparation.Ready(
                plan = discovery.plan,
                authorizationHost = discovery.plan.authorizationHost ?: discovery.plan.issuer,
                serverHost = McpOrigin.parse(connection.endpoint)?.host.orEmpty(),
            )
        }
    }

    /** Second step of re-authorization (the user has agreed): register -> authorization page -> token exchange -> connect once with the new token and refresh the tool catalog along the way. */
    suspend fun completeReauthorization(serverId: String, plan: McpAuthorizationPlan): McpReauthOutcome {
        val target = target(serverId) ?: return McpReauthOutcome.Gone
        try {
            authorizer.authorize(plan, serverId, uid)
        } catch (error: McpAuthorizerException) {
            return when {
                error.isTransient -> McpReauthOutcome.Unreachable
                error.kind == McpAuthorizerException.Kind.Cancelled -> McpReauthOutcome.Cancelled
                else -> McpReauthOutcome.Failed
            }
        }
        return finishReauthorization(serverId)
    }

    /** Replaces the access token (the token input, used on an already saved server). Nothing is saved if the server rejects it. */
    suspend fun submitAccessToken(serverId: String, token: String): McpTokenSubmission {
        val target = target(serverId) ?: return McpTokenSubmission.Gone
        val endpoint = target.endpoint.urlOrNull ?: return McpTokenSubmission.Unreachable
        val trimmed = token.trim()
        if (trimmed.isEmpty()) return McpTokenSubmission.Rejected
        when (makeClient(endpoint, runtimeConfig()).connect(bearerToken = trimmed)) {
            is McpConnectOutcome.Connected -> Unit
            McpConnectOutcome.NeedsAuth -> return McpTokenSubmission.Rejected
            else -> return McpTokenSubmission.Unreachable
        }
        try {
            // A pasted token replaces all earlier credentials: if the old OAuth access token stayed,
            // `validAccessToken` would use it first.
            authorizer.persistCredentials(McpCredentials(pastedToken = trimmed), serverId, uid)
        } catch (error: McpAuthorizerException) {
            return McpTokenSubmission.Unreachable
        }
        return when (finishReauthorization(serverId)) {
            McpReauthOutcome.Connected -> McpTokenSubmission.Connected
            McpReauthOutcome.Gone -> McpTokenSubmission.Gone
            else -> McpTokenSubmission.Unreachable
        }
    }

    /** New credentials are in hand: connect once and refresh the tool catalog along the way (tools that changed meanwhile go back into quarantine as usual). */
    private suspend fun finishReauthorization(serverId: String): McpReauthOutcome = when (refreshTools(serverId)) {
        is McpRefreshResult.Connected -> McpReauthOutcome.Connected
        McpRefreshResult.Gone -> McpReauthOutcome.Gone
        // The server still demands sign-in right after signing in: treated as not successful. The credentials
        // stay (the next refresh or sign-in overwrites them).
        McpRefreshResult.NeedsAuth -> McpReauthOutcome.Failed
        McpRefreshResult.Unreachable, McpRefreshResult.NeedsAddress -> McpReauthOutcome.Unreachable
    }

    // ── Re-entering the address ─────────────────────────────

    /**
     * Gives a server a new address (the user re-enters it when a `localOnly` server's full URL is not on this device).
     *
     * When the new address has a different origin than the old one, the server's tokens are deleted first and the
     * connection state is reset to unknown: the tokens were issued to the original origin
     * and must not be carried to another one. With the same origin the tokens stay. Whether the address looks
     * secret-bearing is re-evaluated against the new address.
     */
    suspend fun updateAddress(serverId: String, urlString: String): McpAddressUpdate {
        val url = when (val checked = McpEndpoint.check(urlString)) {
            is McpEndpointCheck.Valid -> checked.url
            is McpEndpointCheck.Invalid -> return McpAddressUpdate.Invalid(checked.reason)
        }
        val target = target(serverId) ?: return McpAddressUpdate.Gone
        // The `url` in a `localOnly` record is the display URL; its origin (scheme + host + port) equals the full URL's.
        val originChanged = !McpOrigin.isSameOrigin(target.record.url, url)
        try {
            if (originChanged) {
                store.revokeConversationGrants(serverId)
                credentialStore.delete(serverId, uid)
                store.saveConnectionState(McpConnectionState(serverId = serverId))
            }
            store.updateServer(
                target.record.copy(url = url, localOnly = McpLocalOnly.isLocalOnly(url), updatedAt = now()),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            return McpAddressUpdate.Failed
        }
        return McpAddressUpdate.Saved(refreshTools(serverId))
    }

    // ── Removal ─────────────────────────────────────────────

    /**
     * Removes a server: deletes the credentials and the record (along with tool snapshots, permissions and
     * per-conversation switches). Tool records in existing conversations are kept. Returns false when it cannot be
     * deleted.
     */
    suspend fun remove(serverId: String): Boolean = try {
        store.deleteServer(serverId)
        true
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        false
    }

    companion object {
        /** Tools on this server waiting for the user's confirmation (the quarantined ones in the local snapshots). */
        fun pendingChanges(
            snapshots: List<McpToolSnapshot>,
            permissions: Map<String, McpToolPermission>,
        ): List<McpPendingToolChange> = snapshots.filter { it.pendingReview }.map { snapshot ->
            val current = permissions[snapshot.toolName]
            McpPendingToolChange(
                kind = if (current == null) McpToolChangeKind.Added else McpToolChangeKind.Changed,
                snapshot = snapshot,
                permissionAfter = McpToolCatalog.permissionAfterConfirming(snapshot, current),
            )
        }
    }
}
