import Foundation
import os
import SwiftUI
import UIKit

// The family of brand colors in the light appearance (palettes apply to both appearances).
// Source of truth: `light` in `shared/theme-contracts/dark-palettes.v1.json`; the default palette uses the hand-tuned values `light.palettes.dark`,
// the other presets and custom palettes are derived by `light.derivation`, ported step by step from the reference deriveLight implementation,
// with the cases `light.palettes.<id>` and `custom.derivationCases[].light` (per-channel error <= 1).

nonisolated struct OriveoLightBrand: Equatable, Sendable {
    /// Text / icons / strokes on a light page
    let ink: UInt
    /// Text at body size
    let textSafe: UInt
    /// Fill that carries only icons
    let fill: UInt
    /// Fill that carries text on top
    let fillText: UInt
    let fillPressed: UInt
    let gradStart: UInt
    let gradEnd: UInt
    /// Text / icons on a fill
    let onPrimary: UInt
    /// Light chip background
    let soft: UInt
    /// Second brand color (gradient end, glow)
    let accent: UInt
    let bgTop: UInt
    let bgBottom: UInt
    /// Model capsule background
    let pill: UInt

    /// JSON `light.palettes.dark` (the default palette's hand-tuned values)
    static let defaultBrand = OriveoLightBrand(
        ink: 0x8C5FF8, textSafe: 0x6D28D9, fill: 0x8C5FF8, fillText: 0x6D28D9, fillPressed: 0x7B3DEF,
        gradStart: 0x8347F5, gradEnd: 0x6B3BC7, onPrimary: 0xFFFFFF, soft: 0xEDE9FE, accent: 0xD946EF,
        bgTop: 0xF7F5FB, bgBottom: 0xF2EEF7, pill: 0xF3F0FA
    )

    /// Hand-tuned light values of the default palette that differ from `defaultBrand`: the default palette stays unchanged value for value, the other palettes take the lightBrand fields instead.
    enum DefaultLight {
        /// Home violet (send button, caret, soft glow, aurora ring)
        static let homePurple: UInt = 0x8B5CF6
        /// Lavender of the aurora ring / the relay page orb
        static let lavender: UInt = 0xA78BFA
        /// Pale lavender of the aurora ring / the section rule
        static let lavenderLight: UInt = 0xC4B5FD
    }

    // MARK: - Derivation parameters (JSON `light.derivation`)

    private enum Param {
        /// `ladder[key]` = (L, C)
        static let ink = (l: 0.612, c: 0.22)
        static let textSafe = (l: 0.491, c: 0.241)
        static let fill = (l: 0.612, c: 0.22)
        static let fillText = (l: 0.491, c: 0.241)
        static let fillPressed = (l: 0.545, c: 0.246)
        static let gradStart = (l: 0.57, c: 0.242)
        static let gradEnd = (l: 0.493, c: 0.204)
        static let soft = (l: 0.943, c: 0.028)
        static let accent = (l: 0.667, c: 0.259)
        static let bgTop = (l: 0.973, c: 0.008)
        static let bgBottom = (l: 0.955, c: 0.013)
        static let pill = (l: 0.96, c: 0.014)
        /// `bright[key]`
        static let brightFill = 0.75
        static let brightFillText = 0.75
        static let brightFillPressed = 0.7
        static let brightGradStart = 0.8
        static let brightGradEnd = 0.74
        static let step = 0.01
        static let minLightness = 0.2
        static let maxLightness = 0.95
        static let minInk = 3.0
        /// Ink is used for small text such as emphasized words and links: not below the 3.80 of the default hand-tuned violet #8C5FF8 on #F7F5FB (JSON minInkText)
        static let minInkText = 3.8
        static let minText = 4.5
    }

    private static let white: UInt = 0xFFFFFF

    /// Derives the light brand colors from a dark palette (step for step the same as the reference deriveLight).
    static func derive(from palette: OriveoDarkPalette) -> OriveoLightBrand {
        let hue = OriveoCustomPalette.oklch(palette.primary).h
        let accentHue = OriveoCustomPalette.oklch(palette.accent).h
        func at(_ ladder: (l: Double, c: Double), _ lightness: Double? = nil, hue h: Double = hue) -> UInt {
            OriveoCustomPalette.fromOklch(lightness ?? ladder.l, ladder.c, h)
        }
        func contrast(_ a: UInt, _ b: UInt) -> Double { OriveoCustomPalette.contrast(a, b) }
        // Step the lightness down the ladder until test(color) >= min
        func darken(_ ladder: (l: Double, c: Double), hue h: Double = hue, min: Double, test: (UInt) -> Double) -> UInt {
            var color = at(ladder, hue: h)
            var i = 1
            while test(color) < min, ladder.l - Param.step * Double(i) >= Param.minLightness {
                color = at(ladder, ladder.l - Param.step * Double(i), hue: h)
                i += 1
            }
            return color
        }

        let bgTop = at(Param.bgTop)
        let bgBottom = at(Param.bgBottom)
        let soft = at(Param.soft)
        let pill = at(Param.pill)
        let ink = darken(Param.ink, min: Param.minInkText) { contrast($0, bgTop) }
        let accent = darken(Param.accent, hue: accentHue, min: Param.minInk) { contrast($0, bgTop) }
        let textSafe = darken(Param.textSafe, min: Param.minText) {
            Swift.min(contrast($0, white), contrast($0, bgTop), contrast($0, soft))
        }

        // Fill colors: the darkened version with white text vs. a bright base with dark text; pick whichever gives the gradient start the higher chroma
        func chroma(_ lightness: Double) -> Double {
            OriveoCustomPalette.oklch(at(Param.gradStart, lightness)).c
        }
        let bright = chroma(Param.brightGradStart) > chroma(Param.gradStart.l)
        let onPrimary = bright ? palette.onPrimary : white
        func lighten(_ ladder: (l: Double, c: Double), from base: Double) -> UInt {
            var color = at(ladder, base)
            var i = 1
            while contrast(onPrimary, color) < Param.minText, base + Param.step * Double(i) <= Param.maxLightness {
                color = at(ladder, base + Param.step * Double(i))
                i += 1
            }
            return color
        }
        let fill, fillText, fillPressed, gradStart, gradEnd: UInt
        if bright {
            fill = lighten(Param.fill, from: Param.brightFill)
            fillText = lighten(Param.fillText, from: Param.brightFillText)
            fillPressed = lighten(Param.fillPressed, from: Param.brightFillPressed)
            gradStart = lighten(Param.gradStart, from: Param.brightGradStart)
            gradEnd = lighten(Param.gradEnd, from: Param.brightGradEnd)
        } else {
            fill = ink
            fillText = textSafe
            fillPressed = darken(Param.fillPressed, min: Param.minText) { contrast($0, white) }
            gradStart = darken(Param.gradStart, min: Param.minText) { contrast($0, white) }
            gradEnd = darken(Param.gradEnd, min: Param.minText) { contrast($0, white) }
        }
        return OriveoLightBrand(
            ink: ink, textSafe: textSafe, fill: fill, fillText: fillText, fillPressed: fillPressed,
            gradStart: gradStart, gradEnd: gradEnd, onPrimary: onPrimary, soft: soft, accent: accent,
            bgTop: bgTop, bgBottom: bgBottom, pill: pill
        )
    }

    // MARK: - Cache (the dynamic color provider is called on every resolution)

    fileprivate static let cache = OSAllocatedUnfairLock<[OriveoDarkPaletteChoice: OriveoLightBrand]>(initialState: [:])
}

nonisolated extension OriveoDarkPaletteChoice {
    /// This palette's brand colors in the light appearance: the default palette returns the hand-tuned constants, the others are derived by `light.derivation`.
    var lightBrand: OriveoLightBrand {
        if self == .preset(.dark) { return OriveoLightBrand.defaultBrand }
        if let hit = OriveoLightBrand.cache.withLock({ $0[self] }) { return hit }
        let result = OriveoLightBrand.derive(from: palette)
        OriveoLightBrand.cache.withLock { $0[self] = result }
        return result
    }

    /// Whether this is the default palette (in light mode it keeps hand-tuned looks such as per-tab colors and asset images)
    var isDefaultPalette: Bool { self == .preset(.dark) }
}

nonisolated extension UIColor {
    /// Brand dynamic color: light takes the current palette's `lightBrand` field, dark takes the current palette field.
    static func oriveoBrand(
        light: KeyPath<OriveoLightBrand, UInt>,
        lightAlpha: CGFloat = 1,
        dark: KeyPath<OriveoDarkPalette, UInt>,
        darkAlpha: CGFloat = 1
    ) -> UIColor {
        UIColor { trait in
            let choice = trait.oriveoDarkPalette
            if trait.userInterfaceStyle == .dark {
                return UIColor(oriveoHex: choice.palette[keyPath: dark], alpha: darkAlpha)
            }
            return UIColor(oriveoHex: choice.lightBrand[keyPath: light], alpha: lightAlpha)
        }
    }

    /// The variant where dark takes a derived token (`OriveoDarkPalette.Tint`, which carries its own alpha).
    static func oriveoBrand(
        light: KeyPath<OriveoLightBrand, UInt>,
        lightAlpha: CGFloat = 1,
        dark: KeyPath<OriveoDarkPalette, OriveoDarkPalette.Tint>
    ) -> UIColor {
        UIColor { trait in
            let choice = trait.oriveoDarkPalette
            if trait.userInterfaceStyle == .dark {
                let tint = choice.palette[keyPath: dark]
                return UIColor(oriveoHex: tint.hex, alpha: tint.alpha)
            }
            return UIColor(oriveoHex: choice.lightBrand[keyPath: light], alpha: lightAlpha)
        }
    }

    /// In light mode the default palette keeps the hand-tuned value `defaultLight` and the other palettes take the `lightBrand` field (the default palette's light values stay unchanged);
    /// dark takes the current palette field `dark`, or the fixed value `darkFixed` when it is nil.
    static func oriveoBrand(
        defaultLight: UInt,
        light: KeyPath<OriveoLightBrand, UInt>,
        lightAlpha: CGFloat = 1,
        dark: KeyPath<OriveoDarkPalette, UInt>? = nil,
        darkFixed: UInt = 0,
        darkAlpha: CGFloat = 1
    ) -> UIColor {
        UIColor { trait in
            let choice = trait.oriveoDarkPalette
            if trait.userInterfaceStyle == .dark {
                return UIColor(oriveoHex: dark.map { choice.palette[keyPath: $0] } ?? darkFixed, alpha: darkAlpha)
            }
            return UIColor(oriveoHex: choice.lightBrand(field: light, defaultLight: defaultLight), alpha: lightAlpha)
        }
    }
}

nonisolated extension OriveoDarkPaletteChoice {
    /// Takes a light brand color field; when `defaultLight` is non-nil the default palette returns it (keeping the default palette's hand-tuned value).
    func lightBrand(field: KeyPath<OriveoLightBrand, UInt>, defaultLight: UInt? = nil) -> UInt {
        if isDefaultPalette, let defaultLight { return defaultLight }
        return lightBrand[keyPath: field]
    }
}

extension Color {
    /// The SwiftUI version of `UIColor.oriveoBrand`.
    static func brand(
        light: KeyPath<OriveoLightBrand, UInt>,
        lightAlpha: CGFloat = 1,
        dark: KeyPath<OriveoDarkPalette, UInt>,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: .oriveoBrand(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
    }

    /// In light mode the default palette keeps `defaultLight` and the other palettes take the `lightBrand` field; dark takes the current palette field.
    static func brand(
        defaultLight: UInt,
        light: KeyPath<OriveoLightBrand, UInt>,
        lightAlpha: CGFloat = 1,
        dark: KeyPath<OriveoDarkPalette, UInt>,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: .oriveoBrand(
            defaultLight: defaultLight, light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha
        ))
    }

    /// In light mode the default palette keeps `defaultLight` and the other palettes take the `lightBrand` field; dark takes a fixed value.
    static func brand(
        defaultLight: UInt,
        light: KeyPath<OriveoLightBrand, UInt>,
        lightAlpha: CGFloat = 1,
        darkFixed: UInt,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: .oriveoBrand(
            defaultLight: defaultLight, light: light, lightAlpha: lightAlpha, darkFixed: darkFixed, darkAlpha: darkAlpha
        ))
    }

    /// For light-only branches: takes the current palette's (trait) light brand color field regardless of appearance (the light counterpart of `Color.darkPalette`).
    /// When `defaultLight` is non-nil the default palette uses it (keeping the default palette's original value).
    static func lightBrand(
        _ field: KeyPath<OriveoLightBrand, UInt>,
        alpha: Double = 1,
        defaultLight: UInt? = nil
    ) -> Color {
        Color(uiColor: UIColor { trait in
            UIColor(oriveoHex: trait.oriveoDarkPalette.lightBrand(field: field, defaultLight: defaultLight), alpha: CGFloat(alpha))
        })
    }
}
