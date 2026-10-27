import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Dark colors in the chat area follow the current palette: the user bubble gradient-brand plus onPrimary text, and the empty-state glow aurora formula.
@MainActor
@Suite("Dark palette chat colors", .serialized)
struct OriveoDarkPaletteChatColorTests {
    @Test("after switching to ocean, the user bubble gradient ends = ocean primary/accent and the text color = onPrimary")
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
        #expect(stops == [ocean.primary, ocean.accent])
        let text = try #require(cell.bubbleTextColorForTesting)
        #expect(Self.hex(text.resolvedColor(with: cell.traitCollection)) == ocean.onPrimary)
    }

    @Test("after switching to ocean, the UITextView text color of the SwiftUI user bubble resolves to ocean onPrimary under the dark trait")
    func swiftUIUserBubbleTextFollowsOceanPalette() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.overrideUserInterfaceStyle = .dark
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hello ocean", providerKind: .relay,
            providerName: "Relay", modelName: "m", state: .delivered
        )
        let host = UIHostingController(rootView: UserMessageBubble(message: message, showMetadata: false))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        OriveoDarkPaletteSwitcher.apply(.darkOcean, to: [window])
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let textView = try #require(Self.firstTextView(in: host.view), "there is no UITextView in the bubble")
        textView.updateTraitsIfNeeded()
        #expect(textView.traitCollection.userInterfaceStyle == .dark)
        #expect(textView.traitCollection.oriveoDarkPalette == .darkOcean)
        let color = try #require(textView.textColor)
        #expect(Self.hex(color.resolvedColor(with: textView.traitCollection)) == OriveoDarkPalettes.darkOcean.onPrimary)
    }

    private static func firstTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    @Test("voice mute button inverted foreground: dark = the current palette bg (the fill is the near-white text), light mode is still white")
    func voiceMutedForegroundInvertsOnText() {
        let color = VoiceConversationBarContent.mutedForegroundUIColor
        for id in OriveoDarkPaletteID.allCases {
            let trait = UITraitCollection { traits in
                traits.userInterfaceStyle = .dark
                traits.oriveoDarkPalette = id
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
                traits.oriveoDarkPalette = id
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
