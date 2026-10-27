import SwiftUI
import UIKit

enum OriveoTheme {
    enum Palette {
        // Dark-mode token source: entries written as `\.field` in the dark slot take the current dark palette (see OriveoDarkPalettes.swift).
        static let backgroundBase = Color.dynamic(light: 0xFFFFFF, dark: \.bg)
        static let background = Color.dynamic(light: 0xF8FAFC, dark: \.bgSubtle)
        static let backgroundSecondary = Color.dynamic(light: 0xEEF2FF, dark: \.bgInset, lightAlpha: 0.72, darkAlpha: 1)
        static let surface = Color.dynamic(light: 0xFFFFFF, dark: \.surface, lightAlpha: 0.94, darkAlpha: 1)
        static let surfaceElevated = Color.dynamic(light: 0xFFFFFF, dark: \.surfaceRaised, lightAlpha: 0.98, darkAlpha: 1)
        static let surfaceInset = Color.dynamic(light: 0xF8FAFC, dark: \.bgInset, lightAlpha: 1, darkAlpha: 1)
        static let surfaceChrome = Color.dynamic(light: 0xFFFFFF, dark: \.bgSubtle, lightAlpha: 0.96, darkAlpha: 0.92)
        static let textPrimary = Color.dynamic(light: 0x18181B, dark: \.text)
        static let textSecondary = Color.dynamic(light: 0x52525B, dark: \.textSecondary)
        static let textTertiary = Color.dynamic(light: 0x71717A, dark: \.textTertiary)
        static let textDisabledOnControl = Color.dynamic(light: 0x6A6A73, dark: 0x9AA0AC)
        static let border = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
        static let borderStrong = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.18)
        static let cardHighlight = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.08)
        static let hairline = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.70, darkAlpha: 0.06)
        static let glassHighlight = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.34, darkAlpha: 0.08)
        static let scrim = Color.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.45, darkAlpha: 0.72)
        // Brand primary: violet; the dark variant is desaturated and brightened (OKLCH L≈0.69 C≈0.14)
        /// On the UIKit side take the UIColor directly instead of round-tripping through `UIColor(Color)`.
        static let primaryUIColor = UIColor.oriveoDynamic(light: 0x8C5FF8, dark: \.primary)
        static let primary = Color(uiColor: primaryUIColor)
        static let primaryPressed = Color.dynamic(light: 0x7B3DEF, dark: \.primaryHover)
        /// The text-safe fill variant of `primary`: only for accent fills that carry text on top of them
        /// (a selected segmented pill, etc.). `onPrimary` is already at the white / near-black extreme, so the
        /// only lever is the fill, which is pressed one step darker in light mode. Contrast of `onPrimary` on it:
        /// light 7.10:1 / dark 6.89:1 (the original `primary` gives only 4.11 in light mode, below AA).
        /// `primary` itself does not change: fills, icons and strokes that carry no text keep the vivid value.
        /// The dark slot points at the same value as `primary`, which already passes.
        static let primaryTextSafe = Color.dynamic(light: 0x6D28D9, dark: \.primary)
        static let primarySoft = Color.dynamic(light: 0xEDE9FE, dark: \.primary, lightAlpha: 1, darkAlpha: 0.12)
        /// Dark mode takes the current palette primary-glow (primary at 35%).
        /// The UIKit side (CALayer shadows) takes the UIColor directly instead of round-tripping through `UIColor(Color)`, which loses dynamic resolution on some systems.
        static let primaryGlowUIColor = UIColor.oriveoDynamic(light: 0x8C5FF8, lightAlpha: 0.10, dark: \.primaryGlow)
        static let primaryGlow = Color(uiColor: primaryGlowUIColor)
        // Per-tab selected colors in the tab bar: Home uses primary (violet), Providers teal, Settings orange
        static let tabAccentProviders = Color.dynamic(light: 0x0D9488, dark: 0x2DD4BF)
        static let tabAccentSettings = Color.dynamic(light: 0xEA580C, dark: 0xFB923C)
        static let success = Color.dynamic(light: 0x10B981, dark: \.success)
        static let successSoft = Color.dynamic(light: 0x10B981, dark: \.success, lightAlpha: 0.10, darkAlpha: 0.14)
        static let warning = Color.dynamic(light: 0xF59E0B, dark: \.warning)
        static let warningText = Color.dynamic(light: 0x92400E, dark: \.warning)
        static let warningSoft = Color.dynamic(light: 0xF59E0B, dark: \.warning, lightAlpha: 0.10, darkAlpha: 0.14)
        /// Outline for cards that need a look but are not errors (e.g. conflict cards); a line only, never text
        static let warningLine = Color.dynamic(light: 0xF59E0B, dark: \.warning, lightAlpha: 0.40, darkAlpha: 0.32)
        /// Grouped page background (memory page): one step darker than background so cards float
        static let backgroundGrouped = Color.dynamic(light: 0xF4F4F6, dark: \.bg)
        /// Dot-grid background of the memory atlas
        static let memoryAtlasDot = Color.dynamic(light: 0x18181B, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)
        /// Hues of the five memory groups: only for graphics such as star points, the spectrum and group glyphs; text always uses the body color (not part of contrast tests)
        struct MemoryHue {
            let about = Color.dynamic(light: 0x4F46E5, dark: 0x818CF8)
            let preferences = Color.dynamic(light: 0x0D9488, dark: 0x2DD4BF)
            let instructions = Color.dynamic(light: 0xEA580C, dark: 0xFB923C)
            let workingOn = Color.dynamic(light: 0x0891B2, dark: 0x22D3EE)
            let episodic = Color.dynamic(light: 0x7C3AED, dark: 0xA78BFA)
        }
        static let memoryHue = MemoryHue()
        /// Semantic yellow for the quoted-selection preview; keeps clear contrast with body text in light and dark.
        static let quoteSelectionHighlight = Color.dynamic(light: 0xFDE68A, dark: 0x854D0E, lightAlpha: 0.82, darkAlpha: 0.92)
        static let danger = Color.dynamic(light: 0xEF4444, dark: \.error)
        static let dangerSoft = Color.dynamic(light: 0xEF4444, dark: \.error, lightAlpha: 0.10, darkAlpha: 0.14)
        static let info = Color.dynamic(light: 0x3B82F6, dark: \.info)
        static let infoSoft = Color.dynamic(light: 0x3B82F6, dark: \.info, lightAlpha: 0.10, darkAlpha: 0.14)
        static let assistantBubble = Color.dynamic(light: 0xF3F4F6, dark: \.surface, lightAlpha: 1, darkAlpha: 1)
        static let codeBlockBg = Color.dynamic(light: 0xF4F4F5, dark: \.codeBg)
        /// Code block header bar: light mode keeps the original value (the surface of the editor-style dark panel); dark mode takes the current palette codeHeaderBg.
        static let codeBlockHeaderBgUIColor = UIColor.oriveoDynamic(light: 0x111A2E, dark: \.codeHeaderBg)
        static let codeBlockHeaderBg = Color(uiColor: codeBlockHeaderBgUIColor)
        static let codeBlockFg = Color.dynamic(light: 0x18181B, dark: 0xE4E4E7)
        static let codeInlineBg = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.06)
        // On-* foreground: text color on saturated fills (buttons, chips).
        // In light mode it is white; in dark mode the status colors are brightened (e.g. success #6EE7A1) and white text lacks contrast, so dark text is used.
        static let onPrimaryUIColor = UIColor.oriveoDynamic(light: 0xFFFFFF, dark: \.onPrimary)
        static let onPrimary = Color(uiColor: onPrimaryUIColor)
        static let onSuccess = Color.dynamic(light: 0xFFFFFF, dark: 0x062A13)
        static let onWarning = Color.dynamic(light: 0x18181B, dark: 0x18181B)
        static let onDanger = Color.dynamic(light: 0xFFFFFF, dark: 0x1F0A09)
        static let onInfo = Color.dynamic(light: 0xFFFFFF, dark: 0x0A1A3D)
        static let switchThumb = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)
        static let overlay = Color.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.45, darkAlpha: 0.72)
        static let shadow = Color.dynamic(light: 0x0F172A, dark: 0x000000, lightAlpha: 0.08, darkAlpha: 0.34)
        static let shadowStrong = Color.dynamic(light: 0x0F172A, dark: 0x000000, lightAlpha: 0.16, darkAlpha: 0.56)
        /// Solid fill of the system tab bar on iOS 18–25 (from iOS 26 the tab bar is liquid glass and this is unused)
        static let tabBar = Color.dynamic(light: 0xFFFFFF, dark: \.bgSubtle, lightAlpha: 0.94, darkAlpha: 0.88)
        // The light gradient has a subtle hue rotation, bluer violet at the start and warmer violet at the end; dark mode uses gradient-brand (primary → accent, 135°)
        /// Color stops of primaryGradient, used directly on the UIKit side (CAGradientLayer)
        static let primaryGradientUIColors: [UIColor] = [
            UIColor.oriveoDynamic(light: 0x8347F5, dark: \.primary),
            UIColor.oriveoDynamic(light: 0x6B3BC7, dark: \.accent)
        ]
        static let primaryGradientColors: [Color] = primaryGradientUIColors.map { Color(uiColor: $0) }
        static let primaryGradient = LinearGradient(
            colors: primaryGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        static let primaryGradientPressed = LinearGradient(
            colors: [
                Color.dynamic(light: 0x7238E5, dark: \.primaryActive),
                Color.dynamic(light: 0x5A2BB0, dark: \.accent)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    enum Typography {
        static let hero = brandFont(size: 28)
        static let title1 = brandFont(size: 22)
        static let title2 = Font.system(size: 18, weight: .semibold)
        static let title3 = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 16)
        static let caption = Font.system(size: 14)
        static let footnote = Font.system(size: 12)
        static let code = Font.system(size: 14, design: .monospaced)

        // MARK: - v3 quality upgrade tokens
        static func heroDisplay(_ size: CGFloat = 44) -> Font {
            .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        }
        static func display(_ size: CGFloat = 32) -> Font {
            .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        }
        static let eyebrow = Font.system(size: 11, weight: .bold)
        static let monoCaption = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
        static let monoFootnote = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()

        // Brand digits (memory page counts, date blocks, etc.): Plus Jakarta Bold + monospaced digits so the width does not jitter when they change
        static func brandDigits(_ size: CGFloat) -> Font {
            brandFont(size: size).monospacedDigit()
        }

        private static func brandFont(size: CGFloat) -> Font {
            if UIFont(name: "PlusJakartaSans-Bold", size: size) != nil {
                return .custom("PlusJakartaSans-Bold", size: size)
            }
            return .system(size: size, weight: .bold)
        }

        private static let chatFontCache: NSCache<NSString, UIFont> = {
            let cache = NSCache<NSString, UIFont>()
            cache.countLimit = 32
            return cache
        }()
        private static let chatParagraphCache: NSCache<NSString, NSParagraphStyle> = {
            let cache = NSCache<NSString, NSParagraphStyle>()
            cache.countLimit = 16
            return cache
        }()

        static func chatBodyUIFont(size: CGFloat = 17, weight: UIFont.Weight = .regular) -> UIFont {
            let key = "body-\(size)-\(weight.rawValue)" as NSString
            if let cached = chatFontCache.object(forKey: key) { return cached }
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            chatFontCache.setObject(font, forKey: key)
            return font
        }

        static func chatItalicUIFont(size: CGFloat = 17) -> UIFont {
            let key = "italic-\(size)" as NSString
            if let cached = chatFontCache.object(forKey: key) { return cached }
            let font = UIFont.italicSystemFont(ofSize: size)
            chatFontCache.setObject(font, forKey: key)
            return font
        }

        static func chatParagraphStyle(
            lineHeightMultiple: CGFloat = 1.2,
            paragraphSpacing: CGFloat = 4,
            displayScale: CGFloat = OriveoTheme.Typography.currentDisplayScale
        ) -> NSParagraphStyle {
            chatParagraphStyle(
                lineHeightMultiple: lineHeightMultiple,
                paragraphSpacing: paragraphSpacing,
                fontSize: 17,
                displayScale: displayScale
            )
        }

        /// Pixel density for static contexts without a view trait (renderers, cache pre-rendering): the
        /// current trait's displayScale. It is 0 without a host scene or off the main thread, and then
        /// falls back to 3 (the iPhone baseline). Callers that have a view should pass
        /// `traitCollection.displayScale` or SwiftUI's `@Environment(\.displayScale)` directly.
        static var currentDisplayScale: CGFloat {
            let scale = UITraitCollection.current.displayScale
            return scale > 0 ? scale : 3
        }

        static func chatParagraphStyle(
            lineHeightMultiple: CGFloat,
            paragraphSpacing: CGFloat,
            fontSize: CGFloat,
            displayScale: CGFloat
        ) -> NSParagraphStyle {
            // Align to the pixel density of the caller's screen (iPad 2x, iPhone 3x, external displays
            // vary); 0 or less falls back to 3.
            let scale = displayScale > 0 ? displayScale : 3
            let font = chatBodyUIFont(size: fontSize)
            let rawLineHeight = font.lineHeight * lineHeightMultiple
            let alignedLineHeight = (rawLineHeight * scale).rounded() / scale
            let key = "para-aligned-\(fontSize)-\(lineHeightMultiple)-\(paragraphSpacing)-\(scale)" as NSString
            if let cached = chatParagraphCache.object(forKey: key) { return cached }
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = alignedLineHeight
            paragraph.maximumLineHeight = alignedLineHeight
            paragraph.paragraphSpacing = paragraphSpacing
            let immutable = paragraph.copy() as! NSParagraphStyle
            chatParagraphCache.setObject(immutable, forKey: key)
            return immutable
        }

        static func chatBodyAttributes(
            color: UIColor,
            size: CGFloat = 17,
            weight: UIFont.Weight = .regular,
            paragraphSpacing: CGFloat = 4,
            displayScale: CGFloat = OriveoTheme.Typography.currentDisplayScale
        ) -> [NSAttributedString.Key: Any] {
            [
                .font: chatBodyUIFont(size: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: chatParagraphStyle(
                    lineHeightMultiple: 1.2,
                    paragraphSpacing: paragraphSpacing,
                    fontSize: size,
                    displayScale: displayScale
                ),
            ]
        }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Layout {
        /// Upper bound on readable content width in a wide container.
        ///
        /// The app is universal (`TARGETED_DEVICE_FAMILY = "1,2"`) and supports landscape, so a
        /// top-level page can be handed far more width than a phone in portrait: an unfolded
        /// iPhone Duo gives 867pt of safe area, a 13-inch iPad in landscape roughly 1376pt.
        /// Without a clamp a settings row turns into a long bar with the icon pinned left, the
        /// chevron pinned right, and hundreds of points of nothing in between.
        ///
        /// 620 follows what the project already did by hand (the Relay and Local compute setup
        /// footers use 608, the composer's free-tier banner 620); this token is where those
        /// settled. A phone in portrait is at most 440pt wide, so it never triggers there.
        static let contentMaxWidth: CGFloat = 620
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let full: CGFloat = 999

        static let hero: CGFloat = 24
        static let card: CGFloat = 20
        static let inset: CGFloat = 16
        static let chip: CGFloat = 10
    }
}

enum OriveoSurfaceShadowStyle {
    case none
    case soft
    case lifted
}

extension Color {
    init(hex hexString: String, alpha: CGFloat = 1) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var hexValue: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&hexValue)
        self.init(hex: UInt(hexValue), alpha: alpha)
    }

    init(hex: UInt, alpha: CGFloat = 1) {
        self.init(
            uiColor: UIColor(
                red: CGFloat((hex & 0xFF0000) >> 16) / 255,
                green: CGFloat((hex & 0x00FF00) >> 8) / 255,
                blue: CGFloat(hex & 0x0000FF) / 255,
                alpha: alpha
            )
        )
    }

    static func dynamic(light: UInt, dark: UInt, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(
            uiColor: UIColor { trait in
                let hex = trait.userInterfaceStyle == .dark ? dark : light
                let alpha = trait.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
                return UIColor(
                    red: CGFloat((hex & 0xFF0000) >> 16) / 255,
                    green: CGFloat((hex & 0x00FF00) >> 8) / 255,
                    blue: CGFloat(hex & 0x0000FF) / 255,
                    alpha: alpha
                )
            }
        )
    }
}

extension Color {
    /// Converts a palette derived color (`OriveoDarkPalette.Tint`) to a SwiftUI Color.
    init(oriveoTint tint: OriveoDarkPalette.Tint) {
        self.init(hex: tint.hex, alpha: tint.alpha)
    }

}

nonisolated extension UIColor {
    /// Light mode takes a fixed value; dark mode takes a derived color of the current palette (with a fixed alpha).
    static func oriveoDynamic(
        light: UInt,
        lightAlpha: CGFloat = 1,
        dark: KeyPath<OriveoDarkPalette, OriveoDarkPalette.Tint>
    ) -> UIColor {
        UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                let tint = trait.oriveoDarkPalette.palette[keyPath: dark]
                return UIColor(oriveoHex: tint.hex, alpha: tint.alpha)
            }
            return UIColor(oriveoHex: light, alpha: lightAlpha)
        }
    }
}

struct OriveoScreenBackground: View {
    /// Glow hue: nil = brand color (brand violet in light mode, the current palette primary in dark mode); a gold sub-brand page can pass its own hue to avoid a violet-gold clash.
    var glowTint: UInt? = nil
    /// false = draw only the base color without the brand glow (the settings home has its own top glow).
    var showsGlow: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.oriveoDarkPalette) private var darkPalette

    var body: some View {
        Rectangle()
            .fill(baseFillStyle)
            // The glow is an overlay rather than a sibling in a ZStack: a fixed 460 / 500pt circle wider than the content
            // would size the ZStack to the circle and centre it on the content area, so ignoresSafeArea could not fill
            // the side safe areas. On the Duo cover screen the content area is 382pt and the fill reached only
            // (382 + 460) / 2 = 421pt, leaving the host's white showing under the status bar column on the right.
            // An overlay takes no part in sizing.
            .overlay { if showsGlow { glow } }
            .ignoresSafeArea()
    }

    // Brand glow: gives the frosted header and composer a layer of colour to refract
    @ViewBuilder
    private var glow: some View {
        if colorScheme == .dark {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: glowTint ?? darkPalette.palette.primary, alpha: 0.14),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        // The gradient radius must equal the circle radius: a larger one leaves about 2% opacity at the circle edge and cuts a visible edge
                        endRadius: 250
                    )
                )
                .frame(width: 500, height: 500)
                .offset(y: -100)
        } else {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: glowTint ?? 0x8C5FF8, alpha: 0.07),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 230
                    )
                )
                .frame(width: 460, height: 460)
                .offset(y: -80)
        }
    }

    private var baseFillStyle: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        OriveoTheme.Palette.backgroundBase,
                        OriveoTheme.Palette.background,
                        Color(hex: darkPalette.palette.bgSubtle)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color(hex: 0xFAFBFF),
                    Color(hex: 0xF6F5FA)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct OriveoRoundedSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let fill: Color
    let border: Color
    let radius: CGFloat
    let shadow: OriveoSurfaceShadowStyle

    func body(content: Content) -> some View {
        content
            .background(backgroundShape)
            .overlay(
                roundedShape
                    .stroke(border, lineWidth: 1)
            )
            .overlay(highlightOverlay)
    }

    private var roundedShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var backgroundShape: some View {
        roundedShape
            .fill(fill)
            .overlay(
                roundedShape
                    .fill(
                        LinearGradient(
                            colors: [
                                OriveoTheme.Palette.cardHighlight,
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowYOffset)
            .shadow(color: edgeShadowColor, radius: edgeShadowRadius, y: edgeShadowYOffset)
    }

    @ViewBuilder
    private var highlightOverlay: some View {
        if colorScheme == .dark {
            roundedShape
                .stroke(OriveoTheme.Palette.hairline, lineWidth: 0.6)
                .blur(radius: 0.4)
                .mask(
                    roundedShape
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white,
                                    .white.opacity(0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        }
    }

    private var shadowColor: Color {
        switch shadow {
        case .none:
            return .clear
        case .soft:
            return OriveoTheme.Palette.shadow
        case .lifted:
            return OriveoTheme.Palette.shadowStrong
        }
    }

    private var shadowRadius: CGFloat {
        switch shadow {
        case .none:
            return 0
        case .soft:
            return colorScheme == .dark ? 16 : 8
        case .lifted:
            return colorScheme == .dark ? 26 : 14
        }
    }

    private var shadowYOffset: CGFloat {
        switch shadow {
        case .none:
            return 0
        case .soft:
            return colorScheme == .dark ? 10 : 6
        case .lifted:
            return colorScheme == .dark ? 16 : 10
        }
    }

    private var edgeShadowColor: Color {
        shadow == .none ? .clear : shadowColor.opacity(0.6)
    }

    private var edgeShadowRadius: CGFloat {
        switch shadow {
        case .none: return 0
        case .soft: return 2
        case .lifted: return 3
        }
    }

    private var edgeShadowYOffset: CGFloat {
        switch shadow {
        case .none: return 0
        case .soft: return 1
        case .lifted: return 2
        }
    }
}

extension View {
    func oriveoRoundedSurface(
        fill: Color = OriveoTheme.Palette.surface,
        border: Color = OriveoTheme.Palette.border,
        radius: CGFloat = OriveoTheme.Radius.md,
        shadow: OriveoSurfaceShadowStyle = .soft
    ) -> some View {
        modifier(
            OriveoRoundedSurfaceModifier(
                fill: fill,
                border: border,
                radius: radius,
                shadow: shadow
            )
        )
    }

    func oriveoScreenBackground(glowTint: UInt? = nil, showsGlow: Bool = true) -> some View {
        background(OriveoScreenBackground(glowTint: glowTint, showsGlow: showsGlow))
    }
}

// MARK: - V2 Design System

extension OriveoTheme {
    enum V2 {
        enum Colors {
            // V2 tokens share one authoritative palette with V1
            static let bgDefault = Color.dynamic(light: 0xFAFAFA, dark: \.bg)
            static let bgSubtle = Color.dynamic(light: 0xF4F4F5, dark: \.bgSubtle)
            static let bgInset = Color.dynamic(light: 0xF0F0F2, dark: \.bgInset)
            static let surfaceDefault = Color.dynamic(light: 0xFFFFFF, dark: \.surface)
            static let surfaceElevated = Color.dynamic(light: 0xFFFFFF, dark: \.surfaceRaised)
            static let textPrimary = Color.dynamic(light: 0x18181B, dark: \.text)
            static let textSecondary = Color.dynamic(light: 0x52525B, dark: \.textSecondary)
            static let textTertiary = Color.dynamic(light: 0x71717A, dark: \.textTertiary)
            static let borderDefault = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
            static let borderSubtle = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.06)
            static let borderEmphasis = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.18)
            static let primary = Color.dynamic(light: 0x8C5FF8, dark: \.primary)
            static let primaryHover = Color.dynamic(light: 0x7C3AED, dark: \.primaryHover)
            static let primarySubtle = Color.dynamic(light: 0x8C5FF8, dark: \.primary, lightAlpha: 0.08, darkAlpha: 0.15)
            static let warning = Color.dynamic(light: 0xF59E0B, dark: \.warning)
            static let warningSubtle = Color.dynamic(light: 0xF59E0B, dark: \.warning, lightAlpha: 0.10, darkAlpha: 0.14)
            static let danger = Color.dynamic(light: 0xEF4444, dark: \.error)
            static let shadowSm = Color.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.04, darkAlpha: 0.20)
        }

        enum Typography {
            static let body = Font.system(size: 15)
            static let caption = Font.system(size: 13)
            static let footnote = Font.system(size: 11)
        }

        enum Sp {
            static let s4: CGFloat = 4
            static let s6: CGFloat = 6
            static let s8: CGFloat = 8
            static let s12: CGFloat = 12
            static let s16: CGFloat = 16
            static let s20: CGFloat = 20
            static let s24: CGFloat = 24
            static let s32: CGFloat = 32
        }
    }
}

// MARK: - V2 Screen Background

struct OriveoV2ScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ZStack {
            if colorScheme == .dark {
                OriveoTheme.V2.Colors.bgDefault.ignoresSafeArea()
                RadialGradient(
                    colors: [Color(hex: 0x8C5FF8, alpha: 0.06), Color.clear],
                    center: .top, startRadius: 0, endRadius: 400
                ).ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [
                        Color(hex: 0xFAF8FF),
                        Color(hex: 0xF6F4FB)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ).ignoresSafeArea()
            }
        }
    }
}

// MARK: - V2 Card Shine

private struct CardShineModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.70))
                        .frame(height: 1)
                        .padding(.horizontal, 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - V2 Grouped Card

struct GroupedCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    init(cornerRadius: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content()
            .background(
                shape.fill(OriveoTheme.V2.Colors.surfaceDefault)
                    .overlay(
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.02 : 0.40),
                                    Color.clear,
                                    OriveoTheme.V2.Colors.primary.opacity(colorScheme == .dark ? 0.01 : 0.008)
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    )
            )
            .overlay(shape.stroke(OriveoTheme.V2.Colors.borderDefault, lineWidth: 1))
            .cardShine(cornerRadius: cornerRadius)
            .clipShape(shape)
    }
}

// MARK: - V2 Extensions

extension View {
    func oriveoV2ScreenBackground() -> some View {
        background(OriveoV2ScreenBackground())
    }
    func cardShine(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardShineModifier(cornerRadius: cornerRadius))
    }

    /// Clamps content to a readable width and centres it in a wider container.
    ///
    /// Apply it to the **content container inside a ScrollView**, not to the ScrollView or the
    /// page itself: the page background (gradient / aurora) hangs off the ScrollView's
    /// `.background()`, and clamping from the outside squeezes that background into a stripe
    /// with bare margins either side.
    ///
    /// ```swift
    /// ScrollView {
    ///     VStack { ... }
    ///         .oriveoContentWidth()
    /// }
    /// ```
    ///
    /// The trailing `frame(maxWidth: .infinity)` stretches the outer frame back to full width,
    /// so any material or chrome layered after this modifier still spans the container and only
    /// the content is centred.
    func oriveoContentWidth(_ maxWidth: CGFloat = OriveoTheme.Layout.contentMaxWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
