package ai.oriveo.community.feature.mcp

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.mcp.McpAddressUpdate
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpConfirmChangesResult
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpInvalidUrlReason
import ai.oriveo.community.core.mcp.McpPendingToolChange
import ai.oriveo.community.core.mcp.McpReauthorizer
import ai.oriveo.community.core.mcp.McpRefreshResult
import ai.oriveo.community.core.mcp.McpServerActions
import ai.oriveo.community.core.mcp.McpServerEndpoint
import ai.oriveo.community.core.mcp.McpServerHealth
import ai.oriveo.community.core.mcp.McpServerOverview
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.mcp.McpServerSummary
import ai.oriveo.community.core.mcp.McpToolChange
import ai.oriveo.community.core.mcp.McpToolChangeKind
import ai.oriveo.community.core.mcp.McpToolPermission
import ai.oriveo.community.core.mcp.McpToolSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The "sign-in method" row on the detail screen. */
enum class McpSignInLabel { Browser, Token, None }

/** The one thing in progress on the detail screen (only one at a time). */
enum class McpDetailBusy { Reloading, Confirming, Removing, SavingAddress }

/** The sentence shown on the page when an action did not succeed. */
enum class McpDetailNotice { Unreachable, RemoveFailed }

/** The notice inside the "Tools updated" sheet. */
enum class McpChangesNotice { StillPending, NeedsAuth, Unreachable }

data class McpChangesSheetState(
    /** Snapshot from before this read (only available right after reading; after reopening the page only the "now" half remains). */
    val previous: List<McpToolSnapshot> = emptyList(),
    /** Tools this read found the server no longer offers. Not persisted. */
    val removed: List<McpToolChange> = emptyList(),
    val notice: McpChangesNotice? = null,
)

data class McpServerDetailUiState(
    val loaded: Boolean = false,
    /** The server is no longer on this device (it was removed): the page should close. */
    val gone: Boolean = false,
    val summary: McpServerSummary? = null,
    val signIn: McpSignInLabel = McpSignInLabel.None,
    val snapshots: List<McpToolSnapshot> = emptyList(),
    val permissions: Map<String, McpToolPermission> = emptyMap(),
    val busy: McpDetailBusy? = null,
    val notice: McpDetailNotice? = null,
    /** Non-null = the "Tools updated" sheet is open. */
    val changes: McpChangesSheetState? = null,
    /** Non-null = the permission sheet for this tool is open. */
    val permissionTool: String? = null,
    val showRemoveConfirm: Boolean = false,
    /** Re-entering the address. */
    val addressDraft: String = "",
    val addressError: McpInvalidUrlReason? = null,
) {
    val health: McpServerHealth? get() = summary?.health

    /** Tools waiting for the user's confirmation (quarantined). */
    val pending: List<McpPendingToolChange> get() = McpServerActions.pendingChanges(snapshots, permissions)

    /** Whether the tool list is interactive: greyed out when authorization expired or the address is not on this device. */
    val toolsLocked: Boolean get() = health == McpServerHealth.NeedsAuth || health == McpServerHealth.NeedsAddress

    val readOnlyTools: List<McpToolSnapshot> get() = snapshots.filter { it.readOnly }
    val changingTools: List<McpToolSnapshot> get() = snapshots.filterNot { it.readOnly }

    fun permission(tool: McpToolSnapshot): McpToolPermission =
        permissions[tool.toolName] ?: McpToolPermission.defaultFor(tool.readOnly)
}

/**
 * State of the server detail screen: reads local storage and calls [McpServerActions]. A class of its own (rather than living in the ViewModel)
 * so tests can hand it a plain scope.
 */
class McpServerDetailController(
    private val serverId: String,
    private val scope: CoroutineScope,
    private val store: McpServerStore,
    private val credentialStore: McpCredentialStore,
    private val actions: McpServerActions,
    private val reauthorizer: McpReauthorizer,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val _state = MutableStateFlow(McpServerDetailUiState())
    val state: StateFlow<McpServerDetailUiState> = _state.asStateFlow()

    private var job: Job? = null

    /** Reloads local storage. Called on entering the page and after every action. */
    fun reload() {
        scope.launch(dispatcher) { load() }
    }

    private suspend fun load() {
        try {
            val record = store.fetchServer(serverId)
            if (record == null) {
                _state.update { it.copy(loaded = true, gone = true) }
                return
            }
            val connection = store.fetchConnectionState(serverId)
            val snapshots = store.fetchToolSnapshots(serverId)
            val permissions = store.fetchToolPermissions(serverId)
            val credentials = credentialStore.load(serverId, LOCAL_PARTITION_ID)
            val summary = McpServerSummary(
                record = record,
                health = McpServerOverview.health(McpServerEndpoint.resolve(record, LOCAL_PARTITION_ID, credentialStore), connection, snapshots),
                toolCount = snapshots.size,
                lastSuccessAt = connection?.lastSuccessAt,
            )
            _state.update {
                it.copy(
                    loaded = true,
                    summary = summary,
                    signIn = when {
                        record.authKind == McpAuthKind.Token || credentials?.pastedToken != null -> McpSignInLabel.Token
                        credentials?.accessToken != null || credentials?.clientId != null -> McpSignInLabel.Browser
                        else -> McpSignInLabel.None
                    },
                    snapshots = snapshots,
                    permissions = permissions,
                )
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            _state.update { it.copy(loaded = true) }
        }
    }

    private fun begin(busy: McpDetailBusy, block: suspend () -> Unit) {
        if (_state.value.busy != null) return
        _state.update { it.copy(busy = busy, notice = null) }
        job = scope.launch(dispatcher) {
            try {
                block()
            } finally {
                _state.update { it.copy(busy = null) }
            }
        }
    }

    // ── Reload tools ────────────────────────────────────────

    /** "Reload tools". When changes are found, "Tools updated" opens right away; the changed tools are already quarantined at this point. */
    fun reloadTools() = begin(McpDetailBusy.Reloading) {
        val result = actions.refreshTools(serverId)
        load()
        when (result) {
            is McpRefreshResult.Connected -> if (result.changes.isNotEmpty()) {
                _state.update {
                    it.copy(
                        changes = McpChangesSheetState(
                            previous = result.previous,
                            removed = result.changes.filter { change -> change.kind == McpToolChangeKind.Removed },
                        ),
                    )
                }
            }
            McpRefreshResult.Unreachable -> _state.update { it.copy(notice = McpDetailNotice.Unreachable) }
            // The status pill already followed the connection state; the page's primary button becomes "Re-authorize" / the address field.
            McpRefreshResult.NeedsAuth, McpRefreshResult.NeedsAddress, McpRefreshResult.Gone -> Unit
        }
    }

    /** "View changes": opens "Tools updated" (after reopening the page there is no earlier description to compare against). */
    fun openChanges() = _state.update { it.copy(changes = it.changes ?: McpChangesSheetState()) }

    fun dismissChanges() {
        if (_state.value.busy == McpDetailBusy.Confirming) return
        _state.update { it.copy(changes = null) }
    }

    /** "Confirm and keep using". Tools the server changed again during confirmation stay quarantined, and the sheet stays open for another look. */
    fun confirmChanges() = begin(McpDetailBusy.Confirming) {
        val result = actions.confirmChanges(serverId)
        load()
        _state.update { current ->
            val sheet = current.changes ?: McpChangesSheetState()
            when (result) {
                is McpConfirmChangesResult.Confirmed ->
                    if (result.stillPending.isEmpty()) {
                        current.copy(changes = null)
                    } else {
                        // The earlier comparison no longer matches the new pending snapshot.
                        current.copy(changes = McpChangesSheetState(notice = McpChangesNotice.StillPending))
                    }
                McpConfirmChangesResult.NeedsAuth -> current.copy(changes = sheet.copy(notice = McpChangesNotice.NeedsAuth))
                McpConfirmChangesResult.Unreachable, McpConfirmChangesResult.NeedsAddress ->
                    current.copy(changes = sheet.copy(notice = McpChangesNotice.Unreachable))
                McpConfirmChangesResult.Gone -> current.copy(changes = null)
            }
        }
    }

    /** "Disable this server for now": turns it off in every conversation; changed tools stay quarantined. */
    fun pause() {
        _state.update { it.copy(changes = null) }
        scope.launch(dispatcher) { runCatching { actions.pause(serverId) } }
    }

    // ── Permission for a single tool ────────────────────────

    fun openPermission(toolName: String) = _state.update { it.copy(permissionTool = toolName) }

    fun dismissPermission() = _state.update { it.copy(permissionTool = null) }

    fun setPermission(toolName: String, permission: McpToolPermission) {
        // Update the UI first, then persist, then reload from storage as the source of truth.
        _state.update { it.copy(permissions = it.permissions + (toolName to permission)) }
        scope.launch(dispatcher) {
            runCatching { actions.setPermission(serverId, toolName, permission) }
            load()
        }
    }

    // ── Re-authorization ────────────────────────────────────

    fun reauthorize() {
        scope.launch(dispatcher) {
            runCatching { reauthorizer.reauthorize(serverId) }
            load()
        }
    }

    // ── Re-entering the address ─────────────────────────────

    fun updateAddressDraft(value: String) = _state.update { it.copy(addressDraft = value, addressError = null) }

    fun saveAddress() = begin(McpDetailBusy.SavingAddress) {
        when (val result = actions.updateAddress(serverId, _state.value.addressDraft)) {
            is McpAddressUpdate.Invalid -> _state.update { it.copy(addressError = result.reason) }
            is McpAddressUpdate.Saved -> {
                _state.update { it.copy(addressDraft = "") }
                if (result.refresh == McpRefreshResult.Unreachable) _state.update { it.copy(notice = McpDetailNotice.Unreachable) }
            }
            McpAddressUpdate.Failed -> _state.update { it.copy(notice = McpDetailNotice.Unreachable) }
            McpAddressUpdate.Gone -> Unit
        }
        load()
    }

    // ── Removal ─────────────────────────────────────────────

    fun askRemove() = _state.update { it.copy(showRemoveConfirm = true, notice = null) }

    fun dismissRemove() {
        if (_state.value.busy == McpDetailBusy.Removing) return
        _state.update { it.copy(showRemoveConfirm = false) }
    }

    fun confirmRemove() = begin(McpDetailBusy.Removing) {
        if (actions.remove(serverId)) {
            _state.update { it.copy(showRemoveConfirm = false, gone = true) }
        } else {
            _state.update { it.copy(notice = McpDetailNotice.RemoveFailed) }
            load()
        }
    }
}

class McpServerDetailViewModel(
    serverId: String,
    store: McpServerStore,
    credentialStore: McpCredentialStore,
    actions: McpServerActions,
    reauthorizer: McpReauthorizer,
) : ViewModel() {
    val controller = McpServerDetailController(
        serverId = serverId,
        scope = viewModelScope,
        store = store,
        credentialStore = credentialStore,
        actions = actions,
        reauthorizer = reauthorizer,
    )
}
