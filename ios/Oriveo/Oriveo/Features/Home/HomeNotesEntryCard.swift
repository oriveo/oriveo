import SwiftUI

/// Home Notes entry: the left half of the two-card row.
///
/// Title + count, then the latest note title (or the invitation copy), with a stack of three
/// tilted paper sheets peeking out of the bottom edge. Colours are fixed (they do not follow the theme);
/// the illustration is hidden from VoiceOver. The whole card opens the notes list.
struct HomeNotesEntryCard: View {
    let count: Int
    /// Title of the most recently updated note (noteSummaries sorted by updatedAt DESC, `.first`); nil without notes.
    let latestTitle: String?
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var hasPreviewTitle: Bool { Self.subtitle(count: count, latestTitle: latestTitle) != nil }
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                paperStack
                VStack(alignment: .leading, spacing: 2) {
                    AuroraTitleCount(
                        title: L10n.tr("Notes", table: .notes),
                        titleFont: HomeEntryCardStyle.titleFont,
                        count: count,
                        spacing: 6,
                        titleColor: HomeEntryCardStyle.titleInk(isDark),
                        countColor: HomeEntryCardStyle.countInk(isDark)
                    )
                    .lineLimit(1)
                    .frame(minHeight: 21)

                    // "Recently edited" only when the latest note has a title; the title itself sits on the pinned sheet
                    if let subtitle = Self.subtitle(count: count, latestTitle: latestTitle) {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(HomeEntryCardStyle.subtitleInk(isDark))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minHeight: 16, alignment: .leading)
                    }
                }
                .padding(.vertical, 15)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .modifier(HomeEntryCardChrome(bottomTint: isDark ? Color(hex: 0x2B1B28) : Color(hex: 0xFFF1F6)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    /// Three sheets (back to front), positioned from the card's bottom-left like the canvas
    /// (left / bottom overflow / size / rotation); only the front one carries the pushpin and ruled lines.
    private var paperStack: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDark ? Color(hex: 0x562B44) : Color(hex: 0xFBD3E5))
                .opacity(isDark ? 0.8 : 0.75)
                .frame(width: 116, height: 96)
                .rotationEffect(.degrees(-11))
                .offset(x: 44, y: 32)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDark ? Color(hex: 0x3A2633) : Color(hex: 0xFFE6F0))
                .frame(width: 118, height: 96)
                .rotationEffect(.degrees(6))
                .offset(x: 38, y: 27)

            frontSheet
                .rotationEffect(.degrees(-3))
                .offset(x: 30, y: 22)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var frontSheet: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let line = isDark ? Color.white.opacity(0.09) : Color(hex: 0xF2E7ED)
        return VStack(alignment: .leading, spacing: 7) {
            // Latest note title; without notes (or without a title) the invitation copy, up to two lines
            Text(previewLine)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isDark ? Color(hex: 0xEDEBF2) : Color(hex: 0x3F3F46))
                .lineLimit(hasPreviewTitle ? 1 : 2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule().fill(line).frame(height: 2).frame(maxWidth: .infinity, alignment: .leading)
            Capsule().fill(line).frame(width: 98 * 0.74, height: 2)
            Capsule().fill(line).frame(width: 98 * 0.5, height: 2)
        }
        .padding(.top, 15)
        .padding(.horizontal, 12)
        .frame(width: 122, height: 96, alignment: .topLeading)
        .background(shape.fill(isDark ? Color(hex: 0x2A252E) : Color.white))
        .overlay(alignment: .topLeading) {
            // Pushpin drawn in sheet coordinates; the head rises above the top edge, never clipped
            HomeNotesPushpinView(isDark: isDark)
        }
        .shadow(color: isDark ? Color.black.opacity(0.8) : Color(hex: 0xDB2777).opacity(0.32), radius: 8, y: 10) // capability-ui-lint: allow notes entry card pink accent, not a capability colour
    }

    private var previewLine: String {
        Self.previewLine(count: count, latestTitle: latestTitle)
    }

    private var accessibilityText: String {
        Self.accessibilityText(count: count, latestTitle: latestTitle)
    }

    /// Card subtitle: "Recently edited" when the latest note has a title, otherwise none.
    static func subtitle(count: Int, latestTitle: String?) -> String? {
        guard count > 0, let latestTitle, !latestTitle.isEmpty else { return nil }
        return L10n.tr("skills.home.notesRecent", table: .skills)
    }

    /// With notes: the latest title. Empty state (or a latest note without a title): the invitation copy, reusing the existing key.
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

/// Shared values of the two home entry cards (fixed colours, never themed).
enum HomeEntryCardStyle {
    static let height: CGFloat = 150
    static let cornerRadius: CGFloat = 22
    static let spacing: CGFloat = 12
    static let titleFont = Font.system(size: 16, weight: .semibold)

    static func titleInk(_ isDark: Bool) -> Color { isDark ? Color(hex: 0xF4F3F7) : Color(hex: 0x18181B) }
    static func countInk(_ isDark: Bool) -> Color { isDark ? Color(hex: 0x858091) : Color(hex: 0x9A96A6) }
    static func subtitleInk(_ isDark: Bool) -> Color { isDark ? Color(hex: 0x8E899A) : Color(hex: 0x8A8594) }
}

/// Card surface: top-to-bottom wash ending in the card's tint, soft drop shadow, clipped; no outline,
/// the surface alone separates it from the page.
struct HomeEntryCardChrome: ViewModifier {
    let bottomTint: Color

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: HomeEntryCardStyle.cornerRadius, style: .continuous)
        let base = isDark ? Color(hex: 0x1F1D24) : Color.white
        return content
            .frame(maxWidth: .infinity)
            .frame(height: HomeEntryCardStyle.height)
            .background(
                LinearGradient(
                    stops: [.init(color: base, location: 0.38), .init(color: bottomTint, location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(shape)
            .shadow(color: isDark ? Color.black.opacity(0.45) : Color(hex: 0x281E50).opacity(0.16), radius: 10, y: 12)
            .contentShape(shape)
    }
}

/// Pushpin on the front notes sheet: round pink head, a short visible metal needle, a soft shadow
///. Coordinates are in the 122x96 front sheet's own space;
/// decorative illustration, never themed, rotates with the sheet.
enum HomeNotesPushpin {
    static let headDiameter: CGFloat = 11
    /// Distance from the head centre to the pierce point.
    static let needleLength: CGFloat = 9
    /// Tilt of the needle towards the top-left, measured from vertical.
    static let tiltDegrees: Double = 24
    /// Where the needle enters the paper.
    static let pierce = CGPoint(x: 61, y: 10)
    static let needleWidth: CGFloat = 1.2
    static let needleColor: UInt32 = 0xA1A1AA
    /// Radial head gradient, light to dark; same in light and dark appearance.
    static let headColors: [UInt32] = [0xFBCFE8, 0xEC4899, 0x9D174D] // capability-ui-lint: allow notes entry card pink accent, not a capability colour
    static let headStops: [CGFloat] = [0, 0.45, 1]
    /// Gradient centre in the head's unit space; radius is the diameter times `headGradientRadiusScale`.
    static let headGradientCenter = UnitPoint(x: 0.35, y: 0.30)
    static let headGradientRadiusScale: CGFloat = 0.75
    static let highlightDiameter: CGFloat = 3
    static let highlightOffset = CGSize(width: -2, height: -2.2)
    static let shadowOffset = CGSize(width: 2.2, height: 2.6)
    static let shadowBlur: CGFloat = 1.6
    static let holeDiameter: CGFloat = 1.6

    /// Head centre = pierce + (-L * sin(tilt), -L * cos(tilt)).
    static func headCenter(pierce: CGPoint) -> CGPoint {
        let radians = tiltDegrees * .pi / 180
        return CGPoint(
            x: pierce.x - needleLength * CGFloat(sin(radians)),
            y: pierce.y - needleLength * CGFloat(cos(radians))
        )
    }

    static func shadowOpacity(_ isDark: Bool) -> Double { isDark ? 0.45 : 0.22 }
    static func highlightOpacity(_ isDark: Bool) -> Double { isDark ? 0.70 : 0.85 }
    static func holeOpacity(_ isDark: Bool) -> Double { isDark ? 0.40 : 0.28 }
}

/// Layers bottom to top: shadow, pierce hole, needle, head, highlight. Lays out at the sheet's top-leading corner.
struct HomeNotesPushpinView: View {
    let isDark: Bool

    var body: some View {
        let pierce = HomeNotesPushpin.pierce
        let head = HomeNotesPushpin.headCenter(pierce: pierce)
        let diameter = HomeNotesPushpin.headDiameter
        let shadow = CGPoint(x: head.x + HomeNotesPushpin.shadowOffset.width, y: head.y + HomeNotesPushpin.shadowOffset.height)
        let highlight = CGPoint(x: head.x + HomeNotesPushpin.highlightOffset.width, y: head.y + HomeNotesPushpin.highlightOffset.height)
        let stops = zip(HomeNotesPushpin.headColors, HomeNotesPushpin.headStops).map { Gradient.Stop(color: Color(hex: UInt($0)), location: $1) }
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(Color.black.opacity(HomeNotesPushpin.shadowOpacity(isDark)))
                .blur(radius: HomeNotesPushpin.shadowBlur)
                .modifier(HomeNotesPushpinPlacement(center: shadow, diameter: diameter))
            Circle()
                .fill(Color.black.opacity(HomeNotesPushpin.holeOpacity(isDark)))
                .modifier(HomeNotesPushpinPlacement(center: pierce, diameter: HomeNotesPushpin.holeDiameter))
            Path { path in
                path.move(to: pierce)
                path.addLine(to: head)
            }
            .stroke(Color(hex: UInt(HomeNotesPushpin.needleColor)), style: StrokeStyle(lineWidth: HomeNotesPushpin.needleWidth, lineCap: .round))
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: stops),
                        center: HomeNotesPushpin.headGradientCenter,
                        startRadius: 0,
                        endRadius: diameter * HomeNotesPushpin.headGradientRadiusScale
                    )
                )
                .modifier(HomeNotesPushpinPlacement(center: head, diameter: diameter))
            Circle()
                .fill(Color.white.opacity(HomeNotesPushpin.highlightOpacity(isDark)))
                .modifier(HomeNotesPushpinPlacement(center: highlight, diameter: HomeNotesPushpin.highlightDiameter))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Places a circle of `diameter` so its centre lands on `center` in the top-leading coordinate space.
private struct HomeNotesPushpinPlacement: ViewModifier {
    let center: CGPoint
    let diameter: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: diameter, height: diameter)
            .offset(x: center.x - diameter / 2, y: center.y - diameter / 2)
    }
}
