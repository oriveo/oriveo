import SwiftUI

struct HomeNotesEntryCard: View {
    let count: Int
    let latestTitle: String?
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var hasNotes: Bool { count > 0 }
    private var isDark: Bool { colorScheme == .dark }

    private let cardMinHeight: CGFloat = 96

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: OriveoTheme.Spacing.md) {
                iconTile

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        Text(L10n.tr("Notes", table: .notes))
                            .font(OriveoTheme.Typography.title2)
                            .foregroundStyle(AuroraTheme.Colors.textPrimary)
                        if hasNotes {
                            countBadge
                        }
                    }

                    Text(previewLine)
                        .font(AuroraTheme.Typography.body)
                        .foregroundStyle(AuroraTheme.Colors.textSecondary)
                        .lineLimit(hasNotes ? 1 : 2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: OriveoTheme.Spacing.sm)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AuroraTheme.Colors.accent.opacity(0.55))
            }
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.vertical, OriveoTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: cardMinHeight, alignment: .leading)
            .background(cardSurface)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.chip, style: .continuous)
            .fill(AuroraTheme.Colors.accent)
            .frame(width: 44, height: 44)
            .overlay {
                notebookGlyph(size: 23, color: .white)
            }
    }

    private func notebookGlyph(size: CGFloat, color: Color) -> some View {
        Image("NotesNotebook")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }

    private var countBadge: some View {
        Text("\(count)")
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(AuroraTheme.Colors.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(AuroraTheme.Colors.accent.opacity(isDark ? 0.26 : 0.15)))
    }

    private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)
        return tintColor
            .overlay(alignment: .bottomTrailing) {
                notebookGlyph(
                    size: 104,
                    color: AuroraTheme.Colors.accent.opacity(isDark ? 0.20 : 0.12)
                )
                .rotationEffect(.degrees(-8))
                .offset(x: 26, y: 24)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .clipShape(shape)
            .shadow(
                color: isDark ? Color.black.opacity(0.30) : AuroraTheme.Colors.accent.opacity(0.15),
                radius: isDark ? 10 : 14,
                y: isDark ? 5 : 6
            )
    }

    private var tintColor: Color {
        isDark ? Color(hex: 0x272140) : Color(hex: 0xE9E1FB)
    }

    private var previewLine: String {
        if hasNotes, let latestTitle, !latestTitle.isEmpty {
            return latestTitle
        }
        return L10n.tr("Save strong answers with their source, then return to them later.", table: .notes)
    }

    private var accessibilityText: String {
        let title = L10n.tr("Notes", table: .notes)
        if hasNotes {
            return title + ", " + String(format: L10n.tr("%d saved", table: .notes), count)
        }
        return title + ". " + L10n.tr("Save strong answers with their source, then return to them later.", table: .notes)
    }
}
