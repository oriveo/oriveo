import CoreGraphics
import SwiftUI

/// Edge fade for the chat message list: the list content is masked by opacity itself, not painted over with the page background.
enum ChatListEdgeFade {
    /// Composer edge: fully opaque at `composerFadeStart` pt above the composer top, fully transparent at `composerFadeEnd` pt.
    static let composerFadeStart: CGFloat = 40
    static let composerFadeEnd: CGFloat = 4

    /// Smoothstep over [edge0, edge1], clamped to 0...1.
    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// List alpha at `distance` pt above the composer top (negative = behind the composer).
    static func alpha(distanceToComposerTop distance: CGFloat) -> CGFloat {
        smoothstep(composerFadeEnd, composerFadeStart, distance)
    }

    /// Stage-mode list alpha: smoothstep from 0 to 1 over the `VoiceStageChrome.listFadeFraction` band at the top of the visible area;
    /// when `fadeOpacity` (VoiceStageChrome.listFadeOpacity) is 0, it linearly returns to fully opaque.
    static func stageMask(fractionFromTop fraction: CGFloat, fadeOpacity: CGFloat = 1) -> CGFloat {
        let shaped = smoothstep(0, VoiceStageChrome.listFadeFraction, fraction)
        let opacity = min(max(fadeOpacity, 0), 1)
        return 1 - opacity * (1 - shaped)
    }

    /// Composite alpha at `y` in a list of `height`: stage top fade-in times composer bottom fade-out.
    static func combinedAlpha(y: CGFloat, height: CGFloat, stageFadeOpacity: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return stageMask(fractionFromTop: y / height, fadeOpacity: stageFadeOpacity)
            * alpha(distanceToComposerTop: height - y)
    }

    /// Both fade bands are densely sampled into gradient stops, so adjacent pixel rows differ in brightness by only a few levels.
    static func maskStops(height: CGFloat, stageFadeOpacity: CGFloat, samplesPerBand: Int = 24) -> [Gradient.Stop] {
        guard height > 0 else { return [.init(color: .clear, location: 0), .init(color: .clear, location: 1)] }
        var ys: [CGFloat] = [0, height]
        let stageBand = height * VoiceStageChrome.listFadeFraction
        let composerTop = max(0, height - composerFadeStart)
        let composerBottom = max(0, height - composerFadeEnd)
        for index in 0...samplesPerBand {
            let step = CGFloat(index) / CGFloat(samplesPerBand)
            ys.append(stageBand * step)
            ys.append(composerTop + (composerBottom - composerTop) * step)
        }
        let sorted = Array(Set(ys.map { min(max($0, 0), height) })).sorted()
        return sorted.map { y in
            .init(
                color: Color.black.opacity(Double(combinedAlpha(y: y, height: height, stageFadeOpacity: stageFadeOpacity))),
                location: y / height
            )
        }
    }
}

/// Vertical alpha mask for the message list; animatable, so the fade-in band transitions smoothly when the stage appears or collapses.
struct ChatListEdgeFadeMask: View, Animatable {
    var stageFadeOpacity: Double

    var animatableData: Double {
        get { stageFadeOpacity }
        set { stageFadeOpacity = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: ChatListEdgeFade.maskStops(
                    height: proxy.size.height,
                    stageFadeOpacity: CGFloat(stageFadeOpacity)
                ),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
