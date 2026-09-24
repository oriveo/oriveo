import SwiftUI

struct OriveoLabeledField: View {
    let title: String
    @Binding var text: String
    var placeholder: String
    var footnote: String?
    var isSecure: Bool = false
    var isEnabled: Bool = true

    @State private var revealsSecureText = false

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Text(title)
                .lineLimit(1)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            HStack(spacing: OriveoTheme.Spacing.sm) {
                Group {
                    if isSecure && !revealsSecureText {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!isEnabled)
                .foregroundStyle(isEnabled ? OriveoTheme.Palette.textPrimary : OriveoTheme.Palette.textTertiary)

                if isSecure {
                    Button {
                        revealsSecureText.toggle()
                    } label: {
                        Image(systemName: revealsSecureText ? "eye.slash" : "eye")
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    // Without a label VoiceOver reads the SF Symbol's system name ("Show"), which ignores the in-app language and never changes with state. The field holds API keys as well as passwords, so the label names neither.
                    .accessibilityLabel(revealsSecureText ? L10n.tr("Hide characters") : L10n.tr("Show characters"))
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .frame(height: 48)
            .oriveoRoundedSurface(
                fill: isEnabled ? OriveoTheme.Palette.surfaceInset : OriveoTheme.Palette.surface,
                border: isEnabled ? OriveoTheme.Palette.border : OriveoTheme.Palette.border.opacity(0.5),
                radius: 10,
                shadow: .none
            )

            if let footnote {
                Text(footnote)
                    .lineLimit(3)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
        }
    }
}
