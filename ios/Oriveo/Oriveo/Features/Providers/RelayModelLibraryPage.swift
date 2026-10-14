import SwiftUI

/// Detail page > model library subpage: hosts the "enabled models + model library + manual add" content moved out of the detail page as-is,
/// to be reworked later against the catalog board. The content is passed in by the detail page so it keeps its join-animation coordinate space, undo banner and capability test sheet.
/// Header: avatar + "Model Library" + "host · N models (· N keys)" + refresh (the existing full catalog refresh).
struct RelayModelLibraryPage<Content: View>: View {
    let provider: Provider
    let isRefreshing: Bool
    let onBack: () -> Void
    let onRefresh: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                OriveoBackButton(action: onBack)
                    .padding(.leading, -OriveoBackButton.edgeInset)
                if let avatar = RelayAvatarResolver.avatar(for: provider) {
                    RelayAvatarView(avatar: avatar, size: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Model Library", table: .providers))
                        .font(OriveoTheme.Typography.title2)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: subtitle)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        // When the host is long it wraps to a second line and then truncates at the tail, so the model count / key count in the middle are never cut off.
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Button(action: onRefresh) {
                    PhosphorIcon.arrowClockwise.image(.regular)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(isRefreshing ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .accessibilityLabel(L10n.tr("Refresh", table: .providers))
                // The tap target grows from 36 to 44pt; give the extra 4pt back so the icon does not move.
                .padding(.trailing, -4)
            }
            content()
        }
    }

    private var subtitle: String {
        let header = RelayCatalogBoardModel.libraryHeader(provider)
        var parts: [String] = []
        if !header.host.isEmpty { parts.append(header.host) }
        parts.append(L10n.format(L10n.tr(RelayDetailBoardModel.modelsCountKey), Int64(header.modelCount)))
        if let keyCount = header.keyCount {
            parts.append(String(format: L10n.tr(RelayKeysBoardModel.keysCountKey, table: .providers), Int64(keyCount)))
        }
        return parts.joined(separator: " · ")
    }
}
