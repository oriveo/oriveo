import Testing
import UIKit
@testable import Oriveo

/// Hardware Return in the composer: Return sends (the same condition as the send button), ⇧Return inserts a newline, and an input method composing gets it.
@Suite("ComposerReturnKey")
struct ComposerReturnKeyTests {

    private func action(
        _ key: UIKeyboardHIDUsage = .keyboardReturnOrEnter,
        _ modifiers: UIKeyModifierFlags = [],
        marked: Bool = false,
        canSend: Bool = true
    ) -> ComposerReturnKeyAction {
        ComposerReturnKey.action(keyCode: key, modifiers: modifiers, hasMarkedText: marked, canSend: canSend)
    }

    @Test("Return sends when possible and is swallowed otherwise (no newline)")
    func plainReturn() {
        #expect(action(canSend: true) == .send)
        #expect(action(canSend: false) == .ignore)
        #expect(action(.keypadEnter, canSend: true) == .send)
    }

    @Test("⇧Return goes to the system as a newline whether or not sending is possible")
    func shiftReturnInsertsNewline() {
        #expect(action(.keyboardReturnOrEnter, .shift, canSend: true) == .system)
        #expect(action(.keyboardReturnOrEnter, .shift, canSend: false) == .system)
    }

    @Test("With an input method's markedText, Return confirms the candidate and goes to the system")
    func markedTextGoesToSystem() {
        #expect(action(marked: true, canSend: true) == .system)
        #expect(action(marked: true, canSend: false) == .system)
    }

    @Test("Other modifiers and other keys go to the system; Caps Lock and the numeric keypad flag are not modifiers")
    func otherKeysAndModifiers() {
        #expect(action(.keyboardReturnOrEnter, .command) == .system)
        #expect(action(.keyboardReturnOrEnter, .alternate) == .system)
        #expect(action(.keyboardReturnOrEnter, .control) == .system)
        #expect(action(.keyboardA) == .system)
        #expect(action(.keyboardTab) == .system)
        #expect(action(.keyboardReturnOrEnter, .alphaShift) == .send)
        #expect(action(.keypadEnter, .numericPad) == .send)
    }
}
