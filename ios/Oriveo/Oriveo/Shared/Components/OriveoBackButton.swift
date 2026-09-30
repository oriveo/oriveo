import SwiftUI

/// The app-wide page back button: a bare chevron with no fill, border or shadow.
///
/// 22pt icon, the 24-grid path drawn with a 2.2 stroke and round caps, 44×44 touch target,
/// textPrimary, 50% opacity while pressed. Android `OriveoBackButton` and web `BackButton` use the
/// same path, so all three platforms look the same.
///
/// It only owns the look; the caller passes the action (a plain `appState.pop()`, or `dismiss()`,
/// or a confirm-before-leave flow). To line the icon box up with the page margin, add
/// `.padding(.leading, -OriveoBackButton.edgeInset)`.
///
/// Usage: `OriveoBackButton { appState.pop() }`
struct OriveoBackButton: View {
    /// Touch target size.
    static let hitSize: CGFloat = 44
    /// Icon box size.
    static let iconSize: CGFloat = 22
    /// How far the touch target extends past the icon box on each side; used as a negative
    /// leading padding to put the icon box on the page margin.
    static let edgeInset: CGFloat = (hitSize - iconSize) / 2

    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            OriveoBackChevron()
                .stroke(
                    OriveoTheme.Palette.textPrimary,
                    style: StrokeStyle(
                        lineWidth: OriveoBackChevron.strokeWidth * Self.iconSize / OriveoBackChevron.gridSize,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: Self.iconSize, height: Self.iconSize)
                // A hand-drawn path doesn't mirror itself the way an SF Symbol does, so flip it for RTL
                .flipsForRightToLeftLayoutDirection(true)
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(OriveoFlatIconButtonStyle())
        .accessibilityLabel(L10n.tr("Back"))
    }
}

/// The design's chevron path `M14.5 5.5L8 12l6.5 6.5` (24 grid), scaled to the frame.
///
/// Not the SF Symbol `chevron.left`: its proportions and stroke weight change with font weight and
/// size and would not line up with the same path drawn on Android and web; a drawn path is identical
/// on all three.
struct OriveoBackChevron: Shape {
    static let gridSize: CGFloat = 24
    static let strokeWidth: CGFloat = 2.2

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.gridSize
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        path.move(to: point(14.5, 5.5))
        path.addLine(to: point(8, 12))
        path.addLine(to: point(14.5, 18.5))
        return path
    }
}

/// Pressing only drops the opacity to 50%; no background appears. Shared with `OriveoCloseButton`.
struct OriveoFlatIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
