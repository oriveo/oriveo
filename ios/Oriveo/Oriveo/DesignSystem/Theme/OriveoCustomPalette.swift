import Foundation
import os

// Custom dark palette: the user supplies a seed color `#RRGGBB` and a full dark palette is derived from it per the contract.
// Source of truth for the parameters: the `custom` section of `shared/theme-contracts/dark-palettes.v1.json` (`derivation` and `$steps`);
// the algorithm is ported step by step from the reference oklch / fromOklch / hueSliderSeed / deriveCustom implementation,
// with the cases `custom.derivationCases` (per-channel error <= 1).

nonisolated enum OriveoCustomPalette {
    /// The derived primary was lightened / darkened relative to the seed color (JSON `derivation.adjustedNoticeDelta`); drives the one-line notice below the picker.
    enum Adjustment: String, Sendable {
        case lightened
        case darkened
    }

    typealias Derived = (palette: OriveoDarkPalette, adjusted: Adjustment?)

    /// JSON `custom.defaultSeed`
    static let defaultSeed: UInt = 0x60A5FA
    /// JSON `custom.presets`, in the same order
    static let presets: [UInt] = [
        0xFF8A65, 0xFB923C, 0xFBBF24, 0xA3E635, 0x4ADE80, 0x2DD4BF,
        0x22D3EE, 0x60A5FA, 0x818CF8, 0xC084FC, 0xF472B6, 0xFB7185,
    ]

    // MARK: - Parameters (JSON `custom.hueSlider` / `custom.derivation` / `contrastRules`)

    enum HueSlider {
        static let lightness = 0.78
        static let chroma = 0.14
        static let min = 0
        static let max = 359
    }

    private enum Param {
        /// `derivation.familyChroma`; lightness takes the same-named field of `ladderFrom` (dark)
        static let bgChroma = 0.014
        static let bgSubtleChroma = 0.015
        static let bgInsetChroma = 0.016
        static let surfaceChroma = 0.017
        static let surfaceRaisedChroma = 0.02
        static let textChroma = 0.008
        static let textSecondaryChroma = 0.02
        static let textTertiaryChroma = 0.02
        static let codeBgChroma = 0.012
        static let codeHeaderBgChroma = 0.016
        static let minChroma = 0.04
        static let primaryLightness = (lower: 0.72, upper: 0.88)
        static let maxLightness = 0.96
        static let lightenStep = 0.01
        static let accentHueShift = 35.0
        static let accentLightnessDelta = 0.05
        static let accentChromaScale = 0.9
        static let accentMaxLightness = 0.9
        static let hoverLightnessDelta = 0.07
        static let hoverChromaScale = 0.8
        static let hoverMaxLightness = 0.94
        static let activeLightnessDelta = 0.08
        static let onPrimaryStartLightness = 0.22
        static let onPrimaryMinLightness = 0.08
        static let onPrimaryMaxChroma = 0.06
        static let gamutStep = 0.004
        static let adjustedNoticeDelta = 0.02
        static let glowK = 1.0
        /// `contrastRules.surfaces` (bg / surface / surfaceRaised)/ `minSecondaryOnSurfaces` / `minOnPrimary`
        static let minSecondaryOnSurfaces = 4.5
        static let minOnPrimary = 4.5
    }

    // MARK: - Parsing and formatting

    /// Accepts only `#RRGGBB` (either case); anything else is nil.
    static func parseSeed(_ value: Any?) -> UInt? {
        guard let string = value as? String, string.count == 7, string.first == "#" else { return nil }
        let digits = string.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt(digits, radix: 16)
    }

    /// Uppercase `#RRGGBB`
    static func format(_ seed: UInt) -> String {
        "#" + String(format: "%06X", seed & 0xFFFFFF)
    }

    /// Hue slider value (integer degrees) → seed color
    static func hueSliderSeed(_ hue: Int) -> UInt {
        fromOklch(HueSlider.lightness, HueSlider.chroma, Double(hue))
    }

    // MARK: - Derivation (cached: the dynamic color provider is called on every resolution)

    private static let cache = OSAllocatedUnfairLock<[UInt: Derived]>(initialState: [:])

    static func derive(seed: UInt) -> Derived {
        let seed = seed & 0xFFFFFF
        if let hit = cache.withLock({ $0[seed] }) { return hit }
        let result = compute(seed: seed)
        cache.withLock { $0[seed] = result }
        return result
    }

    private static func compute(seed: UInt) -> Derived {
        let ladder = OriveoDarkPalettes.dark
        let (l0, c0, hue) = oklch(seed)
        let chroma = Swift.max(c0, Param.minChroma)

        // Background and text families: lightness comes from the same-named dark field, with the seed hue and a fixed low chroma
        func family(_ ladderValue: UInt, _ familyChroma: Double) -> UInt {
            fromOklch(oklch(ladderValue).l, familyChroma, hue)
        }
        let bg = family(ladder.bg, Param.bgChroma)
        let bgSubtle = family(ladder.bgSubtle, Param.bgSubtleChroma)
        let bgInset = family(ladder.bgInset, Param.bgInsetChroma)
        let surface = family(ladder.surface, Param.surfaceChroma)
        let surfaceRaised = family(ladder.surfaceRaised, Param.surfaceRaisedChroma)
        let text = family(ladder.text, Param.textChroma)
        let textSecondary = family(ladder.textSecondary, Param.textSecondaryChroma)
        let textTertiary = family(ladder.textTertiary, Param.textTertiaryChroma)
        let codeBg = family(ladder.codeBg, Param.codeBgChroma)
        let codeHeaderBg = family(ladder.codeHeaderBg, Param.codeHeaderBgChroma)
        func minOnSurfaces(_ color: UInt) -> Double {
            Swift.min(contrast(color, bg), contrast(color, surface), contrast(color, surfaceRaised))
        }

        // Primary: lightness is clamped into the range; if it still fails the gate it is lightened step by step (hue and chroma unchanged)
        let pBase = Swift.min(Param.primaryLightness.upper, Swift.max(Param.primaryLightness.lower, l0))
        var pL = pBase
        var primary = pBase == l0 ? seed : fromOklch(pL, chroma, hue)
        var i = 1
        while minOnSurfaces(primary) < Param.minSecondaryOnSurfaces, pBase + Param.lightenStep * Double(i) <= Param.maxLightness {
            pL = pBase + Param.lightenStep * Double(i)
            primary = fromOklch(pL, chroma, hue)
            i += 1
        }

        // Accent: hue-shifted, slightly lighter and slightly less chromatic; lightened the same way if it fails the gate
        let aBase = Swift.min(Param.accentMaxLightness, pL + Param.accentLightnessDelta)
        let aChroma = chroma * Param.accentChromaScale
        let aHue = (hue + Param.accentHueShift).truncatingRemainder(dividingBy: 360)
        var accent = fromOklch(aBase, aChroma, aHue)
        i = 1
        while minOnSurfaces(accent) < Param.minSecondaryOnSurfaces, aBase + Param.lightenStep * Double(i) <= Param.maxLightness {
            accent = fromOklch(aBase + Param.lightenStep * Double(i), aChroma, aHue)
            i += 1
        }

        let primaryHover = fromOklch(
            Swift.min(Param.hoverMaxLightness, pL + Param.hoverLightnessDelta), chroma * Param.hoverChromaScale, hue
        )
        let actBase = pL - Param.activeLightnessDelta
        var primaryActive = fromOklch(actBase, chroma, hue)

        // on-primary: a dark color of the same hue, pressed down from the starting lightness until it passes the gate on all four backgrounds
        let onChroma = Swift.min(chroma, Param.onPrimaryMaxChroma)
        func minOnPrimary(_ color: UInt) -> Double {
            [primary, accent, primaryHover, primaryActive].map { contrast(color, $0) }.min() ?? 0
        }
        var onPrimary = fromOklch(Param.onPrimaryStartLightness, onChroma, hue)
        i = 1
        while minOnPrimary(onPrimary) < Param.minOnPrimary,
              Param.onPrimaryStartLightness - Param.lightenStep * Double(i) >= Param.onPrimaryMinLightness {
            onPrimary = fromOklch(Param.onPrimaryStartLightness - Param.lightenStep * Double(i), onChroma, hue)
            i += 1
        }
        // When the pressed state is so dark that on-primary fails the gate, lighten it back (not beyond the primary's lightness)
        i = 1
        while contrast(onPrimary, primaryActive) < Param.minOnPrimary, actBase + Param.lightenStep * Double(i) <= pL {
            primaryActive = fromOklch(actBase + Param.lightenStep * Double(i), chroma, hue)
            i += 1
        }

        let adjusted: Adjustment? = abs(pL - l0) > Param.adjustedNoticeDelta ? (pL > l0 ? .lightened : .darkened) : nil
        let palette = OriveoDarkPalette(
            bg: bg,
            bgSubtle: bgSubtle,
            bgInset: bgInset,
            surface: surface,
            surfaceRaised: surfaceRaised,
            text: text,
            textSecondary: textSecondary,
            textTertiary: textTertiary,
            primary: primary, primaryHover: primaryHover, primaryActive: primaryActive,
            accent: accent, onPrimary: onPrimary,
            codeBg: codeBg,
            codeHeaderBg: codeHeaderBg,
            glowK: Param.glowK
        )
        return (palette, adjusted)
    }

    // MARK: - Color math (formula for formula the same as the reference implementation)

    private static func channels(_ hex: UInt) -> [Double] {
        [Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)]
    }

    private static func toLinear(_ c: Double) -> Double {
        let s = c / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    private static func fromLinear(_ x: Double) -> Double {
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return v * 255
    }

    private static func luminance(_ hex: UInt) -> Double {
        let c = channels(hex).map(toLinear)
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }

    static func contrast(_ a: UInt, _ b: UInt) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (Swift.max(la, lb) + 0.05) / (Swift.min(la, lb) + 0.05)
    }

    static func oklch(_ hex: UInt) -> (l: Double, c: Double, h: Double) {
        let rgb = channels(hex).map(toLinear)
        let r = rgb[0], g = rgb[1], b = rgb[2]
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
        let aAxis = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
        let bAxis = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        let hue = (atan2(bAxis, aAxis) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (lightness, hypot(aAxis, bAxis), hue)
    }

    private static func toHex(_ rgb: [Double]) -> UInt {
        rgb.reduce(UInt(0)) { acc, v in
            (acc << 8) | UInt(Swift.max(0, Swift.min(255, v.rounded(.toNearestOrAwayFromZero))))
        }
    }

    /// OKLCH → sRGB: when out of gamut, chroma is lowered in gamutStep steps until it falls inside the gamut
    static func fromOklch(_ lightness: Double, _ chroma: Double, _ hue: Double) -> UInt {
        let rad = hue * .pi / 180
        var i = 0
        while chroma - Param.gamutStep * Double(i) >= 0 {
            let c = chroma - Param.gamutStep * Double(i)
            let a = c * cos(rad)
            let b = c * sin(rad)
            let l = cube(lightness + 0.3963377774 * a + 0.2158037573 * b)
            let m = cube(lightness - 0.1055613458 * a - 0.0638541728 * b)
            let s = cube(lightness - 0.0894841775 * a - 1.291485548 * b)
            let rgb = [
                4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
            ]
            if rgb.allSatisfy({ $0 >= -1e-4 && $0 <= 1 + 1e-4 }) {
                return toHex(rgb.map { fromLinear(Swift.max(0, Swift.min(1, $0))) })
            }
            i += 1
        }
        let gray = fromLinear(Swift.max(0, Swift.min(1, cube(lightness))))
        return toHex([gray, gray, gray])
    }

    private static func cube(_ x: Double) -> Double { x * x * x }
}
