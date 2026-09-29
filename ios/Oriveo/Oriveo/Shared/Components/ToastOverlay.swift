import SwiftUI

/// One-shot top notice: a centered capsule with a 24pt tinted round icon, the message and an optional action.
/// Android and Web implement the same spec, so appearance changes should land on all three together.
struct ToastOverlay: View {
    @State private var manager = ToastManager.shared

    var body: some View {
        if let toast = manager.current {
            VStack {
                ToastCapsule(toast: toast) {
                    manager.performCurrentAction()
                }
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .padding(.top, OriveoTheme.Spacing.sm)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: manager.current)
        }
    }
}

private struct ToastCapsule: View {
    let toast: Toast
    var onAction: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.style.glyph)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(accent.opacity(0.16)))
                .accessibilityHidden(true)

            Text(toast.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle = toast.actionTitle {
                Rectangle()
                    .fill(OriveoTheme.Palette.border)
                    .frame(width: 1, height: 16)
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, toast.actionTitle == nil ? 16 : 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 480)
        .background {
            let shape = Capsule(style: .continuous)
            shape
                .fill(.regularMaterial)
                .overlay { shape.fill(OriveoTheme.Palette.surfaceElevated.opacity(0.72)) }
                .overlay { shape.strokeBorder(OriveoTheme.Palette.border, lineWidth: 1) }
        }
        .shadow(color: OriveoTheme.Palette.shadow, radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }

    private var accent: Color {
        switch toast.style {
        case .success: return OriveoTheme.Palette.success
        case .error: return OriveoTheme.Palette.danger
        case .warning: return OriveoTheme.Palette.warning
        case .info: return OriveoTheme.Palette.info
        case .removed, .neutral: return OriveoTheme.Palette.textSecondary
        }
    }
}

private extension ToastStyle {
    var glyph: String {
        switch self {
        case .success: return "checkmark"
        case .error: return "xmark"
        case .warning: return "exclamationmark"
        case .info: return "info"
        case .removed: return "minus"
        case .neutral: return "bell.fill"
        }
    }
}
