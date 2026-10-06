import Foundation

// MARK: - Data for the chat tool entry point and the tool panel
//
// Plain data and pure functions: the number on the pill, the three shapes of the panel (unavailable / empty /
// list), the token estimate at the bottom and the over-limit notice all come from here; the UI only draws.
// "Usable tools" is computed by the same `McpToolBridge.plan` the send path uses, not by a second
// implementation.

/// Whether this connection and model can use MCP tools.
nonisolated enum McpToolAvailability: Sendable, Equatable {
    case available
    /// A model or connection known not to support tool calls.
    case modelUnsupported

    var isAvailable: Bool { self == .available }

    static func resolve(provider: Provider, model: AIModel, memory: ToolCallMemoryStore) -> McpToolAvailability {
        McpToolBridge.connectionSupportsTools(provider: provider, model: model, memory: memory)
            ? .available
            : .modelUnsupported
    }
}

/// One server row in the panel.
nonisolated struct McpToolPanelServerRow: Sendable, Equatable, Identifiable {
    enum Status: Sendable, Equatable {
        /// Can carry tools (connected, or not probed yet).
        case ready
        /// Needs reauthorization: the row offers "Reauthorize" instead of a switch.
        case needsAuth
        /// Unreachable: shows when it last succeeded.
        case unreachable(lastSuccessAt: Date?)
        /// The full address of a localOnly server is not on this device (restored from a backup): it has to be
        /// entered again.
        case needsAddress
    }

    var id: UUID
    var name: String
    var iconURL: String?
    /// Number of tools offered to the model (minus "off", quarantined and oversized ones).
    var toolCount: Int
    var status: Status
    var isEnabled: Bool
    var serverURL: String? = nil

    /// Whether the switch can be flipped. An enabled server can always be turned off; a disabled one can only be
    /// turned on while it is usable.
    var canToggle: Bool {
        switch status {
        case .ready: return true
        case .needsAuth: return false
        case .unreachable, .needsAddress: return isEnabled
        }
    }

    /// Whether this request will carry its tools (same exclusion rules as `McpToolBridge.plan`).
    var contributesTools: Bool {
        guard isEnabled else { return false }
        switch status {
        case .ready, .unreachable: return true
        case .needsAuth, .needsAddress: return false
        }
    }
}

nonisolated struct McpToolPanelState: Sendable, Equatable {
    var availability: McpToolAvailability
    var rows: [McpToolPanelServerRow]
    /// Number of tools this request will carry (after truncation).
    var outboundToolCount: Int
    /// Estimated tokens taken by the tool definitions (rounded to the nearest hundred).
    var estimatedTokens: Int
    /// More tools are enabled than `maxToolsPerRequest`; the tail was cut off.
    var truncated: Bool
    var maxToolsPerRequest: Int

    static let empty = McpToolPanelState(
        availability: .available, rows: [], outboundToolCount: 0, estimatedTokens: 0, truncated: false,
        maxToolsPerRequest: McpRuntimeConfig.fallback.maxToolsPerRequest
    )

    /// The number on the pill: servers enabled for this conversation and usable. Always 0 when the connection
    /// cannot use tools (the pill is greyed out).
    var enabledServerCount: Int {
        guard availability.isAvailable else { return 0 }
        return rows.filter(\.contributesTools).count
    }

    var hasServers: Bool { !rows.isEmpty }
}

nonisolated enum McpToolPanelModel {
    /// Token estimate = character count of the serialized definitions of the tools usable now, divided by 4 and
    /// rounded to the nearest hundred. It is an estimate, not a measurement; with tools present but fewer than 50
    /// tokens it reports 100 rather than showing 0.
    static func estimatedTokens(for plan: McpToolPlan) -> Int {
        guard !plan.tools.isEmpty else { return 0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let characters = plan.tools.reduce(0) { total, tool in
            let text = (try? encoder.encode(tool.definition)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return total + text.count
        }
        let rounded = Int((Double(characters) / 4 / 100).rounded()) * 100
        return max(rounded, 100)
    }

    /// The status of one row: first whether the address is on this device, then the connection status.
    static func status(
        endpoint: McpServerEndpointResolution,
        connection: McpConnectionState?
    ) -> McpToolPanelServerRow.Status {
        guard case .ready = endpoint else { return .needsAddress }
        switch connection?.status {
        case .needsAuth: return .needsAuth
        case .unreachable: return .unreachable(lastSuccessAt: connection?.lastSuccessAt)
        case .connected, .unknown, nil: return .ready
        }
    }

    /// Reads everything the panel needs from local storage. Before a new conversation sends its first message,
    /// `conversationId` is the draft id.
    static func load(
        conversationId: UUID,
        store: McpServerStore,
        credentialStore: McpCredentialStore,
        uid: String,
        runtimeConfig: McpRuntimeConfig,
        availability: McpToolAvailability
    ) throws -> McpToolPanelState {
        let enabled = try store.fetchEnabledServerIds(conversationId: conversationId)
        let enabledSet = Set(enabled)
        var rows: [McpToolPanelServerRow] = []
        var inputs: [UUID: McpBridgeServerInput] = [:]
        for record in try store.fetchAllServers() {
            let endpoint = McpServerEndpoint.resolve(record, uid: uid, credentialStore: credentialStore)
            let connection = try store.fetchConnectionState(serverId: record.id)
            let snapshots = try store.fetchToolSnapshots(serverId: record.id)
            let permissions = try store.fetchToolPermissions(serverId: record.id)
            rows.append(McpToolPanelServerRow(
                id: record.id,
                name: record.name,
                iconURL: record.iconURL,
                toolCount: McpToolCatalog.outboundSnapshots(
                    snapshots, permissions: permissions, runtimeConfig: runtimeConfig
                ).count,
                status: status(endpoint: endpoint, connection: connection),
                isEnabled: enabledSet.contains(record.id),
                serverURL: record.url
            ))
            inputs[record.id] = McpBridgeServerInput(
                record: record, endpoint: endpoint, connectionStatus: connection?.status,
                snapshots: snapshots, permissions: permissions
            )
        }
        // The same assembly as the send path: enable order, same exclusions and truncation.
        let plan = availability.isAvailable
            ? McpToolBridge.plan(servers: enabled.compactMap { inputs[$0] }, runtimeConfig: runtimeConfig)
            : .empty
        return McpToolPanelState(
            availability: availability,
            rows: rows,
            outboundToolCount: plan.tools.count,
            estimatedTokens: estimatedTokens(for: plan),
            truncated: plan.truncated,
            maxToolsPerRequest: runtimeConfig.maxToolsPerRequest
        )
    }
}
