import SwiftUI

struct OriveoGradientPanelStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let radius: CGFloat

    init(radius: CGFloat = 22) {
        self.radius = radius
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(panelFill)
            .overlay(cornerGlow)
            .overlay(insetBottomReflection)
            .clipShape(shape)
            .shadow(color: shadow1Color, radius: shadow1Radius, y: shadow1Y)
            .shadow(color: shadow2Color, radius: shadow2Radius, y: shadow2Y)
            .shadow(color: shadow3Color, radius: shadow3Radius, y: shadow3Y)
    }

    private var panelFill: some View {
        shape.fill(
            LinearGradient(
                colors: panelFillColors,
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var panelFillColors: [Color] {
        if colorScheme == .dark {
            // mix(white 7%, surface) → surface → surface → mix(black 14%, surface)
            return [
                blend(.white, with: OriveoTheme.Palette.surface, ratio: 0.07),
                OriveoTheme.Palette.surface,
                OriveoTheme.Palette.surface,
                blend(.black, with: OriveoTheme.Palette.surface, ratio: 0.14)
            ]
        }
        return [
            blend(.white, with: OriveoTheme.Palette.surface, ratio: 0.65),
            OriveoTheme.Palette.surface,
            OriveoTheme.Palette.surface,
            OriveoTheme.Palette.surface
        ]
    }

    private var cornerGlow: some View {
        shape
            .fill(Color.clear)
            .overlay {
                RadialGradient(
                    colors: [
                        cornerGlowColor.opacity(cornerGlowTopLeadingOpacity),
                        Color.clear
                    ],
                    center: UnitPoint(x: -0.05, y: -0.05),
                    startRadius: 0,
                    endRadius: 280
                )
            }
            .overlay {
                RadialGradient(
                    colors: [
                        cornerGlowColor.opacity(cornerGlowBottomTrailingOpacity),
                        Color.clear
                    ],
                    center: UnitPoint(x: 1.05, y: 1.05),
                    startRadius: 0,
                    endRadius: 240
                )
            }
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    private var cornerGlowColor: Color {
        OriveoTheme.Palette.info
    }

    private var cornerGlowTopLeadingOpacity: Double {
        colorScheme == .dark ? 0.12 : 0.065
    }

    private var cornerGlowBottomTrailingOpacity: Double {
        colorScheme == .dark ? 0.08 : 0.045
    }

    private var insetBottomReflection: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            LinearGradient(
                colors: [
                    Color.clear,
                    cornerGlowColor.opacity(colorScheme == .dark ? 0.07 : 0.035)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 6)
            .padding(.horizontal, 1)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }


    private var shadow1Color: Color { OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.9 : 0.10) }
    private var shadow1Radius: CGFloat { colorScheme == .dark ? 4 : 1 }
    private var shadow1Y: CGFloat { colorScheme == .dark ? 4 : 0.5 }

    private var shadow2Color: Color { OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 1.0 : 0.08) }
    private var shadow2Radius: CGFloat { colorScheme == .dark ? 12 : 6 }
    private var shadow2Y: CGFloat { colorScheme == .dark ? 10 : 3 }

    private var shadow3Color: Color { OriveoTheme.Palette.shadowStrong.opacity(colorScheme == .dark ? 0.85 : 0.16) }
    private var shadow3Radius: CGFloat { colorScheme == .dark ? 24 : 18 }
    private var shadow3Y: CGFloat { colorScheme == .dark ? 16 : 10 }

    private func blend(_ a: Color, with b: Color, ratio: Double) -> Color {
        let aUI = UIColor(a)
        let bUI = UIColor(b)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        aUI.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        bUI.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let r = ratio
        return Color(
            red: ar * r + br * (1 - r),
            green: ag * r + bg * (1 - r),
            blue: ab * r + bb * (1 - r),
            opacity: aa * r + ba * (1 - r)
        )
    }
}

extension View {
    func oriveoGradientPanel(radius: CGFloat = 22) -> some View {
        modifier(OriveoGradientPanelStyle(radius: radius))
    }
}
