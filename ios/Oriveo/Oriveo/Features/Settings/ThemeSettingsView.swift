import SwiftUI
import UIKit

// Settings > Theme page.
// Source of truth for the interaction cases: `themePageCases` in `shared/theme-contracts/dark-palettes.v1.json`.

/// One palette card on the theme page: "Light", or a dark palette ("Dark" = `.dark`).
enum ThemeSwatch: Hashable {
    case light
    case palette(OriveoDarkPaletteID)

    /// Order of the horizontally scrolling palette cards: Light first, then the dark palettes in the JSON `order`.
    static let all: [ThemeSwatch] = [.light] + OriveoDarkPaletteID.allCases.map { .palette($0) }

    /// Strength factor of the primary glow at the bottom of the mini card: dark mode takes the palette glowK, light mode uses 0.55.
    var glowStrength: Double {
        switch self {
        case .light: 0.55
        case let .palette(id): id.palette.glowK
        }
    }

    var displayName: String {
        switch self {
        case .light: L10n.tr("Light")
        case let .palette(id): id.displayName
        }
    }

    /// Accessibility description of a swatch: name plus selected state.
    static func accessibility(_ swatch: ThemeSwatch, selected: Bool) -> (label: String, traits: AccessibilityTraits) {
        (swatch.displayName, selected ? .isSelected : [])
    }
}

extension OriveoDarkPaletteID {
    /// Palette name: the default dark shows "Dark", the others show the palette name.
    var displayName: String {
        switch self {
        case .dark: L10n.tr("Dark")
        case .darkPurple: L10n.tr("Palette Purple", table: .settings)
        case .darkGraphite: L10n.tr("Palette Graphite", table: .settings)
        case .darkBlack: L10n.tr("Palette Black", table: .settings)
        case .darkOcean: L10n.tr("Palette Ocean", table: .settings)
        case .darkForest: L10n.tr("Palette Forest", table: .settings)
        case .darkSunset: L10n.tr("Palette Sunset", table: .settings)
        }
    }
}

/// Preference snapshot of the theme page: theme plus the raw stored darkPalette value (nil = unset).
struct ThemePageState: Equatable {
    var theme: ThemeOption
    var darkPalette: String?

    var followsSystem: Bool { theme == .system }
}

enum ThemePageAction: Equatable {
    case tap(ThemeSwatch)
    case setFollowSystem(Bool)
}

/// Pure function of the theme page interaction: takes the current preference, the action and the real system appearance, and returns the new preference.
enum ThemePageReducer {
    static func apply(state: ThemePageState, action: ThemePageAction, systemIsDark: Bool) -> ThemePageState {
        var next = state
        switch action {
        case .tap(.light):
            // Tap Light: theme = light, darkPalette is left alone
            next.theme = .light
        case let .tap(.palette(id)):
            // Tap Dark / a palette: write darkPalette; with Follow System on, theme stays system
            next.darkPalette = id.rawValue
            if !state.followsSystem { next.theme = .dark }
        case .setFollowSystem(true):
            next.theme = .system
        case .setFollowSystem(false):
            // Turn Follow System off: pin to the current system appearance
            next.theme = systemIsDark ? .dark : .light
        }
        return next
    }

    /// Selection display: with Follow System on, the ring sits on resolve(darkPalette); off, light selects Light and dark selects resolve(darkPalette).
    static func selectedSwatch(_ state: ThemePageState) -> ThemeSwatch {
        state.theme == .light ? .light : .palette(OriveoDarkPaletteID.resolve(state.darkPalette))
    }
}

/// Summary on the right of the Theme row in Settings.
func themeRowSummary(theme: ThemeOption, darkPalette: String?) -> String {
    let paletteName = OriveoDarkPaletteID.resolve(darkPalette).displayName
    switch theme {
    case .light:
        return L10n.tr("Light")
    case .dark:
        return paletteName
    case .system:
        return L10n.format(L10n.tr("Follow System · %@", table: .settings), paletteName)
    }
}

struct ThemeSettingsView: View {
    @Environment(AppState.self) private var appState

    /// The code snippet, model name and cost in the preview are illustrative data and are not localized.
    private static let previewCode = "&T"
    private static let previewModelName = "Claude Opus 5.5"
    private static let previewCost = "$0.04"
    private static let previewCodeLanguage = "rust"

    private var state: ThemePageState {
        ThemePageState(theme: appState.preferences.theme, darkPalette: appState.preferences.darkPalette)
    }

    private var selected: ThemeSwatch { ThemePageReducer.selectedSwatch(state) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                previewCard
                paletteSection
                followSystemCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .oriveoContentWidth()
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme_settings_screen")
        .oriveoScreenBackground()
    }

    // MARK: - Interaction

    private func send(_ action: ThemePageAction) {
        let current = state
        let next = ThemePageReducer.apply(state: current, action: action, systemIsDark: Self.systemIsDark())
        if next.theme != current.theme {
            appState.updateTheme(next.theme)
        }
        if next.darkPalette != current.darkPalette, let id = OriveoDarkPaletteID(rawValue: next.darkPalette ?? "") {
            appState.updateDarkPalette(id)
        }
    }

    /// The real system appearance: the window is overridden by preferredColorScheme, so take the trait of the screen the scene is on (unaffected by the window override).
    @MainActor
    static func systemIsDark() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let style = scene?.screen.traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
        return style == .dark
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            Text(L10n.tr("Theme", table: .settings))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 56)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                OriveoBackButton {
                    appState.pop()
                }
                .accessibilityIdentifier("settings_theme_back_button")
                .padding(.leading, -OriveoBackButton.edgeInset)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: OriveoBackButton.hitSize)
        .padding(.horizontal, 20)
    }

    // MARK: - Follow System

    private var followSystemCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Follow System"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(L10n.tr("Uses your selected dark palette when the system is in dark mode.", table: .settings))
                    .font(.system(size: 12))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            Toggle(
                L10n.tr("Follow System"),
                isOn: Binding(
                    get: { state.followsSystem },
                    set: { send(.setFollowSystem($0)) }
                )
            )
            .labelsHidden()
            .tint(OriveoTheme.Palette.primary)
            .accessibilityHint(L10n.tr("Uses your selected dark palette when the system is in dark mode.", table: .settings))
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OriveoTheme.Palette.surface)
        )
    }

    // MARK: - Preview card

    /// Brand secondary color (gradient end = accent): the Web tag.
    private static var previewAccent: Color {
        OriveoTheme.Palette.primaryGradientColors.last ?? OriveoTheme.Palette.primary
    }

    /// The preview follows the selected swatch: light/dark and palette are overridden inside the card subtree, so dynamic tokens resolve against that palette.
    private var previewCard: some View {
        let swatch = selected
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        // The height grows with the content (minimum 352), so long languages / larger Dynamic Type are neither clipped nor scrolled inside
        return VStack(spacing: 0) {
            previewTopBar
            VStack(alignment: .leading, spacing: 9) {
                previewUserBubble
                previewThinkingRow
                Text(Self.previewReply())
                    .font(.system(size: 13.5))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                previewCodeBlock
                previewTags
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            previewComposer
        }
        .frame(maxWidth: .infinity, minHeight: 352)
        .background {
            ZStack {
                OriveoTheme.Palette.backgroundBase
                ChatEmptyStateAurora(prominent: true)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(OriveoTheme.Palette.border, lineWidth: 1))
        .shadow(color: OriveoTheme.Palette.shadow, radius: 20, y: 16)
        .environment(\.colorScheme, swatch == .light ? .light : .dark)
        .environment(\.oriveoDarkPalette, Self.paletteID(of: swatch))
        .animation(.easeInOut(duration: 0.25), value: swatch)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var previewTopBar: some View {
        HStack {
            Image(systemName: "chevron.backward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(width: 18, height: 18)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Circle()
                    .fill(OriveoTheme.Palette.primaryGradient)
                    .frame(width: 8, height: 8)
                    .shadow(color: OriveoTheme.Palette.primaryGlow, radius: 4)
                Text(Self.previewModelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Self.previewCost)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(OriveoTheme.Palette.primary)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .overlay(alignment: .bottom) {
            OriveoTheme.V2.Colors.borderSubtle.frame(height: 1)
        }
    }

    private var previewUserBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.tr("Explain Rust ownership in one paragraph.", table: .settings))
                    .font(.system(size: 13.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.previewTimestamp())
                    .font(.system(size: 10))
                    .opacity(0.7)
            }
            .foregroundStyle(OriveoTheme.Palette.onPrimary)
            // The bubble is at most 220 wide (including 13 of padding on each side); long languages wrap instead of being truncated
            .frame(maxWidth: 194, alignment: .trailing)
            .padding(.horizontal, 13)
            .padding(.top, 9)
            .padding(.bottom, 7)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: 18,
                    bottomTrailingRadius: 6,
                    topTrailingRadius: 18,
                    style: .continuous
                )
                .fill(OriveoTheme.Palette.primaryGradient)
                .shadow(color: OriveoTheme.Palette.primaryGlow, radius: 10, y: 8)
            )
        }
    }

    private var previewThinkingRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
            Text(Self.previewThinkingLabel())
                .font(.system(size: 11))
        }
        .foregroundStyle(OriveoTheme.Palette.textTertiary)
    }

    private var previewCodeBlock: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Self.previewCodeLanguage)
                Spacer(minLength: 8)
                Text(L10n.tr("Copy"))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(MarkdownCodeBlockPalette.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(MarkdownCodeBlockPalette.headerBackground)
            // The code in the preview is literal text, not copy: use verbatim, otherwise the literal is treated as a localization key and an empty entry is added to the catalog at build time
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "let").foregroundColor(Self.previewSyntax.keyword)
                    + Text(verbatim: " s = ").foregroundColor(MarkdownCodeBlockPalette.foreground)
                    + Text(verbatim: "String").foregroundColor(Self.previewSyntax.type)
                    + Text(verbatim: "::from(").foregroundColor(MarkdownCodeBlockPalette.foreground)
                    + Text(verbatim: "\"hi\"").foregroundColor(Self.previewSyntax.string)
                    + Text(verbatim: ");").foregroundColor(MarkdownCodeBlockPalette.foreground)
                Text(verbatim: "let").foregroundColor(Self.previewSyntax.keyword)
                    + Text(verbatim: " r = &s;").foregroundColor(MarkdownCodeBlockPalette.foreground)
            }
            .font(.system(size: 11, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MarkdownCodeBlockPalette.surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(OriveoTheme.Palette.border, lineWidth: 1))
    }

    /// Preview code highlighting: takes the syntax colors of the chat code block (CodeBlockView) directly, with no separate constants.
    static let previewSyntax = (
        keyword: MarkdownCodeBlockPalette.keyword,
        type: MarkdownCodeBlockPalette.type,
        string: MarkdownCodeBlockPalette.string
    )

    private var previewTags: some View {
        HStack(spacing: 6) {
            previewTag(L10n.tr("Reasoning"), fill: OriveoTheme.V2.Colors.primarySubtle, text: OriveoTheme.Palette.primary)
            previewTag(L10n.tr("Web"), fill: Self.previewAccent.opacity(0.14), text: Self.previewAccent)
        }
    }

    private func previewTag(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
    }

    private var previewComposer: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Type a message...", table: .chat))
                .font(.system(size: 12.5))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.onPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(OriveoTheme.Palette.primaryGradient))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 38)
        .background(
            Capsule()
                .fill(Self.previewComposerFill)
                .overlay(Capsule().strokeBorder(OriveoTheme.Palette.primary.opacity(0.22), lineWidth: 1))
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Mini composer background: white in light mode, the palette surface at 82% in dark mode.
    private static let previewComposerFill = Color.dynamic(light: 0xFFFFFF, dark: \.surface, darkAlpha: 0.82)

    /// User bubble time: a fixed moment, 21:41, formatted in local time format.
    static func previewTimestamp(calendar: Calendar = .current, now: Date = Date()) -> String {
        let moment = calendar.date(bySettingHour: 21, minute: 41, second: 0, of: now) ?? now
        return moment.formatted(date: .omitted, time: .shortened)
    }

    /// "Thought for 4 seconds": reuses the duration copy of the chat reasoning block.
    static func previewThinkingLabel() -> String {
        String(format: L10n.tr("Thought for %@", table: .chat), UIKitReasoningBlock.formatDuration(ms: 4000))
    }

    private static func paletteID(of swatch: ThemeSwatch) -> OriveoDarkPaletteID {
        if case let .palette(id) = swatch { return id }
        return .defaultID
    }

    /// Preview reply: in the template `%1$@` = the emphasized word (primary, bold) and `%2$@` = inline code (same source as chat: MarkdownAttributedStringRenderer.codeFg / codeBg).
    static func previewReply() -> AttributedString {
        let template = L10n.tr(
            "Every value has exactly one %1$@. When it goes out of scope, the value is dropped — borrow it with %2$@.",
            table: .settings
        )
        var result = AttributedString()
        var rest = Substring(template)
        while let range = rest.range(of: "%[12]\\$@", options: .regularExpression) {
            result += AttributedString(String(rest[..<range.lowerBound]))
            if rest[range] == "%1$@" {
                var owner = AttributedString(L10n.tr("Theme Preview Owner", table: .settings))
                owner.font = .system(size: 13.5, weight: .semibold)
                owner.foregroundColor = OriveoTheme.Palette.primary
                result += owner
            } else {
                var code = AttributedString(previewCode)
                code.font = .system(size: 12, design: .monospaced)
                code.foregroundColor = Color(uiColor: MarkdownAttributedStringRenderer.codeFg)
                code.backgroundColor = Color(uiColor: MarkdownAttributedStringRenderer.codeBg)
                result += code
            }
            rest = rest[range.upperBound...]
        }
        result += AttributedString(String(rest))
        return result
    }

    // MARK: - Palette cards

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Palettes", table: .settings))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(ThemeSwatch.all, id: \.self) { swatch in
                            paletteCard(swatch).id(swatch)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
                .padding(.horizontal, -16)
                .onAppear {
                    // On first entry: scroll the selected card into view
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
    }

    private func paletteCard(_ swatch: ThemeSwatch) -> some View {
        let isOn = swatch == selected
        let a11y = ThemeSwatch.accessibility(swatch, selected: isOn)
        return Button {
            send(.tap(swatch))
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    PaletteMiniChat(glowStrength: swatch.glowStrength)
                        .environment(\.colorScheme, swatch == .light ? .light : .dark)
                        .environment(\.oriveoDarkPalette, Self.paletteID(of: swatch))
                    if isOn {
                        // A 2pt gap in the page background color plus a 2pt stroke in the current primary color
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(OriveoTheme.Palette.primary, lineWidth: 2)
                            .frame(width: 84, height: 112)
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(OriveoTheme.Palette.border, lineWidth: 1)
                            .frame(width: 76, height: 104)
                    }
                }
                .frame(width: 84, height: 112)
                .padding(.vertical, -4)

                Text(swatch.displayName)
                    .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                    .foregroundStyle(isOn ? OriveoTheme.Palette.textPrimary : OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11y.label)
        .accessibilityAddTraits(a11y.traits)
        .accessibilityAddTraits(.isButton)
    }
}

/// Mini chat card of a palette: the background is that palette bg plus a primary glow at the bottom, with two incoming bubbles and one gradient bubble of your own.
/// The outer layer overrides light/dark and palette, so dynamic tokens resolve against that palette.
private struct PaletteMiniChat: View {
    let glowStrength: Double

    /// Incoming bubble: light grey on the light card, that palette surface in dark mode.
    private static let incomingFill = Color.dynamic(light: 0xE5E7EB, dark: \.surface)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            OriveoTheme.Palette.backgroundBase
            EllipticalGradient(
                colors: [OriveoTheme.Palette.primary.opacity(0.30 * glowStrength), .clear],
                center: UnitPoint(x: 0.5, y: 1.1),
                startRadiusFraction: 0,
                endRadiusFraction: 0.7
            )
            .scaleEffect(x: 1.2, y: 0.7, anchor: UnitPoint(x: 0.5, y: 1.1))
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                bubble(width: 40, height: 14, fill: AnyShapeStyle(Self.incomingFill), incoming: true)
                bubble(width: 28, height: 14, fill: AnyShapeStyle(Self.incomingFill), incoming: true)
                bubble(width: 44, height: 16, fill: AnyShapeStyle(OriveoTheme.Palette.primaryGradient), incoming: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(width: 76, height: 104)
        .clipShape(shape)
    }

    private func bubble(width: CGFloat, height: CGFloat, fill: AnyShapeStyle, incoming: Bool) -> some View {
        let big = height / 2
        return UnevenRoundedRectangle(
            topLeadingRadius: big,
            bottomLeadingRadius: incoming ? 3 : big,
            bottomTrailingRadius: incoming ? big : 3,
            topTrailingRadius: big,
            style: .continuous
        )
        .fill(fill)
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity, alignment: incoming ? .leading : .trailing)
    }
}
