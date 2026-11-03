import SwiftUI

struct NoteSourceBadge: View {
    let providerKind: ProviderKind?
    let modelName: String?
    let providerName: String?
    var size: CGFloat = 16

    private var label: String {
        modelName ?? providerName ?? providerKind?.displayName ?? ""
    }

    private var brand: Color {
        Self.textColor(for: providerKind)
    }

    /// Label color: provider text tint when the source provider is known, otherwise the theme's
    /// on-surface readable primary (same role as Android primaryTextSafe / Web --o-primary-text-on-surface).
    static func textColor(for providerKind: ProviderKind?) -> Color {
        guard let providerKind else { return OriveoTheme.Palette.primaryTextOnSurface }
        return ProviderTints.textTint(for: providerKind.rawValue, fallbackId: "")
    }

    var body: some View {
        HStack(spacing: 5) {
            if let providerKind {
                // Notes do not remember the connection: relay sources are always generic
                ConnectionAvatarIcon(provider: nil, kind: providerKind, size: size)
            }
            if !label.isEmpty {
                Text(label)
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(brand)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
