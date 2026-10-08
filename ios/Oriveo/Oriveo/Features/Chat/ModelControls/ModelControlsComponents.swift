import SwiftUI

// MARK: - Surface

/// The panel's hierarchy relies **only on background contrast, spacing and a very light shadow**; nothing is outlined.
///
/// Outlines stack up quickly: a frame around the card, another around each pill inside it, and a tinted block behind the notes
/// turn the page into a grid. Without them, both themes separate layers through the luminance difference between surface
/// and background, so a card reads as floating on the page rather than drawn on it.
extension View {
    func modelControlSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(ModelControlSurface(cornerRadius: cornerRadius))
    }
}

private struct ModelControlSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    /// Dark mode uses `surfaceElevated` (#252937) instead of `surface` (#1B1F2A): against the page background
    /// #14181F the latter differs by only 3.7 in L*, and a black shadow on a near-black background is almost invisible, so the
    /// separation in dark mode rests on that color difference alone. With the elevated color the difference is 8.6.
    /// Light mode stays as it is: a white card is already at the top of the range, and its separation comes from the shadow.
    private var fill: Color {
        colorScheme == .dark ? OriveoTheme.Palette.surfaceElevated : OriveoTheme.Palette.surface
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.045),
                radius: colorScheme == .dark ? 10 : 14,
                y: colorScheme == .dark ? 3 : 5
            )
    }
}

// MARK: - Labels

/// The single mapping of level labels. The composer's accessibility summary and the panel must say the same thing,
/// or VoiceOver reads a level that differs from the one on screen.
///
/// The vocabulary is fixed. The first thinking level is called `Automatic` rather than "provider default":
/// the latter is a protocol-side term, and a user cannot tell that it sits on the same axis as "Fast".
/// The other levels (Off / Fast / Balanced / Deep / Max) and the web search values keep their names.
/// Enum values are unaffected; only the presentation is fixed.
///
/// `key(_:)` and `text(_:)` are separate so a test can pin the vocabulary directly:
/// on a zh-Hans simulator `L10n.tr` returns the translation, which can never be looked up in the catalog again,
/// and the assertion would depend on the locale it runs in rather than on whether the vocabulary changed.
enum ModelControlIntentLabel {
    /// intent → (catalog key, its table). An unknown intent returns nil (echoed as is; no word is made up).
    static func key(_ intent: String) -> (key: String, table: L10n.Table)? {
        switch intent {
        // The first item that is always in the single-choice list: selecting it injects no level. The composer's
        // accessibility summary reads the same item, and both places must use the same word.
        case ModelOptionCapabilityShape.automaticIntent: return ("Automatic", .localizable)
        case "off": return ("Off", .localizable)
        case "low": return ("Fast", .providers)
        case "balanced": return ("Balanced", .localizable)
        case "deep": return ("Deep", .providers)
        case "max": return ("Max", .providers)
        default: return nil
        }
    }

    static func text(_ intent: String) -> String {
        guard let entry = key(intent) else { return intent }
        return L10n.tr(entry.key, table: entry.table)
    }

    /// The web search vocabulary matches the two "search timing" segments in the panel.
    ///
    /// One value must not have two names across the read-only status row, the VoiceOver summary and the segments;
    /// a user would read them as different concepts. All three say
    /// "Search when needed / Search every message": they always appear under the "Web search" title and need no subject of their own.
    static func webKey(_ preference: CapabilityWebPreference) -> (key: String, table: L10n.Table) {
        switch preference {
        case .inherit: return ("When needed", .chat)
        case .off: return ("Off", .localizable)
        case .automatic: return ("When needed", .chat)
        case .force: return ("Every message", .chat)
        case .custom: return ("Custom", .chat)
        }
    }

    static func webText(_ preference: CapabilityWebPreference) -> String {
        let entry = webKey(preference)
        return L10n.tr(entry.key, table: entry.table)
    }
}

// MARK: - Wrapping layout

/// A simple flow layout that wraps when the width runs out. SwiftUI has none built in; the header line (connection · protocol · seal)
/// wraps with it on narrow screens or at large text sizes instead of truncating.
struct ModelControlWrappingLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7
    var layoutDirection: LayoutDirection = .leftToRight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth == .infinity ? width : maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        let rows = rows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = layoutDirection == .rightToLeft ? bounds.maxX : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    anchor: UnitPoint(
                        x: layoutDirection == .rightToLeft ? 1 : 0,
                        y: 0
                    ),
                    proposal: ProposedViewSize(size)
                )
                x += (size.width + spacing) * (layoutDirection == .rightToLeft ? -1 : 1)
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let additional = current.indices.isEmpty ? size.width : size.width + spacing
            if !current.indices.isEmpty, current.width + additional > maxWidth {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width += additional
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Hairline

/// The hairline between rows. Hierarchy comes from backgrounds and separators, not from borders.
struct ModelControlHairline: View {
    var leadingInset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.textPrimary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
    }
}

// MARK: - Promoting a conversation change to the default

/// The row that appears after a change made inside a conversation.
///
/// A permanent header line saying "these settings only apply to this conversation" asks the user to understand a
/// scope model before changing anything, and says nothing at the moment it matters: right after a change the user wants to keep.
/// So the row appears **after the fact**, and "Set as default" is an action that can be tapped right there.
///
/// **The confirmation must be an inline state change, not a toast.** The `ToastManager` overlay sits below
/// modals, so a toast raised from inside a sheet is never seen.
/// The row therefore turns into a "Set as default" confirmation itself, and the caller fades it out after a few seconds.
///
/// Because the panel is as tall as its content, the row is not pinned to a fixed bottom area: placed last, it is
/// always visible. It has neither a card surface nor a tinted background; it is a line of text with an action.
struct ModelControlScopeUpgradeRow: View {
    let isConfirmed: Bool
    let action: () -> Void

    var body: some View { content }

    private var content: some View {
        HStack(spacing: 8) {
            if isConfirmed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                Text(L10n.tr("New conversations with this model will use these settings.", table: .chat))
                    .font(.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(L10n.tr("Applied to this conversation", table: .chat))
                    .font(.caption)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button {
                    OriveoHaptic.select()
                    action()
                } label: {
                    Text(L10n.tr("Set as default for this model", table: .chat))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notes & rows

/// Explanatory text inside a card. Reasons for every unavailable state, and cost and privacy notices, all use it, with one specification.
/// **No tinted block behind it**: one block per note means three blocks for three notes, the boxed look this page avoids.
struct ModelControlNote: View {
    let text: String
    var systemImage: String?
    var tone: Color = OriveoTheme.Palette.textTertiary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tone)
                    .frame(width: 13)
                    .padding(.top, 1.5)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A secondary entry inside a card (view supported models, custom fields). It is separated by a very light hairline,
/// not drawn as a tinted button, which would add one more box to every card.
struct ModelControlInlineActionLabel: View {
    let title: String
    let systemImage: String
    /// The default color has the same source as the selected level and the toggle. As **text**, the plain `primary` reaches only 4.11:1 in light mode,
    /// and this row is a tappable piece of text.
    var tint: Color = OriveoTheme.Palette.primaryTextSafe
    var detail: String?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(OriveoTheme.Palette.textPrimary.opacity(0.06))
                .frame(height: 0.5)
                .padding(.bottom, 11)

            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .frame(minHeight: 30)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Parts of the model options panel

/// Group heading ("Capabilities", "Parameters").
struct ModelOptionSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Row title.
struct ModelOptionRowTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Explanatory text in a row: the sentence under the title, the one at the top right, the paragraph under the segments. Same specification for all.
struct ModelOptionCaption: View {
    let text: String
    var color: Color = OriveoTheme.Palette.textSecondary
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Status text at the end of a row ("This model has no thinking mode").
struct ModelOptionStatusText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The chevron at the end of a row: the row can be tapped.
struct ModelOptionChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .accessibilityHidden(true)
    }
}

/// A text link inside the card ("Open additional request body").
struct ModelOptionLinkLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// The status seal under the title: a small dot and a few words.
struct ModelOptionSealLabel: View {
    let seal: ModelOptionsSeal

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            Text(seal.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(textColor)
        }
        .accessibilityElement(children: .combine)
    }

    private var dotColor: Color {
        switch seal {
        case .officialConfiguration: return OriveoTheme.Palette.success
        case .unverified: return OriveoTheme.Palette.warning
        }
    }

    /// The text uses the text-safe variant: plain `success` as text on the light page background reaches only about 2.5:1.
    private var textColor: Color {
        switch seal {
        case .officialConfiguration: return Self.officialText
        case .unverified: return OriveoTheme.Palette.warningText
        }
    }

    static let officialText = Color.dynamic(light: 0x047857, dark: 0x6EE7A1)
}

/// The small icon of a thinking level: four bars from short to tall, with as many lit as the effort; Off is a horizontal dash,
/// Automatic a ring of rays. All drawn as fills, without strokes.
struct ModelOptionTierGlyph: View {
    let intent: String
    let isSelected: Bool

    /// How many bars this level lights; nil when it is not an effort level.
    static func filledBars(for intent: String) -> Int? {
        switch intent {
        case "low": return 1
        case "balanced": return 2
        case "deep": return 3
        case "max": return 4
        default: return nil
        }
    }

    private static let barHeights: [CGFloat] = [4, 7, 10, 13]

    var body: some View {
        Group {
            if let filled = Self.filledBars(for: intent) {
                HStack(alignment: .bottom, spacing: 2.5) {
                    ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { index, height in
                        Capsule(style: .continuous)
                            .fill(index < filled ? tint : OriveoTheme.Palette.textPrimary.opacity(0.2))
                            .frame(width: 3, height: height)
                    }
                }
            } else if intent == ModelOptionCapabilityShape.automaticIntent {
                Image(systemName: "rays")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.55))
                    .frame(width: 13, height: 2.5)
            }
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        isSelected ? ModelOptionSegmentedControl.selectedLabel : OriveoTheme.Palette.textSecondary
    }
}

/// The segmented choice in the panel: thinking levels (icon and text) and search timing (text only).
///
/// Every segment can be tapped; a level that cannot be chosen is never passed in. The selected segment is a raised light surface with purple text,
/// the track a very light gray, and neither is outlined.
struct ModelOptionSegmentedControl: View {
    let options: [ModelOptionCapabilityShape.Option]
    /// nil = no segment is highlighted.
    let selection: String?
    /// Thinking levels carry an icon and are tall; search timing has none and is short.
    var showsGlyphs = true
    /// Tapping the selected segment again clears the selection (back to never chosen).
    var allowsClearing = false
    let accessibilityTitle: String
    /// Returns the selected level; nil when the selection is cleared.
    let onSelect: (String?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.id == selection
                Button {
                    switch Self.tap(on: option.id, selection: selection, allowsClearing: allowsClearing) {
                    case .ignored:
                        break
                    case .cleared:
                        OriveoHaptic.select()
                        onSelect(nil)
                    case let .selected(id):
                        OriveoHaptic.select()
                        onSelect(id)
                    }
                } label: {
                    VStack(spacing: 6) {
                        if showsGlyphs {
                            ModelOptionTierGlyph(intent: option.id, isSelected: selected)
                        }
                        Text(option.label)
                            .font(.footnote.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Self.selectedLabel : unselectedLabelColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: showsGlyphs ? 52 : 38)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(selectedFill)
                                // In dark mode the selected segment is a translucent light layer; a shadow would show through from below and darken it, so it is drawn in light mode only.
                                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0 : 0.14), radius: 3, y: 1.5)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(option.label))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OriveoTheme.Palette.textPrimary.opacity(Self.trackAlpha(isDark: colorScheme == .dark)))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        // The animation above is only meant for the highlight. Without this barrier SwiftUI pushes
        // ancestor position and size changes down to the drawing leaves (track, pill, bars), each of
        // which applies the current animation to its own frame: while the sheet is still settling its
        // height and the selection changes in the same transaction, those shapes fly in from an
        // earlier layout while the labels are already in place. With the barrier this layer resolves
        // position and size first, and only the highlight animates inside it.
        .geometryGroup()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityTitle))
    }

    /// What happens after a segment is tapped.
    enum Tap: Equatable {
        case selected(String)
        /// The selected segment was tapped again: back to never chosen.
        case cleared
        case ignored
    }

    static func tap(on id: String, selection: String?, allowsClearing: Bool) -> Tap {
        guard id == selection else { return .selected(id) }
        return allowsClearing ? .cleared : .ignored
    }

    private var unselectedLabelColor: Color { OriveoTheme.Palette.textSecondary }

    /// Text and icon of the selected segment. Light mode uses the text-safe purple; dark mode one step brighter, since the selected segment
    /// is brighter than the track there and the dark value of `primaryTextSafe` on it reaches only about 3:1.
    static let selectedLabel = Color.dynamic(light: 0x6D28D9, dark: 0xD4C8FF)

    /// Background of the selected segment: a layer of white over the track. Opaque in light mode, a raised white surface; in dark mode only a thin layer,
    /// one step brighter than the track, which together with the shadow reads as raised rather than recessed.
    private var selectedFill: Color {
        Color.white.opacity(Self.selectedFillAlpha(isDark: colorScheme == .dark))
    }

    static func selectedFillAlpha(isDark: Bool) -> Double { isDark ? 0.12 : 1 }

    static func trackAlpha(isDark: Bool) -> Double { isDark ? 0.07 : 0.06 }
}

/// The only primary button in the card ("Choose protocol"). Both themes use the same deep purple with white text: a light purple
/// background in dark mode would not give white text enough contrast.
struct ModelOptionCalloutButtonLabel: View {
    let title: String

    static let fill = Color.dynamic(light: 0x6D28D9, dark: 0x6D28D9)
    static let label = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Self.label)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.fill))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One changed item on the "Advanced settings" row: the parameter name lighter, the value heavier, digits in rounded monospace.
struct ModelOptionSettingChip: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.footnote.weight(.medium))
                .opacity(0.82)
            Text(value)
                .font(.system(.footnote, design: .rounded).weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
        .background(Capsule(style: .continuous).fill(OriveoTheme.Palette.primarySoft))
        .accessibilityElement(children: .combine)
    }
}

/// "N more".
struct ModelOptionMoreChip: View {
    let count: Int

    var body: some View {
        Text(String(format: L10n.tr("%lld more", table: .chat), count))
            .font(.footnote.weight(.medium))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .background(Capsule(style: .continuous).fill(OriveoTheme.Palette.textPrimary.opacity(0.06)))
    }
}

/// The close button at the top right of the panel: a visible 30pt circle with a 44pt tap target.
struct ModelOptionCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(OriveoTheme.Palette.textPrimary.opacity(0.08)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.tr("Close")))
    }
}
