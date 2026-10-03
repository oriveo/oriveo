import SwiftUI

// MARK: - Shared building blocks for the MCP setup and management pages
//
// Pages: 16 horizontal inset, card corner radius 20, group spacing 18. All colors come from `OriveoTheme.Palette`
// tokens, so dark mode follows automatically.
// Bottom sheets reuse the chat page's `McpFittedSheet` (30 top padding, no lazy containers in the content).

enum McpPageMetrics {
    static let horizontalPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let cardRadius: CGFloat = 20
    static let fieldRadius: CGFloat = 14
    static let fieldHeight: CGFloat = 52
}

/// Page skeleton: custom top bar (back, centered title, optional trailing action), scrollable content, and a
/// button area pinned to the bottom.
struct McpPageScaffold<Content: View, Trailing: View, Footer: View>: View {
    let title: String
    let onBack: @MainActor () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: McpPageMetrics.sectionSpacing) {
                content()
            }
            .padding(.horizontal, McpPageMetrics.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .oriveoContentWidth()
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer()
                .padding(.horizontal, McpPageMetrics.horizontalPadding)
                .padding(.bottom, 8)
                .oriveoContentWidth()
        }
        .oriveoScreenBackground()
    }

    private var topBar: some View {
        ZStack {
            Text(title)
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 56)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                OriveoBackButton(action: onBack)
                    .padding(.leading, -OriveoBackButton.edgeInset)
                Spacer(minLength: 0)
                trailing()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, McpPageMetrics.horizontalPadding)
    }
}

extension McpPageScaffold where Trailing == EmptyView {
    init(
        title: String,
        onBack: @escaping @MainActor () -> Void,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.init(title: title, onBack: onBack, trailing: { EmptyView() }, content: content, footer: footer)
    }
}

/// White rounded card (list card, hero card, checklist card).
struct McpCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .oriveoRoundedSurface(radius: McpPageMetrics.cardRadius, shadow: .soft)
    }
}

enum McpPillTone {
    case success
    case warning
    case danger
    case neutral
    case primary

    var foreground: Color {
        switch self {
        case .success: return Color.dynamic(light: 0x047857, dark: 0x6EE7A1)
        case .warning: return OriveoTheme.Palette.warningText
        case .danger: return Color.dynamic(light: 0xB91C1C, dark: 0xF8978F)
        case .neutral: return OriveoTheme.Palette.textSecondary
        case .primary: return OriveoTheme.Palette.primaryTextSafe
        }
    }

    var fill: Color {
        switch self {
        case .success: return OriveoTheme.Palette.successSoft
        case .warning: return OriveoTheme.Palette.warningSoft
        case .danger: return OriveoTheme.Palette.dangerSoft
        case .neutral: return OriveoTheme.Palette.surfaceInset
        case .primary: return OriveoTheme.Palette.primarySoft
        }
    }

    var stroke: Color {
        switch self {
        case .success: return OriveoTheme.Palette.success.opacity(0.35)
        case .warning: return OriveoTheme.Palette.warning.opacity(0.35)
        case .danger: return OriveoTheme.Palette.danger.opacity(0.35)
        case .neutral: return OriveoTheme.Palette.borderStrong
        case .primary: return OriveoTheme.Palette.primary.opacity(0.35)
        }
    }
}

/// Status pill: height 24, horizontal padding 9, 12 / 600, tinted fill with a same-color stroke.
struct McpStatusPill: View {
    let text: String
    let tone: McpPillTone

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(tone.fill))
            .overlay(Capsule().stroke(tone.stroke, lineWidth: 1))
    }
}

/// Hero card header: 52 icon, 22 / 800 name, and one line below (pill or caption).
struct McpHeroHeader<Accessory: View>: View {
    let name: String
    let iconURL: String?
    /// When the name is not known yet (host name only), use a globe icon rather than passing off the host name's
    /// initial as the server icon.
    var showsGlobe = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                accessory()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if showsGlobe {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(OriveoTheme.Palette.primarySoft)
                Image(systemName: "globe")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
        } else {
            McpServerIconView(name: name, iconURL: iconURL, size: 52)
        }
    }
}

/// State of one checklist row.
enum McpChecklistState {
    case done
    case active
    case waiting
}

struct McpChecklistItem: Identifiable {
    let id: Int
    var title: String
    var detail: String?
    var state: McpChecklistState
}

/// Three-step checklist card: each row is a 20 status icon plus 15 text; pending rows use the tertiary text color.
struct McpChecklistCard: View {
    let items: [McpChecklistItem]

    var body: some View {
        McpCard(padding: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(OriveoTheme.Palette.border).frame(height: 1).padding(.horizontal, 16)
                }
                HStack(alignment: .center, spacing: 12) {
                    stateIcon(item.state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 15, weight: item.state == .waiting ? .regular : .semibold))
                            .foregroundStyle(
                                item.state == .waiting ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.textPrimary
                            )
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 13))
                                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .padding(.vertical, item.detail == nil ? 0 : 6)
                .accessibilityElement(children: .combine)
                .accessibilityValue(stateLabel(item.state))
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: McpChecklistState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(OriveoTheme.Palette.success)
                .frame(width: 20, height: 20)
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(OriveoTheme.Palette.primary)
                .frame(width: 20, height: 20)
        case .waiting:
            Circle()
                .strokeBorder(OriveoTheme.Palette.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: 18, height: 18)
                .frame(width: 20, height: 20)
        }
    }

    private func stateLabel(_ state: McpChecklistState) -> String {
        switch state {
        case .done: return L10n.tr("Done", table: .mcp)
        case .active: return L10n.tr("Running", table: .mcp)
        case .waiting: return L10n.tr("Waiting", table: .mcp)
        }
    }
}

/// Notice block: corner radius 16, tinted fill with a same-color stroke; 15 / 600 title in the tint color, 13.5
/// body in the secondary text color.
struct McpNoticeBlock: View {
    let title: String
    let message: String
    var tone: McpPillTone = .warning

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.foreground)
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tone.fill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tone.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Input field: height 52, corner radius 14; brand stroke plus a light outer ring when focused; danger stroke
/// with 12.5 error text below when invalid.
struct McpInputField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var hint: String?
    var error: String?
    var monospaced = false
    var isSecure = false
    var keyboard: UIKeyboardType = .default
    var submitLabel: SubmitLabel = .done
    var onSubmit: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            field
                .font(monospaced ? .system(size: 15, design: .monospaced) : .system(size: 16))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .submitLabel(submitLabel)
                .focused($focused)
                .onSubmit { onSubmit?() }
                .padding(.horizontal, 14)
                .frame(height: McpPageMetrics.fieldHeight)
                .background(
                    RoundedRectangle(cornerRadius: McpPageMetrics.fieldRadius, style: .continuous)
                        .fill(OriveoTheme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: McpPageMetrics.fieldRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: focused || error != nil ? 1.5 : 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: McpPageMetrics.fieldRadius + 3, style: .continuous)
                        .fill(focused && error == nil ? OriveoTheme.Palette.primarySoft : Color.clear)
                        .padding(-3)
                )
                .accessibilityLabel(label)
            if let error {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(McpPillTone.danger.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint {
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let prompt = Text(placeholder).foregroundStyle(OriveoTheme.Palette.textTertiary)
        if isSecure {
            SecureField("", text: $text, prompt: prompt)
        } else {
            TextField("", text: $text, prompt: prompt)
        }
    }

    private var borderColor: Color {
        if error != nil { return OriveoTheme.Palette.danger }
        return focused ? OriveoTheme.Palette.primary : OriveoTheme.Palette.border
    }
}

/// Section title (17 / 600) with a trailing count.
struct McpSectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Footnote at the bottom of a page (12.5, tertiary text color).
struct McpFootnote: View {
    let text: String
    var tone: Color = OriveoTheme.Palette.textTertiary

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Soft brand button (the "Reload tools" button in the hero card): height 52, corner radius 16, light brand fill
/// with brand stroke and text.
struct McpSoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
            .frame(maxWidth: .infinity)
            .frame(height: McpSheetMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: McpSheetMetrics.buttonCornerRadius, style: .continuous)
                    .fill(OriveoTheme.Palette.primarySoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: McpSheetMetrics.buttonCornerRadius, style: .continuous)
                    .stroke(OriveoTheme.Palette.primary.opacity(0.35), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Soft danger button (the "Remove" button in the remove confirmation dialog).
struct McpDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(McpPillTone.danger.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: McpSheetMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: McpSheetMetrics.buttonCornerRadius, style: .continuous)
                    .fill(OriveoTheme.Palette.dangerSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: McpSheetMetrics.buttonCornerRadius, style: .continuous)
                    .stroke(OriveoTheme.Palette.danger.opacity(0.35), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum McpPermissionCopy {
    static func label(_ permission: McpToolPermission) -> String {
        switch permission {
        case .auto: return L10n.tr("Run automatically", table: .mcp)
        case .ask: return L10n.tr("Ask every time", table: .mcp)
        case .off: return L10n.tr("Don't use", table: .mcp)
        }
    }

    static func group(readOnly: Bool) -> String {
        readOnly ? L10n.tr("Read only", table: .mcp) : L10n.tr("Changes data", table: .mcp)
    }
}

/// Pre-sign-in prompt: it **must show the host name of the sign-in page**; the client is registered and the
/// browser opened only after the user taps "Continue". Shared by the add flow and re-authorization.
struct McpAuthPromptSheet: View {
    let serverName: String
    let iconURL: String?
    let authorizationHost: String
    let serverHost: String
    let onContinue: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        McpFittedSheet(fallbackHeight: 440, allowsInteractiveDismiss: false) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    McpServerIconView(name: serverName, iconURL: iconURL, size: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: L10n.tr("Sign in to %@", table: .mcp), serverName))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(String(
                            format: L10n.tr(
                                "%1$@'s sign-in page opens next. Your password goes only to %1$@. Oriveo gets an access grant you can revoke anytime.",
                                table: .mcp
                            ),
                            serverName
                        ))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                McpGroupCard {
                    row(L10n.tr("Sign-in page", table: .mcp), authorizationHost, secure: true)
                    Rectangle().fill(OriveoTheme.Palette.border).frame(height: 1).padding(.horizontal, 16)
                    row(L10n.tr("Connects to", table: .mcp), serverHost, secure: false)
                }
                Text(L10n.tr("Make sure the sign-in page's domain is a service you recognize.", table: .mcp))
                    .font(.system(size: 13))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            VStack(spacing: 4) {
                Button(action: onContinue) {
                    Text(L10n.tr("Continue"))
                }
                .buttonStyle(McpPrimaryButtonStyle())
                Button(action: onCancel) {
                    Text(L10n.tr("Cancel"))
                }
                .buttonStyle(McpTextButtonStyle())
            }
        }
    }

    private func row(_ label: String, _ value: String, secure: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(width: 96, alignment: .leading)
            if secure {
                Image(systemName: "lock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.success)
                    .accessibilityHidden(true)
            }
            // The host name is third-party text and is not translated; when too long it is truncated in the middle so
            // both ends (including the registrable domain) stay visible.
            Text(value)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}
