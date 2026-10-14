import SwiftUI
import UIKit

enum RelayModelPlaceholder {
    static let fallback = "gpt-5.6-sol"

    static var current: String {
        #if DEBUG
        if RelayFamilyDebugShots.isActive { return fallback }
        #endif
        let metadataDefault = MetadataClient.shared
            .syncProviderDefaultModelID(providerKind: .openAI)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let metadataDefault, !metadataDefault.isEmpty else { return fallback }
        return metadataDefault
    }
}

/// Read/write rules for an address slot with a scheme chip: the slot shows only the part after the scheme.
/// Pasting a full URL replaces the whole text, clearing the slot clears the whole text, and otherwise the scheme the user
/// already wrote is kept. An address without a scheme stays as typed and is completed by normalization before the request.
enum RelaySchemeSlotText {
    private static let schemePattern = #"^[A-Za-z][A-Za-z0-9+.-]*://"#

    /// The scheme (lowercased) the user wrote in the address text, or nil if there is none.
    static func explicitScheme(in text: String) -> String? {
        guard let range = text.range(of: schemePattern, options: .regularExpression) else { return nil }
        return String(text[range].dropLast(3)).lowercased()
    }

    /// The part shown in the slot: the text with the leading scheme removed.
    static func body(of text: String) -> String {
        guard let range = text.range(of: schemePattern, options: .regularExpression) else { return text }
        return String(text[range.upperBound...])
    }

    /// The full address after the user types `next` into the slot.
    static func text(_ text: String, replacingBodyWith next: String) -> String {
        // Clearing the slot clears the whole text, so no dangling "https://" is left behind.
        if next.isEmpty { return "" }
        if next.contains("://") { return next }
        if let scheme = explicitScheme(in: text) { return "\(scheme)://\(next)" }
        return next
    }
}

struct RelaySetupField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let footnote: String?
    let isSecure: Bool
    let isEnabled: Bool
    let leadingSystemImage: String?
    let usesQuickSetupStyle: Bool
    var highlightToken = 0
    var keyboardType: UIKeyboardType = .default
    var forcesLeftToRightValue = false
    /// Setup-page board: a Phosphor icon before the title (replaces `leadingSystemImage` when given).
    var leadingPhosphor: PhosphorIcon? = nil
    /// Setup-page board: the scheme prefix chip of the address slot. The value is the default scheme shown while the text has
    /// none; the slot shows only the part after the scheme, and editing keeps whatever scheme the user already wrote.
    var schemePrefix: String? = nil
    var trailingActionTitle: String? = nil
    var trailingActionSystemImage: String? = nil
    var trailingActionPhosphor: PhosphorIcon? = nil
    /// Setup-page board: put the trailing action inside the input slot (the "Search" action of the local address slot).
    var trailingActionInSlot = false
    var onTrailingAction: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var revealsSecureText = false
    @State private var isExternallyHighlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                if usesQuickSetupStyle, let leadingPhosphor {
                    leadingPhosphor.image(.regular)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                } else if usesQuickSetupStyle, let leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(OriveoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(
                        usesQuickSetupStyle
                            ? OriveoTheme.Palette.textSecondary
                            : OriveoTheme.Palette.textPrimary
                    )

                Spacer(minLength: 0)

                if !trailingActionInSlot,
                   let trailingActionTitle, let onTrailingAction,
                   trailingActionPhosphor != nil || trailingActionSystemImage != nil {
                    Button(action: onTrailingAction) {
                        Label {
                            Text(trailingActionTitle)
                        } icon: {
                            // Use the Phosphor icon when given (same priority as the in-slot action), else fall back to the system symbol.
                            if let trailingActionPhosphor {
                                trailingActionPhosphor.image(.regular)
                                    .resizable()
                                    .renderingMode(.template)
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                                    .accessibilityHidden(true)
                            } else if let trailingActionSystemImage {
                                Image(systemName: trailingActionSystemImage)
                            }
                        }
                            .font(OriveoTheme.Typography.footnote.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .disabled(!isEnabled)
                    .accessibilityLabel(trailingActionTitle)
                }
            }
            .padding(.leading, usesQuickSetupStyle ? 2 : 0)

            HStack(spacing: OriveoTheme.Spacing.sm) {
                if !usesQuickSetupStyle, let leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }

                if schemePrefix != nil {
                    Text(verbatim: displayedScheme)
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(OriveoTheme.Palette.primarySoft)
                        )
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityHidden(true)
                }

                Group {
                    if isSecure && !revealsSecureText {
                        SecureField(
                            "",
                            text: $text,
                            prompt: Text(placeholder)
                                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        )
                    } else {
                        TextField(
                            "",
                            text: displayedText,
                            prompt: Text(displayedPlaceholder)
                                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        )
                    }
                }
                .font(OriveoTheme.Typography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboardType)
                .disabled(!isEnabled)
                .focused($isFocused)
                .foregroundStyle(isEnabled ? OriveoTheme.Palette.textPrimary : OriveoTheme.Palette.textTertiary)
                .accessibilityLabel(title)
                .accessibilityHint(footnote ?? "")
                .environment(\.layoutDirection, forcesLeftToRightValue ? .leftToRight : layoutDirection)

                if trailingActionInSlot,
                   let trailingActionTitle, let onTrailingAction {
                    Button(action: onTrailingAction) {
                        HStack(spacing: 6) {
                            if let trailingActionPhosphor {
                                trailingActionPhosphor.image(.regular)
                                    .resizable()
                                    .renderingMode(.template)
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)
                                    .accessibilityHidden(true)
                            } else if let trailingActionSystemImage {
                                Image(systemName: trailingActionSystemImage)
                                    .accessibilityHidden(true)
                            }
                            Text(trailingActionTitle)
                                .lineLimit(1)
                        }
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .padding(.horizontal, OriveoTheme.Spacing.md)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                                .fill(OriveoTheme.Palette.surfaceInset.opacity(0.8))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .disabled(!isEnabled)
                    .accessibilityLabel(trailingActionTitle)
                }

                if isSecure {
                    Button {
                        revealsSecureText.toggle()
                    } label: {
                        Group {
                            if usesQuickSetupStyle {
                                PhosphorIcon.eye.image(revealsSecureText ? .duotone : .regular)
                                    .resizable()
                                    .renderingMode(.template)
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: revealsSecureText ? "eye.slash" : "eye")
                                    .font(.system(size: 16, weight: .medium))
                            }
                        }
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr(
                        revealsSecureText ? "Hide API key" : "Show API key",
                        table: .providers
                    ))
                }
            }
            .padding(.leading, schemePrefix != nil ? OriveoTheme.Spacing.sm : OriveoTheme.Spacing.lg)
            .padding(.trailing, isSecure || trailingActionInSlot ? OriveoTheme.Spacing.xs : OriveoTheme.Spacing.lg)
            .frame(minHeight: 54)
            .background(inputBackground)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .onChange(of: highlightToken) { _, _ in
                isExternallyHighlighted = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    isExternallyHighlighted = false
                }
            }

            if let footnote {
                Text(footnote)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, usesQuickSetupStyle ? 2 : 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(usesQuickSetupStyle ? 0 : OriveoTheme.Spacing.xs)
        .opacity(isEnabled ? 1 : 0.66)
    }

    private var explicitScheme: String? {
        RelaySchemeSlotText.explicitScheme(in: text)
    }

    private var displayedScheme: String {
        explicitScheme ?? schemePrefix ?? ""
    }

    private var displayedPlaceholder: String {
        guard schemePrefix != nil else { return placeholder }
        return RelaySchemeSlotText.body(of: placeholder)
    }

    /// With a scheme chip the slot edits only the part after the scheme (rules in `RelaySchemeSlotText`).
    private var displayedText: Binding<String> {
        guard schemePrefix != nil else { return $text }
        return Binding(
            get: { RelaySchemeSlotText.body(of: text) },
            set: { text = RelaySchemeSlotText.text(text, replacingBodyWith: $0) }
        )
    }

    private var inputBackground: some View {
        let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
        return ZStack {
            shape.fill(OriveoTheme.Palette.surfaceInset)

            shape.fill(
                OriveoTheme.Palette.primarySoft.opacity(
                    isFocused
                        ? 1
                        : (colorScheme == .dark ? 0.68 : 0.62)
                )
            )

            if isFocused || isExternallyHighlighted {
                shape.stroke(
                    OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.9 : 0.72),
                    lineWidth: isExternallyHighlighted ? 1.5 : 1.25
                )
            }
        }
        .shadow(
            color: isFocused || isExternallyHighlighted ? OriveoTheme.Palette.primaryGlow : .clear,
            radius: isFocused || isExternallyHighlighted ? 5 : 0,
            y: 0
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused || isExternallyHighlighted)
    }
}

struct RelaySetupMenuField: View {
    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
    }

    let title: String
    @Binding var selection: String
    let options: [Option]
    let footnote: String?
    let isEnabled: Bool
    let leadingSystemImage: String
    var forcesLeftToRightValue = false
    /// A footnote next to the title (setup page).
    var titleFootnote: String? = nil
    var leadingPhosphor: PhosphorIcon? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Group {
                    if let leadingPhosphor {
                        leadingPhosphor.image(.regular)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: leadingSystemImage)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(OriveoTheme.Palette.primary)
                .frame(width: 18)
                .accessibilityHidden(true)

                Text(title)
                    .font(OriveoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)

                if let titleFootnote {
                    Text(verbatim: "· \(titleFootnote)")
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.leading, 2)

            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
            } label: {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Text(selectedTitle)
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.layoutDirection, forcesLeftToRightValue ? .leftToRight : layoutDirection)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .frame(minHeight: 54)
                .frame(maxWidth: .infinity)
                .background(inputBackground)
                .contentShape(Rectangle())
            }
            .disabled(!isEnabled)
            .accessibilityLabel(title)
            .accessibilityValue(selectedTitle)
            .accessibilityHint(footnote ?? "")

            if let footnote {
                Text(footnote)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
                    .accessibilityHidden(true)
            }
        }
        .opacity(isEnabled ? 1 : 0.66)
    }

    private var selectedTitle: String {
        options.first(where: { $0.id == selection })?.title ?? selection
    }

    private var inputBackground: some View {
        let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
        return ZStack {
            shape.fill(OriveoTheme.Palette.surfaceInset)
            shape.fill(OriveoTheme.Palette.primarySoft.opacity(colorScheme == .dark ? 0.68 : 0.62))
        }
    }
}

struct RelaySetupPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OriveoTheme.Typography.title3)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(isEnabled ? OriveoTheme.Palette.onPrimary : OriveoTheme.Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .padding(.vertical, OriveoTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                    .fill(
                        isEnabled
                            ? (configuration.isPressed ? OriveoTheme.Palette.primaryPressed : OriveoTheme.Palette.primary)
                            : OriveoTheme.Palette.surfaceElevated
                    )
            )
            .shadow(
                color: isEnabled ? OriveoTheme.Palette.primaryGlow.opacity(0.7) : .clear,
                radius: 7,
                y: 3
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.99 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
