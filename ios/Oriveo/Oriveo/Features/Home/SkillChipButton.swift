import SwiftUI

struct SkillChipButton: View {
    let skill: Skill
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SkillIconRenderer(
                    icon: skill.icon,
                    tintColor: Color(hex: skill.color),
                    size: 18
                )

                Text(skill.localizedName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AuroraTheme.Colors.textPrimary)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .frame(height: 44)
        }
        .buttonStyle(SkillChipPressStyle(skill: skill, colorScheme: colorScheme))
    }
}


private struct SkillChipPressStyle: ButtonStyle {
    let skill: Skill
    let colorScheme: ColorScheme

    private var skillColor: Color { Color(hex: skill.color) }

    private var chipFill: Color {
        skillColor.opacity(colorScheme == .dark ? 0.12 : 0.06)
    }

    private var chipBorder: Color {
        skillColor.opacity(colorScheme == .dark ? 0.22 : 0.14)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chipFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(skillColor.opacity(configuration.isPressed ? 0.10 : 0))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(chipBorder, lineWidth: 0.6)
            )
            .shadow(
                color: OriveoTheme.Palette.shadow,
                radius: 4, y: 1
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: configuration.isPressed ? 0.12 : 0.18), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
