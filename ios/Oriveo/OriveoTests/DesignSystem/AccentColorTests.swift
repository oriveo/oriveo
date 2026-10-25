import Testing
import UIKit
import SwiftUI
@testable import Oriveo

/// The AccentColor asset and the brand purple `Palette.primaryTextSafe` agree in both appearances (light #6D28D9 / dark #A78BFA).
@MainActor
@Suite("Accent color asset")
struct AccentColorTests {

    private static func rgba(_ color: UIColor, _ style: UIUserInterfaceStyle) -> [Int] {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    @Test("AccentColor resolves to the two primaryTextSafe values under light / dark")
    func accentMatchesPrimaryTextSafe() throws {
        let accent = try #require(UIColor(named: "AccentColor", in: Bundle(for: AppState.self), compatibleWith: nil))
        for (style, scheme) in [(UIUserInterfaceStyle.light, ColorScheme.light), (.dark, .dark)] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            // UIColor(Color) drops the dynamic provider, so resolve through the SwiftUI environment per color scheme and compare.
            let palette = UIColor(cgColor: OriveoTheme.Palette.primaryTextSafe.resolve(in: environment).cgColor)
            #expect(Self.rgba(accent, style) == Self.rgba(palette, style))
        }
        #expect(Self.rgba(accent, .light) == [0x6D, 0x28, 0xD9, 255])
        #expect(Self.rgba(accent, .dark) == [0xA7, 0x8B, 0xFA, 255])
    }
}
