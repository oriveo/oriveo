import SwiftUI

/// "The device is out of space, so new content may not be kept" — a banner that stays.
///
/// It does not share `SyncBannerView`: that one is a one-off notice which disappears after five
/// seconds and can be dismissed. This one states an ongoing condition, and should stay for as long
/// as writes keep failing. Giving it a close button would let the user dismiss the fact that data
/// is being lost; the only thing that takes it away is space actually being freed (a successful
/// write clears it, see `StorageWriteHealthSignal.recordSuccess`).
struct StorageDegradedBannerView: View {
    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.warning)

            Text(L10n.tr("Your device is out of space. New messages might not be saved — free up space to keep this conversation."))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OriveoTheme.Palette.warningSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OriveoTheme.Palette.warning.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.top, OriveoTheme.Spacing.sm)
        .accessibilityElement(children: .combine)
    }
}
