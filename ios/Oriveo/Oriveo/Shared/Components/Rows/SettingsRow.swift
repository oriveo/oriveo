import SwiftUI

struct SettingsRow: View {
    let icon: String?
    let title: String
    var value: String? = nil
    var tint: Color = OriveoTheme.Palette.textPrimary
    var iconColor: Color? = nil
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            if let icon {
                if let iconColor {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(iconColor)
                        )
                } else {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .frame(width: 20)
                }
            }

            Text(title)
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(tint)

            Spacer()

            if let value {
                Text(value)
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
