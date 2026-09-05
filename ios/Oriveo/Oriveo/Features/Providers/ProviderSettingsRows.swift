import Foundation

nonisolated enum ProviderSettingsRow: String, CaseIterable, Sendable {
    case endpoint
    case connection
    case modelBehavior
    case delete

    var icon: String {
        switch self {
        case .endpoint: return "globe"
        case .connection: return "gearshape"
        case .modelBehavior: return "slider.horizontal.3"
        case .delete: return "trash"
        }
    }

    /// Rows shown in a connection's settings list. The endpoint row only applies to
    /// connections whose base URL the user can choose.
    static func rows(hasEndpointOptions: Bool) -> [ProviderSettingsRow] {
        var rows: [ProviderSettingsRow] = []
        if hasEndpointOptions { rows.append(.endpoint) }
        rows.append(.connection)
        rows.append(.modelBehavior)
        rows.append(.delete)
        return rows
    }
}
