import Testing
import UIKit
@testable import Oriveo

@Suite("Phase 3b • ChatScrollGestureObserver distance")
@MainActor
struct ChatScrollGestureObserverTests {
    private func scrollView(contentHeight: CGFloat, offsetY: CGFloat) -> UIScrollView {
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        sv.contentSize = CGSize(width: 390, height: contentHeight)
        sv.contentOffset = CGPoint(x: 0, y: offsetY)
        return sv
    }

    @Test("At Bottom Zero")
    func atBottomZero() {
        #expect(ChatScrollGestureObserver.distance(scrollView(contentHeight: 2000, offsetY: 1200)) == 0)
    }

    @Test("Scrolled Up Positive")
    func scrolledUpPositive() {
        #expect(ChatScrollGestureObserver.distance(scrollView(contentHeight: 2000, offsetY: 700)) == 500)
    }

    @Test("Short Content Zero")
    func shortContentZero() {
        #expect(ChatScrollGestureObserver.distance(scrollView(contentHeight: 400, offsetY: 0)) == 0)
    }

    @Test("Near Top Requests Extend")
    func nearTopRequestsExtend() {
        var extendCount = 0
        let observer = ChatScrollGestureObserver(
            onSettle: {},
            hasMoreAbove: { true },
            onRequestExtendUpward: { extendCount += 1 })
        let sv = scrollView(contentHeight: 2000, offsetY: 10)

        observer.scrollViewDidScroll(sv)
        observer.scrollViewDidScroll(sv)
        #expect(extendCount == 1)

        sv.contentOffset = CGPoint(x: 0, y: 500)
        observer.scrollViewDidScroll(sv)
        sv.contentOffset = CGPoint(x: 0, y: 10)
        observer.scrollViewDidScroll(sv)
        #expect(extendCount == 2)
    }

    @Test("Drag Begin Invokes User Grabbed")
    func dragBeginInvokesUserGrabbed() {
        var grabbedCount = 0
        let observer = ChatScrollGestureObserver(
            onUserGrabbed: { grabbedCount += 1 },
            onSettle: {})
        let sv = scrollView(contentHeight: 2000, offsetY: 100)
        observer.scrollViewWillBeginDragging(sv)
        #expect(grabbedCount == 1)
    }
}
