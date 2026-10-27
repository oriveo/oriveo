import SwiftUI
import UIKit

// Settings > Theme page: an appearance segmented control plus 8 palette cards.
// Source of truth for the interaction cases: `appearancePageCases` in `shared/theme-contracts/dark-palettes.v1.json`.

/// One palette card on the theme page: a preset palette ("Default" = `.dark`), or "Custom" (derived from a seed color).
/// Palettes apply to both appearances: a card is drawn in the appearance currently in effect on the page.
enum ThemeSwatch: Hashable {
    case palette(OriveoDarkPaletteID)
    case custom

    /// Order of the horizontally scrolling palette cards: the presets (in the JSON `order`), with "Custom" last.
    static let all: [ThemeSwatch] = OriveoDarkPaletteID.allCases.map { .palette($0) } + [.custom]

    /// Strength factor of the primary glow at the bottom of the mini card: this palette's glowK.
    var glowStrength: Double {
        switch self {
        case let .palette(id): id.palette.glowK
        case .custom: OriveoCustomPalette.derive(seed: OriveoCustomPalette.defaultSeed).palette.glowK
        }
    }

    var displayName: String {
        switch self {
        case let .palette(id): id.displayName
        case .custom: L10n.tr("Palette Custom", table: .settings)
        }
    }

    /// Accessibility description of a swatch: name plus selected state.
    static func accessibility(_ swatch: ThemeSwatch, selected: Bool) -> (label: String, traits: AccessibilityTraits) {
        (swatch.displayName, selected ? .isSelected : [])
    }
}

extension OriveoDarkPaletteID {
    /// Palette name: the default palette shows "Default", the others show the palette name.
    var displayName: String {
        switch self {
        case .dark: L10n.tr("Default")
        case .darkPurple: L10n.tr("Palette Purple", table: .settings)
        case .darkGraphite: L10n.tr("Palette Graphite", table: .settings)
        case .darkBlack: L10n.tr("Palette Black", table: .settings)
        case .darkOcean: L10n.tr("Palette Ocean", table: .settings)
        case .darkForest: L10n.tr("Palette Forest", table: .settings)
        case .darkSunset: L10n.tr("Palette Sunset", table: .settings)
        }
    }
}

/// Preference snapshot of the theme page: theme, the raw stored darkPalette value (nil = unset) and the raw custom seed color (`darkPaletteCustom`).
struct ThemePageState: Equatable {
    var theme: ThemeOption
    var darkPalette: String?
    var seed: String? = nil

    var isCustom: Bool { darkPalette == OriveoDarkPaletteChoice.customStorageID }

    /// The current seed color: a missing / invalid value falls back to the default seed
    var resolvedSeed: UInt { OriveoCustomPalette.parseSeed(seed) ?? OriveoCustomPalette.defaultSeed }
}

enum ThemePageAction: Equatable {
    /// Appearance segmented control: writes only theme
    case setAppearance(ThemeOption)
    /// Tap a palette card: writes only darkPalette (for Custom without a seed, writes the default seed)
    case tap(ThemeSwatch)
    /// Pick a color: writes the seed plus darkPalette=custom
    case pickSeed(UInt)
}

/// Pure function of the theme page interaction: takes the current preference and an action and returns the new preference. Appearance and palette are independent axes.
enum ThemePageReducer {
    static func apply(state: ThemePageState, action: ThemePageAction) -> ThemePageState {
        var next = state
        switch action {
        case let .setAppearance(theme):
            next.theme = theme
        case let .tap(.palette(id)):
            // The seed color is kept: it is still there the next time Custom is chosen
            next.darkPalette = id.rawValue
        case .tap(.custom):
            next.darkPalette = OriveoDarkPaletteChoice.customStorageID
            if OriveoCustomPalette.parseSeed(state.seed) == nil {
                next.seed = OriveoCustomPalette.format(OriveoCustomPalette.defaultSeed)
            }
        case let .pickSeed(seed):
            next.seed = OriveoCustomPalette.format(seed)
            next.darkPalette = OriveoDarkPaletteChoice.customStorageID
        }
        return next
    }

    /// Selected card = resolve(darkPalette), with a selection ring in every appearance; darkPalette=custom → Custom.
    static func selectedSwatch(_ state: ThemePageState) -> ThemeSwatch {
        if state.isCustom { return .custom }
        return .palette(OriveoDarkPaletteID.resolve(state.darkPalette))
    }
}

/// Summary on the Theme row in Settings: the default palette shows only the appearance name; the others show "appearance · palette name".
func themeRowSummary(theme: ThemeOption, darkPalette: String?) -> String {
    let swatch = ThemePageReducer.selectedSwatch(ThemePageState(theme: theme, darkPalette: darkPalette))
    if swatch == .palette(.dark) { return theme.displayName }
    let template = switch theme {
    case .light: L10n.tr("Light · %@", table: .settings)
    case .dark: L10n.tr("Dark · %@", table: .settings)
    case .system: L10n.tr("Follow System · %@", table: .settings)
    }
    return L10n.format(template, swatch.displayName)
}

struct ThemeSettingsView: View {
    @Environment(AppState.self) private var appState
    /// The appearance currently in effect on the page: the "Primary / Accent" chips in the custom section take the light brand colors or the dark palette values by it
    @Environment(\.colorScheme) private var colorScheme

    /// The code snippet, model name and cost in the preview are illustrative data and are not localized.
    private static let previewCode = "&T"
    private static let previewModelName = "Claude Opus 5.5"
    private static let previewCost = "$0.04"
    private static let previewCodeLanguage = "rust"

    private var state: ThemePageState {
        ThemePageState(
            theme: appState.preferences.theme,
            darkPalette: appState.preferences.darkPalette,
            seed: appState.preferences.darkPaletteCustom
        )
    }

    private var selected: ThemeSwatch { ThemePageReducer.selectedSwatch(state) }

    /// The integer degrees while the hue slider is being dragged (reported by the slider, cleared on release / cancel). While dragging only this page changes color and
    /// the window traits stay untouched: recoloring the whole app would make every page in the navigation stack recompute colors each frame, and the thumb would lag behind the finger.
    @State private var previewHue: Int?
    /// Preview card height: the vertical gradient of the preview mini bubble is anchored to the whole preview card
    @State private var previewCardHeight: CGFloat = 352

    /// The seed color the custom palette currently shows: the hue slider while dragging, the preference otherwise
    private var displayedSeed: UInt {
        previewHue.map(OriveoCustomPalette.hueSliderSeed) ?? state.resolvedSeed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                previewCard
                appearanceSection
                paletteSection
                if selected == .custom {
                    customColorCard
                }
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
        // While the hue slider is dragged only this page's palette environment is overridden for a live preview; after release the preference applies it to all windows
        .transformEnvironment(\.oriveoDarkPalette) { palette in
            if let previewHue { palette = .custom(seed: OriveoCustomPalette.hueSliderSeed(previewHue)) }
        }
    }

    // MARK: - Interaction

    private func send(_ action: ThemePageAction) {
        let current = state
        let next = ThemePageReducer.apply(state: current, action: action)
        if next.theme != current.theme {
            appState.updateTheme(next.theme)
        }
        guard next.darkPalette != current.darkPalette || next.seed != current.seed else { return }
        if next.isCustom {
            appState.updateDarkPalette(.custom(seed: next.resolvedSeed))
        } else if let id = OriveoDarkPaletteID(rawValue: next.darkPalette ?? "") {
            appState.updateDarkPalette(.preset(id))
        }
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

    // MARK: - Appearance

    /// Order of the appearance segments: Light / Dark / Follow System
    static let appearanceOptions: [ThemeOption] = [.light, .dark, .system]

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L10n.tr("Appearance", table: .settings))
            Picker(
                L10n.tr("Appearance", table: .settings),
                selection: Binding(
                    get: { state.theme },
                    set: { send(.setAppearance($0)) }
                )
            ) {
                ForEach(Self.appearanceOptions) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Preview card

    /// Brand secondary color: the text and fill of the Web tag. Dark mode takes accent; light mode is small text, so it takes textSafe (the gradient end of a light-based palette is too bright to read as text),
    /// and the default palette keeps its original gradient-end violet in light mode.
    static let previewAccent = Color.brand(defaultLight: 0x6B3BC7, light: \.textSafe, dark: \.accent)

    /// The preview follows the selected palette: it is drawn in the page's current appearance, and only the card subtree overrides the palette, so dynamic tokens resolve against that one.
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
        .coordinateSpace(.named(Self.previewCardSpace))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewCardHeight = $0 }
        .background {
            ZStack {
                OriveoTheme.Palette.backgroundBase
                ChatEmptyStateAurora(prominent: true)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(OriveoTheme.Palette.border, lineWidth: 1))
        .shadow(color: OriveoTheme.Palette.shadow, radius: 20, y: 16)
        .environment(\.oriveoDarkPalette, choice(of: swatch))
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

    private static let previewCardSpace = "themePreviewCard"

    private var previewUserBubble: some View {
        let bubbleShape = UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 6,
            topTrailingRadius: 18,
            style: .continuous
        )
        return HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.tr("Explain Rust ownership in one paragraph.", table: .settings))
                    .font(.system(size: 13.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    // Body text flush left (matching the chat bubble and the Android / Web previews) with the time at the bottom right; otherwise wrapped text would align to the trailing edge and leave a gap on the left
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                OriveoUserBubbleBackground(
                    shape: bubbleShape, space: Self.previewCardSpace, containerHeight: previewCardHeight
                )
                .shadow(
                    color: OriveoUserBubble.shadowColor,
                    radius: OriveoUserBubble.shadowRadius,
                    y: OriveoUserBubble.shadowOffsetY
                )
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
            Text(Self.previewHighlightedCode())
                .lineSpacing(2)
            .font(.system(size: 11, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MarkdownCodeBlockPalette.background)
        .clipShape(shape)
        .overlay(shape.strokeBorder(OriveoTheme.Palette.border, lineWidth: 1))
    }

    /// Preview code snippet: illustrative code, not localized.
    static let previewSnippet = "let s = String::from(\"hi\");\nlet r = &s;"

    /// Preview code highlighting: handed to the same `SyntaxHighlighter` as the chat code block, so roles and color values match chat exactly;
    /// the colors are converted to SwiftUI dynamic colors and resolve against the light/dark and palette environment of the preview card.
    static func previewHighlightedCode() -> AttributedString {
        let highlighted = SyntaxHighlighter.highlight(
            previewSnippet, language: previewCodeLanguage, baseColor: MarkdownCodeBlockPalette.foregroundUIColor
        )
        var result = AttributedString()
        highlighted.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: highlighted.length)
        ) { value, range, _ in
            var run = AttributedString(highlighted.attributedSubstring(from: range).string)
            run.foregroundColor = Color(uiColor: (value as? UIColor) ?? MarkdownCodeBlockPalette.foregroundUIColor)
            result += run
        }
        return result
    }

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

    /// Mini composer background: white in light mode, this palette's surface at 82% in dark mode.
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

    private func choice(of swatch: ThemeSwatch) -> OriveoDarkPaletteChoice {
        switch swatch {
        case let .palette(id): .preset(id)
        case .custom: .custom(seed: displayedSeed)
        }
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
            sectionHeader(L10n.tr("Palettes", table: .settings))
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
                        .environment(\.oriveoDarkPalette, choice(of: swatch))
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

    // MARK: - Custom palette (color picker)

    /// Accessibility names of the preset colors, in the same order as `OriveoCustomPalette.presets`
    static func presetAccessibilityLabels() -> [String] {
        [
            L10n.tr("Color Coral", table: .settings),
            L10n.tr("Color Orange", table: .settings),
            L10n.tr("Color Amber", table: .settings),
            L10n.tr("Color Lime", table: .settings),
            L10n.tr("Color Green", table: .settings),
            L10n.tr("Color Teal", table: .settings),
            L10n.tr("Color Cyan", table: .settings),
            L10n.tr("Color Blue", table: .settings),
            L10n.tr("Color Indigo", table: .settings),
            L10n.tr("Color Violet", table: .settings),
            L10n.tr("Color Pink", table: .settings),
            L10n.tr("Color Rose", table: .settings),
        ]
    }

    /// The seed color's position on the hue slider (integer degrees, 0-359)
    static func sliderHue(of seed: UInt) -> Int {
        let hue = Int(OriveoCustomPalette.oklch(seed).h.rounded()) % 360
        return min(OriveoCustomPalette.HueSlider.max, max(OriveoCustomPalette.HueSlider.min, hue))
    }

    /// Derivation notice: a one-line explanation when the primary color was lightened / darkened
    static func adjustmentNotice(_ adjustment: OriveoCustomPalette.Adjustment?) -> String? {
        switch adjustment {
        case .lightened: L10n.tr("Lightened so text stays readable", table: .settings)
        case .darkened: L10n.tr("Darkened so it doesn't look washed out", table: .settings)
        case nil: nil
        }
    }

    /// The "Primary / Accent" chips: the light appearance takes the ink / accent of this seed's light brand color, the dark appearance the primary / accent of the derived palette
    static func derivedChipColors(seed: UInt, colorScheme: ColorScheme) -> (primary: UInt, accent: UInt) {
        let choice = OriveoDarkPaletteChoice.custom(seed: seed)
        if colorScheme == .dark {
            return (choice.palette.primary, choice.palette.accent)
        }
        let brand = choice.lightBrand
        return (brand.ink, brand.accent)
    }

    private static let presetDotSize: CGFloat = 32
    private static let presetHitSize: CGFloat = 44

    private var customColorCard: some View {
        let seed = displayedSeed
        let derived = OriveoCustomPalette.derive(seed: seed)
        let chips = Self.derivedChipColors(seed: seed, colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Custom Color", table: .settings))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            presetGrid(selectedSeed: previewHue == nil ? seed : nil)
            hueSlider(seed: seed)
            HStack(spacing: 16) {
                derivedChip(L10n.tr("Primary Color", table: .settings), hex: chips.primary)
                derivedChip(L10n.tr("Accent Color", table: .settings), hex: chips.accent)
                Spacer(minLength: 0)
            }
            if let notice = Self.adjustmentNotice(derived.adjusted) {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OriveoTheme.Palette.surface)
        )
    }

    private func presetGrid(selectedSeed: UInt?) -> some View {
        let labels = Self.presetAccessibilityLabels()
        let presets = OriveoCustomPalette.presets
        return VStack(spacing: 4) {
            ForEach(0 ..< 2, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(row * 6 ..< row * 6 + 6, id: \.self) { index in
                        presetDot(presets[index], label: labels[index], isOn: presets[index] == selectedSeed)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func presetDot(_ preset: UInt, label: String, isOn: Bool) -> some View {
        Button {
            send(.pickSeed(preset))
        } label: {
            ZStack {
                if isOn {
                    // A 2pt gap in the page background color plus a 2pt stroke in textPrimary
                    Circle()
                        .strokeBorder(OriveoTheme.Palette.textPrimary, lineWidth: 2)
                        .frame(width: Self.presetDotSize + 8, height: Self.presetDotSize + 8)
                    Circle()
                        .fill(OriveoTheme.Palette.backgroundBase)
                        .frame(width: Self.presetDotSize + 4, height: Self.presetDotSize + 4)
                }
                Circle()
                    .fill(Color(hex: preset))
                    .frame(width: Self.presetDotSize, height: Self.presetDotSize)
            }
            .frame(width: Self.presetHitSize, height: Self.presetHitSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func hueSlider(seed: UInt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Hue", table: .settings))
                .font(.system(size: 12))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .accessibilityHidden(true)
            ThemeHueSlider(
                hue: Self.sliderHue(of: seed),
                onPreview: { previewHue = $0 },
                onCommit: { hue in
                    let next = OriveoCustomPalette.hueSliderSeed(hue)
                    // Apply the new palette to all windows first, then write the preference: the frame where this page's preview override is removed does not flash back to the old color
                    OriveoDarkPaletteSwitcher.applyToAllWindows(.custom(seed: next))
                    send(.pickSeed(next))
                }
            )
        }
    }

    private func derivedChip(_ title: String, hex: UInt) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(hex: hex))
                .frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Text(verbatim: OriveoCustomPalette.format(hex))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Mini chat card of a palette: the background is that palette's base (light bgTop / dark bg) plus a primary glow at the bottom, with two incoming bubbles and one gradient bubble of your own.
/// The outer layer overrides only the palette (light/dark follows the page), so dynamic tokens resolve against that palette.
private struct PaletteMiniChat: View {
    let glowStrength: Double

    /// Incoming bubble: light grey on the light card, that palette's surface in dark mode.
    private static let incomingFill = Color.dynamic(light: 0xE5E7EB, dark: \.surface)
    /// Card background: that palette's light brand bgTop in light mode, its bg in dark mode
    private static let cardBackground = Color.brand(light: \.bgTop, dark: \.bg)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            Self.cardBackground
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
                outgoingBubble(width: 44, height: 16)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .coordinateSpace(.named(Self.space))
        .clipShape(shape)
    }

    private static let size = CGSize(width: 76, height: 104)
    private static let space = "paletteMiniChat"

    private static func shape(height: CGFloat, incoming: Bool) -> UnevenRoundedRectangle {
        let big = height / 2
        return UnevenRoundedRectangle(
            topLeadingRadius: big,
            bottomLeadingRadius: incoming ? 3 : big,
            bottomTrailingRadius: incoming ? big : 3,
            topTrailingRadius: big,
            style: .continuous
        )
    }

    private func bubble(width: CGFloat, height: CGFloat, fill: AnyShapeStyle, incoming: Bool) -> some View {
        Self.shape(height: height, incoming: incoming)
            .fill(fill)
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, alignment: incoming ? .leading : .trailing)
    }

    /// Your own mini bubble: the vertical color stops are anchored to the whole card; the card is too small to draw the inner highlight.
    private func outgoingBubble(width: CGFloat, height: CGFloat) -> some View {
        OriveoUserBubbleBackground(
            shape: Self.shape(height: height, incoming: false),
            space: Self.space,
            containerHeight: Self.size.height,
            showsHighlight: false
        )
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The theme page's hue slider: the thumb follows the finger continuously, the drag state lives only inside this view, and only the slider redraws while dragging;
/// the page preview (`onPreview`) is notified only when the integer hue changes, and one commit (`onCommit`) is reported on release.
struct ThemeHueSlider: View {
    /// The integer hue the thumb sits at when not dragging
    let hue: Int
    let onPreview: (Int?) -> Void
    let onCommit: (Int) -> Void

    /// The thumb position while dragging (0...1, continuous); cleared automatically on release / cancel
    @GestureState private var dragFraction: CGFloat?

    private static let trackHeight: CGFloat = 12
    private static let thumbSize: CGFloat = 24
    private static let hitHeight: CGFloat = 44
    private static let range = OriveoCustomPalette.HueSlider.min ... OriveoCustomPalette.HueSlider.max
    /// Track gradient: one stop every 30 degrees, computed once
    private static let stops: [Color] = stride(from: 0, through: 360, by: 30).map {
        Color(hex: OriveoCustomPalette.hueSliderSeed(min($0, range.upperBound)))
    }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Self.thumbSize, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: Self.stops, startPoint: .leading, endPoint: .trailing))
                    .frame(height: Self.trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.thumbSize, height: Self.thumbSize)
                    .shadow(color: OriveoTheme.Palette.shadow, radius: 3, y: 1)
                    .offset(x: travel * (dragFraction ?? Self.fraction(of: hue)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // The hue slider is a horizontal drag area SwiftUI handles itself: register it so swipe-back yields, otherwise dragging right would drag the theme page away
            .blocksSwipeBack()
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragFraction) { value, fraction, _ in
                        fraction = Self.fraction(at: value.location.x, travel: travel)
                    }
                    .onEnded { value in
                        onCommit(Self.hue(of: Self.fraction(at: value.location.x, travel: travel)))
                    }
            )
        }
        .frame(height: Self.hitHeight)
        .onChange(of: dragFraction.map(Self.hue(of:))) { _, hue in
            onPreview(hue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Hue", table: .settings))
        .accessibilityValue(Text(verbatim: "\(hue)°"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 10 : direction == .decrement ? -10 : 0
            guard step != 0 else { return }
            onCommit(min(Self.range.upperBound, max(Self.range.lowerBound, hue + step)))
        }
    }

    /// Finger x → thumb position (0...1): the thumb center lines up with the finger
    static func fraction(at x: CGFloat, travel: CGFloat) -> CGFloat {
        min(1, max(0, (x - thumbSize / 2) / travel))
    }

    static func fraction(of hue: Int) -> CGFloat {
        CGFloat(hue - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
    }

    static func hue(of fraction: CGFloat) -> Int {
        range.lowerBound + Int((fraction * CGFloat(range.upperBound - range.lowerBound)).rounded())
    }
}
