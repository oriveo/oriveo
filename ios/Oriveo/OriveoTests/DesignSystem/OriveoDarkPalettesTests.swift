import Foundation
import Testing
import UIKit
@testable import Oriveo

/// The dark palette presets are aligned value by value with the shared `shared/theme-contracts/dark-palettes.v1.json`.
/// Expected values are always read from the JSON, never copied into the test.
@Suite("Dark palettes contract")
struct OriveoDarkPalettesTests {
    /// JSON field name -> field on this client. Parameter names match the JSON; this table only maps the string to a KeyPath.
    static let colorFields: [String: KeyPath<OriveoDarkPalette, UInt>] = [
        "bg": \.bg, "bgSubtle": \.bgSubtle, "bgInset": \.bgInset, "surface": \.surface,
        "surfaceRaised": \.surfaceRaised, "text": \.text, "textSecondary": \.textSecondary,
        "textTertiary": \.textTertiary, "primary": \.primary, "primaryHover": \.primaryHover,
        "primaryActive": \.primaryActive, "accent": \.accent, "onPrimary": \.onPrimary,
        "codeBg": \.codeBg, "codeHeaderBg": \.codeHeaderBg,
    ]

    static let statusFields: [String: KeyPath<OriveoDarkPalette, UInt>] = [
        "success": \.success, "warning": \.warning, "error": \.error, "info": \.info,
    ]

    @Test("palette_instances_equal_json: all 7 palettes equal the JSON field by field, and the order and default id match")
    func paletteInstancesEqualJSON() throws {
        let contract = try Self.loadContract()
        let order = try #require(contract["order"] as? [String])
        #expect(OriveoDarkPaletteID.allCases.map(\.rawValue) == order)
        #expect(OriveoDarkPaletteID.defaultID.rawValue == contract["defaultId"] as? String)

        let palettes = try #require(contract["palettes"] as? [String: [String: Any]])
        let status = try #require((contract["shared"] as? [String: Any])?["status"] as? [String: String])
        for id in OriveoDarkPaletteID.allCases {
            let json = try #require(palettes[id.rawValue], "the JSON lacks \(id.rawValue)")
            let palette = id.palette
            // Every color field in the JSON needs a counterpart here (one more or one fewer counts as drift).
            let jsonColorKeys = Set(json.keys).subtracting(["name", "glowK"])
            #expect(jsonColorKeys == Set(Self.colorFields.keys), "\(id.rawValue) field sets differ")
            for (name, keyPath) in Self.colorFields {
                let expected = try Self.hex(try #require(json[name] as? String, "\(id.rawValue).\(name)"))
                #expect(palette[keyPath: keyPath] == expected, "\(id.rawValue).\(name)")
            }
            let glowK = try #require((json["glowK"] as? NSNumber)?.doubleValue)
            #expect(palette.glowK == glowK, "\(id.rawValue).glowK")
            for (name, keyPath) in Self.statusFields {
                let expected = try Self.hex(try #require(status[name]))
                #expect(palette[keyPath: keyPath] == expected, "\(id.rawValue).status.\(name)")
            }
        }
    }

    @Test("derived_tokens_follow_json: derived alphas, gradient stops and aurora factors follow the JSON derived section")
    func derivedTokensFollowJSON() throws {
        let contract = try Self.loadContract()
        let derived = try #require(contract["derived"] as? [String: Any])
        let tints: [String: KeyPath<OriveoDarkPalette, OriveoDarkPalette.Tint>] = [
            "primarySubtle": \.primarySubtle, "accentSubtle": \.accentSubtle, "primaryGlow": \.primaryGlow,
            "focusRing": \.focusRing, "composerBorder": \.composerBorder, "surfaceOverlay": \.surfaceOverlay,
        ]
        let aurora = try #require(derived["aurora"] as? [String: Any])
        #expect(aurora["scaleBy"] as? String == "glowK")
        let auroraTints: [String: KeyPath<OriveoDarkPalette, OriveoDarkPalette.Tint>] = [
            "bottom": \.auroraBottom, "bottomLeft": \.auroraBottomLeft,
            "bottomRight": \.auroraBottomRight, "top": \.auroraTop,
        ]
        let gradient = try #require(derived["gradientBrand"] as? [String: Any])
        let stops = try #require(gradient["stops"] as? [String])
        #expect(OriveoDarkPalette.gradientBrandAngleDeg == (gradient["angleDeg"] as? NSNumber)?.doubleValue)

        for id in OriveoDarkPaletteID.allCases {
            let palette = id.palette
            for (name, keyPath) in tints {
                let spec = try #require(derived[name] as? [String: Any], "\(name)")
                let (from, alpha) = try Self.tintSpec(spec)
                #expect(palette[keyPath: keyPath] == .init(hex: palette[keyPath: from], alpha: alpha), "\(id.rawValue).\(name)")
            }
            for (name, keyPath) in auroraTints {
                let spec = try #require(aurora[name] as? [String: Any], "aurora.\(name)")
                let (from, alpha) = try Self.tintSpec(spec)
                let actual = palette[keyPath: keyPath]
                #expect(actual.hex == palette[keyPath: from], "\(id.rawValue).aurora.\(name)")
                #expect(abs(actual.alpha - alpha * palette.glowK) < 1e-9, "\(id.rawValue).aurora.\(name) alpha")
            }
            let expectedStops = try stops.map { try #require(Self.colorFields[$0], "\($0)") }.map { palette[keyPath: $0] }
            #expect(palette.gradientBrandStops == expectedStops, "\(id.rawValue).gradientBrand")
        }
    }

    @Test("unknown_or_missing_palette_resolves_default: the stored value is resolved by the JSON resolveCases")
    func unknownOrMissingPaletteResolvesDefault() throws {
        let cases = try #require(try Self.loadContract()["resolveCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let stored: Any? = item["stored"] is NSNull ? nil : item["stored"]
            let renders = try #require(item["renders"] as? String)
            #expect(OriveoDarkPaletteID.resolve(stored).rawValue == renders, "\(item["name"] ?? "?")")
        }
        // A view with no trait written also gets the default palette.
        #expect(UITraitCollection().oriveoDarkPalette == .defaultID)
    }

    @Test("dynamic colors: the dark slot takes the field of the palette in the trait, and the light slot is unaffected by the palette")
    func dynamicColorResolvesPerPalette() throws {
        let color = UIColor.oriveoDynamic(light: 0xF8FAFC, dark: \.bg)
        for id in OriveoDarkPaletteID.allCases {
            let dark = UITraitCollection { traits in
                traits.userInterfaceStyle = .dark
                traits.oriveoDarkPalette = .preset(id)
            }
            let light = UITraitCollection { traits in
                traits.userInterfaceStyle = .light
                traits.oriveoDarkPalette = .preset(id)
            }
            #expect(Self.hex(of: color.resolvedColor(with: dark)) == id.palette.bg, "\(id.rawValue) dark")
            #expect(Self.hex(of: color.resolvedColor(with: light)) == 0xF8FAFC, "\(id.rawValue) light")
        }
    }

    // MARK: - Helpers

    /// The value of the palette field referenced by `dark: \.<field>` in the source (used by other tests when they resolve a token by its declaration).
    static func field(_ name: String, of id: OriveoDarkPaletteID) -> UInt? {
        guard let keyPath = colorFields[name] ?? statusFields[name] else { return nil }
        return id.palette[keyPath: keyPath]
    }

    private static func tintSpec(_ spec: [String: Any]) throws -> (KeyPath<OriveoDarkPalette, UInt>, Double) {
        let from = try #require(spec["from"] as? String)
        let keyPath = try #require(colorFields[from], "unknown field \(from)")
        let alpha = try #require((spec["alpha"] as? NSNumber)?.doubleValue)
        return (keyPath, alpha)
    }

    static func hex(_ string: String) throws -> UInt {
        #expect(string.hasPrefix("#") && string.count == 7, "\(string) is not #RRGGBB")
        return try #require(UInt(string.dropFirst(), radix: 16))
    }

    static func hex(of color: UIColor) -> UInt {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt((r * 255).rounded()) << 16) | (UInt((g * 255).rounded()) << 8) | UInt((b * 255).rounded())
    }

    static func loadContract() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("theme-contracts")
                .appendingPathComponent("dark-palettes.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
