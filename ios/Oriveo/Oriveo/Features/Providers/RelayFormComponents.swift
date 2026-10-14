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
    /// When provided, replaces `systemImage` (the edit-connection page uses Phosphor); without it the row looks exactly as before.
    var phosphorIcon: PhosphorIcon? = nil
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
            } else if let phosphorIcon {
                phosphorIcon.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(accent)
                    .frame(minWidth: 24, minHeight: 24)
                    .accessibilityHidden(true)
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

// MARK: - Soft-fill input slot

/// Input slot surface shared by the endpoint slot and the key-value slots on the edit-connection page. At rest it is
/// only a soft fill; a stroke appears when focused or when highlighted from outside.
/// Replaces the system `.roundedBorder`, which was the only grey-white bordered box on the page and looked harsh in dark mode.
struct RelayFillSlotModifier: ViewModifier {
    let isFocused: Bool
    var isHighlighted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
        content
            .background(shape.fill(OriveoTheme.Palette.surfaceInset))
            .overlay(
                shape.stroke(
                    OriveoTheme.Palette.primary.opacity(isFocused || isHighlighted ? 0.8 : 0),
                    lineWidth: isHighlighted ? 1.5 : 1.25
                )
            )
    }
}

extension View {
    func relayFillSlot(isFocused: Bool, isHighlighted: Bool = false) -> some View {
        modifier(RelayFillSlotModifier(isFocused: isFocused, isHighlighted: isHighlighted))
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

// MARK: - Failure card reveal

/// The verification failure card and the test-connection result row sit at the end of the scrolling content, so they
/// land off-screen while the keyboard is still open. The edit-connection page and the "manual setup" step of the add
/// page share one approach: when a new card or result appears, dismiss the keyboard and scroll it into view.
enum RelayFailureCardReveal {
    /// Anchor of the failure card in the scrolling content; a page has at most one.
    static let anchorID = "relay-failure-card"
    /// Anchor of the status row (test connection / reconnect) at the end of the edit-connection content.
    static let statusAnchorID = "relay-status-row"

    /// Only act when a new card or status appears; do not scroll when one is dismissed (input edited or saved).
    static func shouldReveal<Value: Equatable>(previous: Value?, current: Value?) -> Bool {
        current != nil && current != previous
    }

    static func revealIfNeeded<Value: Equatable>(
        previous: Value?,
        current: Value?,
        anchor anchorID: String = RelayFailureCardReveal.anchorID,
        proxy: ScrollViewProxy
    ) {
        guard shouldReveal(previous: previous, current: current) else { return }
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        // The card is inserted on this frame; wait for layout before scrolling, otherwise the anchor is not found yet.
        Task { @MainActor in
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(anchorID, anchor: .bottom)
            }
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
                // Without a label VoiceOver reads the SF Symbol's system name ("Show"), which ignores the in-app language and never changes with state. This row can hold any secret, so the label does not name what it reveals.
                .accessibilityLabel(revealsSecureText ? L10n.tr("Hide characters") : L10n.tr("Show characters"))
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
