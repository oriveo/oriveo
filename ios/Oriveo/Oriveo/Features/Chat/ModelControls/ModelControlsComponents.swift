import SwiftUI

// MARK: - Accent

struct ModelControlAccent {
    let tint: Color

    static let web = ModelControlAccent(tint: OriveoTheme.Palette.primaryTextSafe)
    static let reasoning = ModelControlAccent(tint: OriveoTheme.Palette.primaryTextSafe)
    static let generation = ModelControlAccent(tint: OriveoTheme.Palette.primaryTextSafe)
    static let neutral = ModelControlAccent(tint: OriveoTheme.Palette.textSecondary)
}

// MARK: - Surface

extension View {
    func modelControlSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(ModelControlSurface(cornerRadius: cornerRadius))
    }
}

private struct ModelControlSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

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

enum ModelControlIntentLabel {
    static func key(_ intent: String) -> (key: String, table: L10n.Table)? {
        switch intent {
        case ModelControlReasoningLayout.automaticIntent: return ("Automatic", .localizable)
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

    static func webKey(_ preference: CapabilityWebPreference) -> (key: String, table: L10n.Table) {
        switch preference {
        case .inherit: return ("Search when needed", .chat)
        case .off: return ("Off", .localizable)
        case .automatic: return ("Search when needed", .chat)
        case .force: return ("Search every message", .chat)
        case .custom: return ("Custom", .chat)
        }
    }

    static func webText(_ preference: CapabilityWebPreference) -> String {
        let entry = webKey(preference)
        return L10n.tr(entry.key, table: entry.table)
    }
}

enum ModelControlReasoningNotes {
    enum Kind: String {
        case cannotTurnOff
        case fixedTier
        case higherLevelsCost
    }

    struct Note: Equatable {
        let kind: Kind
        let text: String
        let systemImage: String
    }

    static func all(isConfigurable: Bool, intents: [String]) -> [Note] {
        guard isConfigurable else { return [] }
        if intents.isEmpty {
            return [Note(
                kind: .fixedTier,
                text: L10n.tr(
                    "This model runs at a fixed thinking level and can’t be adjusted.", table: .chat
                ),
                systemImage: "lock"
            )]
        }
        var notes: [Note] = []
        if !intents.contains("off") {
            notes.append(Note(
                kind: .cannotTurnOff,
                text: L10n.tr("This model cannot turn thinking off.", table: .chat),
                systemImage: "info.circle"
            ))
        }
        notes.append(Note(
            kind: .higherLevelsCost,
            text: L10n.tr(
                "Higher levels are usually slower and can cost more. The provider and model decide what actually runs.",
                table: .chat
            ),
            systemImage: "clock"
        ))
        return notes
    }
}

// MARK: - Status badge

enum ModelControlStatusTone {
    case ready
    case manual
    case unavailable

    var color: Color {
        switch self {
        case .ready: return OriveoTheme.Palette.success
        case .manual: return OriveoTheme.Palette.warning
        case .unavailable: return OriveoTheme.Palette.textTertiary
        }
    }

    var textColor: Color {
        switch self {
        case .ready: return OriveoTheme.Palette.success
        case .manual: return OriveoTheme.Palette.warningText
        case .unavailable: return OriveoTheme.Palette.textSecondary
        }
    }
}

struct ModelControlStatusBadge: View {
    let tone: ModelControlStatusTone
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    static func capsuleOpacity(isDark: Bool) -> Double { isDark ? 0.20 : 0.12 }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone.textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background {
                Capsule(style: .continuous)
                    .fill(tone.color.opacity(Self.capsuleOpacity(isDark: colorScheme == .dark)))
            }
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Card

struct ModelControlCard<Content: View>: View {
    let icon: String
    let accent: ModelControlAccent
    let title: String
    let subtitle: String
    var badge: (tone: ModelControlStatusTone, text: String)?
    var toggle: Binding<Bool>?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.tint)
                    .frame(width: 20)

                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                Spacer(minLength: 8)

                if let toggle {
                    Toggle("", isOn: toggle)
                        .labelsHidden()
                        .tint(OriveoTheme.Palette.primaryTextSafe)
                        .frame(minHeight: 44)
                        .accessibilityLabel(Text(title))
                } else if let badge {
                    ModelControlStatusBadge(tone: badge.tone, text: badge.text)
                }
            }

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -7)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }
}

// MARK: - Intent pills

struct ModelControlIntentOption: Identifiable, Equatable {
    let id: String
    let label: String
    let isEnabled: Bool

    init(id: String, label: String, isEnabled: Bool = true) {
        self.id = id
        self.label = label
        self.isEnabled = isEnabled
    }
}

struct ModelControlIntentPicker: View {
    let options: [ModelControlIntentOption]
    let selection: String
    var isEnabled: Bool = true
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        ModelControlWrappingLayout(spacing: 8, lineSpacing: 8, layoutDirection: layoutDirection) {
            ForEach(options) { option in
                let selected = option.id == selection
                let usable = isEnabled && option.isEnabled

                Button {
                    guard usable, !selected else { return }
                    OriveoHaptic.select()
                    onSelect(option.id)
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(foreground(selected: selected, usable: usable))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minWidth: 56)
                        .background {
                            Capsule(style: .continuous)
                                .fill(fill(selected: selected, usable: usable))
                        }
                        .frame(minHeight: 44)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(ModelControlPillButtonStyle(isEnabled: usable))
                .disabled(!usable)
                .accessibilityLabel(Text(option.label))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84), value: selection)
    }

    private func foreground(selected: Bool, usable: Bool) -> Color {
        if selected { return isEnabled ? selectedLabelColor : dimmedSelectedLabelColor }
        guard usable else { return OriveoTheme.Palette.textDisabledOnControl }
        return OriveoTheme.Palette.textSecondary
    }

    private var selectedLabelColor: Color { OriveoTheme.Palette.onPrimary }

    private var dimmedSelectedLabelColor: Color { OriveoTheme.Palette.textSecondary }

    private var selectedFill: Color { OriveoTheme.Palette.primaryTextSafe }

    private var dimmedSelectedFill: Color {
        OriveoTheme.Palette.textPrimary.opacity(colorScheme == .dark ? 0.14 : 0.10)
    }

    private func fill(selected: Bool, usable: Bool) -> Color {
        guard selected else {
            return OriveoTheme.Palette.textPrimary
                .opacity(Self.unselectedFillAlpha(isDark: colorScheme == .dark, usable: usable))
        }
        return isEnabled ? selectedFill : dimmedSelectedFill
    }

    static func unselectedFillAlpha(isDark: Bool, usable: Bool) -> Double {
        guard isDark else { return 0.06 }
        return usable ? 0.10 : 0.05
    }
}

private struct ModelControlPillButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

// MARK: - Wrapping layout

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

// MARK: - Segmented tiers

struct ModelControlSegmentedPicker: View {
    let tiers: [ModelControlTier]
    let selection: String
    var isDimmed: Bool = false
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tiers) { tier in
                let selected = tier.id == selection
                let usable = tier.isEnabled && !isDimmed

                Button {
                    guard usable, !selected else { return }
                    OriveoHaptic.select()
                    onSelect(tier.id)
                } label: {
                    Text(tier.label)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(foreground(selected: selected, usable: usable))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background {
                            if selected {
                                Capsule(style: .continuous)
                                    .fill(isDimmed ? dimmedSelectedFill : selectedFill)
                                    .matchedGeometryEffect(id: "modelControlSegment", in: indicator)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!usable)
                .accessibilityLabel(Text(tier.label))
                .accessibilityValue(Text(tier.unavailableReason ?? ""))
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous)
                .fill(OriveoTheme.Palette.textPrimary.opacity(Self.trackAlpha(isDark: colorScheme == .dark)))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
    }

    private func foreground(selected: Bool, usable: Bool) -> Color {
        if selected { return isDimmed ? dimmedSelectedLabelColor : selectedLabelColor }
        guard usable else { return OriveoTheme.Palette.textDisabledOnControl }
        return OriveoTheme.Palette.textSecondary
    }

    private var selectedLabelColor: Color { OriveoTheme.Palette.onPrimary }

    private var dimmedSelectedLabelColor: Color { OriveoTheme.Palette.textSecondary }

    private var selectedFill: Color { OriveoTheme.Palette.primaryTextSafe }

    private var dimmedSelectedFill: Color {
        OriveoTheme.Palette.textPrimary.opacity(colorScheme == .dark ? 0.14 : 0.10)
    }

    static func trackAlpha(isDark: Bool) -> Double { isDark ? 0.06 : 0.05 }
}
struct ModelControlHairline: View {
    var leadingInset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.textPrimary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
    }
}


struct ModelControlStatusRow: View {
    let text: String
    var action: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if action != nil {
                Image(systemName: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}


struct ModelControlScopeUpgradeRow: View {
    let isConfirmed: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.5)
            content
        }
        .background(OriveoTheme.Palette.surfaceChrome)
    }

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
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notes & rows

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

struct ModelControlInlineActionLabel: View {
    let title: String
    let systemImage: String
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

struct ModelControlNavigationRow: View {
    let icon: String
    let accent: ModelControlAccent
    let title: String
    let subtitle: String
    var trailingText: String?
    var badge: (tone: ModelControlStatusTone, text: String)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let badge {
                ModelControlStatusBadge(tone: badge.tone, text: badge.text)
            } else if let trailingText {
                Text(trailingText)
                    .font(.subheadline)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
