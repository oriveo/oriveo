import SwiftUI
import UIKit

extension Color {
    /// For the dark branch only: takes a field of the current palette (trait), regardless of the light/dark slot.
    /// When `glowScaled` is true the alpha is further multiplied by the palette glowK (aurora-type glows, contract `derived.aurora`).
    static func darkPalette(
        _ field: KeyPath<OriveoDarkPalette, UInt>,
        alpha: Double = 1,
        glowScaled: Bool = false
    ) -> Color {
        Color(uiColor: UIColor { trait in
            let palette = trait.oriveoDarkPalette.palette
            let resolvedAlpha = glowScaled ? alpha * palette.glowK : alpha
            return UIColor(oriveoHex: palette[keyPath: field], alpha: CGFloat(resolvedAlpha))
        })
    }

    /// Light mode reuses an existing color as is and dark mode takes a field of the current palette, so the light value is not copied again at the call site.
    static func dynamic(
        keepingLight light: Color,
        dark: KeyPath<OriveoDarkPalette, UInt>,
        darkAlpha: CGFloat = 1
    ) -> Color {
        let lightColor = UIColor(light)
        return Color(uiColor: UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(oriveoHex: trait.oriveoDarkPalette.palette[keyPath: dark], alpha: darkAlpha)
            }
            return lightColor.resolvedColor(with: trait)
        })
    }
}
