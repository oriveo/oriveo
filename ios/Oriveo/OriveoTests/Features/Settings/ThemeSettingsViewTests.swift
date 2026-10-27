import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Oriveo

/// Settings > Theme page: the interaction cases are read one by one from `appearancePageCases` in `dark-palettes.v1.json`.
@Suite("ThemeSettingsView")
@MainActor
struct ThemeSettingsViewTests {
    // MARK: - appearancePageCases (one test each)

    @Test("segment_light: choosing Light in the appearance control writes only theme")
    func segmentLight() throws { try runCase("segment_light") }

    @Test("segment_dark: choosing Dark in the appearance control writes only theme, the custom palette and seed are untouched")
    func segmentDark() throws { try runCase("segment_dark") }

    @Test("segment_system: choosing Follow System in the appearance control writes only theme")
    func segmentSystem() throws { try runCase("segment_system") }

    @Test("tap_palette_keeps_appearance_light: tapping a palette in the light appearance writes only darkPalette")
    func tapPaletteKeepsAppearanceLight() throws { try runCase("tap_palette_keeps_appearance_light") }

    @Test("tap_palette_keeps_appearance_system: tapping a palette under Follow System writes only darkPalette")
    func tapPaletteKeepsAppearanceSystem() throws { try runCase("tap_palette_keeps_appearance_system") }

    @Test("tap_default_card: tapping \"Default\" → darkPalette=dark")
    func tapDefaultCard() throws { try runCase("tap_default_card") }

    @Test("tap_custom_without_seed_writes_default_seed: tapping Custom without a seed → writes the default seed, the appearance is untouched")
    func tapCustomWithoutSeed() throws { try runCase("tap_custom_without_seed_writes_default_seed") }

    @Test("tap_custom_keeps_existing_seed: tapping Custom with an existing seed → the seed is unchanged")
    func tapCustomKeepsSeed() throws { try runCase("tap_custom_keeps_existing_seed") }

    @Test("pick_seed_selects_custom: picking a color → writes the seed plus darkPalette=custom, the appearance is untouched")
    func pickSeedSelectsCustom() throws { try runCase("pick_seed_selects_custom") }

    @Test("tap_preset_keeps_seed: tapping another palette → the seed is kept")
    func tapPresetKeepsSeed() throws { try runCase("tap_preset_keeps_seed") }

    @Test("Every JSON appearancePageCases entry has a matching test")
    func appearanceCasesAllCovered() throws {
        let names = Set(try Self.appearanceCases().compactMap { $0["name"] as? String })
        #expect(names == [
            "segment_light",
            "segment_dark",
            "segment_system",
            "tap_palette_keeps_appearance_light",
            "tap_palette_keeps_appearance_system",
            "tap_default_card",
            "tap_custom_without_seed_writes_default_seed",
            "tap_custom_keeps_existing_seed",
            "pick_seed_selects_custom",
            "tap_preset_keeps_seed",
        ])
    }

    @Test("Appearance segment order: Light / Dark / Follow System, labelled with the existing appearance names")
    func appearanceSegments() {
        #expect(ThemeSettingsView.appearanceOptions == [.light, .dark, .system])
        #expect(ThemeSettingsView.appearanceOptions.map(\.displayName) == [
            L10n.tr("Light"), L10n.tr("Dark"), L10n.tr("Follow System"),
        ])
    }

    @Test("Custom card: name = Palette Custom")
    func customSwatchIdentity() {
        #expect(ThemeSwatch.custom.displayName == L10n.tr("Palette Custom", table: .settings))
    }

    @Test("The accessibility labels of the 12 preset colors are distinct and non-empty, in the same order as presets")
    func presetAccessibilityLabelsDistinct() {
        let labels = ThemeSettingsView.presetAccessibilityLabels()
        #expect(labels.count == OriveoCustomPalette.presets.count)
        #expect(labels.count == 12)
        #expect(Set(labels).count == 12)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(labels.first == L10n.tr("Color Coral", table: .settings))
        #expect(labels.last == L10n.tr("Color Rose", table: .settings))
    }

    @Test("Adjustment notice: one sentence each for lightened / darkened, none when not adjusted")
    func adjustmentNotice() {
        #expect(ThemeSettingsView.adjustmentNotice(.lightened) == L10n.tr("Lightened so text stays readable", table: .settings))
        #expect(ThemeSettingsView.adjustmentNotice(.darkened) == L10n.tr("Darkened so it doesn't look washed out", table: .settings))
        #expect(ThemeSettingsView.adjustmentNotice(nil) == nil)
    }

    @Test("Hue slider thumb: sits at the seed hue, range 0-359")
    func sliderHueOfSeed() {
        for hue in [0, 45, 180, 300, 359] {
            let seed = OriveoCustomPalette.hueSliderSeed(hue)
            #expect(abs(ThemeSettingsView.sliderHue(of: seed) - hue) <= 2 || abs(ThemeSettingsView.sliderHue(of: seed) - hue) >= 358, "\(hue)")
        }
        for preset in OriveoCustomPalette.presets {
            #expect((0 ... 359).contains(ThemeSettingsView.sliderHue(of: preset)))
        }
    }

    @Test("The 22 added copy keys are complete and non-empty in all 16 languages in Settings.xcstrings; the Follow System description is gone")
    func customCopyComplete() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo project root
            .appendingPathComponent("Oriveo/Settings.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let keys = [
            "Palette Custom", "Custom Color", "Hue", "Primary Color", "Accent Color",
            "Lightened so text stays readable", "Darkened so it doesn't look washed out",
            "Color Coral", "Color Orange", "Color Amber", "Color Lime", "Color Green", "Color Teal",
            "Color Cyan", "Color Blue", "Color Indigo", "Color Violet", "Color Pink", "Color Rose",
            "Appearance", "Light · %@", "Dark · %@",
        ]
        let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt-BR", "ru", "ar", "hi", "id", "th", "tr", "vi"]
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "missing key \(key)")
            #expect(entry["extractionState"] as? String == "manual", "\(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "\(key)")
            for language in languages {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                #expect(!value.isEmpty, "\(key) lacks \(language)")
            }
        }
        #expect(strings["Uses your selected dark palette when the system is in dark mode."] == nil)
    }

    // MARK: - Selection display

    @Test("Selected card = resolve(darkPalette), with a selection ring in all three appearances; unknown / unset uses the default")
    func selectionIgnoresAppearance() {
        for theme in ThemeOption.allCases {
            #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: theme, darkPalette: "dark-ocean")) == .palette(.darkOcean))
            #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: theme, darkPalette: nil)) == .palette(.dark))
            #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: theme, darkPalette: "dark-future")) == .palette(.dark))
            #expect(ThemePageReducer.selectedSwatch(ThemePageState(theme: theme, darkPalette: "custom", seed: "#4ADE80")) == .custom)
        }
    }

    @Test("8 palette cards: order = JSON order (Default, Purple, Graphite, Black, Ocean, Forest, Sunset) + Custom, the first named \"Default\"")
    func swatchOrderFollowsContract() throws {
        let contract = try OriveoDarkPalettesTests.loadContract()
        let order = try #require(contract["order"] as? [String])
        let palettes = ThemeSwatch.all.compactMap { swatch -> String? in
            if case let .palette(id) = swatch { return id.rawValue }
            return nil
        }
        #expect(palettes == order)
        #expect(ThemeSwatch.all.count == 8)
        #expect(ThemeSwatch.all.first == .palette(.dark))
        #expect(ThemeSwatch.all.first?.displayName == L10n.tr("Default"))
        #expect(ThemeSwatch.all.last == .custom)
        #expect(Set(ThemeSwatch.all).count == 8)
    }

    @Test("Mini card glow strength: this palette's glowK")
    func miniCardGlowStrength() {
        for id in OriveoDarkPaletteID.allCases {
            #expect(ThemeSwatch.palette(id).glowStrength == id.palette.glowK)
        }
    }

    @Test("The custom section's primary / accent chips follow the appearance: light = light brand ink / accent, dark = derived palette primary / accent")
    func derivedChipsFollowAppearance() {
        let seed: UInt = 0x4ADE80
        let choice = OriveoDarkPaletteChoice.custom(seed: seed)
        let light = ThemeSettingsView.derivedChipColors(seed: seed, colorScheme: .light)
        #expect(light.primary == choice.lightBrand.ink)
        #expect(light.accent == choice.lightBrand.accent)
        let dark = ThemeSettingsView.derivedChipColors(seed: seed, colorScheme: .dark)
        let derived = OriveoCustomPalette.derive(seed: seed).palette
        #expect(dark.primary == derived.primary)
        #expect(dark.accent == derived.accent)
        #expect(light.primary != dark.primary)
    }

    @Test("Preview: the thinking row reuses the chat duration copy, and the time is a fixed moment in the local format")
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

    @Test("Preview card Web tag text: light takes this palette's textSafe (the gradient end of a light-based palette is too bright to read as text), the default palette keeps its original violet, dark takes accent")
    func previewWebTagIsReadable() {
        let accent = ThemeSettingsView.previewAccent
        let sunset = OriveoDarkPaletteChoice.darkSunset
        #expect(MarkdownDarkPaletteColorTests.rgba(accent, .light, .darkSunset).hex == sunset.lightBrand.textSafe)
        #expect(MarkdownDarkPaletteColorTests.rgba(accent, .light, .dark).hex == 0x6B3BC7)
        #expect(MarkdownDarkPaletteColorTests.rgba(accent, .dark, .darkSunset).hex == sunset.palette.accent)
    }

    @Test("Hue slider: thumb position and integer hue round-trip without losing degrees, clamped at both ends")
    func hueSliderFractionRoundTrip() {
        for hue in 0 ... 359 {
            #expect(ThemeHueSlider.hue(of: ThemeHueSlider.fraction(of: hue)) == hue, "\(hue)")
        }
        #expect(ThemeHueSlider.fraction(at: -50, travel: 300) == 0)
        #expect(ThemeHueSlider.fraction(at: 999, travel: 300) == 1)
    }

    @Test("Dragging the hue slider does not recolor windows: the theme page switches the window trait in only one place, the commit on release (recoloring the whole app would make the thumb lag behind the finger)")
    func hueDragDoesNotRecolorWindows() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Settings/ThemeSettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.components(separatedBy: "OriveoDarkPaletteSwitcher.").count - 1 == 1)
        #expect(source.contains(".transformEnvironment(\\.oriveoDarkPalette)"))
    }

    @Test("Tab gradient icon cache: only the current custom color is kept, preset palettes stay resident")
    @MainActor
    func tabBrandIconCacheKeepsOneCustom() {
        _ = AppTabBrandIcon.image(for: .home, palette: .darkOcean)
        for seed: UInt in [0xF472B6, 0x4ADE80, 0x60A5FA] {
            _ = AppTabBrandIcon.image(for: .home, palette: .custom(seed: seed))
        }
        let keys = AppTabBrandIcon._testCacheKeys
        #expect(keys.filter { $0.contains("|custom|") }.count == 1)
        #expect(keys.contains { $0.hasSuffix("|custom|#60A5FA") })
        #expect(keys.contains { $0.hasSuffix("|dark-ocean") })
    }

    @Test("The preview code block uses the same highlighter as chat: per-run colors equal the output of SyntaxHighlighter")
    func previewCodeUsesChatHighlighter() {
        let preview = ThemeSettingsView.previewHighlightedCode()
        let chat = SyntaxHighlighter.highlight(
            ThemeSettingsView.previewSnippet, language: "rust", baseColor: MarkdownCodeBlockPalette.foregroundUIColor
        )
        #expect(String(preview.characters) == chat.string)
        let ns = chat.string as NSString
        for (word, expected) in [
            ("let", MarkdownCodeBlockPalette.keywordUIColor),
            ("String", MarkdownCodeBlockPalette.typeUIColor),
            ("\"hi\"", MarkdownCodeBlockPalette.stringUIColor),
        ] {
            let range = ns.range(of: word)
            let chatColor = chat.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
            #expect(chatColor == expected, "\(word)")
            let index = preview.characters.index(preview.startIndex, offsetBy: range.location)
            let previewColor = preview[index..<preview.characters.index(after: index)].runs.first?.foregroundColor
            #expect(previewColor == Color(uiColor: expected), "\(word)")
        }
        // Compare character by character: every preview character takes its color from the same UIColor as the chat highlighter
        for offset in 0..<chat.length {
            let chatColor = chat.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
            let index = preview.characters.index(preview.startIndex, offsetBy: offset)
            let previewColor = preview[index..<preview.characters.index(after: index)].runs.first?.foregroundColor
            #expect(previewColor == chatColor.map { Color(uiColor: $0) }, "offset \(offset)")
        }
    }

    @Test("Preview inline code shares its source with chat: dark text = the previewed palette's accent, background = white at 7%")
    func previewInlineCodeFollowsPreviewedPalette() throws {
        let reply = ThemeSettingsView.previewReply()
        let run = try #require(reply.runs.first { $0.font == .system(size: 12, design: .monospaced) })
        let fg = try #require(run.foregroundColor)
        let bg = try #require(run.backgroundColor)
        for (id, accent) in [(OriveoDarkPaletteID.darkForest, UInt(0xD9F99D)), (.darkSunset, 0xFF7E79)] {
            // Resolved in the preview subtree's environment (dark + the previewed palette)
            let fgColor = MarkdownDarkPaletteColorTests.rgba(fg, .dark, id)
            #expect(fgColor.hex == accent, "\(id.rawValue)")
            let bgColor = MarkdownDarkPaletteColorTests.rgba(bg, .dark, id)
            #expect(bgColor.hex == 0xFFFFFF && bgColor.alpha == 0.07, "\(id.rawValue)")
        }
    }

    // MARK: - Accessibility

    @Test("Swatch a11y: label = palette name, the selected one carries .isSelected")
    func swatchAccessibility() {
        for swatch in ThemeSwatch.all {
            let on = ThemeSwatch.accessibility(swatch, selected: true)
            let off = ThemeSwatch.accessibility(swatch, selected: false)
            #expect(on.label == swatch.displayName)
            #expect(!on.label.isEmpty)
            #expect(on.traits.contains(.isSelected))
            #expect(!off.traits.contains(.isSelected))
        }
        #expect(ThemeSwatch.palette(.dark).displayName == L10n.tr("Default"))
        #expect(ThemeSwatch.palette(.darkSunset).displayName == L10n.tr("Palette Sunset", table: .settings))
    }

    // MARK: - Row summary

    @Test("Row summary, 6 combinations: the default palette shows only the appearance name; the others show \"appearance · palette name\"")
    func rowSummary() {
        let ocean = L10n.tr("Palette Ocean", table: .settings)
        #expect(themeRowSummary(theme: .light, darkPalette: "dark") == L10n.tr("Light"))
        #expect(themeRowSummary(theme: .dark, darkPalette: "dark") == L10n.tr("Dark"))
        #expect(themeRowSummary(theme: .system, darkPalette: "dark") == L10n.tr("Follow System"))
        #expect(themeRowSummary(theme: .light, darkPalette: "dark-ocean") == L10n.format(L10n.tr("Light · %@", table: .settings), ocean))
        #expect(themeRowSummary(theme: .dark, darkPalette: "dark-ocean") == L10n.format(L10n.tr("Dark · %@", table: .settings), ocean))
        #expect(themeRowSummary(theme: .system, darkPalette: "dark-ocean") == L10n.format(
            L10n.tr("Follow System · %@", table: .settings), ocean
        ))
        #expect(themeRowSummary(theme: .dark, darkPalette: "dark-ocean").contains(ocean))
        // Unset / unknown uses the default palette; Custom carries the "Custom" name
        #expect(themeRowSummary(theme: .dark, darkPalette: nil) == L10n.tr("Dark"))
        #expect(themeRowSummary(theme: .light, darkPalette: "dark-future") == L10n.tr("Light"))
        #expect(themeRowSummary(theme: .light, darkPalette: "custom") == L10n.format(
            L10n.tr("Light · %@", table: .settings), L10n.tr("Palette Custom", table: .settings)
        ))
    }

    // MARK: - Helpers

    private static func theme(_ raw: Any?) throws -> ThemeOption {
        let string = try #require(raw as? String)
        return try #require(ThemeOption(rawValue: string))
    }

    private static func appearanceCases() throws -> [[String: Any]] {
        let contract = try OriveoDarkPalettesTests.loadContract()
        return try #require(contract["appearancePageCases"] as? [[String: Any]])
    }

    private static func pageState(_ raw: Any?) throws -> ThemePageState {
        let fields = try #require(raw as? [String: Any])
        return ThemePageState(
            theme: try theme(fields["theme"]),
            darkPalette: fields["darkPalette"] as? String,
            seed: fields["seed"] as? String
        )
    }

    private func runCase(_ name: String) throws {
        let item = try #require(try Self.appearanceCases().first { $0["name"] as? String == name }, "the JSON lacks case \(name)")
        let state = try Self.pageState(item["before"])
        let expected = try Self.pageState(item["after"])

        let action: ThemePageAction
        if let segment = item["segment"] as? String {
            action = .setAppearance(try #require(ThemeOption(rawValue: segment)))
        } else if let pick = item["pickSeed"] as? String {
            action = .pickSeed(try #require(OriveoCustomPalette.parseSeed(pick)))
        } else {
            let tap = try #require(item["tap"] as? String)
            action = tap == OriveoDarkPaletteChoice.customStorageID
                ? .tap(.custom)
                : .tap(.palette(try #require(OriveoDarkPaletteID(rawValue: tap))))
        }
        #expect(ThemePageReducer.apply(state: state, action: action) == expected, "\(name)")
    }
}
