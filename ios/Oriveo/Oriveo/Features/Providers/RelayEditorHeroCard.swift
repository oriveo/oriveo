import SwiftUI

///   │  │ 🔗  https://api.example.com │ │  ← endpoint preview
struct RelayEditorHeroCard: View {
    let provider: Provider
    let displayName: String
    let endpointText: String?
    let relayKind: RelayKind
    let onEditName: () -> Void
    let onChangeKind: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var meta: RelayKindMeta {
        RelayKindMeta.meta(for: relayKind)
    }

    private var brandColor: Color { meta.tint }

    private var heroFill: Color {
        colorScheme == .dark
            ? brandColor.blended(with: OriveoTheme.Palette.surfaceElevated, fraction: 0.82)
            : brandColor.blended(with: .white, fraction: 0.88)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            heroBackground

            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                header
                metaRow
                if let text = endpointText, !text.isEmpty {
                    endpointPreview(text: text)
                } else {
                    endpointPlaceholder
                }
            }
            .padding(OriveoTheme.Spacing.xl)
        }
        .clipShape(RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                .stroke(brandColor.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: 1)
        )
        .shadow(color: brandColor.opacity(colorScheme == .dark ? 0.18 : 0.10), radius: 22, x: 0, y: 12)
    }

    // MARK: - Background

    private var heroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    heroFill,
                    OriveoTheme.Palette.surfaceElevated
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    brandColor.opacity(colorScheme == .dark ? 0.18 : 0.12),
                    Color.clear
                ],
                startPoint: .topTrailing,
                endPoint: .center
            )

            LinearGradient(
                colors: [
                    OriveoTheme.Palette.cardHighlight,
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            badgeIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(OriveoTheme.Typography.title1)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .truncationMode(.tail)

                Text(meta.title)
                    .font(OriveoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(brandColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)

            Button(action: onEditName) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(OriveoTheme.Palette.surfaceElevated.opacity(colorScheme == .dark ? 0.72 : 0.86))
                    )
                    .overlay(Circle().stroke(brandColor.opacity(0.16), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Edit"))
        }
    }

    private var badgeIcon: some View {
        ProviderBadgeIcon(
            kind: .relay,
            size: 56,
            relayKind: relayKind
        )
    }

    // MARK: - Meta Row

    private var metaRow: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            kindPill
            statusPill(provider.status)
            Spacer(minLength: 0)
        }
    }

    private var kindPill: some View {
        Button(action: onChangeKind) {
            HStack(spacing: 5) {
                Image(systemName: meta.systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(meta.title)
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(brandColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(brandColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
            )
            .overlay(
                Capsule()
                    .stroke(brandColor.opacity(0.22), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("Relay type", table: .providers))
    }

    private func statusPill(_ status: ProviderConnectionState) -> some View {
        let label: String
        let tint: Color
        let systemImage: String
        switch status {
        case .connected:
            label = L10n.tr("Connected", table: .providers)
            tint = OriveoTheme.Palette.success
            systemImage = "checkmark.circle.fill"
        case .syncing:
            label = L10n.tr("Syncing", table: .providers)
            tint = OriveoTheme.Palette.primary
            systemImage = "arrow.triangle.2.circlepath"
        case .issue:
            label = L10n.tr("Issue", table: .providers)
            tint = OriveoTheme.Palette.warning
            systemImage = "exclamationmark.triangle.fill"
        }
        return HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.14)))
    }

    // MARK: - Endpoint Preview

    private func endpointPreview(text: String) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(brandColor)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(brandColor.opacity(0.14))
                )

            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceElevated.opacity(colorScheme == .dark ? 0.62 : 0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(brandColor.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var endpointPlaceholder: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(OriveoTheme.Palette.surfaceInset)
                )

            Text(L10n.tr("No endpoint set", table: .providers))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset.opacity(colorScheme == .dark ? 0.62 : 0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(OriveoTheme.Palette.border.opacity(0.5), lineWidth: 0.5)
        )
    }
}
