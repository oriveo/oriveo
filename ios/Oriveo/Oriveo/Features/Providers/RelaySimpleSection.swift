import SwiftUI
import UIKit

struct RelaySimpleSection: View {
    @Binding var name: String
    @Binding var endpoint: String
    @Binding var apiKey: String
    @Binding var defaultModelID: String

    let isSubmitting: Bool
    var showsName: Bool = true
    var endpointFootnote: String? = nil
    var usesQuickSetupStyle: Bool = false
    var discoveredModelIDs: [String] = []
    var endpointNormalizationHighlightToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: fieldSpacing) {
            if showsName {
                RelaySetupField(
                    title: L10n.tr("Display Name", table: .providers),
                    text: $name,
                    placeholder: L10n.tr("e.g. My Relay", table: .providers),
                    footnote: L10n.tr("A display name for this relay provider", table: .providers),
                    isSecure: false,
                    isEnabled: !isSubmitting,
                    leadingSystemImage: usesQuickSetupStyle ? "textformat" : nil,
                    usesQuickSetupStyle: usesQuickSetupStyle
                )
            }

            RelaySetupField(
                title: L10n.tr("Request URL", table: .providers),
                text: $endpoint,
                placeholder: "https://api.example.com",
                footnote: endpointFootnote ?? L10n.tr("The base URL of the OpenAI-compatible API", table: .providers),
                isSecure: false,
                isEnabled: !isSubmitting,
                leadingSystemImage: usesQuickSetupStyle ? "link" : nil,
                usesQuickSetupStyle: usesQuickSetupStyle,
                highlightToken: endpointNormalizationHighlightToken,
                keyboardType: .URL
            )

            RelaySetupField(
                title: L10n.tr("API Key", table: .providers),
                text: $apiKey,
                placeholder: "sk-...",
                footnote: usesQuickSetupStyle
                    ? nil
                    : L10n.tr("Your API key is stored securely on this device and is sent only to your relay.", table: .providers),
                isSecure: true,
                isEnabled: !isSubmitting,
                leadingSystemImage: usesQuickSetupStyle ? "key.horizontal" : nil,
                usesQuickSetupStyle: usesQuickSetupStyle
            )

            if usesQuickSetupStyle {
                privacyNote
            }

            if discoveredModelIDs.isEmpty {
                RelaySetupField(
                    title: L10n.tr("Default Model", table: .providers),
                    text: $defaultModelID,
                    placeholder: RelayModelPlaceholder.current,
                    footnote: L10n.tr("Recommended. Used when the relay does not return a model list.", table: .providers),
                    isSecure: false,
                    isEnabled: !isSubmitting,
                    leadingSystemImage: usesQuickSetupStyle ? "sparkles" : nil,
                    usesQuickSetupStyle: usesQuickSetupStyle
                )
            } else {
                RelayDiscoveredModelField(
                    selection: $defaultModelID,
                    modelIDs: discoveredModelIDs,
                    isEnabled: !isSubmitting,
                    usesQuickSetupStyle: usesQuickSetupStyle
                )
            }
        }
    }

    private var fieldSpacing: CGFloat {
        usesQuickSetupStyle ? OriveoTheme.Spacing.xl : OriveoTheme.Spacing.lg
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(L10n.tr("Your API key is stored securely on this device and is sent only to your relay.", table: .providers))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, -OriveoTheme.Spacing.md)
    }
}

enum RelayModelPlaceholder {
    static let fallback = "gpt-5.6-sol"

    static var current: String {
        let metadataDefault = MetadataClient.shared
            .syncProviderDefaultModelID(providerKind: .openAI)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let metadataDefault, !metadataDefault.isEmpty else { return fallback }
        return metadataDefault
    }
}

struct RelayDiscoveredModelField: View {
    @Binding var selection: String
    let modelIDs: [String]
    let isEnabled: Bool
    let usesQuickSetupStyle: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                if usesQuickSetupStyle {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }

                Text(L10n.tr("Default Model", table: .providers))
                    .font(OriveoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(
                        usesQuickSetupStyle
                            ? OriveoTheme.Palette.textSecondary
                            : OriveoTheme.Palette.textPrimary
                    )
            }
            .padding(.leading, usesQuickSetupStyle ? 2 : 0)

            Menu {
                Picker("", selection: $selection) {
                    ForEach(modelIDs, id: \.self) { modelID in
                        Text(modelID).tag(modelID)
                    }
                }
                .labelsHidden()
            } label: {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Text(selection.isEmpty ? (modelIDs.first ?? "") : selection)
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .frame(minHeight: 54)
                .frame(maxWidth: .infinity)
                .background {
                    let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
                    ZStack {
                        shape.fill(OriveoTheme.Palette.surfaceInset)
                        shape.fill(
                            OriveoTheme.Palette.primarySoft.opacity(colorScheme == .dark ? 0.68 : 0.62)
                        )
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(!isEnabled)
            .accessibilityLabel(L10n.tr("Default Model", table: .providers))

            Text(String(
                format: L10n.tr("Found %d model(s) in the catalog.", table: .providers),
                modelIDs.count
            ))
            .font(OriveoTheme.Typography.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, usesQuickSetupStyle ? 2 : 0)
        }
        .padding(usesQuickSetupStyle ? 0 : OriveoTheme.Spacing.xs)
        .opacity(isEnabled ? 1 : 0.66)
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
    var trailingActionTitle: String? = nil
    var trailingActionSystemImage: String? = nil
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
                if usesQuickSetupStyle, let leadingSystemImage {
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

                if let trailingActionTitle, let trailingActionSystemImage, let onTrailingAction {
                    Button(action: onTrailingAction) {
                        Label(trailingActionTitle, systemImage: trailingActionSystemImage)
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
                            text: $text,
                            prompt: Text(placeholder)
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

                if isSecure {
                    Button {
                        revealsSecureText.toggle()
                    } label: {
                        Image(systemName: revealsSecureText ? "eye.slash" : "eye")
                            .font(.system(size: 16, weight: .medium))
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
            .padding(.leading, OriveoTheme.Spacing.lg)
            .padding(.trailing, isSecure ? OriveoTheme.Spacing.xs : OriveoTheme.Spacing.lg)
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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: leadingSystemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(title)
                    .font(OriveoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
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

struct RelaySetupSecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(isEnabled ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .padding(.vertical, OriveoTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                    .fill(
                        isEnabled
                            ? OriveoTheme.Palette.primarySoft.opacity(configuration.isPressed ? 0.82 : 0.62)
                            : OriveoTheme.Palette.surfaceInset
                    )
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
