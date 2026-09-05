import SwiftUI

struct NoteCard: View {
    let summary: NoteSummary

    private let preview: AttributedString

    init(summary: NoteSummary) {
        self.summary = summary
        self.preview = NoteText.previewAttributed(from: summary.body)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var brand: Color {
        summary.showsSourceBadge
            ? ProviderTints.tint(for: summary.sourceProviderKind?.rawValue ?? "")
            : OriveoTheme.Palette.primary
    }

    static func quoteWatermarkOpacity(isDark: Bool, hasSource: Bool, large: Bool = false) -> Double {
        if large {
            return isDark ? (hasSource ? 0.18 : 0.12) : (hasSource ? 0.10 : 0.045)
        }
        return isDark ? (hasSource ? 0.13 : 0.10) : (hasSource ? 0.06 : 0.03)
    }

    private var previewIsEmpty: Bool {
        preview.characters.isEmpty
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cardSurface
            ambientLayer
            VStack(alignment: .leading, spacing: 14) {
                metadataBar
                titleText
                excerptPanel
                if !summary.tags.isEmpty {
                    tagRow
                        .padding(.top, 1)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: brand.opacity(summary.showsSourceBadge ? 0.12 : 0.05), radius: 20, x: 0, y: 10)
        .shadow(color: OriveoTheme.Palette.shadow.opacity(0.84), radius: 12, x: 0, y: 5)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.dynamic(light: 0xFEFEFC, dark: 0x252937),
                        OriveoTheme.Palette.surface
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                OriveoTheme.Palette.hairline,
                                brand.opacity(summary.showsSourceBadge ? 0.08 : 0.04),
                                OriveoTheme.Palette.border.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(OriveoTheme.Palette.glassHighlight.opacity(0.72))
                    .frame(height: 56)
                    .mask(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
    }

    private var ambientLayer: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(brand.opacity(summary.showsSourceBadge ? 0.13 : 0.035))
                .frame(width: 132, height: 132)
                .blur(radius: 30)
                .offset(x: -244, y: -52)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            brand.opacity(summary.showsSourceBadge ? 0.045 : 0.018)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var metadataBar: some View {
        HStack(alignment: .center, spacing: 8) {
            sourceToken
            Spacer(minLength: 8)
            pinMark
            dateToken
            detailGlyph
        }
    }

    @ViewBuilder
    private var sourceToken: some View {
        if summary.showsSourceBadge {
            NoteSourceBadge(
                providerKind: summary.sourceProviderKind,
                modelName: summary.sourceModelName,
                providerName: summary.sourceProviderName,
                size: 14
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(brand.opacity(0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(brand.opacity(0.08), lineWidth: 1)
                    )
            )
            .layoutPriority(1)
        } else {
            manualToken
        }
    }

    private var manualToken: some View {
        HStack(spacing: 5) {
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .semibold))
            Text(L10n.tr("Notes", table: .notes))
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
        }
        .foregroundStyle(OriveoTheme.Palette.textTertiary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset.opacity(0.68))
        )
    }

    @ViewBuilder
    private var pinMark: some View {
        if summary.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.onPrimary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(OriveoTheme.Palette.primaryPressed)
                        .shadow(color: OriveoTheme.Palette.primary.opacity(0.20), radius: 7, y: 3)
                )
                .accessibilityLabel(L10n.tr("Pinned", table: .notes))
        }
    }

    private var dateToken: some View {
        Text(NoteText.mediumDate(summary.updatedAt))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceInset.opacity(0.72))
            )
    }

    private var detailGlyph: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(OriveoTheme.Palette.textTertiary.opacity(0.62))
            .frame(width: 18, height: 26)
    }

    private var titleText: some View {
        Text(NoteText.displayTitle(summary.title))
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .lineSpacing(2)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var excerptPanel: some View {
        Text(previewIsEmpty ? AttributedString(L10n.tr("Nothing written yet.", table: .notes)) : preview)
            .font(.system(size: 15.5, weight: .regular))
            .foregroundStyle(previewIsEmpty ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.textSecondary)
            .lineSpacing(5)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 40)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OriveoTheme.Palette.surfaceInset.opacity(0.78),
                                brand.opacity(summary.showsSourceBadge ? 0.035 : 0.015)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(brand.opacity(Self.quoteWatermarkOpacity(isDark: colorScheme == .dark, hasSource: summary.showsSourceBadge)))
                            .rotationEffect(.degrees(180))
                            .offset(x: -12, y: 9)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(OriveoTheme.Palette.hairline.opacity(0.46), lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    private var tagRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(summary.tags.prefix(2)), id: \.self) { tag in
                NoteTagChip(
                    tag: tag,
                    brand: brand,
                    hasSource: summary.showsSourceBadge
                )
            }
            if summary.tags.count > 2 {
                Text("+\(summary.tags.count - 2)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OriveoTheme.Palette.surfaceInset.opacity(0.72))
                    )
            }
        }
    }

}
