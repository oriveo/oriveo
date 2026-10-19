import SwiftUI

/// "New feature" red dot: an 8pt solid danger-colored circle, decorative and not read by VoiceOver. Whether it shows is decided by `FeatureBadges`.
struct OriveoFeatureBadgeDot: View {
    var body: some View {
        Circle()
            .fill(OriveoTheme.Palette.danger)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
