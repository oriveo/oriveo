import Foundation

enum ProviderSetupEntryPoint: String, Hashable {
    case welcome
    case providers
    case modelPicker
    case skillEdit
}

enum ManualModelEntryContext: String, Hashable {
    case onboarding
    case providers
    case providerDetail
    case modelPicker
    case skillEdit
}

enum AppRoute: Hashable {
    case providerSetup(entryPoint: ProviderSetupEntryPoint, preselectedKind: ProviderKind? = nil)
    case manualModelEntry(providerID: UUID, context: ManualModelEntryContext)
    case providerDetail(providerID: UUID)
    case chat(conversationID: UUID?)
    case relaySetup(entryPoint: ProviderSetupEntryPoint)
    case localComputeSetup(entryPoint: ProviderSetupEntryPoint)
    case backup
    case folderDetail(folderID: UUID)
    case memory
    /// MCP server management ("MCP servers" in Settings, "Manage MCP servers" in the chat tool panel).
    case mcpServers
    /// Add an MCP server ("Add" on the list page, "Add MCP server" in the empty tool panel).
    case mcpAddServer
    /// Details of one MCP server. `intent` tells "show the details" from "start re-authorizing on entry".
    case mcpServerDetail(serverID: UUID, intent: McpServerDetailIntent)
    case skillsList
    case skillEdit(UUID?)
    case notesList
    case noteDetail(noteID: UUID)
}

/// One navigation policy shared by official providers, Relay, and Local compute setup.
enum ProviderSetupCompletionPolicy {
    /// Removes the complete setup subtree while preserving the route that launched it.
    /// A legacy deep link may enter Relay/Local without the parent providerSetup route, so both
    /// shapes are handled explicitly.
    static func returnedCallerPath(from path: [AppRoute]) -> [AppRoute] {
        if let setupRoot = path.lastIndex(where: { route in
            if case .providerSetup = route { return true }
            return false
        }) {
            return Array(path[..<setupRoot])
        }
        if let directSetup = path.lastIndex(where: { route in
            switch route {
            case .relaySetup, .localComputeSetup: return true
            default: return false
            }
        }) {
            return Array(path[..<directSetup])
        }
        return path
    }
}
