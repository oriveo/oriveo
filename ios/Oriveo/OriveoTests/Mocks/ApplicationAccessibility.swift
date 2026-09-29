import Darwin
import Foundation

/// Turns on application accessibility for the test host process.
///
/// SwiftUI only builds the accessibility elements that tests query (labels, traits, frames) while application
/// accessibility is on. A fresh simulator starts with it off; one that has run Accessibility Inspector or VoiceOver
/// has it on, so the same tests would pass on one machine and fail on another. Enabling it here makes suites that
/// read the accessibility tree independent of the simulator's history.
enum ApplicationAccessibility {
    private typealias IsEnabled = @convention(c) () -> Bool
    private typealias SetEnabled = @convention(c) (Bool) -> Void

    private static let enabled: Bool = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return false }
        guard
            let isSymbol = dlsym(handle, "_AXSApplicationAccessibilityEnabled"),
            let setSymbol = dlsym(handle, "_AXSApplicationAccessibilitySetEnabled")
        else { return false }
        let isEnabled = unsafeBitCast(isSymbol, to: IsEnabled.self)
        if !isEnabled() {
            unsafeBitCast(setSymbol, to: SetEnabled.self)(true)
        }
        return isEnabled()
    }()

    /// Returns whether application accessibility is on after the attempt.
    @discardableResult
    static func enable() -> Bool { enabled }
}
