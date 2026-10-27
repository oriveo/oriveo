import SwiftUI

struct ChatEmptyStateAurora: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.oriveoDarkPalette) private var darkPaletteID

    let prominent: Bool

    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                glowLayer(size: geo.size)
                halftoneLayer(size: geo.size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(appeared ? (prominent ? 1 : 0.4) : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: prominent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: appeared)
        .onAppear {
            appeared = true
        }
    }


    private func halftoneLayer(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let spacing: CGFloat = 15
            let dotMaxRadius: CGFloat = colorScheme == .dark ? 2.7 : 2.3
            let dotMaxAlpha: Double = colorScheme == .dark ? 0.55 : 0.26
            let verticalScale: CGFloat = 1.4
            let maxDimension = max(canvasSize.width, canvasSize.height)
            let base = dotColor

            let bottomFocal = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.90)
            let topFocal = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.07)
            let bottomEnvelopeR = maxDimension * 0.72
            let topEnvelopeR = maxDimension * 0.58
            let topWeight: Double = 0.85

            var y: CGFloat = 0
            var rowIndex = 0
            while y <= canvasSize.height {
                let xOffset: CGFloat = (rowIndex % 2 == 0) ? 0 : spacing / 2
                var x: CGFloat = xOffset
                while x <= canvasSize.width {
                    let bIntensity = envelope(
                        x: x, y: y, focal: bottomFocal, radius: bottomEnvelopeR, verticalScale: verticalScale
                    )
                    let tIntensity = envelope(
                        x: x, y: y, focal: topFocal, radius: topEnvelopeR, verticalScale: verticalScale
                    ) * topWeight
                    let intensity = max(bIntensity, tIntensity)

                    if intensity > 0.02 {
                        let radius = dotMaxRadius * intensity
                        let rect = CGRect(
                            x: x - radius,
                            y: y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(base.opacity(intensity * dotMaxAlpha))
                        )
                    }
                    x += spacing
                }
                y += spacing
                rowIndex += 1
            }
        }
        .allowsHitTesting(false)
    }

    private func envelope(x: CGFloat, y: CGFloat, focal: CGPoint, radius: CGFloat, verticalScale: CGFloat) -> Double {
        let dx = x - focal.x
        let dy = (y - focal.y) * verticalScale
        let distance = (dx * dx + dy * dy).squareRoot()
        let t = max(0, 1 - distance / radius)
        return Double(t * t)
    }


    private func glowLayer(size: CGSize) -> some View {
        let maxDimension = max(size.width, size.height)
        return ZStack {
            RadialGradient(
                colors: [primaryGlowColor, .clear],
                center: UnitPoint(x: 0.5, y: 0.86),
                startRadius: 0,
                endRadius: maxDimension * (colorScheme == .dark ? 0.95 : 0.82)
            )

            RadialGradient(
                colors: [accentGlowColor, .clear],
                center: UnitPoint(x: 0.32, y: 0.80),
                startRadius: 0,
                endRadius: maxDimension * (colorScheme == .dark ? 0.66 : 0.58)
            )
            .blendMode(colorScheme == .dark ? .screen : .normal)

            // Bottom-right glow: dark mode only (the fourth blob of the aurora formula); light mode is unchanged
            if colorScheme == .dark {
                RadialGradient(
                    colors: [Color(oriveoTint: darkTints.bottomRight), .clear],
                    center: UnitPoint(x: 0.72, y: 0.82),
                    startRadius: 0,
                    endRadius: maxDimension * 0.6
                )
                .blendMode(.screen)
            }

            // Top glow: gives the dots above something to catch light from
            RadialGradient(
                colors: [topGlowColor, .clear],
                center: UnitPoint(x: 0.5, y: 0.06),
                startRadius: 0,
                endRadius: maxDimension * 0.55
            )
            .blendMode(colorScheme == .dark ? .screen : .normal)
        }
        .blur(radius: colorScheme == .dark ? 8 : 14)
    }


    /// The four dark-mode glows (aurora formula): bottom primary@26%·k, bottom-left accent@18%·k, bottom-right primary@16%·k, top accent@9%·k.
    struct DarkGlowTints: Equatable {
        let bottom: OriveoDarkPalette.Tint
        let bottomLeft: OriveoDarkPalette.Tint
        let bottomRight: OriveoDarkPalette.Tint
        let top: OriveoDarkPalette.Tint
    }

    static func darkGlowTints(for id: OriveoDarkPaletteChoice) -> DarkGlowTints {
        let palette = id.palette
        return DarkGlowTints(
            bottom: palette.auroraBottom,
            bottomLeft: palette.auroraBottomLeft,
            bottomRight: palette.auroraBottomRight,
            top: palette.auroraTop
        )
    }

    private var darkTints: DarkGlowTints { Self.darkGlowTints(for: darkPaletteID) }

    private var primaryGlowColor: Color {
        colorScheme == .dark
            ? Color(oriveoTint: darkTints.bottom)
            : Color.lightBrand(\.ink, alpha: 0.11)
    }

    private var accentGlowColor: Color {
        colorScheme == .dark
            ? Color(oriveoTint: darkTints.bottomLeft)
            : Color.lightBrand(\.accent, alpha: 0.075, defaultLight: 0x6366F1)
    }

    private var topGlowColor: Color {
        colorScheme == .dark
            ? Color(oriveoTint: darkTints.top)
            : Color.lightBrand(\.ink, alpha: 0.05)
    }

    private var dotColor: Color {
        colorScheme == .dark
            ? Color(hex: darkPaletteID.palette.accent)
            : Color.lightBrand(\.ink)
    }
}
