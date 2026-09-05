import Foundation
import Testing
@testable import Oriveo

/// Contrast and theming rules for the model controls pickers.
///
/// Every ratio is computed from the palette token the component actually references, read out of
/// the source, so adding a compliant token that nothing uses cannot turn these green.
@Suite("Model Control Theme Contrast Tests")
struct ModelControlThemeContrastTests {
    @Test("Unselected Tier Text Meets AA")
    func unselectedTierTextMeetsAA() throws {
        for theme in [Theme.light, .dark] {
            let track = try Self.segmentedTrack(theme)
            let text = try Self.token("textSecondary", theme)
            let ratio = Self.contrast(Self.composite(text, over: track), track)
            #expect(ratio >= 4.5, "unselected level text in \(theme) is only \(ratio):1")
        }
    }

    @Test("Badge Text Uses Text Safe Variant")
    func badgeTextUsesTextSafeVariant() throws {
        let cases: [(tone: String, fillToken: String, textToken: String)] = [
            ("manual", "warning", "warningText"),
            ("unavailable", "textTertiary", "textSecondary"),
        ]
        for theme in [Theme.light, .dark] {
            let page = try Self.pageSurface(theme)
            for item in cases {
                let fillToken = try Self.token(item.fillToken, theme)
                let opacity = ModelControlStatusBadge.capsuleOpacity(isDark: theme == .dark)
                let fill = Self.composite(
                    (fillToken.r, fillToken.g, fillToken.b, opacity), over: page
                )
                let text = try Self.token(item.textToken, theme)
                let ratio = Self.contrast(Self.composite(text, over: fill), fill)
                #expect(ratio >= 4.5, "the \(item.tone) badge text in \(theme) is only \(ratio):1")
            }
        }
        let page = try Self.pageSurface(.light)
        let warning = try Self.token("warning", .light)
        let fill = Self.composite(
            (warning.r, warning.g, warning.b, ModelControlStatusBadge.capsuleOpacity(isDark: false)),
            over: page
        )
        #expect(
            Self.contrast(Self.composite(warning, over: fill), fill) < 4.5,
            "the raw warning colour now passes as text, which invalidates this control case; recheck the measurement"
        )
    }

    @Test("Badge Capsule Opacity Differs By Theme")
    func badgeCapsuleOpacityDiffersByTheme() {
        let light = ModelControlStatusBadge.capsuleOpacity(isDark: false)
        let dark = ModelControlStatusBadge.capsuleOpacity(isDark: true)
        #expect(light != dark, "both themes use the same opacity, so only the light one was tuned")
        #expect(dark >= 0.18, "\(dark) is too faint in dark mode; the pill loses its edge")
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

    /// Disabled level text must genuinely reach AA 4.5 in both themes.
    /// Disabled must not be expressed with opacity.
    /// Colour precedence: `if selected` must appear before `guard usable` in the source.
    /// Both level pickers in the sheet, held to the same spec. Only checking the segmented one was
    /// nearly the mistake here: the other picker had exactly the same two defects plus a tertiary
    /// text colour at half opacity, which the spec forbids.
    /// The original implementation returned the tertiary text colour first, so a greyed-out group
    /// rendered the selected cell as disabled grey on the accent fill - measured 3.61:1 in light and
    /// 2.94:1 in dark, harder to read than when it is not greyed out at all. Asserting the colour
    /// values is not enough: both branches return legitimate tokens and only the order is wrong.
    /// This is not a duplicate of the contrast assertions above; it closes a different route.
    /// `.opacity()` multiplies on top of the colour, and a ratio computed from declared token
    /// values cannot see it. The original implementation stacked two of them - a tertiary text
    /// colour at half opacity inside a button style that dimmed the whole layer to 0.7 - leaving
    /// the text at about three tenths opacity while every declared-value assertion stayed green.
    /// The ratio is measured on the token the component actually references, not on "some compliant
    /// token exists in the palette" - the latter can be made green by adding a token nobody uses.
    /// The surface the card actually presents.
    ///
    /// The dark theme measures against the elevated surface: the control surface switches to the
    /// elevated colour in dark mode, so measuring against the base surface would be measuring a
    /// card that does not exist on screen - darker than reality, which inflates every contrast
    /// ratio computed against it.
    /// It also pins the other half of the spec: disabled is expressed by not responding to taps,
    /// not bolding, and keeping the reason visible - never by lowering contrast. So no disabled
    /// colour is allowed below 4.5.
    @Test("Disabled Tier Text Meets AA", arguments: Self.pickers)
    func disabledTierTextMeetsAA(_ picker: Picker) throws {
        let name = try Self.pickerToken(picker, .disabledLabel)
        for theme in [Theme.light, .dark] {
            let track = try Self.pillTrack(picker, theme, usable: false)
            let text = try Self.token(name, theme)
            let ratio = Self.contrast(Self.composite(text, over: track), track)
            #expect(ratio >= 4.5, "\(picker.name) disabled level text (\(name)) in \(theme) is only \(ratio):1")
        }
    }

    @Test("Selected Tier Text Meets AA", arguments: Self.pickers)
    func selectedTierTextMeetsAA(_ picker: Picker) throws {
        let fillName = try Self.pickerToken(picker, .selectedFill)
        let labelName = try Self.pickerToken(picker, .selectedLabel)
        for theme in [Theme.light, .dark] {
            let fill = try Self.token(fillName, theme)
            let onFill = try Self.token(labelName, theme)
            let ratio = Self.contrast(Self.composite(onFill, over: fill), fill)
            #expect(ratio >= 4.5, "\(picker.name) selected level text (\(labelName) on \(fillName)) in \(theme) is only \(ratio):1")
        }
    }

    @Test("Disabled State Does Not Use Opacity", arguments: Self.pickers)
    func disabledStateDoesNotUseOpacity(_ picker: Picker) throws {
        let body = Self.strippingComments(try Self.scopedBody(Self.componentSource(), from: picker.structSignature))
        #expect(
            !body.contains(".opacity(0.5)") && !body.contains("isEnabled ? 1 :"),
            "\(picker.name) expresses disabled through opacity, which the declared-value contrast assertions cannot see"
        )
    }

    @Test("Pill Button Style Does Not Dim Whole Layer")
    func pillButtonStyleDoesNotDimWholeLayer() throws {
        let body = Self.strippingComments(
            try Self.scopedBody(Self.componentSource(), from: "private struct ModelControlPillButtonStyle: ButtonStyle {")
        )
        #expect(
            !body.contains(".opacity("),
            "the button style is dimming the whole layer again, which multiplies the already recoloured text a second time"
        )
    }

    @Test("Raw Primary Fill Would Fail In Light")
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

    /// When a whole group is disabled, the selected cell goes muted.
    ///
    /// The original rule kept the accent fill on the selected cell whenever a group was greyed out,
    /// which only considered the case of one unavailable level inside an otherwise usable group.
    /// When the whole capability is not configurable, nothing in the row responds yet one saturated
    /// cell still glows - the interface saying "nothing here can be changed" and "this one is
    /// active" at the same time.
    ///
    /// The decision: desaturate, but stay legible and compliant. Selection is carried by a semibold
    /// weight and a fill darker than the unselected cells rather than by colour alone, and the muted
    /// text must reach 4.5:1 against both the fill and the card surface. When only individual levels
    /// are disabled inside a usable group, the selected cell keeps its normal accent treatment.
    @Test("Dimmed Selection Stays Readable", arguments: Self.pickers)
    func dimmedSelectionStaysReadable(_ picker: Picker) throws {
        let labelName = try Self.pickerToken(picker, .dimmedSelectedLabel)
        for theme in [Theme.light, .dark] {
            let fill = try Self.dimmedSelectedFill(picker, theme)
            let surface = try Self.pageSurface(theme)
            let text = try Self.token(labelName, theme)
            let onFill = Self.contrast(Self.composite(text, over: fill), fill)
            let onSurface = Self.contrast(Self.composite(text, over: surface), surface)
            #expect(onFill >= 4.5, "\(picker.name) in \(theme): muted selected text on its fill is only \(onFill):1")
            #expect(onSurface >= 4.5, "\(picker.name) in \(theme): muted selected text on the card surface is only \(onSurface):1")
            let unselected = try Self.pillTrack(picker, theme, usable: false)
            #expect(
                abs(Self.relativeLuminance(fill) - Self.relativeLuminance(unselected)) > 0.005,
                "\(picker.name) in \(theme): the muted selected cell and the unselected cells are almost the same colour, so selection is invisible"
            )
        }
    }

    @Test("Selection Wins Over Disabled In Foreground", arguments: Self.pickers)
    func selectionWinsOverDisabledInForeground(_ picker: Picker) throws {
        let structBody = try Self.scopedBody(Self.componentSource(), from: picker.structSignature)
        let body = try Self.scopedBody(structBody, from: picker.foregroundSignature)
        let selectedAt = try #require(body.range(of: "if selected"), "\(picker.name).foreground has no selected-first branch")
        let usableAt = try #require(body.range(of: "guard usable"), "\(picker.name).foreground has no disabled branch")
        #expect(
            selectedAt.lowerBound < usableAt.lowerBound,
            "\(picker.name) checks disabled before selected, so a greyed-out group renders the selected cell as disabled grey text on the accent fill (measured 3.61 and 2.94:1)"
        )
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

    struct Picker: CustomStringConvertible, Sendable {
        let name: String
        let structSignature: String
        let foregroundSignature: String
        let trackAlpha: @Sendable (_ isDark: Bool, _ usable: Bool) -> Double
        var description: String { name }
    }

    static let pickers: [Picker] = [
        Picker(
            name: "ModelControlSegmentedPicker",
            structSignature: "struct ModelControlSegmentedPicker: View {",
            foregroundSignature: "private func foreground(selected: Bool, usable: Bool) -> Color {",
            trackAlpha: { isDark, _ in ModelControlSegmentedPicker.trackAlpha(isDark: isDark) }
        ),
        Picker(
            name: "ModelControlIntentPicker",
            structSignature: "struct ModelControlIntentPicker: View {",
            foregroundSignature: "private func foreground(selected: Bool, usable: Bool) -> Color {",
            trackAlpha: { isDark, usable in
                ModelControlIntentPicker.unselectedFillAlpha(isDark: isDark, usable: usable)
            }
        ),
    ]

    enum Role: String {
        case disabledLabel
        case selectedLabel
        case selectedFill
        case dimmedSelectedLabel
        case dimmedSelectedFill

        var propertyName: String {
            switch self {
            case .disabledLabel: return ""
            case .selectedLabel: return "selectedLabelColor"
            case .selectedFill: return "selectedFill"
            case .dimmedSelectedLabel: return "dimmedSelectedLabelColor"
            case .dimmedSelectedFill: return "dimmedSelectedFill"
            }
        }
    }

    /// Reads the palette token names the picker actually references out of the components source.
    ///
    /// Hard-coding the token names in the test would let "a compliant token was added but the
    /// component still uses the old one" pass silently. Reading the source means that reverting the
    /// component to an older token turns the contrast assertions above red immediately.
    ///
    /// The scope has to be narrowed to the function: both `foreground` and `fill` contain a
    /// `if selected { return ... }`, so slicing by type alone would match twice.
    private static func pickerToken(_ picker: Picker, _ role: Role) throws -> String {
        let structBody = try scopedBody(componentSource(), from: picker.structSignature)
        let scope: String
        let pattern: String
        switch role {
        case .disabledLabel:
            scope = picker.foregroundSignature
            pattern = #"guard usable else \{ return OriveoTheme\.Palette\.([A-Za-z0-9_]+) \}"#
        case .selectedLabel, .selectedFill, .dimmedSelectedLabel, .dimmedSelectedFill:
            scope = "private var \(role.propertyName): Color {"
            pattern = #"OriveoTheme\.Palette\.([A-Za-z0-9_]+)"#
        }
        let body = try scopedBody(structBody, from: scope)
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        #expect(matches.count == 1, "\(picker.name) matched \(role) \(matches.count) times; it must be unique")
        let match = try #require(matches.first)
        let range = try #require(Range(match.range(at: 1), in: body))
        return String(body[range])
    }

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

    private static func segmentedTrack(_ theme: Theme) throws -> RGBA {
        try pillTrack(pickers[0], theme, usable: true)
    }

    private static func pillTrack(_ picker: Picker, _ theme: Theme, usable: Bool) throws -> RGBA {
        let page = try pageSurface(theme)
        let textPrimary = try token("textPrimary", theme)
        let trackAlpha = picker.trackAlpha(theme == .dark, usable)
        return composite((textPrimary.r, textPrimary.g, textPrimary.b, trackAlpha), over: page)
    }

    private static func dimmedSelectedFill(_ picker: Picker, _ theme: Theme) throws -> RGBA {
        let structBody = try scopedBody(componentSource(), from: picker.structSignature)
        let body = try scopedBody(structBody, from: "private var dimmedSelectedFill: Color {")
        let name = try pickerToken(picker, .dimmedSelectedFill)
        let base = try token(name, theme)
        let pattern = #"colorScheme == \.dark \? ([0-9.]+) : ([0-9.]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try #require(
            regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
            "\(picker.name).dimmedSelectedFill does not expose an opacity for each theme"
        )
        let group = theme == .dark ? 1 : 2
        let range = try #require(Range(match.range(at: group), in: body))
        let alpha = try #require(Double(body[range]))
        return composite((base.r, base.g, base.b, alpha), over: try pageSurface(theme))
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
