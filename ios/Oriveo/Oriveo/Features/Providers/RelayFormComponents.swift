import SwiftUI

// MARK: - Setup status

struct RelaySetupStatusRow: View {
    enum Tone {
        case neutral
        case progress
        case success
        case warning
    }

    let message: String
    let systemImage: String
    let tone: Tone
    var showsProgress = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 24, minHeight: 24)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(minWidth: 24, minHeight: 24)
                    .accessibilityHidden(true)
            }

            Text(message)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            }
        }
        .padding(OriveoTheme.Spacing.md)
        .frame(minHeight: 54)
        .oriveoRoundedSurface(
            fill: fill,
            border: accent.opacity(tone == .neutral || tone == .progress ? 0 : 0.3),
            radius: OriveoTheme.Radius.inset,
            shadow: .none
        )
    }

    private var accent: Color {
        switch tone {
        case .neutral, .progress: OriveoTheme.Palette.textSecondary
        case .success: OriveoTheme.Palette.success
        case .warning: OriveoTheme.Palette.warning
        }
    }

    private var fill: Color {
        switch tone {
        case .neutral: OriveoTheme.Palette.surfaceChrome
        case .progress: OriveoTheme.Palette.primarySoft
        case .success: OriveoTheme.Palette.successSoft
        case .warning: OriveoTheme.Palette.warningSoft
        }
    }
}


struct RelayFormIssueNotes: View {
    let issues: [RelayFormValidation.FieldIssue]

    var body: some View {
        let displayable = RelayFormValidation.displayableIssues(issues)
        if !displayable.isEmpty {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                ForEach(displayable, id: \.code.rawValue) { issue in
                    Text(issue.localizedMessage)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


struct RelayGroupHeader: View {
    let title: String
    let systemImage: String
    var trailing: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? OriveoTheme.Palette.textTertiary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint?.opacity(0.14) ?? OriveoTheme.Palette.surfaceInset)
                )

            Text(title)
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if let trailing {
                Text(trailing)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer()
        }
        .padding(.horizontal, 2)
    }
}


struct RelayRowGroup<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.surfaceChrome,
            border: tint?.opacity(0.18) ?? OriveoTheme.Palette.border,
            radius: OriveoTheme.Radius.md,
            shadow: .none
        )
    }
}

struct RelayRowDivider: View {
    var leadingInset: CGFloat = OriveoTheme.Spacing.lg

    var body: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.border.opacity(0.6))
            .frame(height: 0.6)
            .padding(.leading, leadingInset)
    }
}


struct RelayMenuRow<Content: View>: View {
    let title: String
    let value: String
    var isEnabled: Bool = true
    var footnote: String? = nil
    @ViewBuilder var menuContent: () -> Content

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: OriveoTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(isEnabled
                                         ? OriveoTheme.Palette.textPrimary
                                         : OriveoTheme.Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let footnote {
                        Text(footnote)
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: OriveoTheme.Spacing.sm)

                Text(value)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}


struct RelayToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var footnote: String? = nil
    var isEnabled: Bool = true
    var tint: Color = OriveoTheme.Palette.primary

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(isEnabled
                                     ? OriveoTheme.Palette.textPrimary
                                     : OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let footnote {
                    Text(footnote)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: OriveoTheme.Spacing.sm)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(tint)
                .disabled(!isEnabled)
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, 10)
    }
}


struct RelayInlineTextRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var isEnabled: Bool = true
    var keyboardType: UIKeyboardType = .default
    var autocapitalize: Bool = false
    var isSecure: Bool = false

    @State private var revealsSecureText = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalBody
            verticalBody
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, 12)
    }

    private var titleView: some View {
        Text(title)
            .font(OriveoTheme.Typography.body)
            .foregroundStyle(isEnabled
                             ? OriveoTheme.Palette.textPrimary
                             : OriveoTheme.Palette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.86)
    }

    private var textInput: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Group {
                if isSecure && !revealsSecureText {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .keyboardType(keyboardType)
            .textInputAutocapitalization(autocapitalize ? .sentences : .never)
            .autocorrectionDisabled()
            .font(OriveoTheme.Typography.body)
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .disabled(!isEnabled)

            if isSecure {
                Button { revealsSecureText.toggle() } label: {
                    Image(systemName: revealsSecureText ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var horizontalBody: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            titleView
                .frame(minWidth: 86, alignment: .leading)

            textInput
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleView
            textInput
                .multilineTextAlignment(.leading)
        }
    }
}
