import SwiftUI

/// The page for one `AppRoute`, with its navigation chrome attached.
///
/// Shared by the outer `NavigationStack` destination and the wide-screen right column, so a route
/// looks the same pushed full screen or shown in the right column.
struct AppRouteDestination: View {
    let route: AppRoute
    @Environment(AppState.self) private var appState

    var body: some View {
        switch route {
        case let .providerSetup(entryPoint, preselectedKind):
            ProviderSetupView(entryPoint: entryPoint, preselectedKind: preselectedKind)
                .oriveoNavigationChrome()
        case let .manualModelEntry(providerID, context):
            ManualModelEntryView(providerID: providerID, context: context)
                .oriveoNavigationChrome()
        case let .providerDetail(providerID):
            ProviderDetailView(providerID: providerID)
                .oriveoNavigationChrome()
        case let .relayModelLibrary(providerID, keyID):
            ProviderDetailView(providerID: providerID, page: .modelLibrary, keyFilter: keyID)
                .oriveoNavigationChrome()
        case let .relayKeys(providerID):
            RelayKeysPage(providerID: providerID)
                .oriveoNavigationChrome()
        case let .relayWebSearch(providerID):
            RelayWebSearchPage(providerID: providerID)
                .oriveoNavigationChrome()
        case let .relayModelAdvanced(providerID, modelID, readOnly):
            ProviderDetailView(providerID: providerID, page: .modelAdvanced(modelID: modelID, readOnly: readOnly))
                .oriveoNavigationChrome()
        case let .chat(conversationID):
            ChatView(conversationID: conversationID)
                .chatNavigationChrome()
        case let .relaySetup(entryPoint):
            RelaySetupView(entryPoint: entryPoint)
                .oriveoNavigationChrome()
        case let .localComputeSetup(entryPoint):
            RelaySetupView(entryPoint: entryPoint, initialMethod: .local)
                .oriveoNavigationChrome()
        case .backup:
            BackupView()
                .oriveoNavigationChrome()
        case let .folderDetail(folderID):
            FolderDetailView(folderID: folderID)
                .oriveoNavigationChrome()
        case .memory:
            MemoryView()
                .oriveoNavigationChrome()
        case .memoryInbox:
            MemoryInboxView()
                .oriveoNavigationChrome()
        case .contextSettings:
            ContextSettingsView()
                .oriveoNavigationChrome()
        case .themeSettings:
            ThemeSettingsView()
                .oriveoNavigationChrome()
        case .voiceSettings:
            VoiceSettingsView(appState: appState)
                .oriveoNavigationChrome()
        case .mcpServers:
            McpServersView()
                .oriveoNavigationChrome()
        case .mcpAddServer:
            McpAddServerView()
                .oriveoNavigationChrome()
        case let .mcpServerDetail(serverID, intent):
            McpServerDetailView(serverID: serverID, intent: intent)
                .oriveoNavigationChrome()
        case .skillsList:
            SkillsListView()
                .oriveoNavigationChrome()
        case let .skillEdit(skillID):
            SkillEditView(skillID: skillID)
                .oriveoNavigationChrome()
        case .notesList:
            NotesView()
                .oriveoNavigationChrome()
        case let .noteDetail(noteID):
            NoteDetailView(noteID: noteID)
                .oriveoNavigationChrome()
        }
    }
}
