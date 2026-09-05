import SwiftUI

struct OriveoCard<Content: View>: View {
    var fill: Color = OriveoTheme.Palette.surface
    var border: Color = OriveoTheme.Palette.border
    var contentPadding: EdgeInsets = EdgeInsets(
        top: OriveoTheme.Spacing.lg,
        leading: OriveoTheme.Spacing.lg,
        bottom: OriveoTheme.Spacing.lg,
        trailing: OriveoTheme.Spacing.lg
    )
    var content: () -> Content

    var body: some View {
        content()
            .padding(contentPadding)
            .oriveoRoundedSurface(fill: fill, border: border)
    }
}

struct OriveoSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Spacer()

            if let trailing {
                Text(trailing)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
        }
    }
}

struct OriveoEmptyState: View {
    let systemImage: String
    let title: String
    let description: String
    let actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: OriveoTheme.Spacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)

            VStack(spacing: OriveoTheme.Spacing.sm) {
                Text(title)
                    .font(OriveoTheme.Typography.title2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                Text(description)
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button(actionTitle, action: action)
                .buttonStyle(OriveoPrimaryButtonStyle())
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(OriveoTheme.Spacing.xl)
    }
}

struct OriveoErrorCard: View {
    let error: OriveoError
    var action: () -> Void

    @State private var isExpanded = false

    private var tone: StatusTone {
        switch error.severity {
        case .warning:
            return .warning
        case .critical:
            return .danger
        }
    }

    private var iconName: String {
        switch error.severity {
        case .warning:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "xmark"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: iconName)
                    .foregroundStyle(tone.foreground)

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    Text(error.title)
                        .lineLimit(2)
                        .font(OriveoTheme.Typography.title2)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    Text(error.message)
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
            }

            Button(error.actionTitle, action: action)
                .buttonStyle(OriveoPrimaryButtonStyle())

            Button(isExpanded ? L10n.tr("Hide technical details") : L10n.tr("Technical details")) {
                isExpanded.toggle()
            }
            .buttonStyle(OriveoTextButtonStyle())

            if isExpanded {
                Text(error.detail)
                    .font(OriveoTheme.Typography.code)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OriveoTheme.Spacing.md)
                    .oriveoRoundedSurface(
                        fill: OriveoTheme.Palette.surfaceInset,
                        border: OriveoTheme.Palette.border,
                        radius: OriveoTheme.Radius.sm,
                        shadow: .none
                    )
            }
        }
        .padding(OriveoTheme.Spacing.lg)
        .oriveoRoundedSurface(
            fill: tone.background,
            border: tone.foreground.opacity(0.28),
            shadow: .soft
        )
    }
}
