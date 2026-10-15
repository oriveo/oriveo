import Testing
import UIKit
@testable import Oriveo

/// Multiple windows: whichever window the user touches (or that becomes key) becomes the active window,
/// and `appState.openXxx()` / deep links act on it. A unit test cannot synthesize real touch sequences, so this drives the recognizer the probe attaches directly.
@Suite("WindowActivationProbe", .serialized)
@MainActor
struct WindowActivationProbeTests {

    private func makeState() -> AppState {
        AppState(seedDemoData: true, sessionUID: "window-probe-tests-\(UUID().uuidString)")
    }

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }

    private func probeGesture(on window: UIWindow) -> WindowActivationGestureRecognizer? {
        window.gestureRecognizers?.compactMap { $0 as? WindowActivationGestureRecognizer }.first
    }

    @Test("Once in a window the probe attaches an observe-only recognizer that activates the window on touch-down and fails")
    func touchActivatesWindow() throws {
        let state = makeState()
        let first = UUID(), second = UUID()
        _ = state.windowNavigation(for: first)
        _ = state.windowNavigation(for: second)
        #expect(state.isActiveWindow(first))

        let window = makeWindow()
        defer { window.isHidden = true }
        let probe = WindowActivationProbe.ProbeView()
        probe.onActivate = { state.activateWindowNavigation(second) }
        window.addSubview(probe)

        let gesture = try #require(probeGesture(on: window), "The probe should attach a recognizer to the window once it is in it")
        #expect(!gesture.cancelsTouchesInView, "Observe only: it must not swallow the page's own taps")
        #expect(!gesture.delaysTouchesBegan)

        gesture.touchesBegan([], with: UIEvent())

        #expect(state.isActiveWindow(second))
        #expect(state.navigation === state.windowNavigation(for: second))
        #expect(gesture.state == .failed, "It fails right after the callback and takes no part in recognition")
    }

    @Test("Becoming the key window activates it too")
    func becomingKeyActivatesWindow() {
        let state = makeState()
        let first = UUID(), second = UUID()
        _ = state.windowNavigation(for: first)
        _ = state.windowNavigation(for: second)

        let window = makeWindow()
        defer { window.isHidden = true }
        let probe = WindowActivationProbe.ProbeView()
        probe.onActivate = { state.activateWindowNavigation(second) }
        window.addSubview(probe)

        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: window)

        #expect(state.isActiveWindow(second))
    }

    @Test("Leaving the window removes the recognizer, and another window becoming key does not activate it")
    func leavingWindowDetaches() {
        let state = makeState()
        let first = UUID(), second = UUID()
        _ = state.windowNavigation(for: first)
        _ = state.windowNavigation(for: second)

        let window = makeWindow()
        let other = makeWindow()
        defer {
            window.isHidden = true
            other.isHidden = true
        }
        let probe = WindowActivationProbe.ProbeView()
        probe.onActivate = { state.activateWindowNavigation(second) }
        window.addSubview(probe)
        probe.removeFromSuperview()

        #expect(probeGesture(on: window) == nil, "No recognizer should remain after leaving the window")
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: other)
        #expect(state.isActiveWindow(first))
    }
}
