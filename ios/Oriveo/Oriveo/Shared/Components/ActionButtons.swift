import SafariServices
import SwiftUI

struct OriveoPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .font(OriveoTheme.Typography.title3)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                    .fill(
                        configuration.isPressed ?
                            AnyShapeStyle(OriveoTheme.Palette.primaryGradientPressed) :
                            AnyShapeStyle(OriveoTheme.Palette.primaryGradient)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                    .stroke(OriveoTheme.Palette.hairline.opacity(colorScheme == .dark ? 1 : 0.65), lineWidth: 1)
            )
            .shadow(
                color: OriveoTheme.Palette.primaryGlow,
                radius: colorScheme == .dark ? 22 : 10,
                y: colorScheme == .dark ? 12 : 6
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

struct OriveoSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .font(OriveoTheme.Typography.title3)
            .foregroundStyle(OriveoTheme.Palette.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .oriveoRoundedSurface(
                fill: OriveoTheme.Palette.surfaceChrome,
                border: OriveoTheme.Palette.borderStrong,
                shadow: .soft
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

struct ManagedGoldButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    private static func gold(_ hex: UInt, _ alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    private static func fill(_ hexes: [(UInt, Double)]) -> LinearGradient {
        LinearGradient(
            stops: hexes.map { .init(color: gold($0.0), location: $0.1) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static let fillDark = fill([(0xF6DC96, 0.0), (0xEFC65E, 0.22), (0xDCA83E, 0.62), (0xC08A28, 1.0)])
    private static let fillDarkPressed = fill([(0xEFC65E, 0.0), (0xDCA83E, 0.55), (0xA37420, 1.0)])
    private static let fillLight = fill([(0xF2D286, 0.0), (0xE6B84A, 0.20), (0xCE9832, 0.62), (0xB07C22, 1.0)])
    private static let fillLightPressed = fill([(0xE6B84A, 0.0), (0xCE9832, 0.55), (0x94661B, 1.0)])

    func makeBody(configuration: Configuration) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let pressed = configuration.isPressed

        let fill: LinearGradient = isDark
            ? (pressed ? Self.fillDarkPressed : Self.fillDark)
            : (pressed ? Self.fillLightPressed : Self.fillLight)
        let textColor = isDark ? Self.gold(0x26190A) : Self.gold(0x3B2410)
        let sheen = isDark ? Self.gold(0xFFF8E6, 0.28) : Self.gold(0xFFFFFF, 0.38)
        let glow = isDark
            ? Self.gold(0xDCA83E, pressed ? 0.14 : 0.24)
            : Self.gold(0xB07C22, pressed ? 0.12 : 0.20)

        return configuration.label
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .font(OriveoTheme.Typography.title3)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(sheen, lineWidth: 1))
            .shadow(
                color: glow,
                radius: pressed ? (isDark ? 8 : 6) : (isDark ? 14 : 10),
                y: pressed ? (isDark ? 4 : 3) : (isDark ? 7 : 5)
            )
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

struct OriveoTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OriveoTheme.Typography.caption)
            .foregroundStyle(OriveoTheme.Palette.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct OriveoCircleIconButton: View {
    let systemImage: String
    var fill: AnyShapeStyle = AnyShapeStyle(OriveoTheme.Palette.primary)
    var foreground: Color = .white
    var border: Color = OriveoTheme.Palette.hairline
    var shadowColor: Color = OriveoTheme.Palette.primaryGlow
    var size: CGFloat = 36
    var iconSize: CGFloat = 16
    var bounceValue: Bool = false
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(foreground)
                .symbolEffect(.bounce, value: bounceValue)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(fill)
                        .overlay(
                            Circle()
                                .stroke(border.opacity(colorScheme == .dark ? 1 : 0.65), lineWidth: 1)
                        )
                        .shadow(
                            color: shadowColor,
                            radius: colorScheme == .dark ? 18 : 9,
                            y: colorScheme == .dark ? 10 : 5
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

/// Pages of the project's public repository that the app can open in a browser.
enum ProjectWebDestination: String, Identifiable {
    case sourceCode
    case issues
    case releases

    var id: String { rawValue }

    private static let repository = "https://github.com/oriveo/oriveo"

    var url: URL {
        switch self {
        case .sourceCode:
            return URL(string: Self.repository)!
        case .issues:
            return URL(string: "\(Self.repository)/issues")!
        case .releases:
            return URL(string: "\(Self.repository)/releases")!
        }
    }
}

struct OriveoSafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(OriveoTheme.Palette.primary)
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
