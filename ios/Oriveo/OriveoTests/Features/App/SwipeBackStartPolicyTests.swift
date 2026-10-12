import Testing
import UIKit
@testable import Oriveo

/// Where a back swipe may start.
///
/// From iOS 26 the system back gesture starts anywhere on screen, and the app's own navigation
/// follows. With an edge-only gesture, a swipe starting just outside the edge zone is not a back
/// swipe, and lifting the finger over a row counts as a tap that pushes that row's page. Opening
/// it up leaves the other half to guard: a touch that lands on the page's own horizontal
/// interaction has to yield, otherwise swiping a carousel drags the whole page away.
///
/// Recognition itself needs a real touch sequence; this locks the half that can be verified
/// deterministically — **which start points are allowed**.
@Suite("SwipeBackStartPolicy")
@MainActor
struct SwipeBackStartPolicyTests {

    private let navigationView = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))

    private func page() -> UIView {
        let page = UIView(frame: navigationView.bounds)
        navigationView.addSubview(page)
        return page
    }

    private func allows(
        _ hitView: UIView,
        at location: CGPoint = CGPoint(x: 200, y: 400),
        startsAtEdge: Bool = false,
        supportsContentStart: Bool = true,
        exclusionZones: [UIView] = []
    ) -> Bool {
        SwipeBackStartPolicy.allowsStart(
            hitView: hitView,
            locationInWindow: location,
            startsAtEdge: startsAtEdge,
            navigationView: navigationView,
            supportsContentStart: supportsContentStart,
            exclusionZones: exclusionZones
        )
    }

    @Test("Plain page content allows a start in the middle of the screen")
    func plainContentAllowsContentStart() {
        let row = UIView(frame: CGRect(x: 24, y: 380, width: 352, height: 60))
        page().addSubview(row)

        #expect(allows(row))
    }

    @Test("Where the system gesture is edge-only, a mid-screen start is rejected and the edge still works")
    func edgeOnlySystemsKeepEdgeOnly() {
        let row = page()

        #expect(!allows(row, supportsContentStart: false))
        #expect(allows(row, startsAtEdge: true, supportsContentStart: false))
    }

    @Test("Touches outside the navigation stack (sheets, popups) are rejected, edge starts included")
    func touchesOutsideNavigationStackAreRejected() {
        let sheet = UIView(frame: CGRect(x: 0, y: 300, width: 400, height: 500))

        #expect(!allows(sheet))
        #expect(!allows(sheet, startsAtEdge: true), "otherwise a swipe inside a sheet pops the page underneath it")
    }

    @Test("A start inside a horizontally scrollable area yields; a vertical-only list does not block")
    func horizontalScrollViewsBlockContentStart() {
        let page = page()
        let list = UIScrollView(frame: page.bounds)
        list.contentSize = CGSize(width: 400, height: 3000)
        page.addSubview(list)
        let carousel = UIScrollView(frame: CGRect(x: 0, y: 100, width: 400, height: 120))
        carousel.contentSize = CGSize(width: 1200, height: 120)
        list.addSubview(carousel)
        let card = UIView(frame: CGRect(x: 40, y: 0, width: 200, height: 120))
        carousel.addSubview(card)
        let row = UIView(frame: CGRect(x: 0, y: 300, width: 400, height: 60))
        list.addSubview(row)

        #expect(!allows(card))
        #expect(allows(row))
        #expect(allows(card, startsAtEdge: true), "edge starts match the system and ignore horizontal scrolling inside the page")
    }

    @Test("A scroll view whose content fits its width does not block")
    func nonOverflowingHorizontalScrollViewDoesNotBlock() {
        let chips = UIScrollView(frame: CGRect(x: 0, y: 100, width: 400, height: 44))
        chips.contentSize = CGSize(width: 320, height: 44)
        page().addSubview(chips)

        #expect(allows(chips))
    }

    @Test("A start on a slider yields")
    func slidersBlockContentStart() {
        let slider = UISlider(frame: CGRect(x: 40, y: 380, width: 320, height: 40))
        page().addSubview(slider)

        #expect(!allows(slider))
    }

    @Test("A registered SwiftUI drag area yields; outside it nothing changes")
    func registeredExclusionZonesBlockContentStart() {
        let window = UIWindow(frame: navigationView.bounds)
        window.addSubview(navigationView)
        window.isHidden = false
        defer { window.isHidden = true }
        let page = page()
        let chart = UIView(frame: CGRect(x: 24, y: 200, width: 352, height: 110))
        page.addSubview(chart)

        #expect(!allows(page, at: CGPoint(x: 200, y: 250), exclusionZones: [chart]))
        #expect(allows(page, at: CGPoint(x: 200, y: 500), exclusionZones: [chart]))
    }

    @Test("A drag area that left the screen no longer blocks")
    func detachedExclusionZonesAreIgnored() {
        let detached = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))

        #expect(allows(page(), exclusionZones: [detached]))
    }
}
