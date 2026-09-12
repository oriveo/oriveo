import SwiftUI
import UIKit

enum OriveoTheme {
    enum Palette {
        static let backgroundBase = Color.dynamic(light: 0xFFFFFF, dark: 0x0F1218)
        static let background = Color.dynamic(light: 0xF8FAFC, dark: 0x14181F)
        static let backgroundSecondary = Color.dynamic(light: 0xEEF2FF, dark: 0x181C24, lightAlpha: 0.72, darkAlpha: 1)
        static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1B1F2A, lightAlpha: 0.94, darkAlpha: 1)
        static let surfaceElevated = Color.dynamic(light: 0xFFFFFF, dark: 0x252937, lightAlpha: 0.98, darkAlpha: 1)
        static let surfaceInset = Color.dynamic(light: 0xF8FAFC, dark: 0x181C24, lightAlpha: 1, darkAlpha: 1)
        static let surfaceChrome = Color.dynamic(light: 0xFFFFFF, dark: 0x14181F, lightAlpha: 0.96, darkAlpha: 0.92)
        static let textPrimary = Color.dynamic(light: 0x18181B, dark: 0xECEEF2)
        static let textSecondary = Color.dynamic(light: 0x52525B, dark: 0xB4BAC6)
        static let textTertiary = Color.dynamic(light: 0x71717A, dark: 0x8B919E)
        static let textDisabledOnControl = Color.dynamic(light: 0x6A6A73, dark: 0x9AA0AC)
        static let border = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
        static let borderStrong = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.18)
        static let cardHighlight = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.08)
        static let hairline = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.70, darkAlpha: 0.06)
        static let glassHighlight = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.34, darkAlpha: 0.08)
        static let scrim = Color.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.45, darkAlpha: 0.72)
        static let primary = Color.dynamic(light: 0x8C5FF8, dark: 0xA78BFA)
        static let primaryPressed = Color.dynamic(light: 0x7B3DEF, dark: 0xC4B5FD)
        static let primaryTextSafe = Color.dynamic(light: 0x6D28D9, dark: 0xA78BFA)
        static let primarySoft = Color.dynamic(light: 0xEDE9FE, dark: 0xA78BFA, lightAlpha: 1, darkAlpha: 0.12)
        static let primaryGlow = Color.dynamic(light: 0x8C5FF8, dark: 0x8C5FF8, lightAlpha: 0.10, darkAlpha: 0.22)
        static let tabAccentProviders = Color.dynamic(light: 0x0D9488, dark: 0x2DD4BF)
        static let tabAccentSettings = Color.dynamic(light: 0xEA580C, dark: 0xFB923C)
        static let success = Color.dynamic(light: 0x10B981, dark: 0x6EE7A1)
        static let successSoft = Color.dynamic(light: 0x10B981, dark: 0x6EE7A1, lightAlpha: 0.10, darkAlpha: 0.14)
        static let warning = Color.dynamic(light: 0xF59E0B, dark: 0xFCD34D)
        static let warningText = Color.dynamic(light: 0x92400E, dark: 0xFCD34D)
        static let warningSoft = Color.dynamic(light: 0xF59E0B, dark: 0xFCD34D, lightAlpha: 0.10, darkAlpha: 0.14)
        static let quoteSelectionHighlight = Color.dynamic(light: 0xFDE68A, dark: 0x854D0E, lightAlpha: 0.82, darkAlpha: 0.92)
        static let danger = Color.dynamic(light: 0xEF4444, dark: 0xF8978F)
        static let dangerSoft = Color.dynamic(light: 0xEF4444, dark: 0xF8978F, lightAlpha: 0.10, darkAlpha: 0.14)
        static let info = Color.dynamic(light: 0x3B82F6, dark: 0x8DB6FF)
        static let infoSoft = Color.dynamic(light: 0x3B82F6, dark: 0x8DB6FF, lightAlpha: 0.10, darkAlpha: 0.14)
        static let userBubble = Color.dynamic(light: 0x8C5FF8, dark: 0x7C5BEE, lightAlpha: 1, darkAlpha: 1)
        static let assistantBubble = Color.dynamic(light: 0xF3F4F6, dark: 0x1B1F2A, lightAlpha: 1, darkAlpha: 1)
        static let codeBlockBg = Color.dynamic(light: 0xF4F4F5, dark: 0x0C0F16)
        static let codeBlockFg = Color.dynamic(light: 0x18181B, dark: 0xE4E4E7)
        static let codeInlineBg = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.06)
        static let onPrimary = Color.dynamic(light: 0xFFFFFF, dark: 0x0F1218)
        static let onSuccess = Color.dynamic(light: 0xFFFFFF, dark: 0x062A13)
        static let onWarning = Color.dynamic(light: 0x18181B, dark: 0x18181B)
        static let onDanger = Color.dynamic(light: 0xFFFFFF, dark: 0x1F0A09)
        static let onInfo = Color.dynamic(light: 0xFFFFFF, dark: 0x0A1A3D)
        static let switchThumb = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)
        static let overlay = Color.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.45, darkAlpha: 0.72)
        static let shadow = Color.dynamic(light: 0x0F172A, dark: 0x000000, lightAlpha: 0.08, darkAlpha: 0.34)
        static let shadowStrong = Color.dynamic(light: 0x0F172A, dark: 0x000000, lightAlpha: 0.16, darkAlpha: 0.56)
        /// Solid fill of the system tab bar on iOS 18–25 (from iOS 26 the tab bar is liquid glass and this is unused)
        static let tabBar = Color.dynamic(light: 0xFFFFFF, dark: 0x14181F, lightAlpha: 0.94, darkAlpha: 0.88)
        static let primaryGradient = LinearGradient(
            colors: [
                Color.dynamic(light: 0x8347F5, dark: 0x8347F5),
                Color.dynamic(light: 0x6B3BC7, dark: 0x6B3BC7)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        static let primaryGradientPressed = LinearGradient(
            colors: [
                Color.dynamic(light: 0x7238E5, dark: 0x7238E5),
                Color.dynamic(light: 0x5A2BB0, dark: 0x5A2BB0)
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

        static func chatParagraphStyle(lineHeightMultiple: CGFloat = 1.2, paragraphSpacing: CGFloat = 4) -> NSParagraphStyle {
            chatParagraphStyle(
                lineHeightMultiple: lineHeightMultiple,
                paragraphSpacing: paragraphSpacing,
                fontSize: 17
            )
        }

        static func chatParagraphStyle(
            lineHeightMultiple: CGFloat,
            paragraphSpacing: CGFloat,
            fontSize: CGFloat
        ) -> NSParagraphStyle {
            let scale = UIScreen.main.scale > 0 ? UIScreen.main.scale : 2.0
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
            paragraphSpacing: CGFloat = 4
        ) -> [NSAttributedString.Key: Any] {
            [
                .font: chatBodyUIFont(size: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: chatParagraphStyle(
                    lineHeightMultiple: 1.2,
                    paragraphSpacing: paragraphSpacing,
                    fontSize: size
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

struct OriveoScreenBackground: View {
    var glowTint: UInt = 0x8C5FF8

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(baseFillStyle)

            if colorScheme == .dark {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: glowTint, alpha: 0.14),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 300
                        )
                    )
                    .frame(width: 500, height: 500)
                    .offset(y: -100)
            } else {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: glowTint, alpha: 0.07),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 280
                        )
                    )
                    .frame(width: 460, height: 460)
                    .offset(y: -80)
            }
        }
        .ignoresSafeArea()
    }

    private var baseFillStyle: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        OriveoTheme.Palette.backgroundBase,
                        OriveoTheme.Palette.background,
                        Color(hex: 0x10141C)
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

    func oriveoScreenBackground(glowTint: UInt = 0x8C5FF8) -> some View {
        background(OriveoScreenBackground(glowTint: glowTint))
    }
}

// MARK: - V2 Design System

extension OriveoTheme {
    enum V2 {
        enum Colors {
            static let bgDefault = Color.dynamic(light: 0xFAFAFA, dark: 0x0F1218)
            static let bgSubtle = Color.dynamic(light: 0xF4F4F5, dark: 0x14181F)
            static let bgInset = Color.dynamic(light: 0xF0F0F2, dark: 0x181C24)
            static let surfaceDefault = Color.dynamic(light: 0xFFFFFF, dark: 0x1B1F2A)
            static let surfaceElevated = Color.dynamic(light: 0xFFFFFF, dark: 0x252937)
            static let textPrimary = Color.dynamic(light: 0x18181B, dark: 0xECEEF2)
            static let textSecondary = Color.dynamic(light: 0x52525B, dark: 0xB4BAC6)
            static let textTertiary = Color.dynamic(light: 0x71717A, dark: 0x8B919E)
            static let borderDefault = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
            static let borderSubtle = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.06)
            static let borderEmphasis = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.18)
            static let primary = Color.dynamic(light: 0x8C5FF8, dark: 0xA78BFA)
            static let primaryHover = Color.dynamic(light: 0x7C3AED, dark: 0xC4B5FD)
            static let primarySubtle = Color.dynamic(light: 0x8C5FF8, dark: 0xA78BFA, lightAlpha: 0.08, darkAlpha: 0.12)
            static let warning = Color.dynamic(light: 0xF59E0B, dark: 0xFCD34D)
            static let warningSubtle = Color.dynamic(light: 0xF59E0B, dark: 0xFCD34D, lightAlpha: 0.10, darkAlpha: 0.14)
            static let danger = Color.dynamic(light: 0xEF4444, dark: 0xF8978F)
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

    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
