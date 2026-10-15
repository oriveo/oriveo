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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var appState: AppState
    @State private var hasStartedBackgroundServices = false
    @State private var reachability = ServiceReachabilityMonitor.shared
    /// Full window width (root container width plus the leading and trailing safe areas).
    /// 0 means not measured yet, which counts as a single column.
    @State private var windowWidth: CGFloat = 0

    private var isOnChatScreen: Bool {
        appState.navigation.isShowingChat
    }

    /// The two-column judgement: both the layout branch and the conversation carrier come from this one result.
    private var usesSplitLayout: Bool {
        NavigationManager.usesSplitLayout(
            horizontalSizeClass: horizontalSizeClass,
            windowWidth: windowWidth
        )
    }

    var body: some View {
        Group {
            if let blockedReason = appState.databaseHealthProbe.health.blockedReason {
                // The local data cannot be opened: going any further would keep nothing, so the
                // screen stops here and explains itself.
                StorageBlockedView(reason: blockedReason) {
                    appState.loadSession()
                }
            } else {
                mainContent
            }
        }
        .animation(.snappy, value: appState.databaseHealthProbe.health)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Writes are failing: history is intact and still readable, but whatever is new may
            // not be kept. That is an ongoing condition, not a one-off notice, so the banner stays
            // (unlike the sync notice below, which leaves after five seconds).
            if StorageWriteHealth.shared.isDegraded {
                StorageDegradedBannerView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

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
        .animation(.snappy, value: StorageWriteHealth.shared.isDegraded)
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
        // The confirmation before a remote MCP tool changes data is presented from the app root: the answer
        // keeps running in the background, so the user has to see it on whatever page they are. This only
        // presents; nobody seeing the sheet is not a refusal. The gate has no timeout and never feeds back
        // "the user declined" because a page changed.
        .mcpConfirmationPresenter(appState: appState)
        // The "sign-in expired" pause is presented from the root for the same reason. It is not shown again
        // while that conversation's chat page is on screen (both buttons are already under the step block).
        .mcpReauthorizationPresenter(appState: appState)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
        } action: { width in
            windowWidth = width
        }
        .onChange(of: usesSplitLayout, initial: true) { _, split in
            // Moves the conversation to the carrier that matches the new layout (folding,
            // unfolding, or the window width crossing 780pt). The render branch reads
            // `navigation.isRegularWidth` too, so which layout is drawn and which carrier holds
            // the conversation are always the same judgement and can never be a frame apart.
            appState.navigation.updateLayoutWidth(isRegular: split)
            // A size class change swaps the Home tab's view tree, and the outer nav may be
            // rebuilt with it. The back swipe recognizer is bound to that nav, so re-confirm
            // here — a no-op when it is still attached.
            SwipeBackCoordinator.shared.refreshIfNeeded()
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

private extension View {
    func oriveoNavigationChrome() -> some View {
        navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
    }
}

// Swipe back: a pan recognizer on the window drives the system interactive pop transition.
// Where a swipe may start follows the system: from iOS 26 the system back gesture starts anywhere
// on screen, so this one does too; earlier systems stay edge-only. With an edge-only gesture, a
// swipe that starts just outside the edge zone is not a back swipe, and lifting the finger while
// it is still over a row counts as a tap that pushes that row's page.
// `SwipeBackStartPolicy` decides when a full-screen start yields to the page's own gestures.
final class SwipeBackCoordinator: NSObject, UIGestureRecognizerDelegate {
    static let shared = SwipeBackCoordinator()
    private weak var navController: UINavigationController?
    private weak var attachedWindow: UIWindow?
    private weak var attachedGesture: UIPanGestureRecognizer?
    var isBackSwipeEnabled = true
    /// Areas where SwiftUI handles a horizontal drag itself (registered by `blocksSwipeBack()`).
    /// Nothing in UIKit backs them, so hit testing cannot find them.
    private let exclusionZones = NSHashTable<UIView>.weakObjects()

    func registerExclusionZone(_ view: UIView) {
        exclusionZones.add(view)
    }

    /// Whether the current binding still holds.
    ///
    /// This used to be a one-shot `isSetup` flag paired with a `weak navController`, and the two
    /// together have an inevitable consequence: once the outer nav is rebuilt the weak reference
    /// goes nil while `isSetup` stays true, so setup never runs again and
    /// `gestureRecognizerShouldBegin` returns false forever — **the back swipe is dead, with no
    /// error anywhere**. The two-column layout adds a trigger for exactly that: the Home tab
    /// swaps its whole view tree between `NavigationSplitView` and a bare `HomeView` as the
    /// width changes. So the binding has to be re-entrant and judged on "is it still attached".
    private var isBound: Bool {
        guard let navController, navController.viewIfLoaded?.window != nil else { return false }
        return attachedGesture != nil && attachedWindow != nil
    }

    func setupIfNeeded() {
        guard !isBound else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.bind()
        }
    }

    /// Re-confirms the binding after the window structure may have changed (a size class swap).
    /// A no-op when it is still attached.
    func refreshIfNeeded() {
        guard !isBound else { return }
        bind()
    }

    private func bind() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }
        bind(to: window)
    }

    private func bind(to window: UIWindow) {
        guard let root = window.rootViewController,
              let nav = Self.findNavController(from: root) else { return }

        // Detach the previous recognizer before rebinding, otherwise every rebind leaves another
        // one on the window and they all recognise the same swipe.
        if let attachedGesture, let attachedWindow {
            attachedWindow.removeGestureRecognizer(attachedGesture)
        }
        attachedGesture = nil
        attachedWindow = nil
        navController = nav

        guard let systemGesture = nav.interactivePopGestureRecognizer,
              let systemTarget = systemGesture.delegate else { return }

        let panGesture = SwipeBackPanGestureRecognizer(
            target: systemTarget,
            action: Selector(("handleNavigationTransition:"))
        )
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        panGesture.shouldTrack = { [weak self] touch, startsAtEdge in
            self?.shouldTrack(touch, startsAtEdge: startsAtEdge) ?? false
        }
        window.addGestureRecognizer(panGesture)
        attachedWindow = window
        attachedGesture = panGesture
    }

    #if DEBUG
    /// Testing hook: run a binding against a given window, bypassing the "first connected scene"
    /// lookup (there is no real scene in a unit test).
    func bindForTesting(window: UIWindow) { bind(to: window) }

    /// Testing hook: the depth-first lookup is a pure function; exposing it is what lets a test
    /// assert that the **outer** nav is the one that wins.
    static func findNavControllerForTesting(from vc: UIViewController?) -> UINavigationController? {
        findNavController(from: vc)
    }
    #endif

    private func shouldTrack(_ touch: UITouch, startsAtEdge: Bool) -> Bool {
        guard let nav = navController, let hitView = touch.view else { return false }
        var supportsContentStart = false
        if #available(iOS 26.0, *) { supportsContentStart = true }
        return SwipeBackStartPolicy.allowsStart(
            hitView: hitView,
            locationInWindow: touch.location(in: nil),
            startsAtEdge: startsAtEdge,
            navigationView: nav.view,
            supportsContentStart: supportsContentStart,
            exclusionZones: exclusionZones.allObjects
        )
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

/// Whether a touch may start a back swipe.
enum SwipeBackStartPolicy {
    static func allowsStart(
        hitView: UIView,
        locationInWindow: CGPoint,
        startsAtEdge: Bool,
        navigationView: UIView,
        supportsContentStart: Bool,
        exclusionZones: [UIView]
    ) -> Bool {
        // The recognizer sits on the window, so touches inside a sheet or popup pass through it
        // too, while it drives the navigation stack underneath: without this guard a swipe
        // inside a sheet pops the page below it.
        guard hitView.isDescendant(of: navigationView) else { return false }
        if startsAtEdge { return true }
        guard supportsContentStart else { return false }

        for zone in exclusionZones where zone.window != nil {
            if zone.bounds.contains(zone.convert(locationInWindow, from: nil)) { return false }
        }

        // Yield when the touch lands on the page's own horizontal interaction: a horizontally
        // scrollable area (pagers included), a slider, or a text input being edited (caret drag).
        var current: UIView? = hitView
        while let view = current, view !== navigationView {
            if view is UISlider { return false }
            if view is UITextInput, view.isFirstResponder { return false }
            if let scrollView = view as? UIScrollView, scrollView.isScrollEnabled {
                let inset = scrollView.adjustedContentInset
                if scrollView.contentSize.width + inset.left + inset.right > scrollView.bounds.width + 1 {
                    return false
                }
            }
            current = view.superview
        }
        return true
    }
}

final class SwipeBackPanGestureRecognizer: UIPanGestureRecognizer {
    var edgeActivationWidth: CGFloat = 24
    var requiredHorizontalTranslation: CGFloat = 12
    // A start away from the edge counts as scrolling once vertical travel reaches this first.
    // Edge starts have no such limit: nothing else competes for them there.
    var contentStartVerticalSlop: CGFloat = 10
    /// Whether this touch may start a back swipe (`SwipeBackStartPolicy`); the second argument
    /// is whether it began inside the left edge zone.
    var shouldTrack: (UITouch, Bool) -> Bool = { _, startsAtEdge in startsAtEdge }
    private var trackingStartLocation: CGPoint?
    private var startedAtEdge = true
    private weak var trackedView: UIView?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view, let touch = touches.first else { return }
        let location = touch.location(in: view)
        let startsAtEdge = location.x <= edgeActivationWidth
        guard shouldTrack(touch, startsAtEdge) else {
            state = .failed
            return
        }
        trackingStartLocation = location
        startedAtEdge = startsAtEdge
        trackedView = touch.view
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
        if !startedAtEdge, abs(dy) > contentStartVerticalSlop {
            state = .failed
            return
        }
        if dx >= requiredHorizontalTranslation {
            super.touchesMoved(touches, with: event)
            if state == .began || state == .changed {
                setTranslation(.zero, in: view)
                cancelScrollingUnderTouch()
            }
        }
    }

    /// Stops scrolling under the finger once the back swipe begins: the two recognizers run
    /// simultaneously, so a diagonal swipe would otherwise scroll the page while popping it.
    private func cancelScrollingUnderTouch() {
        var current = trackedView
        while let view = current {
            if let pan = (view as? UIScrollView)?.panGestureRecognizer, pan.isEnabled {
                pan.isEnabled = false
                pan.isEnabled = true
            }
            current = view.superview
        }
    }

    override func reset() {
        super.reset()
        trackingStartLocation = nil
        startedAtEdge = true
        trackedView = nil
    }
}

/// Marks an area where SwiftUI handles a horizontal drag itself (a `DragGesture` scrub and the
/// like): a touch that starts inside it does not start a back swipe. UIKit scroll views and
/// sliders need no marking; `SwipeBackStartPolicy` finds them by hit testing.
private struct SwipeBackExclusionZone: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        SwipeBackCoordinator.shared.registerExclusionZone(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    func blocksSwipeBack() -> some View {
        background(SwipeBackExclusionZone())
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
                homeTabContent
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
        // The animation is scoped to the tint only: attached to the whole TabView it also animates every
        // layout change inside the tab content during the switch (on iOS 27 the Providers balance label
        // and amount slide from left to right when the balance resets to "--").
        .animation(.easeInOut(duration: 0.2)) { content in
            content.tint(Self.tint(for: appState.selectedTab))
        }
        .modifier(LegacyTabBarBackground())
        .id(appState.preferences.language)
    }

    /// Two columns on a wide screen: the sidebar is the whole HomeView, unchanged, so the home
    /// screen looks the same on a phone, an unfolded Duo and an iPad; the detail column is the
    /// conversation. At compact width there is no split view — the conversation still goes
    /// through the outer NavigationStack, exactly as it did before two columns (covering the
    /// screen including the tab bar, with an edge swipe popping back to the previous route).
    ///
    /// The fixed 400pt sidebar is how "the same layout in all three shapes" is delivered: 400
    /// lines up with the 402pt of a phone in portrait. 360–440 is adjustable; giving the sidebar
    /// less leaves the detail column more.
    @ViewBuilder
    private var homeTabContent: some View {
        if appState.navigation.isRegularWidth {
            NavigationSplitView {
                HomeView()
                    .navigationSplitViewColumnWidth(min: 360, ideal: 400, max: 440)
                    .toolbar(.hidden, for: .navigationBar)
            } detail: {
                ChatDetailColumn()
                    .navigationBarBackButtonHidden(true)
                    .toolbar(.hidden, for: .navigationBar)
            }
        } else {
            HomeView()
        }
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
