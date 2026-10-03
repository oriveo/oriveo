package ai.oriveo.community.feature.mcp

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.mcp.McpAddCoordinator
import ai.oriveo.community.core.mcp.McpCredentialStore
import ai.oriveo.community.core.mcp.McpServerActions
import ai.oriveo.community.core.mcp.McpServerOverview
import ai.oriveo.community.core.mcp.McpServerStore
import ai.oriveo.community.core.mcp.McpServerSummary
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** View model for the add screen: it only ties [McpAddServerFlow] to the screen's lifecycle. Destroying the screen cancels an add in progress and abandons an unfinished one. */
class McpAddServerViewModel(
    coordinator: McpAddCoordinator,
    store: McpServerStore,
    applicationScope: CoroutineScope,
) : ViewModel() {
    val flow = McpAddServerFlow(
        scope = viewModelScope,
        coordinator = coordinator,
        store = store,
        cleanupScope = applicationScope,
    )

    override fun onCleared() {
        flow.close()
    }
}

data class McpServersUiState(
    /** The first read of local storage has not returned yet: do not draw the empty state, so people who already have servers do not see a flash of "no servers yet". */
    val loaded: Boolean = false,
    val servers: List<McpServerSummary> = emptyList(),
    val refreshing: Boolean = false,
)

/** Data for the server list screen: read from local storage, and only fresh after [reload]. */
class McpServersViewModel(
    private val store: McpServerStore,
    private val credentialStore: McpCredentialStore,
    private val actions: McpServerActions,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {
    private val _state = MutableStateFlow(McpServersUiState())
    val state: StateFlow<McpServersUiState> = _state.asStateFlow()

    /** Re-reads local storage. Called when entering the screen and when coming back from the add / detail screens. A failed read is presented as "no servers". */
    fun reload() {
        viewModelScope.launch(dispatcher) {
            val servers = try {
                McpServerOverview.load(store, credentialStore, LOCAL_PARTITION_ID)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                emptyList()
            }
            _state.value = _state.value.copy(loaded = true, servers = servers)
        }
    }

    /** Pull to refresh: re-probes the connection state of every server, writes each result back to local storage, then re-reads. */
    fun refresh() {
        if (_state.value.refreshing) return
        _state.value = _state.value.copy(refreshing = true)
        viewModelScope.launch(dispatcher) {
            try {
                actions.probeAll()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // Ignored: servers that could not be probed keep their previous state.
            }
            val servers = try {
                McpServerOverview.load(store, credentialStore, LOCAL_PARTITION_ID)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.value.servers
            }
            _state.value = _state.value.copy(loaded = true, servers = servers, refreshing = false)
        }
    }
}
