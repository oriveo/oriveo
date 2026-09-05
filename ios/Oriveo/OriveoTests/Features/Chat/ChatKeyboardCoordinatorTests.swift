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
            viewFrameInScreen: view, keyboardFrameInScreen: .zero) == 700)
    }

    @Test("Keyboard Overlap Clips To Keyboard Top")
    func keyboardOverlapClipsToKeyboardTop() {
        let view = CGRect(x: 0, y: 100, width: 390, height: 700)        // view [100, 800]
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 336)
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            viewFrameInScreen: view, keyboardFrameInScreen: keyboard) == 400)   // 500 − 100
    }

    @Test("Keyboard Below View No Clip")
    func keyboardBelowViewNoClip() {
        let view = CGRect(x: 0, y: 100, width: 390, height: 300)        // view [100, 400]
        let keyboard = CGRect(x: 0, y: 500, width: 390, height: 336)
        #expect(ChatKeyboardCoordinator.effectiveViewport(
            viewFrameInScreen: view, keyboardFrameInScreen: keyboard) == 300)
    }
}
