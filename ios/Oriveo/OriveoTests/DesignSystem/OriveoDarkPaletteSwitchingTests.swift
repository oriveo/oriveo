import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Switching the dark palette at runtime: only the window traitOverrides are written, the view hierarchy is not rebuilt, input and scroll position are kept, and colors resolve to the new palette.
@MainActor
@Suite("Dark palette switching", .serialized)
struct OriveoDarkPaletteSwitchingTests {
    /// A view registered for the palette trait: it counts callbacks, equivalent to a card in the product that resolves CGColor.
    private final class TraitProbeView: UIView {
        private(set) var refreshCount = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            registerForTraitChanges(OriveoDarkPaletteTrait.colorAppearanceTraits) { (view: TraitProbeView, _: UITraitCollection) in
                view.refreshCount += 1
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }

    @Test("switching_palette_keeps_view_state: the same view instance, input text and scroll position are unchanged, and colors become the new palette")
    func switchingPaletteKeepsViewState() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.overrideUserInterfaceStyle = .dark
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }

        let scrollView = UIScrollView(frame: root.view.bounds)
        scrollView.contentSize = CGSize(width: 320, height: 4000)
        root.view.addSubview(scrollView)
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        textView.text = "draft that must survive"
        textView.textColor = UIColor.oriveoDynamic(light: 0x18181B, dark: \.text)
        textView.backgroundColor = UIColor.oriveoDynamic(light: 0xFFFFFF, dark: \.surface)
        scrollView.addSubview(textView)
        let probe = TraitProbeView(frame: CGRect(x: 0, y: 300, width: 10, height: 10))
        scrollView.addSubview(probe)
        window.layoutIfNeeded()
        scrollView.contentOffset = CGPoint(x: 0, y: 640)

        textView.updateTraitsIfNeeded()
        #expect(textView.traitCollection.oriveoDarkPalette == .defaultID)
        #expect(Self.hex(textView.textColor, in: textView) == OriveoDarkPalettes.dark.text)
        let refreshesBefore = probe.refreshCount
        let rootView = root.view

        OriveoDarkPaletteSwitcher.apply(.darkOcean, to: [window])
        window.layoutIfNeeded()
        textView.updateTraitsIfNeeded()
        probe.updateTraitsIfNeeded()

        #expect(window.rootViewController === root)
        #expect(root.view === rootView)
        #expect(textView.superview === scrollView && scrollView.superview === rootView)
        #expect(textView.text == "draft that must survive")
        #expect(scrollView.contentOffset == CGPoint(x: 0, y: 640))
        #expect(textView.traitCollection.oriveoDarkPalette == .darkOcean)
        #expect(Self.hex(textView.textColor, in: textView) == OriveoDarkPalettes.darkOcean.text)
        #expect(Self.hex(textView.backgroundColor, in: textView) == OriveoDarkPalettes.darkOcean.surface)
        #expect(probe.refreshCount > refreshesBefore, "the view registered for the palette trait received no refresh")

        // Writing the same palette again triggers no refresh (zero writes, zero notifications).
        let refreshesAfter = probe.refreshCount
        OriveoDarkPaletteSwitcher.apply(.darkOcean, to: [window])
        window.layoutIfNeeded()
        probe.updateTraitsIfNeeded()
        #expect(probe.refreshCount == refreshesAfter)
    }

    @Test("preference_change_updates_window_trait: a change of the stored preference moves the window trait; unset / unknown ids fall back to the default dark")
    func preferenceChangeUpdatesWindowTrait() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let rootView = try #require(window.rootViewController?.view)
        window.layoutIfNeeded()

        var preference = AppPreference(theme: .dark, language: .system)
        preference.darkPalette = OriveoDarkPaletteID.darkForest.rawValue
        OriveoDarkPaletteSwitcher.applyStoredPreference(preference.darkPalette, seed: preference.darkPaletteCustom, to: [window])
        window.layoutIfNeeded()
        rootView.updateTraitsIfNeeded()
        #expect(rootView.traitCollection.oriveoDarkPalette == .darkForest)

        preference.darkPalette = "dark-aurora-future"
        OriveoDarkPaletteSwitcher.applyStoredPreference(preference.darkPalette, seed: preference.darkPaletteCustom, to: [window])
        window.layoutIfNeeded()
        rootView.updateTraitsIfNeeded()
        #expect(rootView.traitCollection.oriveoDarkPalette == .defaultID)

        preference.darkPalette = OriveoDarkPaletteID.darkSunset.rawValue
        OriveoDarkPaletteSwitcher.applyStoredPreference(preference.darkPalette, seed: preference.darkPaletteCustom, to: [window])
        window.layoutIfNeeded()
        rootView.updateTraitsIfNeeded()
        #expect(rootView.traitCollection.oriveoDarkPalette == .darkSunset)

        preference.darkPalette = nil
        OriveoDarkPaletteSwitcher.applyStoredPreference(preference.darkPalette, seed: preference.darkPaletteCustom, to: [window])
        window.layoutIfNeeded()
        rootView.updateTraitsIfNeeded()
        #expect(rootView.traitCollection.oriveoDarkPalette == .defaultID)
    }

    @Test("a palette in the SwiftUI environment resolves to that palette's color values through the trait bridge")
    func swiftUIEnvironmentResolvesPalette() {
        for id in OriveoDarkPaletteID.allCases {
            var environment = EnvironmentValues()
            environment.colorScheme = .dark
            environment.oriveoDarkPalette = .preset(id)
            let resolved = UIColor(cgColor: OriveoTheme.Palette.backgroundBase.resolve(in: environment).cgColor)
            #expect(Self.hex(resolved) == id.palette.bg, "\(id.rawValue)")
        }
    }

    @Test("debug_palette_menu_removed: once the real preference takes over, Settings has no Debug palette section and switching only goes through the theme page")
    func debugPaletteMenuOnlyInDebug() throws {
        let source = try String(contentsOf: Self.findFile([
            "ios", "Oriveo", "Oriveo", "Features", "Settings", "SettingsView.swift",
        ]), encoding: .utf8)
        #expect(source.contains("navigation.attemptNavigate(to: .themeSettings)"), "Settings has no theme page entry, so this assertion has lost its subject")
        #expect(!source.contains("debugDarkPalette"))
        #expect(!source.contains("OriveoDarkPaletteSwitcher"))
        #expect(!source.contains("settings_debug_dark_palette"))
    }

    // MARK: - Helpers

    private static func hex(_ color: UIColor?, in view: UIView) -> UInt? {
        guard let color else { return nil }
        return hex(color.resolvedColor(with: view.traitCollection))
    }

    private static func hex(_ color: UIColor) -> UInt {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt((r * 255).rounded()) << 16) | (UInt((g * 255).rounded()) << 8) | UInt((b * 255).rounded())
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
