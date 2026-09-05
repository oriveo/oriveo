import SwiftUI


extension View {
    func flatGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
        return VStack(spacing: 0, content: content)
            .background(
                shape
                    .fill(Color.dynamic(light: 0xFFFFFF, dark: 0x252937))
                    .shadow(
                        color: Color.dynamic(light: 0x0F172A, dark: 0x000000, lightAlpha: 0.06, darkAlpha: 0.28),
                        radius: 10,
                        y: 4
                    )
            )
            .overlay(
                shape.stroke(
                    Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0, darkAlpha: 0.07),
                    lineWidth: 1
                )
            )
    }

    func flatSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .padding(.leading, OriveoTheme.Spacing.lg)
    }

    func insetHairline() -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        OriveoTheme.Palette.borderStrong.opacity(0.65),
                        OriveoTheme.Palette.borderStrong.opacity(0.65),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, OriveoTheme.Spacing.lg)
    }

    func flatTapRow<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
