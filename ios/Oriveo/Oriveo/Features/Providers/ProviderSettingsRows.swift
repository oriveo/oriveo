import Foundation

nonisolated enum ProviderSettingsRow: String, CaseIterable, Sendable {
    case endpoint
    case connection
    /// Parameters entry: for official connections it lives in the settings section with the same icon
    /// as the composer chip; for custom LLMs it is drawn in the detail page's "Models" card (the icon
    /// and row color belong to `RelayDetailBoardModel`). Both sides ask `rows` whether it is listed.
    case parameters
    case delete

    var icon: String {
        switch self {
        case .endpoint: return "globe"
        case .connection: return "gearshape"
        case .parameters: return "slider.horizontal.3"
        case .delete: return "trash"
        }
    }

    /// Whether the bottom of the detail page shows the "Settings" title and section. Relay and local
    /// connections do not: their only listed row, parameters, moved into the board's "Models" card,
    /// so another section would be a leftover outside the board.
    static func usesSettingsSection(for provider: Provider) -> Bool {
        ProviderForm.of(provider) != .relay
    }

    /// Rows shown in a connection's settings list. An empty array means the whole section is not
    /// rendered. The endpoint row only applies to connections whose base URL the user can choose.
    ///
    /// `parameters` is an always-on row, so the list is never empty in the community edition.
    static func rows(for provider: Provider, hasEndpointOptions: Bool) -> [ProviderSettingsRow] {
        // Relay and local connections have their edit-connection and delete entries in the detail
        // page's header and bottom buttons, so the settings section does not repeat them.
        // Every community connection allows advanced settings and deletion,
        // so the section is never empty here; `hasEndpointOptions` only decides the endpoint row.
        let isCustomLLM = ProviderForm.of(provider) == .relay
        var rows: [ProviderSettingsRow] = []
        if hasEndpointOptions { rows.append(.endpoint) }
        if !isCustomLLM { rows.append(.connection) }
        rows.append(.parameters)
        if !isCustomLLM { rows.append(.delete) }
        return rows
    }
}
