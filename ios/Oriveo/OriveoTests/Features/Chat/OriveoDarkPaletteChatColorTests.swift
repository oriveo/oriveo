import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Dark colors in the chat area follow the current palette: the user bubble gradient-brand plus onPrimary text, and the empty-state glow aurora formula.
@MainActor
@Suite("Dark palette chat colors", .serialized)
struct OriveoDarkPaletteChatColorTests {
    @Test("after switching to ocean, the user bubble vertical color stops = ocean accent → primary (7 stops) and the text color = onPrimary")
    func userBubbleFollowsOceanPalette() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.overrideUserInterfaceStyle = .dark
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }

        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        root.view.addSubview(cell)
        window.layoutIfNeeded()

        OriveoDarkPaletteSwitcher.apply(.darkOcean, to: [window])
        window.layoutIfNeeded()
        cell.updateTraitsIfNeeded()
        cell.layoutIfNeeded()

        let ocean = OriveoDarkPalettes.darkOcean
        #expect(cell.traitCollection.userInterfaceStyle == .dark)
        #expect(cell.traitCollection.oriveoDarkPalette == .darkOcean)
        let stops = cell.bubbleGradientColorsForTesting.map { Self.hex(UIColor(cgColor: $0)) }
        #expect(stops == OriveoUserBubble.stops(for: .darkOcean, dark: true))
        // First stop = fixture userBubbleStops first stop (accent lightness and chroma with primary hue)
        let contract = try OriveoDarkPalettesTests.loadContract()
        let table = try #require(contract["userBubbleStops"] as? [String: [String: [String]]])
        let fixtureFirst = try #require(table[OriveoDarkPaletteID.darkOcean.rawValue]?["dark"]?.first)
        #expect(stops.first == (try OriveoDarkPalettesTests.hex(fixtureFirst)))
        #expect(stops.last == ocean.primary)
        let text = try #require(cell.bubbleTextColorForTesting)
        #expect(Self.hex(text.resolvedColor(with: cell.traitCollection)) == ocean.onPrimary)
    }

    @Test("voice mute button inverted foreground: dark = the current palette bg (the fill is the near-white text), light mode is still white")
    func voiceMutedForegroundInvertsOnText() {
        let color = VoiceConversationBarContent.mutedForegroundUIColor
        for id in OriveoDarkPaletteID.allCases {
            let trait = UITraitCollection { traits in
                traits.userInterfaceStyle = .dark
                traits.oriveoDarkPalette = .preset(id)
            }
            #expect(Self.hex(color.resolvedColor(with: trait)) == 0x18181B)
        }
        #expect(Self.hex(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) == 0xFFFFFF)
        let fill = VoiceConversationBarContent.mutedFillUIColor
        #expect(Self.hex(fill.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) == 0x7C4DFF)
        #expect(Self.hex(fill.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))) == 0xC4B5FD)
    }

    @Test("the user bubble gradient keeps its original value in light mode")
    func userBubbleLightUnchanged() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let stops = OriveoTheme.Palette.primaryGradientUIColors.map { Self.hex($0.resolvedColor(with: light)) }
        #expect(stops == [0x8347F5, 0x6B3BC7])
        #expect(Self.hex(UserMessageCell.bubbleTextColor.resolvedColor(with: light)) == 0xFFFFFF)
    }

    @Test("dark primary button foreground = the current palette onPrimary; light mode is still white")
    func primaryButtonForegroundFollowsPalette() {
        let color = OriveoPrimaryButtonStyle.foregroundUIColor
        for id in OriveoDarkPaletteID.allCases {
            let trait = UITraitCollection { traits in
                traits.userInterfaceStyle = .dark
                traits.oriveoDarkPalette = .preset(id)
            }
            #expect(Self.hex(color.resolvedColor(with: trait)) == id.palette.onPrimary)
        }
        #expect(Self.hex(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) == 0xFFFFFF)
    }

    @Test("empty-state glow bottom color = primary@0.26 x glowK")
    func auroraBottomFollowsPalette() {
        let ocean = OriveoDarkPalettes.darkOcean
        let tints = ChatEmptyStateAurora.darkGlowTints(for: .darkOcean)
        #expect(tints.bottom.hex == ocean.primary)
        #expect(abs(tints.bottom.alpha - 0.26 * ocean.glowK) < 0.0001)
        #expect(tints.top.hex == ocean.accent)

        let fallback = ChatEmptyStateAurora.darkGlowTints(for: .dark)
        #expect(fallback.bottom.hex == OriveoDarkPalettes.dark.primary)
        #expect(abs(fallback.bottom.alpha - 0.26 * 0.4) < 0.0001)
    }

    @Test("Raised-card secondary action: gray background light #F2F2F5 α1 / dark white α0.10; text light 0x3F3F46 / dark 0xEDEDEF")
    func secondaryActionTokens() {
        // UIColor(Color) drops the dynamic provider, so color is read via Color.resolve(in:), resolved by colorScheme.
        let lightFill = Self.resolved(OriveoTheme.Palette.secondaryActionFill, .light)
        let darkFill = Self.resolved(OriveoTheme.Palette.secondaryActionFill, .dark)
        #expect(Self.hex(lightFill) == 0xF2F2F5)
        #expect(abs(Self.alpha(lightFill) - 1) < 0.001)
        #expect(Self.hex(darkFill) == 0xFFFFFF)
        #expect(abs(Self.alpha(darkFill) - 0.10) < 0.001)
        #expect(Self.hex(Self.resolved(OriveoTheme.Palette.secondaryActionText, .light)) == 0x3F3F46)
        #expect(Self.hex(Self.resolved(OriveoTheme.Palette.secondaryActionText, .dark)) == 0xEDEDEF)
    }

    @Test("Neutral inset background: light #F0F0F2 alpha 1 (same as V2 bgInset), dark = palette bgInset")
    func backgroundSecondaryIsNeutralInset() {
        let light = Self.resolved(OriveoTheme.Palette.backgroundSecondary, .light)
        #expect(Self.hex(light) == 0xF0F0F2)
        #expect(abs(Self.alpha(light) - 1) < 0.001)
        #expect(Self.hex(light) == Self.hex(Self.resolved(OriveoTheme.V2.Colors.bgInset, .light)))
        let dark = Self.resolved(OriveoTheme.Palette.backgroundSecondary, .dark)
        #expect(Self.hex(dark) == Self.hex(Self.resolved(OriveoTheme.Palette.surfaceInset, .dark)))
    }

    private static func resolved(_ color: Color, _ scheme: ColorScheme) -> UIColor {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return UIColor(cgColor: color.resolve(in: environment).cgColor)
    }

    private static func alpha(_ color: UIColor) -> CGFloat {
        var alpha: CGFloat = 0
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }

    private static func hex(_ color: UIColor) -> UInt {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (UInt((red * 255).rounded()) << 16)
            | (UInt((green * 255).rounded()) << 8)
            | UInt((blue * 255).rounded())
    }
}
