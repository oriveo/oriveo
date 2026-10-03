package ai.oriveo.community.core.mcp

// Server overview for the management screen and the settings entry. Reads local storage only; sends no requests.

/** A server's current state. The first four map to the status pills; [NeedsAddress] means the address has to be entered again. */
enum class McpServerHealth {
    Connected,
    NeedsAuth,
    Unreachable,

    /** Some tools are quarantined, waiting for the user to confirm them. */
    NeedsReview,

    /** The full URL of a `localOnly` server is not on this device (restored from a backup / moved to a new device): no request can be sent until the address is entered again. */
    NeedsAddress,
    ;

    val needsAttention: Boolean get() = this != Connected
}

data class McpServerSummary(
    val record: McpServerRecord,
    val health: McpServerHealth,
    /** Number of tools the server offers (including quarantined and "do not use" ones: this is the server's size, not how many a request will carry). */
    val toolCount: Int,
    val lastSuccessAt: Long?,
) {
    /** Loadable server icon URL; null when absent or rejected by the rules (the UI falls back to an initial-letter tile). */
    val iconUrl: String? get() = McpServerIconPolicy.loadable(record.iconURL, record.url)
}

object McpServerOverview {
    /** First whether the address is on this device, then the connection state, and finally whether any tool awaits confirmation. */
    fun health(
        endpoint: McpServerEndpointResolution,
        connection: McpConnectionState?,
        snapshots: List<McpToolSnapshot>,
    ): McpServerHealth = when {
        endpoint.urlOrNull == null -> McpServerHealth.NeedsAddress
        connection?.status == McpConnectionStatus.NeedsAuth -> McpServerHealth.NeedsAuth
        connection?.status == McpConnectionStatus.Unreachable -> McpServerHealth.Unreachable
        snapshots.any { it.pendingReview } -> McpServerHealth.NeedsReview
        else -> McpServerHealth.Connected
    }

    suspend fun load(store: McpServerStore, credentialStore: McpCredentialStore, uid: String): List<McpServerSummary> =
        store.fetchAllServers().map { record ->
            val connection = store.fetchConnectionState(record.id)
            val snapshots = store.fetchToolSnapshots(record.id)
            McpServerSummary(
                record = record,
                health = health(McpServerEndpoint.resolve(record, uid, credentialStore), connection, snapshots),
                toolCount = snapshots.size,
                lastSuccessAt = connection?.lastSuccessAt,
            )
        }

    fun attentionCount(servers: List<McpServerSummary>): Int = servers.count { it.health.needsAttention }
}
