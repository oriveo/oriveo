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

    @Test("Unfolded Duo held sideways with the vertical navigation bar shown: the zero-height strip gives a safe top of 24 → still no room")
    func duoVerticalBarSafeTopNeedsNoClearance() {
        #expect(!ChatDetailColumn.needsTopTabBarClearance(columnMinYInWindow: 0, columnSafeAreaTop: 24, usesVerticalBar: true))
    }

    @Test("Unfolded Duo held sideways: the window adds 16pt of safe area for the top-left corner, column top y and safe top both report 16 → no room (not a top tab bar)")
    func duoCornerClearanceNeedsNoTabBarClearance() {
        #expect(!ChatDetailColumn.needsTopTabBarClearance(columnMinYInWindow: 16, columnSafeAreaTop: 16, cornerClearance: 16))
        #expect(!ChatDetailColumn.needsTopTabBarClearance(columnMinYInWindow: 0, columnSafeAreaTop: 16, cornerClearance: 16))
    }

    @Test("A top status bar beyond the corner clearance → still leave room")
    func statusBarBeyondCornerClearanceNeedsClearance() {
        #expect(ChatDetailColumn.needsTopTabBarClearance(columnMinYInWindow: 32, columnSafeAreaTop: 16, cornerClearance: 16))
    }

    @Test("Corner clearance = corner-adapted top safe line − original top safe line, never negative")
    func windowCornerTopClearance() {
        // Unfolded Duo held sideways: safe top 0, UIKit safeArea(cornerAdaptation: .vertical) top 16 (measured with the probe)
        #expect(WindowCornerClearance.topClearance(safeTop: 0, cornerAdaptedTop: 16) == 16)
        // iPhone in portrait / iPad: the status bar already clears the corners
        #expect(WindowCornerClearance.topClearance(safeTop: 62, cornerAdaptedTop: 62) == 0)
        #expect(WindowCornerClearance.topClearance(safeTop: 32, cornerAdaptedTop: 16) == 0)
    }
}
