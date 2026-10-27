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
        #expect(stops.first == ocean.accent)
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
            #expect(Self.hex(color.resolvedColor(with: trait)) == id.palette.bg)
        }
        #expect(Self.hex(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) == 0xFFFFFF)
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
