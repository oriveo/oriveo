import SwiftUI

enum AppRootBackgroundServicePolicy {
    static func shouldStart(
        hasStartedBackgroundServices: Bool,
        isRunningTests: Bool,
        isRunningPreviews: Bool
    ) -> Bool {
        !hasStartedBackgroundServices && !isRunningTests && !isRunningPreviews
    }
}

struct AppRootView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var appState: AppState
    @State private var hasStartedBackgroundServices = false
    @State private var reachability = ServiceReachabilityMonitor.shared

    private var isOnChatScreen: Bool {
        if case .chat = appState.navigation.path.last { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isOnChatScreen {
                ServiceReachabilityBannerView(state: reachability.bannerState) {
                    reachability.dismissCurrentBanner()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            NavigationStack(path: $appState.navigation.path) {
                Group {
                    if appState.hasCompletedOnboarding {
                        MainTabView()
                            .transition(.opacity)
                    } else {
                        OnboardingFlowView()
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: appState.hasCompletedOnboarding)
                .oriveoScreenBackground()
                .navigationDestination(for: AppRoute.self, destination: destinationView(for:))
            }
            .toolbar(.hidden, for: .navigationBar)
            .environment(appState)
        }
        .animation(.snappy, value: reachability.bannerState)
        .overlay { ToastOverlay() }
        .alert(L10n.tr("Add provider to use this Skill"), isPresented: $appState.showSkillProviderPrompt) {
            Button(L10n.tr("Not now"), role: .cancel) {}
            Button(L10n.tr("Add Provider")) {
                appState.openProviderSetup(from: .providers)
            }
        } message: {
            Text(L10n.tr("This Skill needs an available AI provider before it can start a conversation."))
        }
        .onAppear {
            SwipeBackCoordinator.shared.setupIfNeeded()
        }
        .task {
            guard AppRootBackgroundServicePolicy.shouldStart(
                hasStartedBackgroundServices: hasStartedBackgroundServices,
                isRunningTests: AppRuntime.isRunningTests,
                isRunningPreviews: AppRuntime.isRunningPreviews
            ) else { return }
            hasStartedBackgroundServices = true
            ServiceReachabilityMonitor.shared.start()
            await MetadataClient.shared.initialize()
            await appState.refreshProviderMetadata()
        }
    }

    @ViewBuilder
    private func destinationView(for route: AppRoute) -> some View {
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
        case let .chat(conversationID):
            ChatView(conversationID: conversationID)
                .oriveoNavigationChrome()
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

private extension View {
    func oriveoNavigationChrome() -> some View {
        navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
    }
}

final class SwipeBackCoordinator: NSObject, UIGestureRecognizerDelegate {
    static let shared = SwipeBackCoordinator()
    private var isSetup = false
    private weak var navController: UINavigationController?
    var isBackSwipeEnabled = true

    func setupIfNeeded() {
        guard !isSetup else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setup()
        }
    }

    private func setup() {
        guard !isSetup else { return }
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let root = window.rootViewController,
              let nav = Self.findNavController(from: root) else { return }

        isSetup = true
        self.navController = nav

        guard let systemGesture = nav.interactivePopGestureRecognizer,
              let systemTarget = systemGesture.delegate else { return }

        let panGesture = SwipeBackPanGestureRecognizer(
            target: systemTarget,
            action: Selector(("handleNavigationTransition:"))
        )
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        window.addGestureRecognizer(panGesture)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navController, nav.viewControllers.count > 1 else { return false }
        guard isBackSwipeEnabled else { return false }
        guard nav.transitionCoordinator == nil else { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let translation = pan.translation(in: pan.view)
        return translation.x > 0 && abs(translation.x) > abs(translation.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private static func findNavController(from vc: UIViewController?) -> UINavigationController? {
        guard let vc else { return nil }
        if let nav = vc as? UINavigationController { return nav }
        if let presented = vc.presentedViewController,
           let nav = findNavController(from: presented) { return nav }
        for child in vc.children {
            if let nav = findNavController(from: child) { return nav }
        }
        return nil
    }
}

final class SwipeBackPanGestureRecognizer: UIPanGestureRecognizer {
    var edgeActivationWidth: CGFloat = 24
    var requiredHorizontalTranslation: CGFloat = 12
    private var trackingStartLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view, let touch = touches.first else { return }
        let location = touch.location(in: view)
        if location.x > edgeActivationWidth {
            state = .failed
            return
        }
        trackingStartLocation = location
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else {
            super.touchesMoved(touches, with: event)
            return
        }
        guard let view,
              let touch = touches.first,
              let start = trackingStartLocation else {
            super.touchesMoved(touches, with: event)
            return
        }
        let current = touch.location(in: view)
        let dx = current.x - start.x
        let dy = current.y - start.y
        if dx < -4 || abs(dy) > abs(dx) {
            state = .failed
            return
        }
        if dx >= requiredHorizontalTranslation {
            super.touchesMoved(touches, with: event)
            if state == .began || state == .changed {
                setTranslation(.zero, in: view)
            }
        }
    }

    override func reset() {
        super.reset()
        trackingStartLocation = nil
    }
}

private struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        // The system TabView: from iOS 26 it is the native floating liquid glass tab bar (neutral glass
        // selection lens, lift and drag on press, light/dark adaptation to the content behind it, increased
        // contrast and reduced transparency). Only the system component gets these; a custom drawing
        // through public API cannot reproduce them.
        TabView(selection: $appState.selectedTab) {
            Tab(AppTab.home.title, image: Self.icon(for: .home, selected: appState.selectedTab), value: AppTab.home) {
                HomeView()
            }

            Tab(AppTab.providers.title, image: Self.icon(for: .providers, selected: appState.selectedTab), value: AppTab.providers) {
                ProvidersView()
            }

            Tab(AppTab.settings.title, image: Self.icon(for: .settings, selected: appState.selectedTab), value: AppTab.settings) {
                SettingsView()
            }
        }
        // The selected icon and label take the current tab's colour (Home violet / Providers teal /
        // Settings orange), and controls inside the page follow it too
        .tint(Self.tint(for: appState.selectedTab))
        .modifier(LegacyTabBarBackground())
        .animation(.easeInOut(duration: 0.2), value: appState.selectedTab)
        .id(appState.preferences.language)
    }

    /// The selected tab gets the icon with the gradient baked in; the others use the monochrome template
    private static func icon(for tab: AppTab, selected: AppTab) -> String {
        tab == selected ? tab.tabBarSelectedIconAsset : tab.tabBarIconAsset
    }

    private static func tint(for tab: AppTab) -> Color {
        switch tab {
        case .providers: return OriveoTheme.Palette.tabAccentProviders
        case .settings: return OriveoTheme.Palette.tabAccentSettings
        default: return OriveoTheme.Palette.primary
        }
    }
}

/// On iOS 18–25 the system tab bar keeps its solid fill. From iOS 26 it gets no background at all:
/// a custom fill would defeat the liquid glass adaptation, and Apple asks for custom tab bar
/// backgrounds to be removed.
private struct LegacyTabBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .toolbarBackground(OriveoTheme.Palette.tabBar, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

#Preview {
    AppRootView(appState: .preview)
}
