import Foundation
import Testing
@testable import Oriveo

/// Contrast and theming rules for the model controls pickers.
///
/// Every ratio is computed from the palette token the component actually references, read out of
/// the source, so adding a compliant token that nothing uses cannot turn these green.
@Suite("Model Control Theme Contrast Tests")
struct ModelControlThemeContrastTests {
    /// Text of unselected segments in the segmented choice, on the track; both themes must reach AA 4.5.
    ///
    /// **What is measured is the token the control really references**, not "the palette has a token that passes";
    /// the latter could turn green by adding a token nobody uses.
    @Test("text of unselected segments reaches 4.5:1 in light and dark")
    func unselectedSegmentTextMeetsAA() throws {
        let name = try Self.controlToken("private var unselectedLabelColor: Color {")
        for theme in [Theme.light, .dark] {
            let track = try Self.track(theme)
            let text = try Self.token(name, theme)
            let ratio = Self.contrast(Self.composite(text, over: track), track)
            #expect(ratio >= 4.5, "in \(theme) the text of unselected segments (\(name)) is only \(ratio):1")
        }
    }

    /// The selected segment: purple text on the selected segment's own background, **checked separately for each theme**.
    ///
    /// In dark mode a selected segment that is "one layer brighter than the track, with the same purple as light mode" gives the purple text
    /// only about 3:1; taking the card color instead gives enough contrast but makes the selected segment darker than the track, as if recessed. So in dark mode the selected segment
    /// is brighter than the track and the text uses a purple one step brighter, and both facts are pinned together.
    @Test("text of the selected segment reaches 4.5:1 in light and dark, and in both the selected segment is brighter than the track")
    func selectedSegmentTextMeetsAA() throws {
        for theme in [Theme.light, .dark] {
            let fill = try Self.selectedFill(theme)
            let text = try Self.componentColor("selectedLabel", in: Self.controlSignature, theme)
            let ratio = Self.contrast(Self.composite(text, over: fill), fill)
            #expect(ratio >= 4.5, "in \(theme) the text of the selected segment is only \(ratio):1")
            let track = try Self.track(theme)
            #expect(
                Self.relativeLuminance(fill) > Self.relativeLuminance(track) + 0.01,
                "in \(theme) the selected segment is not brighter than the track and would look recessed"
            )
        }
    }

    /// Control case: if dark mode kept light mode's text-safe purple, it would not pass on the brightened selected segment. Without this,
    /// the test above could not prove that the brighter purple in dark mode changes anything.
    @Test("primaryTextSafe as selected text in dark mode really does not pass")
    func textSafePurpleWouldFailOnTheRaisedCellInDark() throws {
        let fill = try Self.selectedFill(.dark)
        let text = try Self.token("primaryTextSafe", .dark)
        let ratio = Self.contrast(Self.composite(text, over: fill), fill)
        #expect(ratio < 4.5, "primaryTextSafe passes after all (\(ratio):1); this control case no longer holds and the measurement needs rechecking")
    }

    /// The "Choose protocol" primary button: deep purple with white text in both themes.
    @Test("text of the in-card primary button reaches 4.5:1 in light and dark")
    func calloutButtonTextMeetsAA() throws {
        let signature = "struct ModelOptionCalloutButtonLabel: View {"
        for theme in [Theme.light, .dark] {
            let fill = try Self.componentColor("fill", in: signature, theme)
            let label = try Self.componentColor("label", in: signature, theme)
            let ratio = Self.contrast(label, fill)
            #expect(ratio >= 4.5, "in \(theme) the primary button's text is only \(ratio):1")
        }
    }

    /// This control has no disabled state: a level that cannot be chosen is never passed in. So there must be no
    /// dimming of a segment through opacity either; that layer multiplies outside the color, and a contrast computed from declared values does not see it.
    @Test("the segmented choice has no disabled state and dims no segment through opacity")
    func segmentedControlHasNoDimmedState() throws {
        let body = Self.strippingComments(
            try Self.scopedBody(Self.componentSource(), from: Self.controlSignature)
        )
        #expect(!body.contains(".disabled("))
        #expect(!body.contains(".opacity(0."), "the segmented choice contains a hard-coded opacity")
        #expect(!body.contains("isEnabled"))
    }

    @Test("Palette Declares Both Themes")
    func paletteDeclaresBothThemes() throws {
        for name in [
            "background", "surface", "surfaceElevated", "textPrimary", "textSecondary", "textTertiary",
            "primary", "onPrimary", "warningText", "textDisabledOnControl", "primaryTextSafe",
        ] {
            let light = try Self.token(name, .light)
            let dark = try Self.token(name, .dark)
            #expect(
                !Self.nearlyEqual(light, dark),
                "\(name) declares the same value for both themes, which means there is no dark theme at all"
            )
        }
    }

    /// Control case. Without it, the test above could not prove that switching to the text-safe fill variant changes anything;
    /// if plain `primary` ever passes by itself, the brand color was changed and the measurement needs rechecking.
    @Test("plain primary as a fill carrying text really does not pass in light mode")
    func rawPrimaryFillWouldFailInLight() throws {
        let primary = try Self.token("primary", .light)
        let onPrimary = try Self.token("onPrimary", .light)
        let ratio = Self.contrast(Self.composite(onPrimary, over: primary), primary)
        #expect(ratio < 4.5, "the raw primary colour now passes (\(ratio):1), which invalidates this control case; recheck the measurement")
    }

    @Test("Primary Itself Unchanged")
    func primaryItselfUnchanged() throws {
        let light = try Self.token("primary", .light)
        let dark = try Self.token("primary", .dark)
        #expect(Self.nearlyEqual(light, (0x8C / 255.0, 0x5F / 255.0, 0xF8 / 255.0, 1)), "the light primary colour was changed")
        #expect(Self.nearlyEqual(dark, (0xA7 / 255.0, 0x8B / 255.0, 0xFA / 255.0, 1)), "the dark primary colour was changed")
    }

    // MARK: - Palette source

    enum Theme: String, CustomStringConvertible {
        case light
        case dark
        var description: String { self == .light ? "light" : "dark" }
    }

    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    private static func token(_ name: String, _ theme: Theme) throws -> RGBA {
        let source = try String(contentsOf: findFile([
            "ios", "Oriveo", "Oriveo", "DesignSystem", "Theme", "OriveoTheme.swift",
        ]), encoding: .utf8)
        let marker = "static let \(name) = Color.dynamic("
        let start = try #require(source.range(of: marker), "OriveoTheme has no token \(name)")
        let rest = source[start.upperBound...]
        let end = try #require(rest.firstIndex(of: ")"))
        let args = String(rest[..<end])

        func hex(_ label: String) throws -> UInt {
            let pattern = "\(label): 0x"
            let range = try #require(args.range(of: pattern), "\(name) is missing \(label)")
            let digits = args[range.upperBound...].prefix { $0.isHexDigit }
            return try #require(UInt(digits, radix: 16))
        }
        func alpha(_ label: String) -> Double {
            guard let range = args.range(of: "\(label): ") else { return 1 }
            let digits = args[range.upperBound...].prefix { $0.isNumber || $0 == "." }
            return Double(digits) ?? 1
        }

        let value = try hex(theme.rawValue)
        return (
            Double((value & 0xFF0000) >> 16) / 255,
            Double((value & 0x00FF00) >> 8) / 255,
            Double(value & 0x0000FF) / 255,
            alpha(theme == .light ? "lightAlpha" : "darkAlpha")
        )
    }

    private static let controlSignature = "struct ModelOptionSegmentedControl: View {"

    /// Reads from `ModelControlsComponents.swift` the palette token a color property of the segmented choice **really references**.
    ///
    /// The token name is not hard-coded in the test: "a passing token was added but the control still uses the old one" would pass silently.
    /// The scope is narrowed to the property, and exactly one match is required.
    private static func controlToken(_ propertySignature: String) throws -> String {
        let structBody = try scopedBody(componentSource(), from: controlSignature)
        let body = try scopedBody(structBody, from: propertySignature)
        let regex = try NSRegularExpression(pattern: #"OriveoTheme\.Palette\.([A-Za-z0-9_]+)"#)
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        #expect(matches.count == 1, "\(propertySignature) matches \(matches.count) times; it must be unique")
        let match = try #require(matches.first)
        let range = try #require(Range(match.range(at: 1), in: body))
        return String(body[range])
    }

    /// Background of the selected segment: a layer of white over the track, with the strength taken from the product's own static function.
    private static func selectedFill(_ theme: Theme) throws -> RGBA {
        let alpha = ModelOptionSegmentedControl.selectedFillAlpha(isDark: theme == .dark)
        return composite((1, 1, 1, alpha), over: try track(theme))
    }

    /// Reads from the component source the declared value of `static let <name> = Color.dynamic(light:dark:)` inside a struct.
    /// The same reason as for reading `OriveoTheme.swift`: bridging a dynamic color back to `UIColor` at runtime loses the dark variant.
    private static func componentColor(_ name: String, in signature: String, _ theme: Theme) throws -> RGBA {
        let body = try scopedBody(componentSource(), from: signature)
        let marker = "static let \(name) = Color.dynamic("
        let start = try #require(body.range(of: marker), "\(signature) has no \(name)")
        let args = body[start.upperBound...].prefix { $0 != ")" }
        let label = try #require(args.range(of: "\(theme.rawValue): 0x"), "\(name) lacks \(theme.rawValue)")
        let value = try #require(UInt(args[label.upperBound...].prefix { $0.isHexDigit }, radix: 16))
        return (
            Double((value & 0xFF0000) >> 16) / 255,
            Double((value & 0x00FF00) >> 8) / 255,
            Double(value & 0x0000FF) / 255,
            1
        )
    }

    /// Starting at `signature` (which ends in `{`), takes the body of that block by balancing braces.
    /// "Find the first `}` in the same column" is not used because nested closures and one-line properties both break it.
    private static func scopedBody(_ source: String, from signature: String) throws -> String {
        let start = try #require(source.range(of: signature), "could not find \(signature) in the source")
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        throw ScopeError.unbalanced(signature)
    }

    enum ScopeError: Error { case unbalanced(String) }

    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func componentSource() throws -> String {
        try String(contentsOf: findFile([
            "ios", "Oriveo", "Oriveo", "Features", "Chat", "ModelControls",
            "ModelControlsComponents.swift",
        ]), encoding: .utf8)
    }

    private static func pageSurface(_ theme: Theme) throws -> RGBA {
        let background = try token("background", theme)
        let surface = try token(theme == .dark ? "surfaceElevated" : "surface", theme)
        return composite(surface, over: background)
    }

    /// The track of the segmented choice: `textPrimary` at very low opacity composited over the card. The opacity comes from the product's
    /// own static function; a hand-copied value would give a false green where the code changed and the assertion still measures the old value.
    private static func track(_ theme: Theme) throws -> RGBA {
        let page = try pageSurface(theme)
        let textPrimary = try token("textPrimary", theme)
        let alpha = ModelOptionSegmentedControl.trackAlpha(isDark: theme == .dark)
        return composite((textPrimary.r, textPrimary.g, textPrimary.b, alpha), over: page)
    }

    // MARK: - Color math

    private static func composite(_ foreground: RGBA, over background: RGBA) -> RGBA {
        let alpha = foreground.a
        return (
            alpha * foreground.r + (1 - alpha) * background.r,
            alpha * foreground.g + (1 - alpha) * background.g,
            alpha * foreground.b + (1 - alpha) * background.b,
            1
        )
    }

    private static func relativeLuminance(_ color: RGBA) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    private static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func nearlyEqual(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.004 && abs(a.g - b.g) < 0.004
            && abs(a.b - b.b) < 0.004 && abs(a.a - b.a) < 0.004
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
