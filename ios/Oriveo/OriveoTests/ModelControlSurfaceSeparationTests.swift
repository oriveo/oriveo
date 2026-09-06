import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// After Model Controls dropped its strokes, card-vs-page separation **depends entirely
/// on background contrast and shadow**.
///
/// The two mechanisms split the work across the two themes, and both are thin:
///   - Dark `#1B1F2A` on `#14181F`: ΔL* ≈ 3.7; a black shadow on a near-black ground is
///     almost invisible, so **only luminance contrast is holding**;
///   - Light `#FFFFFF` on `#F8FAFC`: ΔL* ≈ 1.8; luminance contrast is almost gone, so
///     **only the shadow is holding**.
///
/// Both are well below WCAG's 3:1 non-text UI-component boundary (measured 1.05 / 1.08).
/// The design is internally consistent, but if either side is silently weakened — someone
/// retunes a theme token, someone deletes the "redundant" shadow — that theme collapses
/// into a flat sheet and no existing test will fail. This suite drives a stake into each
/// of those two thin boundaries.
///
/// **It cannot replace a device visual check**: it can only tell whether the separation
/// mechanism is still there, not whether it looks good.
@Suite("Model Controls surface separation", .serialized)
@MainActor
struct ModelControlSurfaceSeparationTests {
    /// Current measured value, floored with a little slack. **May only rise, never fall**:
    /// raising it means separation got stronger; lowering it silently weakens the only
    /// mechanism holding dark-theme separation.
    private static let minimumDarkDeltaLStar = 3.0
    /// Light-theme luminance contrast is already near zero, so there is no contrast floor
    /// here — the shadow owns that theme; see `lightThemeKeepsShadow`.
    private static let minimumLightDeltaLStar = 1.0

    /// Colours are parsed out of the `OriveoTheme.swift` declarations rather than resolved
    /// through `UIColor(Color)`, and that is deliberate: bridging
    /// `Color(uiColor: UIColor { trait in ... })` back to `UIColor` drops the dynamic provider,
    /// so both themes resolve to the same light value (`traits.performAsCurrent` does not
    /// recover it either). Measuring through the bridge fails silently — a colour still comes
    /// back and every assertion still runs, they just measure the wrong object. Reading the two
    /// numbers written in the product avoids the bridge entirely.
    ///
    /// The dark theme measures `surfaceElevated` (#252937, ΔL* 8.6), not `surface`
    /// (#1B1F2A, ΔL* 3.7), because that is what `ModelControlSurface` fills with in dark mode.
    /// The token this reads has to follow the component, or it measures a card that is not on
    /// screen.
    @Test("Card and page stay separable by luminance in both themes")
    func surfaceSeparatesFromBackground() throws {
        for (theme, floor) in [
            ("dark", Self.minimumDarkDeltaLStar),
            ("light", Self.minimumLightDeltaLStar),
        ] {
            let background = try Self.declaredToken("background", theme)
            let surface = try Self.declaredToken(Self.surfaceToken(theme), theme)
            // surface carries alpha (light 0.94); perceived color is the composite over background.
            let composited = Self.composite(surface, over: background)
            let delta = Self.lStar(composited) - Self.lStar(background)
            #expect(
                delta >= floor,
                "\(theme) theme card-vs-background ΔL* dropped to \(delta), below the floor \(floor)"
            )
        }
    }

    /// Both themes must declare two actually different numbers. If they share a value,
    /// the assertion above "stably passes" while dark-theme card and background have
    /// no separation at all.
    @Test("Surface and background declare distinct values per theme")
    func tokensDeclareBothThemes() throws {
        for name in ["background", "surface", "surfaceElevated"] {
            let light = try Self.declaredToken(name, "light")
            let dark = try Self.declaredToken(name, "dark")
            #expect(
                abs(Self.lStar(light) - Self.lStar(dark)) > 1,
                "\(name) declares the same value in both themes"
            )
        }
    }

    /// Which token `ModelControlSurface` actually fills in this theme. **Read from the
    /// component source now**, rather than copying a second table in the test — a copy
    /// would keep measuring the old token after the component switched.
    private static func surfaceToken(_ theme: String) throws -> String {
        let source = try String(
            contentsOf: findFile([
                "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
                "ModelControlsComponents.swift",
            ]),
            encoding: .utf8
        )
        let marker = "colorScheme == .dark ? OriveoTheme.Palette."
        let start = try #require(
            source.range(of: marker),
            "ModelControlSurface no longer picks a card-face token per theme — this assertion lost its subject"
        )
        let rest = source[start.upperBound...]
        let dark = String(rest.prefix { $0.isLetter || $0.isNumber })
        let lightMarker = ": OriveoTheme.Palette."
        let lightStart = try #require(rest.range(of: lightMarker))
        let light = String(rest[lightStart.upperBound...].prefix { $0.isLetter || $0.isNumber })
        return theme == "dark" ? dark : light
    }

    /// Parse `static let <name> = Color.dynamic(light:dark:lightAlpha:darkAlpha:)` from `OriveoTheme.swift`.
    private static func declaredToken(
        _ name: String, _ theme: String
    ) throws -> (r: Double, g: Double, b: Double, a: Double) {
        let source = try String(
            contentsOf: findFile([
                "ios", "Oriveo", "Oriveo", "DesignSystem", "Theme", "OriveoTheme.swift",
            ]),
            encoding: .utf8
        )
        let marker = "static let \(name) = Color.dynamic("
        let start = try #require(source.range(of: marker), "OriveoTheme has no token \(name)")
        let rest = source[start.upperBound...]
        let end = try #require(rest.firstIndex(of: ")"))
        let args = String(rest[..<end])

        let hexRange = try #require(args.range(of: "\(theme): 0x"), "\(name) is missing \(theme)")
        let digits = args[hexRange.upperBound...].prefix { $0.isHexDigit }
        let value = try #require(UInt(digits, radix: 16))

        var alpha = 1.0
        if let alphaRange = args.range(of: "\(theme)Alpha: ") {
            let raw = args[alphaRange.upperBound...].prefix { $0.isNumber || $0 == "." }
            alpha = Double(raw) ?? 1
        }
        return (
            Double((value & 0xFF0000) >> 16) / 255,
            Double((value & 0x00FF00) >> 8) / 255,
            Double(value & 0x0000FF) / 255,
            alpha
        )
    }

    /// The only pillar of light-theme separation. `ModelControlSurface`'s light ΔL* is
    /// only 1.8; if the shadow is deleted the page becomes a blank white sheet — card
    /// edges vanish while every existing test stays green.
    @Test("The borderless surface keeps a non-zero shadow in both themes")
    func lightThemeKeepsShadow() throws {
        let source = try String(
            contentsOf: Self.findFile([
                "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
                "ModelControlsComponents.swift",
            ]),
            encoding: .utf8
        )
        #expect(source.contains(".shadow("), "ModelControlSurface lost its shadow — light theme would lose its only separation mechanism")
        // Each theme has its own shadow strength: a black shadow on a dark ground is almost
        // invisible and relies on luminance contrast, so the two values must not be merged.
        #expect(source.contains("colorScheme == .dark ? 0.28 : 0.045"))
    }

    // MARK: - Color math

    private static func rgba(_ color: Color, _ traits: UITraitCollection) -> (r: Double, g: Double, b: Double, a: Double)? {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b), Double(a))
    }

    private static func composite(
        _ foreground: (r: Double, g: Double, b: Double, a: Double),
        over background: (r: Double, g: Double, b: Double, a: Double)
    ) -> (r: Double, g: Double, b: Double, a: Double) {
        let alpha = foreground.a
        return (
            alpha * foreground.r + (1 - alpha) * background.r,
            alpha * foreground.g + (1 - alpha) * background.g,
            alpha * foreground.b + (1 - alpha) * background.b,
            1
        )
    }

    /// CIE L*: perceptually uniform luminance, closer to "can you see the separation" than raw RGB or a WCAG ratio.
    private static func lStar(_ color: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let y = 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
        return y > 0.008856 ? 116 * pow(y, 1.0 / 3.0) - 16 : 903.3 * y
    }

    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("source not found: \(components.joined(separator: "/"))")
    }
}
