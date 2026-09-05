import SwiftUI

struct GenerationParameterSupportedModelsPage: View {
    let provider: Provider
    let parameterID: String
    let parameterTitle: String
    let scope: GenerationParameterEntryScope

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if candidates.isEmpty {
                    Text(L10n.tr(
                        "No model in this connection accepts this parameter.",
                        table: .providers
                    ))
                    .font(.system(size: 13.5))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                } else {
                    Text(L10n.tr(
                        "These models in this connection accept this parameter.",
                        table: .providers
                    ))
                    .font(.system(size: 13.5))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { ModelControlHairline() }
                            HStack(spacing: 12) {
                                ProviderBadgeIcon(
                                    kind: provider.kind, size: 26, relayKind: provider.relayKind
                                )
                                Text(candidate.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                    }
                    .modelControlSurface()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(OriveoTheme.Palette.background)
        .navigationTitle(parameterTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var candidates: [AIModel] {
        provider.models.filter { candidate in
            let refs = GenerationParameterPanelPresentation.visibleParameters(
                provider: provider,
                model: candidate,
                scope: scope,
                identity: nil
            )
            guard let ref = refs.first(where: { $0.id == parameterID }) else { return false }
            return GenerationParameterSupportPresentation.entry(for: ref.support).control == .editable
        }
    }
}
