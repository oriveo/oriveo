import SwiftUI

/// The fixed Notes entry card on Home, built from the same material as the hero composer card
/// (AuroraHeroSurface with a single soft glow top-right).
///
/// Left: `Notes` 17/semibold, the count (monospaced accent, baseline aligned) and the title of the
/// most recent note (single line, truncated).
/// Right: the Lucide notebook-pen line glyph at 40pt (without the binder ticks, see notebookGlyph),
/// tinted with a #C4B5FD → #EC8FEA → #8DB4FF linear gradient.
/// No chevron, no count badge, no watermark, no solid icon tile; the whole card opens the notes list.
struct HomeNotesEntryCard: View {
    let count: Int
    /// Title of the most recently updated note (`noteSummaries` sorted by updatedAt DESC, `.first`).
    /// nil when there are no notes.
    let latestTitle: String?
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var hasNotes: Bool { count > 0 }

    private static let cornerRadius: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        Button(action: onOpen) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L10n.tr("Notes", table: .notes))
                            .font(.system(size: 17, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(AuroraTheme.Colors.textPrimary)
                            .lineLimit(1)
                        if hasNotes {
                            Text("\(count)")
                                .font(AuroraTheme.Typography.countMono)
                                .foregroundStyle(AuroraTheme.Colors.accent)
                        }
                    }
                    // Line heights are 22 / 18 (SF's natural line heights are about 20 / 15.3);
                    // without padding the line boxes the card ends up 4pt short.
                    .frame(minHeight: 22)

                    Text(previewLine)
                        .font(.system(size: 13))
                        .foregroundStyle(AuroraTheme.Colors.textSecondary)
                        // With notes: the latest title on one truncated line. Empty state: the invitation
                        // may take two lines, half a sentence would not be readable.
                        .lineLimit(hasNotes ? 1 : 2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 18, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                notebookGlyph
            }
            // A 1px border plus padding 16/18/16/20 (border-box): content sits 1pt further from each edge.
            .padding(.top, 17)
            .padding(.trailing, 19)
            .padding(.bottom, 17)
            .padding(.leading, 21)
            .background(AuroraHeroSurface(cornerRadius: Self.cornerRadius, glow: .notesCorner))
            // In dark mode the same aurora crown as the hero, one step weaker, without the near-white hot
            // core and without the halo outside the card: Notes does not compete with the hero.
            .overlay {
                if colorScheme == .dark {
                    AuroraCrownRim(cornerRadius: Self.cornerRadius, scale: AuroraCrown.notesRimScale, hotCore: false)
                } else {
                    shape.strokeBorder(AuroraHeroSurface.rim(isDark: false), lineWidth: 1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    /// The notebook line glyph: the NotesNotebookLine template vector (stroke 1.6 on a 24 grid).
    /// The gradient is defined in objectBoundingBox terms, so the zero-height binder ticks would never
    /// pick up colour and the body is filled across its own bounding box (4,2)→(20,22). The asset
    /// therefore omits the ticks, and the gradient endpoints follow the body's bounding box rather
    /// than the full 24 grid.
    private var notebookGlyph: some View {
        Image("NotesNotebookLine")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0xC4B5FD), location: 0),
                        .init(color: Color(hex: 0xEC8FEA), location: 0.5),
                        .init(color: Color(hex: 0x8DB4FF), location: 1),
                    ],
                    startPoint: UnitPoint(x: 4.0 / 24, y: 2.0 / 24),
                    endPoint: UnitPoint(x: 20.0 / 24, y: 22.0 / 24)
                )
            )
            .accessibilityHidden(true)
    }

    private var previewLine: String {
        Self.previewLine(count: count, latestTitle: latestTitle)
    }

    private var accessibilityText: String {
        Self.accessibilityText(count: count, latestTitle: latestTitle)
    }

    /// With notes: the latest title. Empty state (or a latest note without a title): the invitation
    /// copy, reusing the existing key.
    static func previewLine(count: Int, latestTitle: String?) -> String {
        if count > 0, let latestTitle, !latestTitle.isEmpty {
            return latestTitle
        }
        return L10n.tr("Save strong answers with their source, then return to them later.", table: .notes)
    }

    /// When there are notes, VoiceOver also reads the latest title shown on the card, so the spoken and
    /// visible information match.
    static func accessibilityText(count: Int, latestTitle: String?) -> String {
        let title = L10n.tr("Notes", table: .notes)
        if count > 0 {
            let saved = title + ", " + String(format: L10n.tr("%d saved", table: .notes), count)
            guard let latestTitle, !latestTitle.isEmpty else { return saved }
            return saved + ", " + latestTitle
        }
        return title + ". " + L10n.tr("Save strong answers with their source, then return to them later.", table: .notes)
    }
}
