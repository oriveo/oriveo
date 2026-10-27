import SwiftUI
import UIKit

// Dark palette presets.
// Source of truth for the values: `shared/theme-contracts/dark-palettes.v1.json` (shared by every client, read-only); change the JSON first when changing a value.
// Parameter names match the JSON field names one to one. Light mode is not affected by the palette.

/// Palette id; the rawValue is the JSON id, and the order follows the JSON `order`.
nonisolated enum OriveoDarkPaletteID: String, CaseIterable, Sendable {
    case dark = "dark"
    case darkPurple = "dark-purple"
    case darkGraphite = "dark-graphite"
    case darkBlack = "dark-black"
    case darkOcean = "dark-ocean"
    case darkForest = "dark-forest"
    case darkSunset = "dark-sunset"

    static let defaultID: OriveoDarkPaletteID = .dark

    /// Parsing the stored value: missing, non-string and unknown ids all fall back to the default palette (the stored value is not written back; the caller decides).
    static func resolve(_ stored: Any?) -> OriveoDarkPaletteID {
        guard let raw = stored as? String, let id = OriveoDarkPaletteID(rawValue: raw) else { return defaultID }
        return id
    }

    var palette: OriveoDarkPalette {
        switch self {
        case .dark: OriveoDarkPalettes.dark
        case .darkPurple: OriveoDarkPalettes.darkPurple
        case .darkGraphite: OriveoDarkPalettes.darkGraphite
        case .darkBlack: OriveoDarkPalettes.darkBlack
        case .darkOcean: OriveoDarkPalettes.darkOcean
        case .darkForest: OriveoDarkPalettes.darkForest
        case .darkSunset: OriveoDarkPalettes.darkSunset
        }
    }
}

/// The dark palette the user picked: one of the 7 presets, or a custom one (seed color -> a derived full palette, see `OriveoCustomPalette`).
/// The storage layer keeps `storageID` in `darkPalette`; the custom seed color lives separately in `darkPaletteCustom` (`#RRGGBB`).
nonisolated enum OriveoDarkPaletteChoice: Hashable, Sendable {
    case preset(OriveoDarkPaletteID)
    case custom(seed: UInt)

    /// JSON `custom.id`
    static let customStorageID = "custom"
    static let defaultID: OriveoDarkPaletteChoice = .preset(.defaultID)

    // Static members named after the preset ids, so `choice == .darkOcean` keeps working.
    static let dark: OriveoDarkPaletteChoice = .preset(.dark)
    static let darkPurple: OriveoDarkPaletteChoice = .preset(.darkPurple)
    static let darkGraphite: OriveoDarkPaletteChoice = .preset(.darkGraphite)
    static let darkBlack: OriveoDarkPaletteChoice = .preset(.darkBlack)
    static let darkOcean: OriveoDarkPaletteChoice = .preset(.darkOcean)
    static let darkForest: OriveoDarkPaletteChoice = .preset(.darkForest)
    static let darkSunset: OriveoDarkPaletteChoice = .preset(.darkSunset)

    var palette: OriveoDarkPalette {
        switch self {
        case let .preset(id): id.palette
        case let .custom(seed): OriveoCustomPalette.derive(seed: seed).palette
        }
    }

    /// The value written into `darkPalette`
    var storageID: String {
        switch self {
        case let .preset(id): id.rawValue
        case .custom: Self.customStorageID
        }
    }

    /// Key for caching per-palette derived assets (icons, etc.): a custom palette includes its seed color.
    var cacheKey: String {
        switch self {
        case let .preset(id): id.rawValue
        case let .custom(seed): Self.customStorageID + "|" + OriveoCustomPalette.format(seed)
        }
    }

    /// Parsing the stored value (the JSON top-level `resolveCases` and `custom.resolveCases`):
    /// `custom` + a valid seed -> custom; `custom` with a missing / invalid seed -> custom with the default seed; everything else as `OriveoDarkPaletteID.resolve`.
    static func resolve(stored: Any?, seed: Any?) -> OriveoDarkPaletteChoice {
        if let raw = stored as? String, raw == customStorageID {
            return .custom(seed: OriveoCustomPalette.parseSeed(seed) ?? OriveoCustomPalette.defaultSeed)
        }
        return .preset(OriveoDarkPaletteID.resolve(stored))
    }

    /// `darkPalette` stored values this client knows (the 7 preset ids + `custom`).
    static func isKnownStoredID(_ raw: String) -> Bool {
        raw == customStorageID || OriveoDarkPaletteID(rawValue: raw) != nil
    }
}

/// One dark palette: 15 color fields, a glow factor and 4 status colors (the status colors are shared by all palettes and written once in `dark`).
nonisolated struct OriveoDarkPalette: Equatable, Sendable {
    let bg: UInt
    let bgSubtle: UInt
    let bgInset: UInt
    let surface: UInt
    let surfaceRaised: UInt
    let text: UInt
    let textSecondary: UInt
    let textTertiary: UInt
    let primary: UInt
    let primaryHover: UInt
    let primaryActive: UInt
    let accent: UInt
    let onPrimary: UInt
    let codeBg: UInt
    let codeHeaderBg: UInt
    let glowK: Double
    let success: UInt
    let warning: UInt
    let error: UInt
    let info: UInt

    init(
        bg: UInt, bgSubtle: UInt, bgInset: UInt, surface: UInt, surfaceRaised: UInt,
        text: UInt, textSecondary: UInt, textTertiary: UInt,
        primary: UInt, primaryHover: UInt, primaryActive: UInt, accent: UInt, onPrimary: UInt,
        codeBg: UInt, codeHeaderBg: UInt, glowK: Double,
        success: UInt = OriveoDarkPalettes.dark.success,
        warning: UInt = OriveoDarkPalettes.dark.warning,
        error: UInt = OriveoDarkPalettes.dark.error,
        info: UInt = OriveoDarkPalettes.dark.info
    ) {
        self.bg = bg
        self.bgSubtle = bgSubtle
        self.bgInset = bgInset
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.text = text
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.primary = primary
        self.primaryHover = primaryHover
        self.primaryActive = primaryActive
        self.accent = accent
        self.onPrimary = onPrimary
        self.codeBg = codeBg
        self.codeHeaderBg = codeHeaderBg
        self.glowK = glowK
        self.success = success
        self.warning = warning
        self.error = error
        self.info = info
    }
}

nonisolated enum OriveoDarkPalettes {
    static let dark = OriveoDarkPalette(
        bg: 0x111113, bgSubtle: 0x151517, bgInset: 0x19191C, surface: 0x1C1C1F, surfaceRaised: 0x27272B,
        text: 0xEDEDEF, textSecondary: 0xB3B3BA, textTertiary: 0x8E8E96,
        primary: 0xA78BFA, primaryHover: 0xC4B5FD, primaryActive: 0x9370F7, accent: 0xC4B5FD, onPrimary: 0x160B2E,
        codeBg: 0x0B0B0D, codeHeaderBg: 0x17171A, glowK: 0.4,
        success: 0x6EE7A1, warning: 0xFCD34D, error: 0xF8978F, info: 0x8DB6FF
    )
    static let darkPurple = OriveoDarkPalette(
        bg: 0x130F1D, bgSubtle: 0x171224, bgInset: 0x1B152A, surface: 0x1E1830, surfaceRaised: 0x29213F,
        text: 0xEEEAF6, textSecondary: 0xBDB4D0, textTertiary: 0x9A92AE,
        primary: 0xA78BFA, primaryHover: 0xC4B5FD, primaryActive: 0x9370F7, accent: 0xF0ABFC, onPrimary: 0x160B2E,
        codeBg: 0x0E0B17, codeHeaderBg: 0x1A1528, glowK: 1
    )
    static let darkGraphite = OriveoDarkPalette(
        bg: 0x1B1D21, bgSubtle: 0x1F2125, bgInset: 0x22252A, surface: 0x25282D, surfaceRaised: 0x30343B,
        text: 0xECEEF1, textSecondary: 0xBAC0C8, textTertiary: 0x9CA2AC,
        primary: 0x6AA6FF, primaryHover: 0x94C0FF, primaryActive: 0x3B82F6, accent: 0x7DE3FF, onPrimary: 0x04132A,
        codeBg: 0x131519, codeHeaderBg: 0x212328, glowK: 1
    )
    static let darkBlack = OriveoDarkPalette(
        bg: 0x000000, bgSubtle: 0x060607, bgInset: 0x09090B, surface: 0x0C0C0E, surfaceRaised: 0x18181B,
        text: 0xE8E8EB, textSecondary: 0xABABB3, textTertiary: 0x87878F,
        primary: 0xFF6B9D, primaryHover: 0xFF94B8, primaryActive: 0xF43F7E, accent: 0x7DD3FC, onPrimary: 0x1F0410,
        codeBg: 0x0A0A0B, codeHeaderBg: 0x141416, glowK: 1
    )
    static let darkOcean = OriveoDarkPalette(
        bg: 0x061418, bgSubtle: 0x09191E, bgInset: 0x0B1D22, surface: 0x0D2127, surfaceRaised: 0x142D35,
        text: 0xE6F3F4, textSecondary: 0xA6C2C6, textTertiary: 0x7F9DA2,
        primary: 0x2DD4BF, primaryHover: 0x5EEAD4, primaryActive: 0x14B8A6, accent: 0x67B7FF, onPrimary: 0x021614,
        codeBg: 0x041013, codeHeaderBg: 0x0A1B20, glowK: 1
    )
    static let darkForest = OriveoDarkPalette(
        bg: 0x0B140F, bgSubtle: 0x0E1813, bgInset: 0x111C16, surface: 0x132019, surfaceRaised: 0x1B2B22,
        text: 0xE8F1EB, textSecondary: 0xAEC0B4, textTertiary: 0x86998D,
        primary: 0x34D399, primaryHover: 0x6EE7B7, primaryActive: 0x10B981, accent: 0xD9F99D, onPrimary: 0x03160C,
        codeBg: 0x08100C, codeHeaderBg: 0x101B15, glowK: 1
    )
    static let darkSunset = OriveoDarkPalette(
        bg: 0x16100D, bgSubtle: 0x1A1310, bgInset: 0x1E1713, surface: 0x221915, surfaceRaised: 0x2E221C,
        text: 0xF4ECE6, textSecondary: 0xC9B8AB, textTertiary: 0xA08F82,
        primary: 0xFDBA4D, primaryHover: 0xFDCF7F, primaryActive: 0xF59E0B, accent: 0xFF7E79, onPrimary: 0x241005,
        codeBg: 0x100B09, codeHeaderBg: 0x1C1511, glowK: 1
    )
}

// MARK: - Derived tokens (JSON `derived`)

nonisolated extension OriveoDarkPalette {
    /// A derived color with opacity: a field of this palette plus a fixed alpha.
    struct Tint: Equatable, Sendable {
        let hex: UInt
        let alpha: Double
    }

    var primarySubtle: Tint { Tint(hex: primary, alpha: 0.15) }
    var accentSubtle: Tint { Tint(hex: accent, alpha: 0.14) }
    var primaryGlow: Tint { Tint(hex: primary, alpha: 0.35) }
    var focusRing: Tint { Tint(hex: primary, alpha: 0.5) }
    var composerBorder: Tint { Tint(hex: primary, alpha: 0.22) }
    var surfaceOverlay: Tint { Tint(hex: bg, alpha: 0.88) }

    /// Brand gradient: 135 degrees, primary → accent. In the SwiftUI coordinate system y points down, so 135 degrees runs from top-left to bottom-right.
    static let gradientBrandAngleDeg: Double = 135
    var gradientBrandStops: [UInt] { [primary, accent] }

    /// The four aurora glows, with alpha multiplied by the palette glowK.
    var auroraBottom: Tint { Tint(hex: primary, alpha: 0.26 * glowK) }
    var auroraBottomLeft: Tint { Tint(hex: accent, alpha: 0.18 * glowK) }
    var auroraBottomRight: Tint { Tint(hex: primary, alpha: 0.16 * glowK) }
    var auroraTop: Tint { Tint(hex: accent, alpha: 0.09 * glowK) }
}

// MARK: - Runtime switching: a custom trait

/// The UIKit trait of the current dark palette. Switching = writing `window.traitOverrides`; dynamic colors re-resolve with the trait
/// and the view hierarchy is not rebuilt (forcing a refresh with a root-view `.id()` is not allowed).
nonisolated struct OriveoDarkPaletteTrait: UITraitDefinition {
    static let defaultValue: OriveoDarkPaletteChoice = .defaultID
    static let affectsColorAppearance = true
    static let name = "OriveoDarkPalette"
    static let identifier = "ai.oriveo.community.darkPalette"

    /// The full set of traits that refresh colors: light/dark plus the palette. Views that resolve CGColor by hand register `registerForTraitChanges` with it.
    static var colorAppearanceTraits: [UITrait] { [UITraitUserInterfaceStyle.self, OriveoDarkPaletteTrait.self] }
}

nonisolated extension UITraitCollection {
    var oriveoDarkPalette: OriveoDarkPaletteChoice { self[OriveoDarkPaletteTrait.self] }
}

extension UIMutableTraits {
    var oriveoDarkPalette: OriveoDarkPaletteChoice {
        get { self[OriveoDarkPaletteTrait.self] }
        set { self[OriveoDarkPaletteTrait.self] = newValue }
    }
}

/// Bridges the trait to SwiftUI `@Environment(\.oriveoDarkPalette)` so both sides read the same value.
nonisolated struct OriveoDarkPaletteEnvironmentKey: EnvironmentKey, UITraitBridgedEnvironmentKey {
    static let defaultValue: OriveoDarkPaletteChoice = .defaultID

    static func read(from traitCollection: UITraitCollection) -> OriveoDarkPaletteChoice {
        traitCollection.oriveoDarkPalette
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: OriveoDarkPaletteChoice) {
        mutableTraits.oriveoDarkPalette = value
    }
}

extension EnvironmentValues {
    var oriveoDarkPalette: OriveoDarkPaletteChoice {
        get { self[OriveoDarkPaletteEnvironmentKey.self] }
        set { self[OriveoDarkPaletteEnvironmentKey.self] = newValue }
    }
}

enum OriveoDarkPaletteSwitcher {
    /// Writes the palette into the traitOverrides of every connected window. Only the trait changes; the preference is driven by AppPreference.darkPalette, see applyStoredPreference.
    @MainActor
    static func apply(_ choice: OriveoDarkPaletteChoice, to windows: [UIWindow]) {
        for window in windows {
            // Reading traitOverrides when not overridden throws NSInternalInconsistencyException, so check contains first.
            let overrides = window.traitOverrides
            if overrides.contains(OriveoDarkPaletteTrait.self), overrides.oriveoDarkPalette == choice { continue }
            window.traitOverrides.oriveoDarkPalette = choice
        }
    }

    /// Stored preference value → window trait: unset / unknown ids use the default dark; `custom` takes the seed color (a missing / invalid one uses the default seed).
    @MainActor
    static func applyStoredPreference(_ stored: String?, seed: String?, to windows: [UIWindow]? = nil) {
        let choice = OriveoDarkPaletteChoice.resolve(stored: stored, seed: seed)
        if let windows {
            apply(choice, to: windows)
        } else {
            applyToAllWindows(choice)
        }
    }

    @MainActor
    static func applyToAllWindows(_ choice: OriveoDarkPaletteChoice) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        apply(choice, to: windows)
    }
}

// MARK: - Dynamic colors

nonisolated extension UIColor {
    /// Light mode takes a fixed value; dark mode takes a field of the current palette (trait).
    static func oriveoDynamic(
        light: UInt,
        dark: KeyPath<OriveoDarkPalette, UInt>,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> UIColor {
        UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(oriveoHex: trait.oriveoDarkPalette.palette[keyPath: dark], alpha: darkAlpha)
            }
            return UIColor(oriveoHex: light, alpha: lightAlpha)
        }
    }

    convenience init(oriveoHex hex: UInt, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex & 0xFF0000) >> 16) / 255,
            green: CGFloat((hex & 0x00FF00) >> 8) / 255,
            blue: CGFloat(hex & 0x0000FF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// A dynamic color whose dark slot references a field of the current palette (the palette version of `Color.dynamic(light:dark:)`).
    static func dynamic(
        light: UInt,
        dark: KeyPath<OriveoDarkPalette, UInt>,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: .oriveoDynamic(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }
}
