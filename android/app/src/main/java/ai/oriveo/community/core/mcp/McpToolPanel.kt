package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import kotlin.math.roundToInt
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Data behind the chat screen's tools entry point and panel.
//
// Plain data + pure functions: the number on the pill, the panel's three shapes (unavailable / empty / list), and
// the token estimate and over-limit notice at the bottom all come from here; the UI only draws. Which tools are
// available is decided by the same `McpToolBridge.plan` the send path uses, not by a second computation.

/** Whether this connection and this model can use MCP tools. */
enum class McpToolAvailability {
    Available,

    /** A model or connection known not to support tool calling. */
    ModelUnsupported,
    ;

    val isAvailable: Boolean get() = this == Available
}

/** One server's row in the panel. */
data class McpToolPanelServerRow(
    val id: String,
    val name: String,
    val iconURL: String?,
    /** Number of tools that will be offered to the model (excluding "do not use", quarantined and oversized ones). */
    val toolCount: Int,
    val status: Status,
    val isEnabled: Boolean,
    val serverUrl: String? = null,
) {
    sealed interface Status {
        /** Tools can be attached (connected, or not probed yet). */
        data object Ready : Status

        /** Needs re-authorization: the row offers Re-authorize instead of a switch. */
        data object NeedsAuth : Status

        /** Unreachable: shows the time of the last success. */
        data class Unreachable(val lastSuccessAt: Long?) : Status

        /** The full URL of a localOnly server is not on this device (restored from a backup): the address has to be entered again. */
        data object NeedsAddress : Status
    }

    /** Whether the switch can be flipped. An enabled server can always be turned off; a disabled one can be turned on only when usable. */
    val canToggle: Boolean
        get() = when (status) {
            Status.Ready -> true
            Status.NeedsAuth -> false
            is Status.Unreachable, Status.NeedsAddress -> isEnabled
        }

    /** Whether this request will carry its tools (same exclusion conditions as `McpToolBridge.plan`). */
    val contributesTools: Boolean
        get() = isEnabled && when (status) {
            Status.Ready, is Status.Unreachable -> true
            Status.NeedsAuth, Status.NeedsAddress -> false
        }
}

data class McpToolPanelState(
    val availability: McpToolAvailability,
    val rows: List<McpToolPanelServerRow>,
    /** Number of tools this request will carry (after truncation). */
    val outboundToolCount: Int,
    /** Estimated tokens taken by the tool definitions (rounded to the nearest hundred). */
    val estimatedTokens: Int,
    /** More tools are enabled than `maxToolsPerRequest`, so the trailing ones were cut off. */
    val truncated: Boolean,
    val maxToolsPerRequest: Int,
) {
    /** The number on the pill: servers enabled for this conversation and usable. Always 0 when the connection cannot use tools (the pill is greyed out). */
    val enabledServerCount: Int
        get() = if (availability.isAvailable) rows.count { it.contributesTools } else 0

    val hasServers: Boolean get() = rows.isNotEmpty()

    companion object {
        val Empty = McpToolPanelState(
            availability = McpToolAvailability.Available,
            rows = emptyList(),
            outboundToolCount = 0,
            estimatedTokens = 0,
            truncated = false,
            maxToolsPerRequest = McpRuntimeConfig.fallback.maxToolsPerRequest,
        )
    }
}

object McpToolPanelModel {
    /**
     * Token estimate = serialized character count of this request's tool definitions / 4, rounded to the nearest hundred.
     * It is an estimate, not a measurement; with tools present but under 50 tokens it reports 100 rather than 0.
     */
    fun estimatedTokens(plan: McpToolPlan): Int {
        if (plan.tools.isEmpty()) return 0
        val characters = plan.tools.sumOf { serialized(it.definition).length }
        val rounded = (characters / 4.0 / 100.0).roundToInt() * 100
        return maxOf(rounded, 100)
    }

    private fun serialized(definition: ToolLoopToolDefinition): String = McpJson.canonical(
        buildJsonObject {
            put("type", "function")
            put(
                "function",
                buildJsonObject {
                    put("name", definition.function.name)
                    put("description", definition.function.description)
                    put("parameters", definition.function.parameters)
                },
            )
        },
    )

    /** A row's status: first whether the address is on this device, then the connection state. */
    fun status(endpoint: McpServerEndpointResolution, connection: McpConnectionState?): McpToolPanelServerRow.Status {
        if (endpoint.urlOrNull == null) return McpToolPanelServerRow.Status.NeedsAddress
        return when (connection?.status) {
            McpConnectionStatus.NeedsAuth -> McpToolPanelServerRow.Status.NeedsAuth
            McpConnectionStatus.Unreachable -> McpToolPanelServerRow.Status.Unreachable(connection.lastSuccessAt)
            McpConnectionStatus.Connected, McpConnectionStatus.Unknown, null -> McpToolPanelServerRow.Status.Ready
        }
    }

    /** Reads everything the panel needs from local storage. `conversationId` is the draft id until a new conversation sends its first message. */
    suspend fun load(
        conversationId: String,
        store: McpServerStore,
        credentialStore: McpCredentialStore,
        uid: String,
        runtimeConfig: McpRuntimeConfig,
        availability: McpToolAvailability,
    ): McpToolPanelState {
        val enabled = store.fetchEnabledServerIds(conversationId)
        val enabledSet = enabled.map { it.lowercase() }.toSet()
        val rows = mutableListOf<McpToolPanelServerRow>()
        val inputs = mutableMapOf<String, McpBridgeServerInput>()
        for (record in store.fetchAllServers()) {
            val endpoint = McpServerEndpoint.resolve(record, uid, credentialStore)
            val connection = store.fetchConnectionState(record.id)
            val snapshots = store.fetchToolSnapshots(record.id)
            val permissions = store.fetchToolPermissions(record.id)
            rows += McpToolPanelServerRow(
                id = record.id,
                name = record.name,
                iconURL = McpServerIconPolicy.loadable(record.iconURL, record.url),
                serverUrl = record.url,
                toolCount = McpToolCatalog.outboundSnapshots(snapshots, permissions).size,
                status = status(endpoint, connection),
                isEnabled = record.id.lowercase() in enabledSet,
            )
            inputs[record.id.lowercase()] = McpBridgeServerInput(
                record = record,
                endpoint = endpoint,
                connectionStatus = connection?.status,
                snapshots = snapshots,
                permissions = permissions,
            )
        }
        // Assembled exactly like the send path: in enable order, with the same exclusions and truncation.
        val plan = if (availability.isAvailable) {
            McpToolBridge.plan(enabled.mapNotNull { inputs[it.lowercase()] }, runtimeConfig)
        } else {
            McpToolPlan.Empty
        }
        return McpToolPanelState(
            availability = availability,
            rows = rows,
            outboundToolCount = plan.tools.size,
            estimatedTokens = estimatedTokens(plan),
            truncated = plan.truncated,
            maxToolsPerRequest = runtimeConfig.maxToolsPerRequest,
        )
    }
}
