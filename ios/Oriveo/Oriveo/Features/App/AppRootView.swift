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

/// The scene value for "Open in New Window".
///
/// It carries a one-off `nonce`: `openWindow(value:)` brings an existing window with the same value
/// forward instead of creating one, so with only the conversation id a second "Open in New Window"
/// for the same conversation would just bring back the window opened last time (setting the value
/// to nil does not change the scene's identity either). A fresh value per request opens a new
/// window every time, as Safari does.
struct WindowOpenRequest: Codable, Hashable {
    let conversationID: UUID
    var nonce = UUID()
}

/// A conversation to open in a new window: applied to **this** window's navigation when the
/// new window first appears.
///
/// It does not go through `AppState.openChat`, which acts on the active window — and when the
/// new window appears, the active one is usually still the window that asked for it.
enum WindowOpenRequestPolicy {
    /// Does nothing before onboarding is finished (the request stays as it is). Otherwise switches to the Home tab,
    /// opens the conversation and clears the request, so restoring the window does not open it a second time.
    @MainActor
    static func consume(
        _ request: inout WindowOpenRequest?,
        hasCompletedOnboarding: Bool,
        navigation: NavigationManager
    ) {
        guard hasCompletedOnboarding, let id = request?.conversationID else { return }
        navigation.selectedTab = .home
        if navigation.isRegularWidth {
            navigation.popToRoot()
        }
        navigation.presentChat(conversationID: id)
        request = nil
    }
}

struct AppRootView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    #if DEBUG
    @Environment(\.openWindow) private var openWindow
    #endif
    @Bindable var appState: AppState
    /// This window's scene value: the conversation to open in this window, consumed when the
    /// window first appears (see `WindowOpenRequestPolicy`).
    var windowOpenRequest: Binding<WindowOpenRequest?> = .constant(nil)
    /// This window's identity: used to get and release this window's navigation state and to
    /// tell whether it is the active window.
    @State private var windowToken = UUID()
    /// The UIWindow this view lives in (reported by the window probe). Not observed: it only wires
    /// up UIKit and never drives a redraw.
    @State private var hostWindow = HostWindowBox()
    @State private var reachability = ServiceReachabilityMonitor.shared
    /// Full window width (root container width plus the leading and trailing safe areas).
    /// 0 means not measured yet, which counts as a single column.
    @State private var windowWidth: CGFloat = 0

    /// Background services (reachability, metadata) are per process: with several windows only
    /// the first one starts them.
    private static var hasStartedBackgroundServices = false
    #if DEBUG
    /// The `-AUTO_OPEN_SECOND_WINDOW` testing hook fires only once (from the first window).
    private static var hasAutoOpenedSecondWindow = false

    /// Writes every window's navigation state to `tmp/shots-probe/windows.json` so a simulator run can check that windows stay isolated.
    private static func writeWindowNavigationSnapshot(appState: AppState) {
        let windows: [[String: Any]] = appState.allWindowNavigations.map { manager in
            [
                "isActive": manager === appState.navigation,
                "isPrimary": manager === appState.primaryNavigation,
                "selectedTab": manager.selectedTab.rawValue,
                "isRegularWidth": manager.isRegularWidth,
                "path": manager.path.map { String(describing: $0) },
                "chatDetail": String(describing: manager.chatDetail),
                "providersDetail": String(describing: manager.providersDetail),
                "notesDetail": String(describing: manager.notesDetail),
            ]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shots-probe", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["windows": windows], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("windows.json"))
        } catch {
            print("[AUTO_OPEN_SECOND_WINDOW] failed to write the window snapshot: \(error)")
        }
    }
    #endif

    /// This window's own navigation state. With several windows (iPad, Duo) each window has its
    /// own, so they never interfere. Idempotent: the first read registers this window (and makes
    /// it the active window when there is none).
    private var navigation: NavigationManager {
        appState.windowNavigation(for: windowToken)
    }

    /// App-wide prompts (the Skill-needs-a-provider alert, MCP confirmation and re-authorization)
    /// appear only in the active window, so the same thing is not asked once per window; banners
    /// and toasts stay in every window.
    private var isActiveWindow: Bool {
        appState.isActiveWindow(windowToken)
    }

    private var isOnChatScreen: Bool {
        navigation.isShowingChat
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
        .environment(\.windowNavigation, navigation)
        // Judged at the window root with the window's size class: in the two-column Home the list sits in the split view sidebar, whose size class does not describe the window
        .environment(
            \.canOpenConversationWindow,
            NavigationManager.canOpenConversationWindow(
                supportsMultipleWindows: supportsMultipleWindows,
                horizontalSizeClass: horizontalSizeClass
            )
        )
        .background(
            WindowActivationProbe(
                onActivate: { appState.activateWindowNavigation(windowToken) },
                onWindowChange: { window in
                    hostWindow.window = window
                    guard let window else { return }
                    SwipeBackCoordinator.shared.setupIfNeeded(window: window)
                }
            )
        )
        .onAppear {
            var request = windowOpenRequest.wrappedValue
            WindowOpenRequestPolicy.consume(
                &request,
                hasCompletedOnboarding: appState.hasCompletedOnboarding,
                navigation: navigation
            )
            if request != windowOpenRequest.wrappedValue {
                windowOpenRequest.wrappedValue = request
            }
        }
        #if DEBUG
        .onChange(of: supportsMultipleWindows, initial: true) { _, supported in
            ShotsLayoutProbe.supportsMultipleWindows = supported
        }
        .task {
            // Testing hook: about 1.5s after the first window mounts, open the first conversation in a new window
            guard CommandLine.arguments.contains("-AUTO_OPEN_SECOND_WINDOW"),
                  !Self.hasAutoOpenedSecondWindow else { return }
            Self.hasAutoOpenedSecondWindow = true
            try? await Task.sleep(for: .milliseconds(1500))
            guard let first = appState.recentConversations.first else { return }
            openWindow(value: WindowOpenRequest(conversationID: first.id))
            // A full-screen iPad only shows the front window, so a screenshot cannot prove the first window was left alone; once the new window settles, write every window's navigation state to disk
            try? await Task.sleep(for: .milliseconds(3000))
            Self.writeWindowNavigationSnapshot(appState: appState)
        }
        #endif
        .onDisappear {
            appState.releaseWindowNavigation(windowToken)
        }
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

            NavigationStack(path: Bindable(navigation).path) {
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
                .navigationDestination(for: AppRoute.self) { AppRouteDestination(route: $0) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .environment(appState)
        }
        .animation(.snappy, value: StorageWriteHealth.shared.isDegraded)
        .animation(.snappy, value: reachability.bannerState)
        .overlay { ToastOverlay() }
        .alert(L10n.tr("Add provider to use this Skill"), isPresented: Binding(
            get: { isActiveWindow && appState.showSkillProviderPrompt },
            set: { isPresented in
                guard isActiveWindow else { return }
                appState.showSkillProviderPrompt = isPresented
            }
        )) {
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
        .mcpConfirmationPresenter(appState: appState, isActiveWindow: isActiveWindow)
        // The "sign-in expired" pause is presented from the root for the same reason. It is not shown again
        // while that conversation's chat page is on screen (both buttons are already under the step block).
        .mcpReauthorizationPresenter(appState: appState, isActiveWindow: isActiveWindow)
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
            // Animations off: when folding, the conversation simply appears on top of the stack
            // instead of being pushed.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                navigation.updateLayoutWidth(isRegular: split)
            }
            // A size class change swaps the Home tab's view tree, and the outer nav may be
            // rebuilt with it. The back swipe recognizer is bound to that nav, so re-confirm
            // here — a no-op when it is still attached.
            if let window = hostWindow.window {
                SwipeBackCoordinator.shared.refreshIfNeeded(window: window)
            }
        }
        .onAppear {
            if let window = hostWindow.window {
                SwipeBackCoordinator.shared.setupIfNeeded(window: window)
            }
        }
        .task {
            guard AppRootBackgroundServicePolicy.shouldStart(
                hasStartedBackgroundServices: Self.hasStartedBackgroundServices,
                isRunningTests: AppRuntime.isRunningTests,
                isRunningPreviews: AppRuntime.isRunningPreviews
            ) else { return }
            Self.hasStartedBackgroundServices = true
            ServiceReachabilityMonitor.shared.start()
            await MetadataClient.shared.initialize()
            await appState.refreshProviderMetadata()
        }
    }
}

/// Holds the host window weakly: a `@State` value must not retain the UIWindow (window → root
/// controller → view state → window would form a cycle).
private final class HostWindowBox {
    weak var window: UIWindow?
}

extension View {
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

    /// The binding on one window: that window's outer nav and the recognizer attached to the window.
    private final class WindowBinding {
        weak var navController: UINavigationController?
        weak var gesture: UIPanGestureRecognizer?
    }

    /// With several windows (iPad, Duo) each window has its own outer nav, so each gets its own
    /// binding; an entry goes away once its window is released.
    private let bindings = NSMapTable<UIWindow, WindowBinding>.weakToStrongObjects()
    /// One switch for all windows: pages flip it in onAppear / onDisappear. Known limitation —
    /// when two windows both show a page that turns the back swipe off, leaving that page in
    /// either window turns it back on for the other window too.
    var isBackSwipeEnabled = true
    /// Areas where SwiftUI handles a horizontal drag itself (registered by `blocksSwipeBack()`).
    /// Nothing in UIKit backs them, so hit testing cannot find them.
    private let exclusionZones = NSHashTable<UIView>.weakObjects()

    func registerExclusionZone(_ view: UIView) {
        exclusionZones.add(view)
    }

    /// Whether the binding on a window still holds.
    ///
    /// This used to be a one-shot `isSetup` flag paired with a `weak navController`, and the two
    /// together have an inevitable consequence: once the outer nav is rebuilt the weak reference
    /// goes nil while `isSetup` stays true, so setup never runs again and
    /// `gestureRecognizerShouldBegin` returns false forever — **the back swipe is dead, with no
    /// error anywhere**. The two-column layout adds a trigger for exactly that: the Home tab
    /// swaps its whole view tree between `NavigationSplitView` and a bare `HomeView` as the
    /// width changes. So the binding has to be re-entrant and judged on "is it still attached".
    private func isBound(_ window: UIWindow) -> Bool {
        guard let binding = bindings.object(forKey: window),
              let navController = binding.navController,
              navController.viewIfLoaded?.window != nil else { return false }
        return binding.gesture != nil
    }

    /// First wiring: waits for the root view's nav to exist before binding. `window` is the
    /// caller's window.
    func setupIfNeeded(window: UIWindow) {
        guard !isBound(window) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
            guard let self, let window else { return }
            self.bind(to: window)
        }
    }

    /// Re-confirms the binding after the window structure may have changed (a size class swap).
    /// A no-op when it is still attached.
    func refreshIfNeeded(window: UIWindow) {
        guard !isBound(window) else { return }
        bind(to: window)
    }

    private func bind(to window: UIWindow) {
        guard let root = window.rootViewController,
              let nav = Self.findNavController(from: root) else { return }

        // Detach this window's previous recognizer before rebinding, otherwise every rebind leaves
        // another one on the window and they all recognise the same swipe. Other windows' recognizers
        // are left alone.
        let binding = bindings.object(forKey: window) ?? WindowBinding()
        if let previous = binding.gesture {
            window.removeGestureRecognizer(previous)
        }
        binding.gesture = nil
        binding.navController = nav
        bindings.setObject(binding, forKey: window)

        guard let systemGesture = nav.interactivePopGestureRecognizer,
              let systemTarget = systemGesture.delegate else { return }

        let panGesture = SwipeBackPanGestureRecognizer(
            target: systemTarget,
            action: Selector(("handleNavigationTransition:"))
        )
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        panGesture.shouldTrack = { [weak self, weak binding] touch, startsAtEdge in
            guard let self, let nav = binding?.navController else { return false }
            return self.shouldTrack(touch, startsAtEdge: startsAtEdge, nav: nav)
        }
        window.addGestureRecognizer(panGesture)
        binding.gesture = panGesture
    }

    /// The outer nav of the window the recognizer is attached to.
    private func navController(for gestureRecognizer: UIGestureRecognizer) -> UINavigationController? {
        guard let window = gestureRecognizer.view as? UIWindow else { return nil }
        return bindings.object(forKey: window)?.navController
    }

    #if DEBUG
    /// Testing hook: run a binding against a given window, bypassing the setup delay.
    func bindForTesting(window: UIWindow) { bind(to: window) }

    /// Testing hook: the back swipe recognizer currently attached to a window.
    func attachedGestureForTesting(window: UIWindow) -> UIGestureRecognizer? {
        bindings.object(forKey: window)?.gesture
    }

    /// Testing hook: the depth-first lookup is a pure function; exposing it is what lets a test
    /// assert that the **outer** nav is the one that wins.
    static func findNavControllerForTesting(from vc: UIViewController?) -> UINavigationController? {
        findNavController(from: vc)
    }
    #endif

    private func shouldTrack(_ touch: UITouch, startsAtEdge: Bool, nav: UINavigationController) -> Bool {
        guard let hitView = touch.view else { return false }
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
        guard let nav = navController(for: gestureRecognizer), nav.viewControllers.count > 1 else { return false }
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
    @Environment(\.windowNavigation) private var windowNavigation

    /// This window's navigation state; a host without one injected (previews, tests) falls back
    /// to the active window.
    private var navigation: NavigationManager { windowNavigation ?? appState.navigation }

    var body: some View {
        @Bindable var navigation = navigation
        // The system TabView: from iOS 26 it is the native floating liquid glass tab bar (neutral glass
        // selection lens, lift and drag on press, light/dark adaptation to the content behind it, increased
        // contrast and reduced transparency). Only the system component gets these; a custom drawing
        // through public API cannot reproduce them.
        TabView(selection: $navigation.selectedTab) {
            Tab(AppTab.home.title, image: Self.icon(for: .home, selected: navigation.selectedTab), value: AppTab.home) {
                homeTabContent
            }

            Tab(AppTab.providers.title, image: Self.icon(for: .providers, selected: navigation.selectedTab), value: AppTab.providers) {
                providersTabContent
            }

            Tab(AppTab.settings.title, image: Self.icon(for: .settings, selected: navigation.selectedTab), value: AppTab.settings) {
                SettingsView()
            }
        }
        // The selected icon and label take the current tab's colour (Home violet / Providers teal /
        // Settings orange), and controls inside the page follow it too
        // The animation is scoped to the tint only: attached to the whole TabView it also animates every
        // layout change inside the tab content during the switch (on iOS 27 the Providers balance label
        // and amount slide from left to right when the balance resets to "--").
        .animation(.easeInOut(duration: 0.2)) { content in
            content.tint(Self.tint(for: navigation.selectedTab))
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
    @ViewBuilder
    private var homeTabContent: some View {
        if navigation.isRegularWidth {
            TabSplitLayout {
                HomeView()
            } detail: {
                ChatDetailColumn()
                    // The empty state has no toolbar items, so it gets no system bar even when bars
                    // are vertical, which would otherwise leave an empty vertical strip
                    .chatNavigationChrome(showsSystemBar: navigation.chatDetail != .empty)
            }
        } else {
            HomeView()
        }
    }

    /// Two columns on a wide screen: the sidebar is the provider list, the detail column the provider
    /// opened from it (`providersDetail`). At compact width it stays one column and the detail is
    /// pushed full screen on the outer NavigationStack.
    @ViewBuilder
    private var providersTabContent: some View {
        if navigation.isRegularWidth {
            TabSplitLayout {
                ProvidersView()
                    .splitColumnTopTabBarClearance()
            } detail: {
                SplitDetailColumn {
                    providersDetailContent
                }
            }
        } else {
            ProvidersView()
        }
    }

    /// The Providers right column: the selected detail route if there is one; otherwise the first
    /// provider (rendered only, not written back to `providersDetail`, so the default is never moved
    /// onto the single-column stack as if the user had picked it); an empty backdrop when there are no
    /// providers. `.id` rebuilds the page when the provider changes instead of reusing the previous
    /// provider's private page state.
    @ViewBuilder
    private var providersDetailContent: some View {
        if let route = navigation.providersDetail {
            AppRouteDestination(route: route)
                .id(route)
        } else if let provider = appState.providers.first {
            ProviderDetailView(providerID: provider.id)
                .id(provider.id)
        } else {
            OriveoTheme.Palette.backgroundBase
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

/// The two-column shell of a wide tab: the sidebar is the tab's root list, the detail column the page
/// opened from it; every tab shares the same column widths and fold alignment.
///
/// The fixed 400pt sidebar is how "the same layout in all three shapes" is delivered: 400 lines up
/// with the 402pt of a phone in portrait. 360–440 is adjustable; giving the sidebar less leaves the
/// detail column more. Half-folded, the sidebar lines up with the fold (see
/// `NavigationManager.foldAlignedSidebarWidth`). The sidebar hides the system navigation bar; the
/// detail column's chrome is up to the caller.
fileprivate struct TabSplitLayout<Sidebar: View, Detail: View>: View {
    private let sidebar: Sidebar
    private let detail: Detail
    @State private var foldSidebarWidth: CGFloat?

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 360, ideal: foldSidebarWidth ?? 400, max: foldSidebarWidth ?? 440)
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            detail
        }
        .onGeometryChange(for: CGFloat?.self) { proxy in
            // The 27.0 SDK has no fold region API (the project sets this condition by SDK name, see project.pbxproj)
            #if ORIVEO_SDK_BEFORE_27_1
            return nil
            #else
            guard #available(iOS 27.1, *) else { return nil }
            let fold = proxy.reservedRegions(kind: .division).first(where: \.isActive)
            // Full width including the leading and trailing safe areas (the Duo's 84pt vertical status bar on the right), measured the same way as the two-column test
            let fullWidth = proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            return NavigationManager.foldAlignedSidebarWidth(divisionMidX: fold?.frame.midX, containerWidth: fullWidth)
            #endif
        } action: { foldSidebarWidth = $0 }
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
