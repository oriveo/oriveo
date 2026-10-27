import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Oriveo

/// Settings > Theme page: the interaction cases are read one by one from `themePageCases` in `dark-palettes.v1.json`.
@Suite("ThemeSettingsView")
@MainActor
struct ThemeSettingsViewTests {
    // MARK: - themePageCases (one test each)

    @Test("tap_light: tapping Light -> theme=light, darkPalette is left alone")
    func tapLight() throws { try runCase("tap_light") }

    @Test("tap_palette_follow_off: tapping a palette with Follow System off -> theme=dark + darkPalette=id")
    func tapPaletteFollowOff() throws { try runCase("tap_palette_follow_off") }

    @Test("tap_palette_follow_on: tapping a palette with Follow System on -> only darkPalette is written, theme stays system")
    func tapPaletteFollowOn() throws { try runCase("tap_palette_follow_on") }

    @Test("turn_follow_on: turning Follow System on -> theme=system")
    func turnFollowOn() throws { try runCase("turn_follow_on") }

    @Test("turn_follow_off_uses_current_system_appearance: turning Follow System off -> theme = the current system appearance")
    func turnFollowOffUsesCurrentSystemAppearance() throws {
        try runCase("turn_follow_off_uses_current_system_appearance")
    }

    @Test("turning Follow System off under a light system lands on light")
    func turnFollowOffInLightSystem() {
        let state = ThemePageState(theme: .system, darkPalette: "dark-black")
        let next = ThemePageReducer.apply(state: state, action: .setFollowSystem(false), systemIsDark: false)
        #expect(next == ThemePageState(theme: .light, darkPalette: "dark-black"))
    }

    // MARK: - Selection display

    @Test("Follow System on: the ring sits on resolve(darkPalette) and Light is not selected; unknown / unset use the default dark")
    func selectionWhenFollowingSystem() {
        #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: .system, darkPalette: "dark-ocean")) == .palette(.darkOcean))
        #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: .system, darkPalette: nil)) == .palette(.dark))
        #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: .system, darkPalette: "dark-future")) == .palette(.dark))
        #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: .system, darkPalette: "dark-ocean")) != .light)
    }

    @Test("Follow System off: light selects Light, dark selects resolve(darkPalette)")
    func selectionWhenFixed() {
        #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: .light, darkPalette: "dark-forest")) == .light)
        #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: .dark, darkPalette: "dark-forest")) == .palette(.darkForest))
        #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: .dark, darkPalette: nil)) == .palette(.dark))
    }

    @Test("palette card order: Light first, then the JSON order (Dark, Purple, Graphite, Black, Ocean, Forest, Sunset)")
    func swatchOrderFollowsContract() throws {
        let contract = try OriveoDarkPalettesTests.loadContract()
        let order = try #require(contract["order"] as? [String])
        #expect(ThemeSwatch.all.first == .light)
        let palettes = ThemeSwatch.all.dropFirst().compactMap { swatch -> String? in
            if case let .palette(id) = swatch { return id.rawValue }
            return nil
        }
        #expect(palettes == order)
        #expect(Set(ThemeSwatch.all).count == 8)
    }

    @Test("mini card glow strength: dark takes the palette glowK, light is 0.55")
    func miniCardGlowStrength() {
        #expect(ThemeSwatch.light.glowStrength == 0.55)
        for id in OriveoDarkPaletteID.allCases {
            #expect(ThemeSwatch.palette(id).glowStrength == id.palette.glowK)
        }
    }

    @Test("preview: the thinking row reuses the chat duration copy, and the time prints a fixed moment in the local format")
    func previewTexts() throws {
        #expect(ThemeSettingsView.previewThinkingLabel() == String(
            format: L10n.tr("Thought for %@", table: .chat),
            UIKitReasoningBlock.formatDuration(ms: 4000)
        ))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9)))
        let moment = try #require(calendar.date(bySettingHour: 21, minute: 41, second: 0, of: day))
        let stamp = ThemeSettingsView.previewTimestamp(calendar: calendar, now: day)
        #expect(stamp == moment.formatted(date: .omitted, time: .shortened))
        #expect(stamp.contains("41"))
    }

    @Test("preview code highlighting reuses the chat CodeBlockView syntax colors")
    func previewSyntaxReusesCodeBlockPalette() {
        #expect(ThemeSettingsView.previewSyntax.keyword == MarkdownCodeBlockPalette.keyword)
        #expect(ThemeSettingsView.previewSyntax.type == MarkdownCodeBlockPalette.type)
        #expect(ThemeSettingsView.previewSyntax.string == MarkdownCodeBlockPalette.string)
    }

    @Test("the preview code block is literal text: it uses Text(verbatim:) and is not a localization key (otherwise every build adds empty entries to Localizable.xcstrings)")
    func previewCodeUsesVerbatimText() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo project root
            .appendingPathComponent("Oriveo/Features/Settings/ThemeSettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("Text(\"let\")"))
        #expect(!source.contains("Text(\"::from(\")"))
        #expect(source.contains("Text(verbatim: \"::from(\")"))
    }

    @Test("preview inline code shares its source with chat: dark text = the previewed palette accent on a 7% white background")
    func previewInlineCodeFollowsPreviewedPalette() throws {
        let reply = ThemeSettingsView.previewReply()
        let run = try #require(reply.runs.first { $0.font == .system(size: 12, design: .monospaced) })
        let fg = try #require(run.foregroundColor)
        let bg = try #require(run.backgroundColor)
        for (id, accent) in [(OriveoDarkPaletteID.darkForest, UInt(0xD9F99D)), (.darkSunset, 0xFF7E79)] {
            // Resolved with the environment of the preview subtree (dark plus the previewed palette)
            let fgColor = MarkdownDarkPaletteColorTests.rgba(fg, .dark, id)
            #expect(fgColor.hex == accent, "\(id.rawValue)")
            let bgColor = MarkdownDarkPaletteColorTests.rgba(bg, .dark, id)
            #expect(bgColor.hex == 0xFFFFFF && bgColor.alpha == 0.07, "\(id.rawValue)")
        }
    }

    // MARK: - Accessibility

    @Test("swatch a11y: label = the palette name, and a selected swatch carries .isSelected")
    func swatchAccessibility() {
        for swatch in ThemeSwatch.all {
            let on = ThemeSwatch.accessibility(swatch, selected: true)
            let off = ThemeSwatch.accessibility(swatch, selected: false)
            #expect(on.label == swatch.displayName)
            #expect(!on.label.isEmpty)
            #expect(on.traits.contains(.isSelected))
            #expect(!off.traits.contains(.isSelected))
        }
        #expect(ThemeSwatch.light.displayName == L10n.tr("Light"))
        #expect(ThemeSwatch.palette(.dark).displayName == L10n.tr("Dark"))
        #expect(ThemeSwatch.palette(.darkSunset).displayName == L10n.tr("Palette Sunset", table: .settings))
    }

    // MARK: - Row summary

    @Test("row summary: light -> Light; dark -> the palette name; system -> Follow System · palette name")
    func rowSummary() {
        #expect(themeRowSummary(theme: .light, darkPalette: "dark-ocean") == L10n.tr("Light"))
        #expect(themeRowSummary(theme: .dark, darkPalette: nil) == L10n.tr("Dark"))
        #expect(themeRowSummary(theme: .dark, darkPalette: "dark-ocean") == L10n.tr("Palette Ocean", table: .settings))
        #expect(themeRowSummary(theme: .dark, darkPalette: "dark-future") == L10n.tr("Dark"))
        let follow = themeRowSummary(theme: .system, darkPalette: "dark-forest")
        #expect(follow == L10n.format(
            L10n.tr("Follow System · %@", table: .settings),
            L10n.tr("Palette Forest", table: .settings)
        ))
        #expect(follow.contains(L10n.tr("Palette Forest", table: .settings)))
    }

    // MARK: - Helpers

    private static func theme(_ raw: Any?) throws -> ThemeOption {
        let string = try #require(raw as? String)
        return try #require(ThemeOption(rawValue: string))
    }

    private func runCase(_ name: String) throws {
        let contract = try OriveoDarkPalettesTests.loadContract()
        let cases = try #require(contract["themePageCases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["name"] as? String == name }, "the JSON lacks case \(name)")
        let before = try #require(item["before"] as? [String: Any])
        let after = try #require(item["after"] as? [String: Any])

        let state = ThemePageState(
            theme: try Self.theme(before["theme"]),
            darkPalette: before["darkPalette"] as? String
        )
        #expect(state.followsSystem == (before["follow"] as? Bool), "\(name) before.follow does not match theme")

        let action: ThemePageAction
        if let tap = item["tap"] as? String {
            if tap == "light" {
                action = .tap(.light)
            } else {
                let id = try #require(OriveoDarkPaletteID(rawValue: tap))
                action = .tap(.palette(id))
            }
        } else {
            action = .setFollowSystem(try #require(item["toggleFollow"] as? Bool))
        }

        let expected = ThemePageState(
            theme: try Self.theme(after["theme"]),
            darkPalette: after["darkPalette"] as? String
        )
        // If a case gives no system appearance, the result must not depend on it: run both
        let appearances: [Bool]
        if let system = before["systemAppearance"] as? String {
            appearances = [system == "dark"]
        } else {
            appearances = [true, false]
        }
        for systemIsDark in appearances {
            let next = ThemePageReducer.apply(state: state, action: action, systemIsDark: systemIsDark)
            #expect(next == expected, "\(name) systemIsDark=\(systemIsDark)")
        }
    }
}
