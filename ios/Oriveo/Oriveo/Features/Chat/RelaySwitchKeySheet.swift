import SwiftUI

// MARK: - Chat "Switch key"
//
// The condition is derived only from persisted model state (`relayDeniedKeyID` + the catalog alternates), and no field is added to messages;
// the selection is written back through `rebind`, the panel closes, and nothing is resent automatically (the user taps the existing retry).

enum RelaySwitchKey {
    static let buttonKey = "Switch key"
    static let titleKey = "Use another key for %@"
    static let hintKey = "These keys list this model. Send again after switching."

    struct Option: Equatable, Identifiable, Sendable {
        let id: String
        /// Name or mask (the same read model as the keys page).
        let title: String
        let maskedSecret: String
    }

    struct Offer: Equatable, Identifiable, Sendable {
        let providerID: UUID
        let modelID: String
        let modelName: String
        let options: [Option]

        var id: String { "\(providerID.uuidString)/\(modelID)" }
    }

    /// Show the button when: a failed assistant message, its model is still enabled on that relay connection, the current key is judged to have no access, and another key lists it.
    static func offer(for message: ChatMessage, providers: [Provider]) -> Offer? {
        guard message.role == .assistant, message.state == .failed,
              let providerID = message.providerID, let modelID = message.modelID,
              let provider = providers.first(where: { $0.id == providerID }), provider.kind == .relay,
              let model = provider.models.first(where: { $0.id == modelID }),
              let state = RelayKeyBinding.modelState(provider, modelID: modelID),
              state.deniedOnCurrentKey, !state.alternateKeyIDs.isEmpty else { return nil }
        let rows = RelayKeysBoardModel.make(provider).rows
        let options = state.alternateKeyIDs.compactMap { keyID in
            rows.first { $0.id == keyID }.map { Option(id: $0.id, title: $0.title, maskedSecret: $0.maskedSecret) }
        }
        guard !options.isEmpty else { return nil }
        return Offer(providerID: providerID, modelID: modelID, modelName: model.name, options: options)
    }

    /// Select a key: `rebind` (which also clears the no-access flag); no resend.
    @discardableResult
    static func select(_ offer: Offer, keyID: String, manager: ProviderManager) async -> Bool {
        guard offer.options.contains(where: { $0.id == keyID }) else { return false }
        return await manager.applyRelayKeyOperation(
            providerID: offer.providerID,
            .rebind(modelID: offer.modelID, keyID: keyID)
        )
    }
}

/// Switch-key panel: title "Switch key for <model>" + explanation + each alternate (name or mask + mask).
struct RelaySwitchKeySheet: View {
    let offer: RelaySwitchKey.Offer
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            Text(String(format: L10n.tr(RelaySwitchKey.titleKey, table: .providers), offer.modelName))
                .font(OriveoTheme.Typography.title3.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr(RelaySwitchKey.hintKey, table: .providers))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(offer.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        onSelect(option.id)
                        dismiss()
                    } label: {
                        HStack(spacing: OriveoTheme.Spacing.sm) {
                            PhosphorIcon.key.image(.regular)
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: option.title)
                                    .font(OriveoTheme.Typography.body)
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if option.title != option.maskedSecret {
                                    Text(verbatim: option.maskedSecret)
                                        .font(OriveoTheme.Typography.footnote.monospaced())
                                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                        .lineLimit(1)
                                        .environment(\.layoutDirection, .leftToRight)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, OriveoTheme.Spacing.md)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < offer.options.count - 1 {
                        Rectangle()
                            .fill(OriveoTheme.Palette.border.opacity(0.45))
                            .frame(height: 0.5)
                            .padding(.leading, OriveoTheme.Spacing.md)
                    }
                }
            }
            .oriveoRoundedSurface(
                fill: OriveoTheme.Palette.surfaceElevated,
                border: OriveoTheme.Palette.border.opacity(0.66),
                radius: OriveoTheme.Radius.lg,
                shadow: .soft
            )

            Spacer(minLength: 0)
        }
        // Custom sheet without a navigation bar: 24pt of top padding.
        .padding(.top, 24)
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oriveoScreenBackground()
    }
}
