import SwiftUI

struct OriveoIconPlate<Content: View>: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        size: CGFloat = 40,
        cornerRadius: CGFloat = 11,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.content = content
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: fillColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            shape.strokeBorder(
                LinearGradient(
                    colors: borderColors,
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )

            VStack(spacing: 0) {
                Rectangle()
                    .fill(OriveoTheme.Palette.cardHighlight)
                    .frame(height: 1)
                    .padding(.horizontal, 1)
                Spacer(minLength: 0)
            }
            .clipShape(shape)
            .allowsHitTesting(false)

            content()
        }
        .frame(width: size, height: size)
        .shadow(
            color: OriveoTheme.Palette.shadow.opacity(colorScheme == .dark ? 0.7 : 0.12),
            radius: colorScheme == .dark ? 1.5 : 0.8,
            y: colorScheme == .dark ? 1 : 0.4
        )
    }

    private var fillColors: [Color] {
        if colorScheme == .dark {
            return [
                blend(.white, with: OriveoTheme.Palette.surface, ratio: 0.06),
                OriveoTheme.Palette.surface
            ]
        }
        return [
            blend(.white, with: OriveoTheme.Palette.surface, ratio: 0.35),
            OriveoTheme.Palette.surface
        ]
    }

    private var borderColors: [Color] {
        if colorScheme == .dark {
            return [
                OriveoTheme.Palette.cardHighlight,
                OriveoTheme.Palette.hairline,
                OriveoTheme.Palette.shadow
            ]
        }
        return [
            OriveoTheme.Palette.hairline,
            OriveoTheme.Palette.textPrimary.opacity(0.06),
            OriveoTheme.Palette.textPrimary.opacity(0.12)
        ]
    }

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
