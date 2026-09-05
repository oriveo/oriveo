import SwiftUI

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0 ..< 3) { index in
                Circle()
                    .fill(OriveoTheme.Palette.primary.opacity(0.75))
                    .frame(width: 6, height: 6)
                    .shadow(color: OriveoTheme.Palette.primary.opacity(0.3), radius: 4, y: 0)
                    .scaleEffect(reduceMotion ? 1 : (animating ? 1 : 0.72))
                    .offset(y: reduceMotion ? 0 : (animating ? -4 : 0))
                    .animation(
                        reduceMotion
                            ? .default
                            : .spring(response: 0.35, dampingFraction: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                        value: animating
                    )
            }

            Text(L10n.tr("Generating"))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
        .padding(.vertical, OriveoTheme.Spacing.xs)
        .onAppear { animating = !reduceMotion }
    }
}
