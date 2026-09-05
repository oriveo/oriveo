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
        let state = AppState(seedDemoData: launchConfiguration.shouldSeedDemoData)
        _appState = State(wrappedValue: state)
        _currentColorScheme = State(wrappedValue: state.preferences.theme.preferredColorScheme)
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(appState: appState)
                .environment(appState)
                .environment(\.locale, appState.preferences.language.locale)
                .preferredColorScheme(currentColorScheme)
                .task {
                    #if DEBUG
                    await runDebugLaunchAutomationIfNeeded()
                    #endif
                }
                .onChange(of: appState.preferences.theme) { _, newTheme in
                    currentColorScheme = newTheme.preferredColorScheme
                }
                .onReceive(NotificationCenter.default.publisher(for: .oriveoWillTerminate)) { _ in
                    appState.chatManager.flushStreamingTextToMessage()
                    appState.persistLifecycleCriticalData(checkpoint: true)
                }
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
    }

    private func hasDebugArgument(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(name)
    }
    #endif
}
