import SwiftUI

/// A slim banner under the navigation bar that only appears while the device is offline.
struct ServiceReachabilityBannerView: View {
    let state: ServiceReachabilityMonitor.State
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        if let model = bannerModel {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: model.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.foreground)

                Text(model.text)
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: OriveoTheme.Spacing.sm)

                if model.dismissible, let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(model.foreground.opacity(0.75))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("Close"))
                }
            }
            .padding(.leading, OriveoTheme.Spacing.lg)
            .padding(.trailing, OriveoTheme.Spacing.sm)
            .padding(.vertical, OriveoTheme.Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(model.background)
            .clipShape(.rect(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        }
    }

    private var bannerModel: BannerModel? {
        switch state {
        case .online:
            return nil
        case .noNetwork:
            return BannerModel(
                icon: "wifi.slash",
                text: L10n.tr("No internet connection"),
                foreground: OriveoTheme.Palette.danger,
                background: OriveoTheme.Palette.dangerSoft,
                dismissible: true
            )
        }
    }

    private struct BannerModel {
        let icon: String
        let text: String
        let foreground: Color
        let background: Color
        let dismissible: Bool
    }
}
