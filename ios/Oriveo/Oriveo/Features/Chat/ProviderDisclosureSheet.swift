import SwiftUI

struct ProviderDisclosureSheet: View {
    let provider: ProviderKind
    let onAccept: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 28)
                .padding(.bottom, 16)

            Text(String(format: L10n.tr("You're about to use %@", table: .chat), provider.displayName))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Text(bodyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

            if let policyURL = provider.privacyPolicyURL {
                Link(destination: policyURL) {
                    HStack(spacing: 4) {
                        Text(String(format: L10n.tr("View %@ privacy policy", table: .chat), provider.displayName))
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.bottom, 20)
            }

            VStack(spacing: 12) {
                Button {
                    onAccept()
                    dismiss()
                } label: {
                    Text(L10n.tr("Continue"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Text(L10n.tr("Cancel"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .interactiveDismissDisabled()
    }

    private var bodyText: String {
        switch provider {
        case .relay:
            return L10n.tr("Your message will be sent to the custom endpoint you've configured. Oriveo cannot verify the privacy practices of third-party endpoints.", table: .chat)
        default:
            return String(
                format: L10n.tr("Your message will be sent to %@ to generate a response. Oriveo does not store your messages or API keys on our servers.", table: .chat),
                provider.displayName
            )
        }
    }
}
