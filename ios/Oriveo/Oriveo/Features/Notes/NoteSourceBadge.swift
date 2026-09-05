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
        ProviderTints.tint(for: providerKind?.rawValue ?? "")
    }

    var body: some View {
        HStack(spacing: 5) {
            if let providerKind {
                ProviderBadgeIcon(kind: providerKind, size: size)
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
