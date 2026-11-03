import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// `Palette.primaryTextOnSurface` is the brand color used as text / links on page surfaces.
/// Light bright seeds (amber, teal) must stay readable on white; dark keeps `primary`.
@MainActor
@Suite("Primary text on surface")
struct PrimaryTextOnSurfaceTests {
    private static func resolved(_ style: UIUserInterfaceStyle, _ choice: OriveoDarkPaletteChoice) -> UInt {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.oriveoDarkPalette = choice
        }
        return OriveoDarkPalettesTests.hex(of: OriveoTheme.Palette.primaryTextOnSurfaceUIColor.resolvedColor(with: traits))
    }

    private static func custom(_ seed: String) throws -> OriveoDarkPaletteChoice {
        .custom(seed: try #require(OriveoCustomPalette.parseSeed(seed)))
    }

    @Test("default palette in light resolves to 0x6D28D9")
    func defaultPaletteIsTextSafePurple() {
        #expect(Self.resolved(.light, .defaultID) == 0x6D28D9)
    }

    @Test("bright seeds in light reach 4.5:1 against white", arguments: ["#FBBF24", "#2DD4BF"])
    func brightSeedsAreReadableOnWhite(seed: String) throws {
        let choice = try Self.custom(seed)
        let text = Self.resolved(.light, choice)
        let ratio = OriveoCustomPalette.contrast(text, 0xFFFFFF)
        #expect(ratio >= 4.5, "\(seed) text on white is only \(ratio):1")
        #expect(text == choice.lightBrand.textSafe)
    }

    @Test("dark mode resolves to primary", arguments: ["#FBBF24", "#2DD4BF"])
    func darkModeIsPrimary(seed: String) throws {
        let choice = try Self.custom(seed)
        #expect(Self.resolved(.dark, choice) == choice.palette.primary)
        #expect(Self.resolved(.dark, .defaultID) == OriveoDarkPaletteChoice.defaultID.palette.primary)
    }
}
