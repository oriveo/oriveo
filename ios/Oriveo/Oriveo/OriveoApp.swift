//  Local BYOK client entry point. No account required.

import SwiftUI

struct AppLaunchConfiguration {
    let isRunningTests: Bool

    var shouldSeedDemoData: Bool { isRunningTests }
}

@main
struct OriveoApp: App {
    @UIApplicationDelegateAdaptor(OriveoAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState
    @State private var currentColorScheme: ColorScheme?

    init() {
        let launchConfiguration = AppLaunchConfiguration(isRunningTests: AppRuntime.isRunningTests)
        #if DEBUG
        // The relay-family sample pages need demo connections in `providers`. AppState has only this one entry point
        // that does not persist; without it, any assignment to `providers` would write the session snapshot and Keychain.
        let state = AppState(
            seedDemoData: launchConfiguration.shouldSeedDemoData || RelayFamilyDebugShots.isRequested
                || MemoryShots.isRequested || ContextShots.isRequested
        )
        // Memory and context sample pages: the demo seed is fixed to dark, so switch to following the system
        // before the window is created; otherwise a sheet presented at launch (the raw page) keeps the old dark appearance.
        if MemoryShots.isRequested || ContextShots.isRequested { state.preferences.theme = .system }
        #else
        let state = AppState(seedDemoData: launchConfiguration.shouldSeedDemoData)
        #endif
        _appState = State(wrappedValue: state)
        _currentColorScheme = State(wrappedValue: state.preferences.theme.preferredColorScheme)
    }

    var body: some Scene {
        // The window value is the conversation to open in that window (passed by "Open in New Window" in the conversation menu); nil for the default window the system opens.
        WindowGroup(for: WindowOpenRequest.self) { $conversationID in
            #if DEBUG
            // Debug samples: launched with `-OriveoModelOptionsSample <name>`, the app shows only that sample
            // instead of the main interface.
            if let sample = ModelOptionsSample.requestedName {
                ModelOptionsSampleHost(name: sample)
            } else {
                appRoot(conversationID: $conversationID)
            }
            #else
            appRoot(conversationID: $conversationID)
            #endif
        }
        .commands {
            AppMenuCommands(appState: appState)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appState.chatManager.prepareForSessionBoundary()
                appState.chatManager.flushStreamingTextToMessage()
                appState.persistLifecycleCriticalData(checkpoint: true)
            } else if newPhase == .active {
                appState.chatManager.endSessionBoundary()
            }
        }
    }

    /// Launch tasks are per process: with several windows (iPad, Duo) every window mounts its own
    /// appRoot, and only the first one runs them.
    private static var hasRunLaunchTasks = false

    private func appRoot(conversationID: Binding<WindowOpenRequest?>) -> some View {
        AppRootView(
            appState: appState,
            windowOpenRequest: conversationID
        )
            .environment(appState)
            .environment(\.locale, appState.preferences.language.locale)
            .preferredColorScheme(currentColorScheme)
            .task {
                guard !Self.hasRunLaunchTasks else { return }
                Self.hasRunLaunchTasks = true
                #if DEBUG
                await runDebugLaunchAutomationIfNeeded()
                #endif
            }
            .onChange(of: appState.preferences.theme) { _, newTheme in
                currentColorScheme = newTheme.preferredColorScheme
            }
            // Dark palette: applied to the trait of every window at launch, when a new window appears, and when the preference changes (local / backup restore)
            .onChange(of: [appState.preferences.darkPalette, appState.preferences.darkPaletteCustom], initial: true) { _, _ in
                OriveoDarkPaletteSwitcher.applyStoredPreference(
                    appState.preferences.darkPalette,
                    seed: appState.preferences.darkPaletteCustom
                )
            }
            .onOpenURL { url in
                // An MCP sign-in callback goes only to the authorization that started it (claimed by
                // `state`); one from the wrong place or with an unknown `state` is rejected by the router.
                if McpOAuthCallbackRouter.claims(url) {
                    McpOAuthCallbackRouter.shared.deliver(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .oriveoWillTerminate)) { _ in
                appState.chatManager.flushStreamingTextToMessage()
                appState.persistLifecycleCriticalData(checkpoint: true)
            }
    }

    #if DEBUG
    @MainActor
    private func runDebugLaunchAutomationIfNeeded() async {
        if hasDebugArgument("-AUTO_OPEN_FIRST_CHAT") {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let recents = appState.recentConversations
            let target = recents.first(where: {
                $0.messages.first?.role == .user && $0.messages.count >= 2
            }) ?? recents.first(where: { $0.messages.count >= 1 }) ?? recents.first
            if let id = target?.id {
                appState.openChat(conversationID: id)
            }
        }

        // Direct-open sample pages: page names, demo data and navigation live in RelayFamilyDebugShots / MemoryShots / ContextShots.
        if let page = debugArgumentValue("-AUTO_OPEN_PAGE") {
            if let shot = RelayFamilyDebugShots.Shot(rawValue: page) {
                await RelayFamilyDebugShots.open(shot, appState: appState)
            } else if let shot = MemoryShots.Shot(rawValue: page) {
                await MemoryShots.open(shot, appState: appState)
            } else if let shot = ContextShots.Shot(rawValue: page) {
                await ContextShots.open(shot, appState: appState)
            }
        }
    }

    private func debugArgumentValue(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func hasDebugArgument(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(name)
    }
    #endif
}
