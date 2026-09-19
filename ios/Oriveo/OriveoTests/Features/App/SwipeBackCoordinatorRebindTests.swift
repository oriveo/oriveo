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
}
