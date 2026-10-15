import Testing
import UIKit
@testable import Oriveo

@Suite("ChatKeyboardCoordinator effectiveViewport")
@MainActor
struct ChatKeyboardCoordinatorTests {
    @Test("Keyboard Hidden Full Height")
    func keyboardHiddenFullHeight() {
        let view = CGRect(x: 0, y: 100, width: 390, height: 700)
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            viewFrame: view, keyboardFrame: .zero, windowMaxY: 844) == 700)
    }

    @Test("Keyboard Overlap Clips To Keyboard Top")
    func keyboardOverlapClipsToKeyboardTop() {
        let view = CGRect(x: 0, y: 100, width: 390, height: 700)        // view [100, 800]
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 336)
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            viewFrame: view, keyboardFrame: keyboard, windowMaxY: 836) == 400)   // 500 − 100
    }

    @Test("Keyboard Below View No Clip")
    func keyboardBelowViewNoClip() {
        let view = CGRect(x: 0, y: 100, width: 390, height: 300)        // view [100, 400]
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 336)
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            viewFrame: view, keyboardFrame: keyboard, windowMaxY: 836) == 300)
    }

    @Test("Floating Keyboard Above The Window Bottom Leaves The Full View Height")
    func floatingKeyboardNoClip() {
        let view = CGRect(x: 0, y: 100, width: 1024, height: 1200)      // view [100, 1300]
        let keyboard = CGRect(x: 300, y: 600, width: 320, height: 260)  // floating mid-screen, bottom 860 < window bottom 1366
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            viewFrame: view, keyboardFrame: keyboard, windowMaxY: 1366) == 1200)
    }

    /// Simulates a 1366×1024 screen with an 800×600 window offset by (100, 200) and a view at y 50,
    /// 500pt tall inside the window. On screen the view spans [250, 750] and a docked keyboard top at
    /// 624 leaves 374 visible. Comparing in window coordinates ([50, 550]) would report no overlap.
    @Test("Offset Window Converts The Keyboard Frame Into View Coordinates Before Clipping")
    func offsetWindowConvertsScreenKeyboard() {
        let screen = UIView(frame: CGRect(x: 0, y: 0, width: 1366, height: 1024))
        let window = UIView(frame: CGRect(x: 100, y: 200, width: 800, height: 600))
        let view = UIView(frame: CGRect(x: 0, y: 50, width: 800, height: 500))
        screen.addSubview(window)
        window.addSubview(view)
        let keyboard = CGRect(x: 0, y: 624, width: 1366, height: 400)   // docked on the screen bottom at 1024
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            for: view, keyboardFrameInScreen: keyboard, screenSpace: screen, window: window) == 374)
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            for: view, keyboardFrameInScreen: .zero, screenSpace: screen, window: window) == 500)
    }

    @Test("Offset Window With A Floating Keyboard Leaves The Full View Height")
    func offsetWindowFloatingKeyboard() {
        let screen = UIView(frame: CGRect(x: 0, y: 0, width: 1366, height: 1024))
        let window = UIView(frame: CGRect(x: 100, y: 200, width: 800, height: 600))
        let view = UIView(frame: CGRect(x: 0, y: 50, width: 800, height: 500))
        screen.addSubview(window)
        window.addSubview(view)
        let keyboard = CGRect(x: 300, y: 400, width: 320, height: 260)  // bottom 660 < window bottom 800
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            for: view, keyboardFrameInScreen: keyboard, screenSpace: screen, window: window) == 500)
    }
}
