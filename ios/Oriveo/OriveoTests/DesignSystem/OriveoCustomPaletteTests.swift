import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Custom dark palette: derivation, hue slider and stored-value parsing; the cases are always read from
/// the `custom` section of `shared/theme-contracts/dark-palettes.v1.json`.
@Suite("Custom dark palette")
struct OriveoCustomPaletteTests {
    static func customContract() throws -> [String: Any] {
        try #require(try OriveoDarkPalettesTests.loadContract()["custom"] as? [String: Any])
    }

    @Test("defaultSeed / presets match the JSON")
    func seedsMatchContract() throws {
        let custom = try Self.customContract()
        let defaultSeed = try #require(custom["defaultSeed"] as? String)
        #expect(OriveoCustomPalette.defaultSeed == (try OriveoDarkPalettesTests.hex(defaultSeed)))
        let presets = try #require(custom["presets"] as? [String])
        #expect(OriveoCustomPalette.presets == (try presets.map(OriveoDarkPalettesTests.hex)))
    }

    @Test("derivationCases: every field of every case is within 1 per channel, and adjusted is equal")
    func derivationCasesMatch() throws {
        let cases = try #require(try Self.customContract()["derivationCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let seedString = try #require(item["seed"] as? String)
            let seed = try #require(OriveoCustomPalette.parseSeed(seedString))
            let expect = try #require(item["expect"] as? [String: String])
            let derived = OriveoCustomPalette.derive(seed: seed)
            for (field, hexString) in expect {
                let keyPath = try #require(OriveoDarkPalettesTests.colorFields[field], "unknown field \(field)")
                let expected = try OriveoDarkPalettesTests.hex(hexString)
                let actual = derived.palette[keyPath: keyPath]
                for shift in [16, 8, 0] {
                    let e = Int((expected >> UInt(shift)) & 0xFF)
                    let a = Int((actual >> UInt(shift)) & 0xFF)
                    #expect(abs(e - a) <= 1, "\(seedString).\(field): expected \(hexString), got \(OriveoCustomPalette.format(actual))")
                }
            }
            let adjusted = item["adjusted"] as? String
            #expect(derived.adjusted?.rawValue == adjusted, "\(seedString) adjusted")
        }
    }

    @Test("hueSliderSeed matches the reference implementation")
    func hueSliderSeedMatchesReference() {
        // The expected values come from the reference hueSliderSeed implementation
        #expect(OriveoCustomPalette.hueSliderSeed(0) == 0xFF8FB4)
        #expect(OriveoCustomPalette.hueSliderSeed(200) == 0x07D0D8)
    }

    @Test("parseSeed accepts only #RRGGBB, and format outputs uppercase")
    func parseAndFormat() {
        #expect(OriveoCustomPalette.parseSeed("#c084fc") == 0xC084FC)
        #expect(OriveoCustomPalette.parseSeed("#C084FC") == 0xC084FC)
        #expect(OriveoCustomPalette.parseSeed("C084FC") == nil)
        #expect(OriveoCustomPalette.parseSeed("#C084F") == nil)
        #expect(OriveoCustomPalette.parseSeed("#C084FG") == nil)
        #expect(OriveoCustomPalette.parseSeed("blue") == nil)
        #expect(OriveoCustomPalette.parseSeed(42) == nil)
        #expect(OriveoCustomPalette.parseSeed(nil) == nil)
        #expect(OriveoCustomPalette.format(0xC084FC) == "#C084FC")
        #expect(OriveoCustomPalette.format(0x00000A) == "#00000A")
    }

    @Test("custom.resolveCases: the rendered palette")
    func customResolveCases() throws {
        let cases = try #require(try Self.customContract()["resolveCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let stored = item["stored"] as? String
            let storedSeed = item["storedSeed"] as? String
            let renders = try #require(item["renders"] as? String)
            let choice = OriveoDarkPaletteChoice.resolve(stored: stored, seed: storedSeed)
            #expect(choice.storageID == renders, "\(name)")
            if let seedString = item["seed"] as? String {
                #expect(choice == .custom(seed: try OriveoDarkPalettesTests.hex(seedString)), "\(name)")
            } else {
                #expect(choice == .preset(try #require(OriveoDarkPaletteID(rawValue: renders))), "\(name)")
            }

            var preference = AppPreference(theme: .dark, language: .system)
            preference.darkPalette = stored
            preference.darkPaletteCustom = storedSeed
            #expect(preference.resolvedDarkPalette == choice, "\(name)")
        }
    }

    @Test("Switching the trait from custom(A) to custom(B): the dynamic color resolves to two different values")
    func traitSwitchBetweenCustomSeedsReResolves() {
        let color = UIColor.oriveoDynamic(light: 0xF8FAFC, dark: \.primary)
        func resolve(_ seed: UInt) -> UInt {
            let traits = UITraitCollection { traits in
                traits.userInterfaceStyle = .dark
                traits.oriveoDarkPalette = .custom(seed: seed)
            }
            return OriveoDarkPalettesTests.hex(of: color.resolvedColor(with: traits))
        }
        let a = resolve(0xFF8A65)
        let b = resolve(0x22D3EE)
        #expect(a != b)
        #expect(a == OriveoCustomPalette.derive(seed: 0xFF8A65).palette.primary)
        #expect(b == OriveoCustomPalette.derive(seed: 0x22D3EE).palette.primary)
    }

    @Test("Choice: storageID / cacheKey / isKnownStoredID")
    func choiceIdentity() {
        #expect(OriveoDarkPaletteChoice.darkOcean.storageID == "dark-ocean")
        #expect(OriveoDarkPaletteChoice.custom(seed: 0xC084FC).storageID == "custom")
        #expect(OriveoDarkPaletteChoice.custom(seed: 0xC084FC).cacheKey != OriveoDarkPaletteChoice.custom(seed: 0xFB7185).cacheKey)
        #expect(OriveoDarkPaletteChoice.isKnownStoredID("custom"))
        #expect(OriveoDarkPaletteChoice.isKnownStoredID("dark-forest"))
        #expect(!OriveoDarkPaletteChoice.isKnownStoredID("dark-aurora-future"))
        #expect(OriveoDarkPaletteChoice.defaultID == .preset(.dark))
    }
}
