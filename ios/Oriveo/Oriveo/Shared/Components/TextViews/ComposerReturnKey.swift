import UIKit

/// How the composer handles Return on a hardware keyboard. The software keyboard's Return goes through `insertText("\n")`, not here, and is unchanged.
enum ComposerReturnKeyAction: Equatable {
    /// Send (the same path as the send button).
    case send
    /// Swallow: when sending is not possible Return does nothing, not even a newline.
    case ignore
    /// Pass to the system: ⇧Return inserts a newline, an input method confirms its candidate, and other keys.
    case system
}

enum ComposerReturnKey {
    /// - Parameters:
    ///   - keyCode: the key pressed.
    ///   - modifiers: the modifier keys held.
    ///   - hasMarkedText: an input method is composing (there is markedText); Return then confirms the candidate and goes to the system.
    ///   - canSend: the same can-send condition as the send button.
    static func action(
        keyCode: UIKeyboardHIDUsage,
        modifiers: UIKeyModifierFlags,
        hasMarkedText: Bool,
        canSend: Bool
    ) -> ComposerReturnKeyAction {
        guard keyCode == .keyboardReturnOrEnter || keyCode == .keypadEnter else { return .system }
        guard !hasMarkedText else { return .system }
        // Caps Lock and the numeric keypad flag are not modifiers; holding any of ⇧ / ⌥ / ⌃ / ⌘ passes it to the system (⇧Return inserts a newline).
        let significant = modifiers.intersection([.shift, .alternate, .control, .command])
        guard significant.isEmpty else { return .system }
        return canSend ? .send : .ignore
    }
}
