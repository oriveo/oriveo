import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Light brand colors follow the palette: the derived results are checked against the `light` section of `shared/theme-contracts/dark-palettes.v1.json`,
/// with the cases always read from it and every field within 1 per channel.
@MainActor
@Suite("Light brand colors")
struct OriveoLightBrandTests {
    nonisolated(unsafe) static let fields: [String: KeyPath<OriveoLightBrand, UInt>] = [
        "ink": \.ink, "textSafe": \.textSafe, "fill": \.fill, "fillText": \.fillText,
        "fillPressed": \.fillPressed, "gradStart": \.gradStart, "gradEnd": \.gradEnd,
        "onPrimary": \.onPrimary, "soft": \.soft, "accent": \.accent,
        "bgTop": \.bgTop, "bgBottom": \.bgBottom, "pill": \.pill,
    ]

    static func lightContract() throws -> [String: Any] {
        try #require(try OriveoDarkPalettesTests.loadContract()["light"] as? [String: Any])
    }

    /// Apart from `mode`, the fields of the expectation table must correspond one to one with `fields`; compared channel by channel
    static func expectMatches(_ brand: OriveoLightBrand, _ expect: [String: String], tolerance: Int, _ label: String) throws {
        let keys = Set(expect.keys).subtracting(["mode"])
        #expect(keys == Set(fields.keys), "\(label) field set")
        for key in keys {
            let keyPath = try #require(fields[key])
            let expected = try OriveoDarkPalettesTests.hex(try #require(expect[key]))
            let actual = brand[keyPath: keyPath]
            for shift in [16, 8, 0] {
                let e = Int((expected >> UInt(shift)) & 0xFF)
                let a = Int((actual >> UInt(shift)) & 0xFF)
                #expect(abs(e - a) <= tolerance, "\(label).\(key): expected \(expect[key] ?? ""), got \(OriveoCustomPalette.format(actual))")
            }
        }
    }

    static func lightTrait(_ choice: OriveoDarkPaletteChoice) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = .light
            traits.oriveoDarkPalette = choice
        }
    }

    @Test("light.palettes: the default palette equals its hand-tuned values exactly, the other presets are derived within 1 per channel")
    func presetsMatchContract() throws {
        let palettes = try #require(try Self.lightContract()["palettes"] as? [String: [String: String]])
        #expect(Set(palettes.keys) == Set(OriveoDarkPaletteID.allCases.map(\.rawValue)))
        for id in OriveoDarkPaletteID.allCases {
            let expect = try #require(palettes[id.rawValue], "missing \(id.rawValue)")
            let choice = OriveoDarkPaletteChoice.preset(id)
            try Self.expectMatches(choice.lightBrand, expect, tolerance: id == .defaultID ? 0 : 1, id.rawValue)
            if id != .defaultID {
                try Self.expectMatches(OriveoLightBrand.derive(from: id.palette), expect, tolerance: 1, "\(id.rawValue) derive")
            }
        }
        #expect(OriveoDarkPaletteChoice.defaultID.lightBrand == OriveoLightBrand.defaultBrand)
    }

    @Test("custom.derivationCases[].light: custom palette derivation is within 1 per channel")
    func customCasesMatchContract() throws {
        let cases = try #require(try OriveoCustomPaletteTests.customContract()["derivationCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let seedString = try #require(item["seed"] as? String)
            let seed = try #require(OriveoCustomPalette.parseSeed(seedString))
            let expect = try #require(item["light"] as? [String: String], "\(seedString) lacks light")
            try Self.expectMatches(OriveoDarkPaletteChoice.custom(seed: seed).lightBrand, expect, tolerance: 1, seedString)
        }
    }

    @Test("Palette.primary in light takes the palette's ink: Ocean gets Ocean's ink, the default is still #8C5FF8")
    func primaryFollowsPaletteInLight() {
        let primary = UIColor(OriveoTheme.Palette.primary)
        let ocean = OriveoDarkPaletteChoice.darkOcean.lightBrand.ink
        #expect(ocean != 0x8C5FF8)
        #expect(OriveoDarkPalettesTests.hex(of: primary.resolvedColor(with: Self.lightTrait(.darkOcean))) == ocean)
        #expect(OriveoDarkPalettesTests.hex(of: primary.resolvedColor(with: Self.lightTrait(.defaultID))) == 0x8C5FF8)
    }

    @Test("Markdown links in a code block: light takes the palette's textSafe (the default palette is still #7C3AED); dark takes accent")
    func codeBlockLinkFollowsPalette() {
        // SwiftUI Color resolves through the environment (a UIColor(Color) round trip loses the dynamic resolution)
        let link = MarkdownCodeBlockPalette.markdownLink
        let ocean = OriveoDarkPaletteChoice.darkOcean
        #expect(MarkdownDarkPaletteColorTests.rgba(link, .light, .darkOcean).hex == ocean.lightBrand.textSafe)
        #expect(MarkdownDarkPaletteColorTests.rgba(link, .light, .dark).hex == 0x7C3AED)
        #expect(MarkdownDarkPaletteColorTests.rgba(link, .dark, .darkOcean).hex == ocean.palette.accent)
    }

    @Test("Tab colors: the default palette is still violet / teal / orange in light mode, and Ocean uses ink for all three")
    func tabTintsFollowPaletteInLight() {
        func tint(_ tab: AppTab, _ choice: OriveoDarkPaletteChoice) -> UInt {
            OriveoDarkPalettesTests.hex(of: UIColor(AppTabTint.color(for: tab)).resolvedColor(with: Self.lightTrait(choice)))
        }
        #expect(tint(.home, .defaultID) == 0x8C5FF8)
        #expect(tint(.providers, .defaultID) == 0x0D9488)
        #expect(tint(.settings, .defaultID) == 0xEA580C)
        let ink = OriveoDarkPaletteChoice.darkOcean.lightBrand.ink
        for tab in [AppTab.home, .providers, .settings] {
            #expect(tint(tab, .darkOcean) == ink, "\(tab.rawValue)")
        }
    }

    @Test("The selected tab icon of a non-default palette is drawn live in light mode, with the appearance in the cache key")
    func lightSelectedTabIconIsRendered() throws {
        let image = try #require(AppTabBrandIcon.image(for: .home, palette: .darkOcean, light: true))
        #expect(image.renderingMode == .alwaysOriginal)
        #expect(AppTabBrandIcon._testCacheKeys.contains("home|dark-ocean|light"))
    }
}
