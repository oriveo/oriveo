import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Dark colors of Home and the tabs follow the current palette: after switching to forest, the send button / aurora crown / card / tab tint all take the forest tokens;
/// light values are unchanged.
@MainActor
@Suite("Dark palette home colors")
struct OriveoDarkPaletteHomeColorTests {
    /// The same path as view rendering: light/dark plus palette in the SwiftUI environment (the palette key bridged to the trait).
    private static func traits(_ scheme: ColorScheme, _ palette: OriveoDarkPaletteID = .darkForest) -> EnvironmentValues {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        environment.oriveoDarkPalette = palette
        return environment
    }

    /// Resolves to 0xRRGGBB and alpha (two decimals).
    private static func resolve(_ color: Color, _ environment: EnvironmentValues) -> (hex: UInt, alpha: Double) {
        let resolved = color.resolve(in: environment)
        let channel = { (v: Float) in UInt((min(max(v, 0), 1) * 255).rounded()) }
        let hex = (channel(resolved.red) << 16) | (channel(resolved.green) << 8) | channel(resolved.blue)
        return (hex, (Double(resolved.opacity) * 100).rounded() / 100)
    }

    private static let forest = OriveoDarkPalettes.darkForest

    @Test("forest: send button = primary, arrow = onPrimary; light mode is still the fixed violet + white")
    func sendButtonFollowsPalette() {
        #expect(Self.resolve(AuroraTheme.Colors.sendFill, Self.traits(.dark)).hex == Self.forest.primary)
        #expect(Self.resolve(AuroraTheme.Colors.onSendFill, Self.traits(.dark)).hex == Self.forest.onPrimary)
        #expect(Self.resolve(AuroraTheme.Colors.sendFill, Self.traits(.light)).hex == 0x8B5CF6)
        #expect(Self.resolve(AuroraTheme.Colors.onSendFill, Self.traits(.light)).hex == 0xFFFFFF)
    }

    @Test("aurora crown: left/right = accent, middle = primary, strength multiplied by the palette glowK (forest / sunset each take their own value)")
    func auroraCrownThreeStopsFollowPalette() {
        for id in [OriveoDarkPaletteID.darkForest, .darkSunset] {
            let palette = id.palette
            let env = Self.traits(.dark, id)
            let left = Self.resolve(AuroraCrown.left, env)
            let middle = Self.resolve(AuroraCrown.middle, env)
            let right = Self.resolve(AuroraCrown.right, env)
            #expect(left.hex == palette.accent && left.alpha == palette.glowK, "\(id.rawValue)")
            #expect(middle.hex == palette.primary && middle.alpha == palette.glowK, "\(id.rawValue)")
            #expect(right.hex == palette.accent && right.alpha == palette.glowK, "\(id.rawValue)")
        }
    }

    @Test("aurora crown main color = accent, strength multiplied by the palette glowK")
    func auroraCrownFollowsPaletteAndGlowK() {
        let forestGlow = Self.resolve(AuroraCrown.left, Self.traits(.dark))
        #expect(forestGlow.hex == Self.forest.accent)
        #expect(forestGlow.alpha == Self.forest.glowK)
        #expect(Self.resolve(AuroraCrown.wash, Self.traits(.dark)).hex == Self.forest.accent)

        let defaultGlow = Self.resolve(AuroraCrown.left, Self.traits(.dark, .dark))
        #expect(defaultGlow.hex == OriveoDarkPalettes.dark.accent)
        #expect(defaultGlow.alpha == OriveoDarkPalettes.dark.glowK)
    }

    @Test("forest: card / pill / screen background take the palette surface family; light mode is unchanged")
    func surfacesFollowPalette() {
        let dark = Self.traits(.dark)
        #expect(Self.resolve(AuroraTheme.Colors.groupCardFill, dark).hex == Self.forest.surface)
        let cardFill = Self.resolve(AuroraTheme.Colors.cardFill, dark)
        #expect(cardFill.hex == Self.forest.surface && cardFill.alpha == 0.55)
        #expect(Self.resolve(AuroraTheme.Colors.pillFill, dark).hex == Self.forest.surfaceRaised)
        #expect(Self.resolve(AuroraHeroSurface.darkBaseBottom, dark).hex == Self.forest.surface)

        let light = Self.traits(.light)
        #expect(Self.resolve(AuroraTheme.Colors.groupCardFill, light).hex == 0xFFFFFF)
        #expect(Self.resolve(AuroraTheme.Colors.pillFill, light).hex == 0xF3F0FA)
        #expect(Self.resolve(AuroraTheme.Colors.accent, light).hex == 0x8B5CF6)
        #expect(Self.resolve(AuroraTheme.Colors.accent, dark).hex == Self.forest.primary)
        #expect(Self.resolve(AuroraTheme.Colors.accentGlow, dark).hex == Self.forest.accent)
    }

    @Test("tab tint: in dark mode all three tabs are the palette primary; light mode is still violet / teal / orange")
    func tabTintIsPrimaryInDark() {
        for tab in AppTab.allCases {
            #expect(Self.resolve(AppTabTint.color(for: tab), Self.traits(.dark)).hex == Self.forest.primary, "\(tab)")
        }
        let light = Self.traits(.light)
        #expect(Self.resolve(AppTabTint.color(for: .home), light).hex == 0x8C5FF8)
        #expect(Self.resolve(AppTabTint.color(for: .providers), light).hex == 0x0D9488)
        #expect(Self.resolve(AppTabTint.color(for: .settings), light).hex == 0xEA580C)
    }

    @Test("the selected tab icon in dark mode is drawn live from the palette gradient-brand and rendered as original")
    func selectedTabIconUsesBrandGradient() throws {
        let image = try #require(AppTabBrandIcon.image(for: .home, palette: .darkForest))
        #expect(image.renderingMode == .alwaysOriginal)
        #expect(image.size == UIImage(named: AppTab.home.tabBarIconAsset)?.size)
    }
}
