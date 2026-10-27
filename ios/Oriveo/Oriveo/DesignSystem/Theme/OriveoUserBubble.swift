import os
import SwiftUI
import UIKit

// User bubble: a viewport-anchored vertical gradient (JSON `derived.userBubble`).
// One vertical gradient spans the chat's visible area (top → bottom) and each bubble shows only the segment it sits in; bubbles outside the chat list
// (the theme page preview, palette cards) are anchored to their own container. The 7 color stops are taken in advance by OKLCH interpolation (L and C linear, hue along the short arc),
// ported from the reference bubbleStops / bubbleFor implementation, with the cases `userBubbleStops` and
// `custom.derivationCases[].bubble` (per-channel error <= 1). The platform gradient only needs to interpolate in sRGB between adjacent stops.

nonisolated enum OriveoUserBubble {
    /// JSON `derived.userBubble.stops`
    static let stopCount = 7
    /// Top inner highlight: white, 1pt, alpha 0.22 in dark / 0.28 in light (`highlight`)
    static let highlightWidth: CGFloat = 1
    static let highlightAlphaDark: CGFloat = 0.22
    static let highlightAlphaLight: CGFloat = 0.28
    /// Outer shadow: the bottom color at 0.16, blur 14, shifted down 4 (`shadow`). The CALayer / SwiftUI radius is about half the CSS blur.
    static let shadowAlpha: Float = 0.16
    static let shadowBlur: CGFloat = 14
    static let shadowRadius: CGFloat = shadowBlur / 2
    static let shadowOffsetY: CGFloat = 4
    /// An endpoint with chroma below this interpolates with the other endpoint's hue (grey has no hue)
    private static let achromaticChroma = 0.02

    // MARK: - Color stops

    /// Takes `count` color stops (top → bottom) by OKLCH interpolation between the top and bottom colors.
    static func stops(top: UInt, bottom: UInt, count: Int = stopCount) -> [UInt] {
        let a = OriveoCustomPalette.oklch(top)
        let b = OriveoCustomPalette.oklch(bottom)
        var ha = a.h
        var hb = b.h
        if a.c < achromaticChroma { ha = hb }
        if b.c < achromaticChroma { hb = ha }
        var dh = hb - ha
        if dh > 180 { dh -= 360 }
        if dh < -180 { dh += 360 }
        return (0..<count).map { i in
            let t = count == 1 ? 0 : Double(i) / Double(count - 1)
            let hue = (ha + dh * t + 360).truncatingRemainder(dividingBy: 360)
            return OriveoCustomPalette.fromOklch(a.l + (b.l - a.l) * t, a.c + (b.c - a.c) * t, hue)
        }
    }

    private struct Key: Hashable {
        let choice: OriveoDarkPaletteChoice
        let dark: Bool
    }

    /// The dynamic color provider is called on every resolution, so results are cached per (palette, appearance); the key of a custom palette includes its seed color.
    private static let cache = OSAllocatedUnfairLock<[Key: [UInt]]>(initialState: [:])

    /// The bubble color stops of a palette (top → bottom): accent → primary in dark, gradEnd → gradStart in light.
    static func stops(for choice: OriveoDarkPaletteChoice, dark: Bool) -> [UInt] {
        let key = Key(choice: choice, dark: dark)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let result: [UInt]
        if dark {
            let palette = choice.palette
            result = stops(top: palette.accent, bottom: palette.primary)
        } else {
            let brand = choice.lightBrand
            result = stops(top: brand.gradEnd, bottom: brand.gradStart)
        }
        cache.withLock { $0[key] = result }
        return result
    }

    static func stops(for trait: UITraitCollection) -> [UInt] {
        stops(for: trait.oriveoDarkPalette, dark: trait.userInterfaceStyle == .dark)
    }

    /// The 7 dynamic color stops (top → bottom), resolved with the appearance and palette traits.
    static let uiColors: [UIColor] = (0..<stopCount).map { index in
        UIColor { trait in UIColor(oriveoHex: stops(for: trait)[index]) }
    }

    static let colors: [Color] = uiColors.map { Color(uiColor: $0) }

    /// Outer shadow color: the bottom stop (without alpha; the alpha comes from `shadowAlpha`).
    static let shadowBaseUIColor = UIColor { trait in UIColor(oriveoHex: stops(for: trait)[stopCount - 1]) }
    /// The SwiftUI outer shadow color (alpha already applied).
    static let shadowColor = Color(uiColor: UIColor { trait in
        UIColor(oriveoHex: stops(for: trait)[stopCount - 1], alpha: CGFloat(shadowAlpha))
    })

    static let highlightUIColor = UIColor { trait in
        UIColor.white.withAlphaComponent(trait.userInterfaceStyle == .dark ? highlightAlphaDark : highlightAlphaLight)
    }

    static let highlightColor = Color(uiColor: highlightUIColor)

    // MARK: - Anchoring

    /// The gradient's start and end y in the bubble's coordinate system: with visible-area height H and the bubble top at y = t in the visible area → start −t, end H − t.
    static func anchor(viewportHeight: CGFloat, bubbleTopInViewport: CGFloat) -> (startY: CGFloat, endY: CGFloat) {
        (-bubbleTopInViewport, viewportHeight - bubbleTopInViewport)
    }

    /// Converts to the gradient layer's unit coordinates (relative to the bubble height h); with invalid geometry it falls back to the bubble itself, top → bottom.
    static func unitPoints(
        viewportHeight: CGFloat,
        bubbleTopInViewport: CGFloat,
        bubbleHeight: CGFloat
    ) -> (start: CGPoint, end: CGPoint) {
        guard viewportHeight > 0, bubbleHeight > 0 else {
            return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
        }
        let span = anchor(viewportHeight: viewportHeight, bubbleTopInViewport: bubbleTopInViewport)
        return (CGPoint(x: 0.5, y: span.startY / bubbleHeight), CGPoint(x: 0.5, y: span.endY / bubbleHeight))
    }
}

// MARK: - SwiftUI: a bubble background anchored to a container

/// Bubble background (SwiftUI): the vertical stops are anchored to the named coordinate space `space` (height `containerHeight`), with the top inner highlight on top.
/// Used for bubbles outside the chat list, such as the theme page preview card and palette cards.
struct OriveoUserBubbleBackground<S: Shape>: View {
    let shape: S
    let space: String
    let containerHeight: CGFloat
    var showsHighlight = true

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(space))
            let points = OriveoUserBubble.unitPoints(
                viewportHeight: containerHeight,
                bubbleTopInViewport: frame.minY,
                bubbleHeight: frame.height
            )
            ZStack {
                shape.fill(LinearGradient(
                    colors: OriveoUserBubble.colors,
                    startPoint: UnitPoint(x: points.start.x, y: points.start.y),
                    endPoint: UnitPoint(x: points.end.x, y: points.end.y)
                ))
                if showsHighlight {
                    // Inner highlight = the bubble shape minus itself shifted down 1pt, leaving only an arc along the top edge
                    ZStack {
                        shape.fill(OriveoUserBubble.highlightColor)
                        shape.offset(y: OriveoUserBubble.highlightWidth).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .clipShape(shape)
                }
            }
        }
    }
}
