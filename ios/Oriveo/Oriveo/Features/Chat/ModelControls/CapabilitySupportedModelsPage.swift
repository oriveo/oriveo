import SwiftUI

struct CapabilitySupportedModelsPage: View {
    let provider: Provider
    let capability: String
    var title: String?
    let candidates: [AIModel]
    let onSelect: (AIModel) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header

                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 {
                            Rectangle()
                                .fill(OriveoTheme.Palette.textPrimary.opacity(0.06))
                                .frame(height: 0.5)
                                .padding(.leading, 54)
                        }
                        row(for: candidate)
                    }
                }
                .modelControlSurface()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .background(OriveoTheme.Palette.background)
        .navigationTitle(capabilityTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var capabilityTitle: String {
        if let title, !title.isEmpty { return title }
        switch capability {
        case "web": return L10n.tr("Web Search", table: .chat)
        case "reasoning": return L10n.tr("Thinking Mode", table: .chat)
        default: return L10n.tr("Advanced Settings")
        }
    }

    private var header: some View {
        ModelControlNote(
            text: L10n.tr(
                "These models in this connection support it automatically. Choosing one switches this conversation to that model.",
                table: .chat
            ),
            systemImage: "arrow.triangle.swap",
            tone: OriveoTheme.Palette.textSecondary
        )
        .padding(.horizontal, 4)
    }

    private func row(for candidate: AIModel) -> some View {
        Button {
            OriveoHaptic.select()
            onSelect(candidate)
        } label: {
            HStack(spacing: 12) {
                ProviderBadgeIcon(kind: provider.kind, size: 26, relayKind: provider.relayKind)

                Text(candidate.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(L10n.tr("Switch", table: .chat))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(L10n.tr("Switches this conversation to this model.", table: .chat)))
    }
}
