import SwiftUI

struct NoteTagChip: View {
    let tag: String
    let brand: Color
    let hasSource: Bool
    var role: NoteTagChipVisualRole = .applied
    var isSelected = false
    var onTap: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        let colors = Self.colors(role: role, isSelected: isSelected)
        HStack(spacing: 5) {
            Image(systemName: "tag.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.icon)
            Text(tag)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(colors.text)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary.opacity(0.65))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, onRemove == nil ? 9 : 5)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(colors.background)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(colors.border, lineWidth: 1)
                )
        )
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            onTap?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }

    private struct ChipColors {
        let background: Color
        let border: Color
        let icon: Color
        let text: Color
    }

    private static func colors(role: NoteTagChipVisualRole, isSelected: Bool) -> ChipColors {
        let textColor = Color.dynamic(light: 0x6E5518, dark: 0xEAD9AC)
        let iconColor = Color.dynamic(light: 0xC79A2C, dark: 0xDCC07C)

        let background: Color = {
            if isSelected { return Color.dynamic(light: 0xF3E2A8, dark: 0x4C4027) }
            return role == .suggestion
                ? Color.dynamic(light: 0xFCF7E8, dark: 0x322B1D)
                : Color.dynamic(light: 0xFBF1D5, dark: 0x3A3220)
        }()
        let border: Color = isSelected
            ? Color.dynamic(light: 0xD9BD6C, dark: 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.14)
            : Color.dynamic(light: 0xEAD8A2, dark: 0xFFFFFF, lightAlpha: 0.9, darkAlpha: 0.07)

        let dimmed = role == .suggestion
        return ChipColors(
            background: background,
            border: border,
            icon: iconColor.opacity(dimmed ? 0.6 : 1.0),
            text: isSelected
                ? Color.dynamic(light: 0x55400F, dark: 0xF4E7C0)
                : textColor.opacity(dimmed ? 0.78 : 1.0)
        )
    }
}
