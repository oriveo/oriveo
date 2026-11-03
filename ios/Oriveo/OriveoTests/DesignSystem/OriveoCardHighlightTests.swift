import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Card sheen (rounded-surface gradient): white 0.0275 (7/255) in dark, 55% in light; layered over
/// surface fills only, never over surfaceElevated (Palette or V2). Decorative cardHighlight: white 8% in
/// dark, 55% in light.
@MainActor
@Suite("Card highlight")
struct OriveoCardHighlightTests {
    private static func rgba(_ color: Color, _ style: ColorScheme) -> (hex: UInt, alpha: Double) {
        var env = EnvironmentValues()
        env.colorScheme = style
        env.oriveoDarkPalette = .preset(.darkForest)
        let resolved = UIColor(cgColor: color.resolve(in: env).cgColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = (UInt((r * 255).rounded()) << 16) | (UInt((g * 255).rounded()) << 8) | UInt((b * 255).rounded())
        return (hex, (Double(a) * 100).rounded() / 100)
    }

    private static func rawAlpha(_ color: Color, _ style: ColorScheme) -> Double {
        var env = EnvironmentValues()
        env.colorScheme = style
        env.oriveoDarkPalette = .preset(.darkForest)
        return Double(color.resolve(in: env).opacity)
    }

    @Test("Dark card sheen is white at 7/255 alpha")
    func sheenDarkAlpha() {
        #expect(Self.rgba(OriveoTheme.Palette.cardSheen, .dark).hex == 0xFFFFFF)
        let alpha = Self.rawAlpha(OriveoTheme.Palette.cardSheen, .dark)
        #expect(abs(alpha - 0.0275) < 0.0005, "dark sheen alpha is \(alpha)")
    }

    @Test("Light card sheen is white at 55% alpha")
    func sheenLightAlpha() {
        let value = Self.rgba(OriveoTheme.Palette.cardSheen, .light)
        #expect(value.hex == 0xFFFFFF)
        #expect(value.alpha == 0.55)
    }

    @Test("Dark highlight is white at 8% alpha")
    func darkAlpha() {
        let value = Self.rgba(OriveoTheme.Palette.cardHighlight, .dark)
        #expect(value.hex == 0xFFFFFF)
        #expect(value.alpha == 0.08)
    }

    @Test("Light highlight stays white at 55% alpha")
    func lightAlpha() {
        let value = Self.rgba(OriveoTheme.Palette.cardHighlight, .light)
        #expect(value.hex == 0xFFFFFF)
        #expect(value.alpha == 0.55)
    }

    @Test("Highlight applies over surface")
    func appliesOverSurface() {
        #expect(OriveoCardHighlight.applies(to: OriveoTheme.Palette.surface))
    }

    @Test("Highlight applies over surface in light even though surface and surfaceElevated resolve alike")
    func appliesOverSurfaceInLight() {
        #expect(Self.rgba(OriveoTheme.Palette.surface, .light).hex == Self.rgba(OriveoTheme.Palette.surfaceElevated, .light).hex)
        #expect(OriveoCardHighlight.applies(to: OriveoTheme.Palette.surface))
    }

    @Test("Highlight does not apply over surfaceElevated")
    func skipsSurfaceElevated() {
        #expect(!OriveoCardHighlight.applies(to: OriveoTheme.Palette.surfaceElevated))
        #expect(!OriveoCardHighlight.applies(to: OriveoTheme.V2.Colors.surfaceElevated))
    }
}
