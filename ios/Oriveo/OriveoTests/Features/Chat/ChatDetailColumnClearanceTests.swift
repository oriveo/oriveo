import CoreGraphics
import Testing
@testable import Oriveo

/// When the wide-screen detail column leaves room for the iPad floating tab bar (values taken from the simulator layout probe).
@Suite("ChatDetailColumnClearance")
struct ChatDetailColumnClearanceTests {

    @Test("13-inch iPad in portrait: column top y=32, own safe top 0 → leave room")
    func iPadColumnBelowStatusBarNeedsClearance() {
        #expect(ChatDetailColumn.needsTopTabBarClearance(columnMinYInWindow: 32, columnSafeAreaTop: 0))
    }

    @Test("Column reaching the window top with its own safe top → leave room")
    func columnUnderStatusBarNeedsClearance() {
        #expect(ChatDetailColumn.needsTopTabBarClearance(columnMinYInWindow: 0, columnSafeAreaTop: 32))
    }

    @Test("Unfolded Duo held sideways: status bar vertical on the right, column top 0, safe top 0 → no room")
    func duoInnerLandscapeNeedsNoClearance() {
        #expect(!ChatDetailColumn.needsTopTabBarClearance(columnMinYInWindow: 0, columnSafeAreaTop: 0))
    }
}
