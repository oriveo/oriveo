import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Inline code and table headers in chat Markdown follow the current palette in dark mode (shared/theme-contracts/dark-palettes.v1.json); light values are unchanged.
/// All colors are trait-dynamic: one UIColor instance resolves to different values under different palette traits, so switching palettes works without a rebuild.
@MainActor
@Suite("Markdown dark palette colors")
struct MarkdownDarkPaletteColorTests {
    /// The accent and surfaceRaised of the forest / sunset palettes in the JSON
    private static let expected: [(id: OriveoDarkPaletteID, accent: UInt, surfaceRaised: UInt)] = [
        (.darkForest, 0xD9F99D, 0x1B2B22),
        (.darkSunset, 0xFF7E79, 0x2E221C),
    ]
    /// The surface and bgInset of the forest / sunset palettes in the JSON
    private static let tableBody: [(id: OriveoDarkPaletteID, surface: UInt, bgInset: UInt)] = [
        (.darkForest, 0x132019, 0x111C16),
        (.darkSunset, 0x221915, 0x1E1713),
    ]

    private static func traits(_ style: UIUserInterfaceStyle, _ palette: OriveoDarkPaletteID = .darkForest) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.oriveoDarkPalette = palette
        }
    }

    private static func rgba(_ color: UIColor, _ traits: UITraitCollection) -> (hex: UInt, alpha: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = (UInt((r * 255).rounded()) << 16) | (UInt((g * 255).rounded()) << 8) | UInt((b * 255).rounded())
        return (hex, (Double(a) * 100).rounded() / 100)
    }

    /// A SwiftUI Color is resolved by environment (light/dark plus palette, bridged to the trait): under a remote runtime UIColor(Color) loses the dynamic provider, so it cannot be taken that way.
    static func rgba(_ color: Color, _ style: ColorScheme, _ palette: OriveoDarkPaletteID = .darkForest) -> (hex: UInt, alpha: Double) {
        var env = EnvironmentValues()
        env.colorScheme = style
        env.oriveoDarkPalette = palette
        return rgba(UIColor(cgColor: color.resolve(in: env).cgColor), traits(.light))
    }

    @Test("inline code: dark text = the palette accent on a 7% white background; light mode is still 0x0F172A / 0xE2E8F0")
    func inlineCodeFollowsPalette() {
        for item in Self.expected {
            let dark = Self.traits(.dark, item.id)
            #expect(Self.rgba(MarkdownAttributedStringRenderer.codeFg, dark).hex == item.accent, "\(item.id.rawValue)")
            let bg = Self.rgba(MarkdownAttributedStringRenderer.codeBg, dark)
            #expect(bg.hex == 0xFFFFFF && bg.alpha == 0.07, "\(item.id.rawValue)")
        }
        let light = Self.traits(.light)
        #expect(Self.rgba(MarkdownAttributedStringRenderer.codeFg, light).hex == 0x0F172A)
        #expect(Self.rgba(MarkdownAttributedStringRenderer.codeBg, light).hex == 0xE2E8F0)
    }

    @Test("inline code: the run colors actually produced by the UIKit path of MarkdownMessageView resolve with the palette")
    func messageViewInlineCodeRunUsesPaletteAccent() throws {
        let rendered = CachedMarkdownView.renderMarkdown("use `foo` here", isDark: true)
        let ns = rendered.string as NSString
        let location = ns.range(of: "foo").location
        #expect(location != NSNotFound)
        let fg = try #require(rendered.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor)
        for item in Self.expected {
            #expect(Self.rgba(fg, Self.traits(.dark, item.id)).hex == item.accent, "\(item.id.rawValue)")
        }
    }

    @Test("table header background: dark = the palette surfaceRaised (renderer / table card / streaming table card); light mode is still 0xF1F5F9")
    func tableHeaderFollowsPalette() {
        let colors = [
            MarkdownAttributedStringRenderer.tableHeaderBg,
            UIKitTableCard.headerBg,
            UIKitStreamingTableCard.headerBg,
        ]
        for color in colors {
            for item in Self.expected {
                #expect(Self.rgba(color, Self.traits(.dark, item.id)).hex == item.surfaceRaised, "\(item.id.rawValue)")
            }
            #expect(Self.rgba(color, Self.traits(.light)).hex == 0xF1F5F9)
        }
    }

    @Test("table body: dark cell background = the palette surface, zebra rows = the palette bgInset, grid lines = shared.border (white at 10%); light mode is unchanged")
    func tableBodyFollowsPalette() {
        for item in Self.tableBody {
            let dark = Self.traits(.dark, item.id)
            #expect(Self.rgba(UIKitTableCard.cellBg, dark).hex == item.surface, "\(item.id.rawValue)")
            #expect(Self.rgba(UIKitTableCard.altRowBg, dark).hex == item.bgInset, "\(item.id.rawValue)")
            let borders = [
                Self.rgba(UIKitTableCard.gridLineColor(), dark),
                Self.rgba(UIKitTableCard.gridLineColor(lightAlpha: 0.25), dark),
                Self.rgba(MarkdownMessageView.tableBorder, .dark, item.id),
                Self.rgba(MarkdownCodeBlockPalette.markdownTableBorder, .dark, item.id),
            ]
            for resolved in borders {
                #expect(resolved.hex == 0xFFFFFF && resolved.alpha == 0.1, "\(item.id.rawValue)")
            }
            #expect(Self.rgba(MarkdownMessageView.tableAltRowBg, .dark, item.id).hex == item.bgInset, "\(item.id.rawValue)")
            // Separators and field names drawn as text must stay readable, so they cannot use the 10% white line color
            #expect(Self.rgba(MarkdownAttributedStringRenderer.tableSeparatorTextColor, dark).hex == item.id.palette.textTertiary, "\(item.id.rawValue)")
            let inline = Self.rgba(MarkdownCodeBlockPalette.markdownInlineBackground, .dark, item.id)
            #expect(inline.hex == 0xFFFFFF && inline.alpha == 0.07, "\(item.id.rawValue)")
        }
        let light = Self.traits(.light)
        #expect(Self.rgba(UIKitTableCard.cellBg, light).hex == 0xFFFFFF)
        #expect(Self.rgba(UIKitTableCard.altRowBg, light).hex == 0xF8FAFC)
        let grid = Self.rgba(UIKitTableCard.gridLineColor(lightAlpha: 0.25), light)
        #expect(grid.hex == 0xCBD5E1 && grid.alpha == 0.25)
        #expect(Self.rgba(MarkdownAttributedStringRenderer.tableSeparatorTextColor, light).hex == 0xCBD5E1)
        #expect(Self.rgba(MarkdownMessageView.tableBorder, .light).hex == 0xD1D5DB)
        #expect(Self.rgba(MarkdownCodeBlockPalette.markdownTableBorder, .light).hex == 0x334155)
        #expect(Self.rgba(MarkdownCodeBlockPalette.markdownInlineBackground, .light).hex == 0x1B2740)
    }
}
