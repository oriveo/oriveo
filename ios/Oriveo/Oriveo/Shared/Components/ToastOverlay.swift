import SwiftUI

struct ToastOverlay: View {
    @State private var manager = ToastManager.shared

    var body: some View {
        if let toast = manager.current {
            VStack {
                ToastCard(toast: toast) {
                    manager.performCurrentAction()
                }
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .padding(.top, OriveoTheme.Spacing.sm)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: manager.current)
        }
    }
}

private struct ToastCard: View {
    let toast: Toast
    var onAction: () -> Void = {}

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            if let icon = iconName {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(toast.message)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            if let actionTitle = toast.actionTitle {
                Spacer(minLength: OriveoTheme.Spacing.sm)
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(OriveoTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(toast.style == .neutral ? OriveoTheme.Palette.info : accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
        .background {
            let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay { shape.fill(tint) }
                .overlay { shape.strokeBorder(accent.opacity(isSemantic ? 0.28 : 0), lineWidth: 1) }
        }
        .shadow(color: OriveoTheme.Palette.shadow, radius: 10, y: 4)
    }

    private var isSemantic: Bool { toast.style != .neutral }

    private var iconName: String? {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .neutral: return nil
        }
    }

    private var accent: Color {
        switch toast.style {
        case .success: return OriveoTheme.Palette.success
        case .error: return OriveoTheme.Palette.danger
        case .warning: return OriveoTheme.Palette.warning
        case .info: return OriveoTheme.Palette.info
        case .neutral: return OriveoTheme.Palette.textPrimary
        }
    }

    private var tint: Color {
        switch toast.style {
        case .success: return OriveoTheme.Palette.successSoft
        case .error: return OriveoTheme.Palette.dangerSoft
        case .warning: return OriveoTheme.Palette.warningSoft
        case .info: return OriveoTheme.Palette.infoSoft
        case .neutral: return Color.clear
        }
    }
}
