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
