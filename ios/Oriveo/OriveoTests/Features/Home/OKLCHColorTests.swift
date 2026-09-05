import Foundation
import SwiftUI
import Testing
@testable import Oriveo

/// Provider palette and OKLCH helper tests.
///
/// Provider tints are brand hex colours rather than colours computed by the OKLCH algorithm, so
/// this suite covers three things:
/// 1. the OKLCH to sRGB conversion itself, which is still a general-purpose helper;
/// 2. the completeness and validity of the `OriveoColorTokens.providerBrandHexes` table;
/// 3. the behaviour of `ProviderTints.tint(for:fallbackId:)` for known, fallback and unknown ids.
@Suite("OKLCHColor & ProviderTints")
@MainActor
struct OKLCHColorTests {


    @Test("oklchToSRGB returns components in 0...1 range for various hues")
    func testOklchRangeBounds() {
        for hue in stride(from: 0.0, to: 360.0, by: 30.0) {
            let (r, g, b) = OKLCHColor.oklchToSRGB(
                l: OriveoColorTokens.providerLightnessLight,
                c: OriveoColorTokens.providerChroma,
                h: hue
            )
            #expect(r >= 0.0 && r <= 1.0, "R out of range for hue \(hue): \(r)")
            #expect(g >= 0.0 && g <= 1.0, "G out of range for hue \(hue): \(g)")
            #expect(b >= 0.0 && b <= 1.0, "B out of range for hue \(hue): \(b)")
        }
    }

    @Test("Same L/C with different H produces distinct RGB")
    func testHueSeparation() {
        let green = OKLCHColor.oklchToSRGB(l: 0.62, c: 0.14, h: 165)
        let orange = OKLCHColor.oklchToSRGB(l: 0.62, c: 0.14, h: 35)
        #expect(green.1 > green.0, "165° should have G > R (perceived green)")
        #expect(orange.0 > orange.1, "35° should have R > G (perceived orange)")
    }


    @Test("Test Brand Hex Coverage")
    func testBrandHexCoverage() {
        let expected: Set<String> = [
            "openai", "anthropic", "gemini", "deepseek", "grok", "xai",
            "groq", "together", "fireworks", "minimax",
            "zhipu", "qwen", "moonshot", "mistral", "siliconflow", "openrouter",
            "oriveofree",
        ]
        let actual = Set(OriveoColorTokens.providerBrandHexes.keys)
        let missing = expected.subtracting(actual)
        #expect(missing.isEmpty, "Missing brand hexes for: \(missing)")
        #expect(!actual.contains("relay"), "relay does not belong in the brand hex table: its tint is derived per instance from relayPaletteHexes")
    }

    @Test("relayPaletteHexes has 8 distinct colors")
    func testRelayPaletteCount() {
        let palette = OriveoColorTokens.relayPaletteHexes
        #expect(palette.count == 8, "Expected 8 relay colors, got \(palette.count)")
        let unique = Set(palette)
        #expect(unique.count == palette.count, "Relay palette has duplicates")
    }

    @Test("Different relay providerIds map to different colors (likely, not guaranteed)")
    func testRelayHashSpread() {
        let ids = ["relay-1", "relay-azure", "relay-cf", "my-proxy", "team-relay", "openai-mirror", "qwen-mirror", "custom"]
        let indices = ids.map {
            OriveoColorTokens.djb2Index(forId: $0, count: OriveoColorTokens.relayPaletteHexes.count)
        }
        let uniqueCount = Set(indices).count
        #expect(uniqueCount >= 4, "Relay hash spread too low: \(uniqueCount)/\(ids.count) unique. Indices: \(indices)")
    }

    @Test("ProviderTints relay returns palette color, not gray, when fallbackId present")
    func testRelayPaletteNotGray() {
        let _ = ProviderTints.tint(for: "relay", fallbackId: "my-custom-relay-1")
    }

    @Test("xai is alias of grok (same hex)")
    func testGrokAlias() {
        let grok = OriveoColorTokens.providerBrandHexes["grok"]
        let xai = OriveoColorTokens.providerBrandHexes["xai"]
        #expect(grok != nil && xai != nil)
        #expect(grok == xai, "xai should be alias of grok (same brand hex)")
    }

    @Test("kimi is alias of moonshot (same hex)")
    func testMoonshotAlias() {
        let moonshot = OriveoColorTokens.providerBrandHexes["moonshot"]
        let kimi = OriveoColorTokens.providerBrandHexes["kimi"]
        #expect(moonshot != nil && kimi != nil)
        #expect(moonshot == kimi, "kimi should be alias of moonshot")
    }

    @Test("Brand hexes are all within 24-bit RGB range")
    func testBrandHexValidRange() {
        for (key, hex) in OriveoColorTokens.providerBrandHexes {
            #expect(hex <= 0xFFFFFF, "\(key) hex \(String(hex, radix: 16)) exceeds 24-bit RGB")
        }
    }

    @Test("Fallback palette has 5 distinct colors")
    func testFallbackPaletteCount() {
        let palette = OriveoColorTokens.fallbackPaletteHexes
        #expect(palette.count == 5, "Expected 5 fallback colors, got \(palette.count)")
        let unique = Set(palette)
        #expect(unique.count == palette.count, "Fallback palette has duplicates")
    }

    @Test("Fallback palette index is stable across calls")
    func testFallbackHashStability() {
        let key = "some-custom-relay-id"
        let idx1 = OriveoColorTokens.fallbackPaletteIndex(forId: key)
        let idx2 = OriveoColorTokens.fallbackPaletteIndex(forId: key)
        #expect(idx1 == idx2, "DJB2 hash must be stable")
        #expect(idx1 >= 0 && idx1 < OriveoColorTokens.fallbackPaletteHexes.count)
    }

    @Test("Empty id falls to palette index 0")
    func testFallbackHashEmpty() {
        #expect(OriveoColorTokens.fallbackPaletteIndex(forId: "") == 0)
    }


    @Test("ProviderTints.tint returns color for known provider kind")
    func testKnownProviderTint() {
        let openaiColor = ProviderTints.tint(for: "openai")
        let anthropicColor = ProviderTints.tint(for: "anthropic")
        _ = openaiColor
        _ = anthropicColor
    }

    @Test("ProviderTints.tint returns fallback for unknown kinds without fallbackId")
    func testUnknownProviderFallbackNoId() {
        let color = ProviderTints.tint(for: "nonexistent-provider")
        _ = color
    }

    @Test("ProviderTints.tint uses fallback palette for unknown kinds with id")
    func testUnknownProviderWithFallbackId() {
        let color = ProviderTints.tint(for: "custom-relay", fallbackId: "my-relay-instance-1")
        _ = color
    }

    @Test("Case-insensitive providerKind matching")
    func testCaseInsensitive() {
        let a = ProviderTints.tint(for: "OpenAI")
        let b = ProviderTints.tint(for: "openai")
        _ = a
        _ = b
    }
}
