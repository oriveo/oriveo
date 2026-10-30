import Testing
import UIKit
@testable import Oriveo

/// The left-edge back swipe is bound to whichever UINavigationController was found at launch.
/// The original implementation paired a one-shot `isSetup` flag with a `weak navController`:
/// once the nav was rebuilt the weak reference went nil while setup never ran again — the swipe
/// died permanently, with no error anywhere. The two-column layout adds a trigger for that (the
/// Home tab swaps between NavigationSplitView and a bare HomeView), so the binding must be
/// re-entrant.
///
/// The gesture itself needs a real touch sequence and is out of reach for a unit test; what is
/// locked here is the half that can be verified deterministically — **the binding predicate and
/// that rebinding does not stack recognizers**.
@Suite("SwipeBackCoordinatorRebind")
@MainActor
struct SwipeBackCoordinatorRebindTests {

    /// Builds a real window + nav tree mirroring the app's root structure.
    private func makeWindow(depth: Int) -> (UIWindow, UINavigationController) {
        let nav = UINavigationController(rootViewController: UIViewController())
        for _ in 1..<max(depth, 1) { nav.pushViewController(UIViewController(), animated: false) }
        let host = UIViewController()
        host.addChild(nav)
        host.view.addSubview(nav.view)
        nav.didMove(toParent: host)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.isHidden = false
        return (window, nav)
    }

    @Test("Depth-first finds the outer nav — a split view's column nav sits deeper")
    func findsOuterNavigationController() {
        let (window, outer) = makeWindow(depth: 2)
        defer { window.isHidden = true }

        let found = SwipeBackCoordinator.findNavControllerForTesting(from: window.rootViewController)

        #expect(found === outer, "must land on the outer nav, or the swipe drives the wrong stack")
    }

    @Test("With a split view nested inside, depth-first still reaches the outer nav first")
    func innerNavDoesNotWinOverOuter() throws {
        let (window, outer) = makeWindow(depth: 2)
        defer { window.isHidden = true }

        // Hang a subtree with its own nav off the outer nav's top view controller, mirroring
        // the NavigationSplitView inside the Home tab.
        let inner = UINavigationController(rootViewController: UIViewController())
        let top = try #require(outer.viewControllers.last)
        top.addChild(inner)
        top.view.addSubview(inner.view)
        inner.didMove(toParent: top)

        let found = SwipeBackCoordinator.findNavControllerForTesting(from: window.rootViewController)

        #expect(found === outer)
        #expect(found !== inner)
    }

    @Test("Rebinding does not stack recognizers")
    func rebindDoesNotStackGestures() {
        let (window, _) = makeWindow(depth: 2)
        defer { window.isHidden = true }
        let before = window.gestureRecognizers?.count ?? 0

        let coordinator = SwipeBackCoordinator()
        coordinator.bindForTesting(window: window)
        let afterFirst = window.gestureRecognizers?.count ?? 0
        coordinator.bindForTesting(window: window)
        coordinator.bindForTesting(window: window)
        let afterThird = window.gestureRecognizers?.count ?? 0

        #expect(afterFirst == before + 1, "the first bind should attach one recognizer")
        #expect(afterThird == afterFirst, "a rebind must detach the old one, or several recognizers read the same swipe")
    }

    @Test("Multiple windows: each window gets its own recognizer, and rebinding one leaves the other alone")
    func eachWindowKeepsItsOwnGesture() {
        let (windowA, _) = makeWindow(depth: 2)
        let (windowB, _) = makeWindow(depth: 2)
        defer {
            windowA.isHidden = true
            windowB.isHidden = true
        }

        let coordinator = SwipeBackCoordinator()
        coordinator.bindForTesting(window: windowA)
        coordinator.bindForTesting(window: windowB)
        let gestureA = coordinator.attachedGestureForTesting(window: windowA)
        let gestureB = coordinator.attachedGestureForTesting(window: windowB)

        #expect(gestureA != nil)
        #expect(gestureB != nil)
        #expect(gestureA !== gestureB)
        #expect(gestureA?.view === windowA, "Binding the second window must not detach the first window's recognizer")
        #expect(gestureB?.view === windowB)

        // Rebind B: B gets a new recognizer and A keeps its own
        coordinator.bindForTesting(window: windowB)
        #expect(coordinator.attachedGestureForTesting(window: windowA) === gestureA)
        #expect(gestureA?.view === windowA)
        #expect(gestureB?.view == nil, "B's old recognizer should have been detached")
        #expect(coordinator.attachedGestureForTesting(window: windowB)?.view === windowB)
    }

    /// The back button sits against the left edge, so one tap with a slight rightward drift starts the swipe
    /// and also fires the button's `pop()` on release; SwiftUI then calls `setViewControllers` to preempt the
    /// swipe's interactive transition and UIKit throws `Failed to preempt running transition`. The transition
    /// must count as running from start until its completion animation ends, and pops are dropped meanwhile.
    @Test("A swipe-started pop transition counts as running and drops pops until it finishes, then clears itself")
    func swipeTransitionBlocksProgrammaticPopUntilFinished() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(UIViewController(), animated: false)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(100))

        let coordinator = SwipeBackCoordinator()
        coordinator.bindForTesting(window: window)
        let navigation = NavigationManager()
        navigation.isSwipeBackTransitionRunning = { coordinator.isSwipeBackTransitionRunning }
        navigation.path = [.memory]
        #expect(!coordinator.isSwipeBackTransitionRunning)

        // What the system target starts in .began is an animated pop
        nav.popViewController(animated: true)
        try #require(nav.transitionCoordinator != nil, "An animated pop should have a transition coordinator")
        coordinator.beginSwipeTransitionForTesting(window: window)
        #expect(coordinator.isSwipeBackTransitionRunning)

        navigation.pop()
        navigation.popToRoot()
        #expect(navigation.path == [.memory], "While the swipe transition runs, the back button / popToRoot must not change path")

        let deadline = Date().addingTimeInterval(3)
        while coordinator.isSwipeBackTransitionRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!coordinator.isSwipeBackTransitionRunning, "Must clear once the transition ends, otherwise the back button is dead forever")
        navigation.pop()
        #expect(navigation.path.isEmpty)
    }
}
