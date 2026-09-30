import SwiftUI

/// The app-wide close button: a bare ×, no fill, border or shadow, same spec as `OriveoBackButton`.
///
/// The design's close glyph: 24-grid path `M7 7l10 10M17 7L7 17`, 2 stroke, round caps; 44×44 touch
/// target, 50% opacity while pressed. Defaults to textPrimary; panels with their own palette pass `tint`.
/// To line the icon box up with the trailing margin, add `.padding(.trailing, -OriveoBackButton.edgeInset)`.
///
/// Usage: `OriveoCloseButton(accessibilityLabel: L10n.tr("Close")) { dismiss() }`
struct OriveoCloseButton: View {
    private let accessibilityLabel: String
    private let tint: Color
    private let action: @MainActor () -> Void

    init(
        accessibilityLabel: String,
        tint: Color = OriveoTheme.Palette.textPrimary,
        action: @escaping @MainActor () -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            OriveoCloseGlyph()
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: OriveoCloseGlyph.strokeWidth * OriveoBackButton.iconSize / OriveoBackChevron.gridSize,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: OriveoBackButton.iconSize, height: OriveoBackButton.iconSize)
                .frame(width: OriveoBackButton.hitSize, height: OriveoBackButton.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(OriveoFlatIconButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The design's × path (24 grid), scaled to the frame.
struct OriveoCloseGlyph: Shape {
    static let strokeWidth: CGFloat = 2

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / OriveoBackChevron.gridSize
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        path.move(to: point(7, 7))
        path.addLine(to: point(17, 17))
        path.move(to: point(17, 7))
        path.addLine(to: point(7, 17))
        return path
    }
}
