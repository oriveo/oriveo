import Testing
import UIKit
@testable import Oriveo

@Suite("UIKitProviderBadge has no backing plate")
@MainActor
struct UIKitProviderBadgeTests {
    private func backgroundAlpha(_ badge: UIKitProviderBadge) -> CGFloat {
        var alpha: CGFloat = 0
        badge.backgroundColor?.getWhite(nil, alpha: &alpha)
        return alpha
    }

    @Test("Relay custom / unset-type logo has a transparent background")
    func relayFallbackLogoHasNoBackground() {
        let custom = UIKitProviderBadge(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        custom.configure(kind: .relay, relayKind: .custom)
        #expect(backgroundAlpha(custom) == 0)

        let unset = UIKitProviderBadge(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        unset.configure(kind: .relay, relayKind: nil)
        #expect(backgroundAlpha(unset) == 0)
    }

    @Test("Still transparent after switching between light and dark")
    func appearanceChangeKeepsClearBackground() {
        let badge = UIKitProviderBadge(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        badge.configure(kind: .relay, relayKind: nil)
        badge.overrideUserInterfaceStyle = .dark
        badge.traitCollectionDidChange(UITraitCollection(userInterfaceStyle: .light))
        #expect(backgroundAlpha(badge) == 0)
    }
}
