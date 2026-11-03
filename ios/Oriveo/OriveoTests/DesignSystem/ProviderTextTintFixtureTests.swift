import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Provider text tint must match the shared fixture `provider-text-tint.v1.json` (per channel <= 1),
/// and the near-white hero pill label must read at 4.5:1 for every kind and every relay preset.
@MainActor
@Suite("Provider text tint fixture")
struct ProviderTextTintFixtureTests {
    @Test("Text tint matches every shared fixture case within one per channel")
    func providerTextTintMatchesSharedFixture() throws {
        let fixture = try Self.loadFixture()
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let id = try #require(item["id"] as? String)
            let brand = try Self.hex(item["brand"])
            let light = try Self.hex(item["light"])
            let dark = try Self.hex(item["dark"])
            let gotLight = ProviderTints.textTintHex(brand, isDark: false)
            let gotDark = ProviderTints.textTintHex(brand, isDark: true)
            #expect(Self.close(gotLight, light), "\(id) light: got \(Self.format(gotLight)), want \(Self.format(light))")
            #expect(Self.close(gotDark, dark), "\(id) dark: got \(Self.format(gotDark)), want \(Self.format(dark))")
        }
    }

    @Test("Text tint rule constants equal the fixture rule")
    func providerTextTintRuleMatchesFixture() throws {
        let fixture = try Self.loadFixture()
        let rule = try #require(fixture["rule"] as? [String: Any])
        #expect(rule["minContrast"] as? Double == ProviderTints.TextTintRule.minContrast)
        #expect(rule["step"] as? Double == ProviderTints.TextTintRule.step)
        let light = try #require(rule["light"] as? [Any]).map { try Self.hex($0) }
        let dark = try #require(rule["dark"] as? [Any]).map { try Self.hex($0) }
        #expect(light == ProviderTints.TextTintRule.lightBackgrounds)
        #expect(dark == ProviderTints.TextTintRule.darkBackgrounds)
    }

    @Test("Local brand, relay and fallback palettes equal the fixture brand colours")
    func providerTextTintPalettesMatchFixture() throws {
        let fixture = try Self.loadFixture()
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        var checked = 0
        for item in cases {
            let id = try #require(item["id"] as? String)
            let brand = try Self.hex(item["brand"])
            let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let local: UInt?
            switch parts[0] {
            case "brand":
                local = OriveoColorTokens.providerBrandHexes[parts[1]].map(UInt.init)
            case "relay":
                local = Int(parts[1]).flatMap { OriveoColorTokens.relayPaletteHexes.indices.contains($0) ? UInt(OriveoColorTokens.relayPaletteHexes[$0]) : nil }
            case "fallback":
                local = Int(parts[1]).flatMap { OriveoColorTokens.fallbackPaletteHexes.indices.contains($0) ? UInt(OriveoColorTokens.fallbackPaletteHexes[$0]) : nil }
            default:
                local = nil
            }
            guard let local else { continue }
            #expect(local == brand, "\(id): local \(Self.format(local)) differs from fixture \(Self.format(brand))")
            checked += 1
        }
        #expect(checked >= 29, "only \(checked) fixture cases matched a local palette entry")
    }

    @Test("Hero pill label reaches 4.5:1 on #F5F5F5 for every kind and relay preset")
    func heroPillLabelMeetsContrast() throws {
        let fixture = try Self.loadFixture()
        let pill = try #require(fixture["pillLabel"] as? [String: Any])
        let worst = try Self.hex(pill["worstBackground"])

        var brands: [(name: String, color: Color, isDark: Bool)] = []
        for kind in ProviderKind.allCases where kind != .relay {
            for isDark in [false, true] {
                let subdued: Color
                if kind == .grok {
                    subdued = Color(hex: UInt(0x2E3036))
                } else {
                    let raw = Self.resolve(kind.chartFill, isDark: isDark)
                    subdued = Color(hex: raw).hsbAdjusted(saturation: 0.62, brightness: 0.88)
                }
                brands.append(("\(kind.rawValue)/\(isDark ? "dark" : "light")", subdued, isDark))
            }
        }
        for id in OriveoDarkPaletteID.allCases {
            let primaries: [(String, UInt, Bool)] = [
                ("ink", OriveoDarkPaletteChoice.preset(id).lightBrand.ink, false),
                ("primary", id.palette.primary, true),
            ]
            for (field, hex, isDark) in primaries {
                let subdued = Color(hex: hex).hsbAdjusted(saturation: 0.62, brightness: 0.88)
                brands.append(("relay/\(id.rawValue)/\(field)", subdued, isDark))
            }
        }

        #expect(brands.count > 14)
        for entry in brands {
            let label = HeroPillLabel.hex(brandColor: entry.color, isDark: entry.isDark)
            let ratio = OriveoCustomPalette.contrast(label, worst)
            #expect(ratio >= 4.5, "\(entry.name): label \(Self.format(label)) is \(ratio):1 on \(Self.format(worst))")
        }
    }

    @Test("Note source badge falls back to the on-surface text-safe primary without a provider")
    func noteSourceBadgeFallsBackToTextSafe() throws {
        for isDark in [false, true] {
            let mode = isDark ? "dark" : "light"
            let fallback = Self.resolve(NoteSourceBadge.textColor(for: nil), isDark: isDark)
            let textSafe = Self.resolve(OriveoTheme.Palette.primaryTextOnSurface, isDark: isDark)
            let secondary = Self.resolve(OriveoTheme.Palette.textSecondary, isDark: isDark)
            #expect(fallback == textSafe, "\(mode): nil kind got \(Self.format(fallback)), want \(Self.format(textSafe))")
            #expect(fallback != secondary || textSafe == secondary, "\(mode): nil kind still uses textSecondary")
            for kind in ProviderKind.allCases {
                let got = Self.resolve(NoteSourceBadge.textColor(for: kind), isDark: isDark)
                let want = Self.resolve(ProviderTints.textTint(for: kind.rawValue, fallbackId: ""), isDark: isDark)
                #expect(got == want, "\(kind.rawValue) \(mode): got \(Self.format(got)), want \(Self.format(want))")
            }
        }
    }

    // MARK: - Helpers

    private static func resolve(_ color: Color, isDark: Bool) -> UInt {
        let trait = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let ui = UIColor(color).resolvedColor(with: trait)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ v: CGFloat) -> UInt { UInt((max(0, min(1, v)) * 255).rounded()) }
        return (channel(r) << 16) | (channel(g) << 8) | channel(b)
    }

    private static func hex(_ value: Any?) throws -> UInt {
        let text = try #require(value as? String)
        let cleaned = text.hasPrefix("#") ? String(text.dropFirst()) : text
        return try #require(UInt(cleaned, radix: 16), "bad hex \(text)")
    }

    private static func close(_ a: UInt, _ b: UInt) -> Bool {
        [16, 8, 0].allSatisfy { shift in
            abs(Int((a >> UInt(shift)) & 0xFF) - Int((b >> UInt(shift)) & 0xFF)) <= 1
        }
    }

    private static func format(_ hex: UInt) -> String {
        String(format: "#%06X", hex)
    }

    static func loadFixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("\u{5171}\u{4EAB}")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("provider-tint")
                .appendingPathComponent("provider-text-tint.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
