import SwiftUI

/// The iPadOS menu bar: availability comes from the active window's `AppCommandState`, and commands run in the active window through `AppState.perform`.
/// ⌃⌘S uses the system sidebar command (available only while the two-column NavigationSplitView is present); ⌘W uses the system Close Window (`performClose:`).
struct AppMenuCommands: Commands {
    let appState: AppState

    var body: some Commands {
        let state = appState.commandState

        CommandGroup(replacing: .newItem) {
            commandButton(L10n.tr("New Chat"), .newChat, state: state)
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            commandButton(L10n.tr("Settings"), .showTab(.settings), state: state)
                .keyboardShortcut(",", modifiers: .command)
        }

        SidebarCommands()

        CommandGroup(before: .sidebar) {
            commandButton(AppTab.home.title, .showTab(.home), state: state)
                .keyboardShortcut("1", modifiers: .command)
            commandButton(AppTab.providers.title, .showTab(.providers), state: state)
                .keyboardShortcut("2", modifiers: .command)
            commandButton(AppTab.settings.title, .showTab(.settings), state: state)
                .keyboardShortcut("3", modifiers: .command)
        }

        CommandMenu(L10n.tr("Chat")) {
            commandButton(L10n.tr("Search Conversations"), .searchConversations, state: state)
                .keyboardShortcut("f", modifiers: .command)
            commandButton(L10n.tr("Choose Model"), .chooseModel, state: state)
                .keyboardShortcut("k", modifiers: .command)
            commandButton(L10n.tr("Stop Generating"), .stopGenerating, state: state)
                .keyboardShortcut(".", modifiers: .command)
            commandButton(L10n.tr("Copy Last Response"), .copyLastResponse, state: state)
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }

    private func commandButton(_ title: String, _ command: AppCommand, state: AppCommandState) -> some View {
        Button(title) {
            appState.perform(command)
        }
        .disabled(!state.isEnabled(command))
    }
}
