import SwiftUI

struct OriveoFadeHairline: View {
    let insetLeading: CGFloat
    let insetTrailing: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    init(insetLeading: CGFloat = 0, insetTrailing: CGFloat = 0) {
        self.insetLeading = insetLeading
        self.insetTrailing = insetTrailing
    }

    var body: some View {
        LinearGradient(
            colors: [
                Color.clear,
                lineColor,
                lineColor,
                Color.clear
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.leading, insetLeading)
        .padding(.trailing, insetTrailing)
    }

    private var lineColor: Color {
        OriveoTheme.Palette.border
    }
}
