import SwiftUI

/// The right column of a wide two-column tab: holds one level of detail next to the tab's root list.
///
/// It looks like `ChatDetailColumn`, the same in every tab: 32pt of clearance under the floating iPad
/// tab bar, a 1pt border on the leading edge against the sidebar, and hidden system bars. Its content
/// is marked as the column root, so an `OriveoBackButton` in it does not appear — the sidebar list
/// stays on screen and there is no previous page to go back to.
struct SplitDetailColumn<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.isSplitColumnRoot, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .splitColumnTopTabBarClearance()
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(OriveoTheme.Palette.border)
                    .frame(width: 1)
                    .ignoresSafeArea()
            }
            .oriveoNavigationChrome()
    }
}

extension View {
    /// Gives a column of the two-column layout 32pt of clearance under the floating iPad tab bar (the same
    /// test as `ChatDetailColumn`). The Providers sidebar uses it too: a button at its top trailing corner
    /// (such as Add Provider) would otherwise run into the capsule's leading edge, and clearing both columns
    /// keeps their tops aligned. System bars are always hidden here, so they are never vertical.
    func splitColumnTopTabBarClearance() -> some View {
        modifier(SplitColumnTopTabBarClearance())
    }
}

private struct SplitColumnTopTabBarClearance: ViewModifier {
    /// The column's top edge in the window and the column's own safe top; their sum is the window's top safe line.
    @State private var columnTop = ColumnTopGeometry(minYInWindow: 0, safeAreaTop: 0)

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: needsTopTabBarClearance ? 32 : 0)
            }
            // Read outside the safeAreaInset: it measures the column's own geometry without the 32pt above, so it cannot feed back on itself.
            .onGeometryChange(for: ColumnTopGeometry.self) {
                ColumnTopGeometry(minYInWindow: $0.frame(in: .global).minY, safeAreaTop: $0.safeAreaInsets.top)
            } action: { columnTop = $0 }
    }

    private var needsTopTabBarClearance: Bool {
        ChatDetailColumn.needsTopTabBarClearance(
            columnMinYInWindow: columnTop.minYInWindow,
            columnSafeAreaTop: columnTop.safeAreaTop,
            usesVerticalBar: false
        )
    }
}
