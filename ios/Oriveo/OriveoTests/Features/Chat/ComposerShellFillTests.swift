import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

@Suite("ComposerShellFill")
struct ComposerShellFillTests {

    @Test("Light fills are opaque for every state")
    func lightFillsAreOpaque() {
        for state in ComposerShellFill.State.allCases {
            #expect(ComposerShellFill.spec(for: state).light.alpha == 1, "state \(state)")
        }
    }

    @Test("Light fills equal the tint composited onto the page base")
    func lightFillHexValues() {
        #expect(ComposerShellFill.spec(for: .idle).light.hex == 0xFBFBFB)
        #expect(ComposerShellFill.spec(for: .focused).light.hex == 0xFBFBFB)
        // 0xFBF9FF at alpha 0.19 source-over the light page base, rounded per channel.
        #expect(ComposerShellFill.spec(for: .draftHighlight).light.hex == 0xFAFAFB)
    }

    @Test("Dark fills keep their translucent values")
    func darkFillsUnchanged() {
        #expect(ComposerShellFill.spec(for: .focused).dark == .init(hex: 0x101113, alpha: 0.46))
        #expect(ComposerShellFill.spec(for: .draftHighlight).dark == .init(hex: 0x0B0C0E, alpha: 0.42))
        #expect(ComposerShellFill.spec(for: .idle).dark == .init(hex: 0x07080A, alpha: 0.38))
    }

    @Test("light_base_matches_theme_token")
    func lightBaseMatchesThemeToken() {
        let token = UIColor(OriveoTheme.Palette.backgroundBase)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        #expect(ComposerShellFill.lightPageBase == OriveoDarkPalettesTests.hex(of: token))
        // The light fill for an opaque-white tint must equal the page base itself.
        #expect(ComposerShellFill.compositeOver(.init(hex: 0x123456, alpha: 0), base: ComposerShellFill.lightPageBase).hex
            == ComposerShellFill.lightPageBase)
    }

    @Test("Composite output is opaque for any input alpha")
    func compositeIsAlwaysOpaque() {
        let alphas: [CGFloat] = [0, 0.11, 0.19, 0.5, 0.99, 1]
        for alpha in alphas {
            let out = ComposerShellFill.compositeOver(.init(hex: 0x123456, alpha: alpha), base: 0xFFFFFF)
            #expect(out.alpha == 1, "alpha \(alpha)")
        }
        #expect(ComposerShellFill.compositeOver(.init(hex: 0x123456, alpha: 1), base: 0xFFFFFF).hex == 0x123456)
        #expect(ComposerShellFill.compositeOver(.init(hex: 0x123456, alpha: 0), base: 0xFFFFFF).hex == 0xFFFFFF)
    }
}
