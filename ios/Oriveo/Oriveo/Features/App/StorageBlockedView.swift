import SwiftUI

/// The full-screen page shown when the local data cannot be opened.
///
/// ## Why it takes the whole screen
///
/// With the database unreachable, `loadSession` falls back to the recovery snapshot and everything
/// looks normal: the user can send messages, start conversations and change settings, and none of
/// it survives the next launch. Letting them carry on is not leniency, it is letting them work for
/// nothing.
///
/// ## Two cases, kept apart
///
/// - `.storageFull`: the user can fix it → say it is about space, and that the data is still there.
/// - `.unavailable`: the user cannot fix it → do not mention space (that would mislead), offer a
///   retry and a way to ask for help.
///
/// ## No "Free Up Space" button
///
/// iOS has no public API for opening Settings › General › iPhone Storage; `openSettingsURLString`
/// only reaches this app's own settings pane. A button that says "free up space" and takes the
/// user somewhere else is worse than no button, so the action here is Try Again and the body text
/// carries the instruction.
struct StorageBlockedView: View {
    let reason: DatabaseBlockedReason
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: OriveoTheme.Spacing.lg) {
            Image(systemName: iconName)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)

            VStack(spacing: OriveoTheme.Spacing.sm) {
                Text(title)
                    .font(OriveoTheme.Typography.title3)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(L10n.tr("Try Again"), action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .oriveoScreenBackground()
    }

    private var iconName: String {
        switch reason {
        case .storageFull: return "externaldrive.badge.exclamationmark"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch reason {
        case .storageFull: return L10n.tr("Out of Storage")
        case .unavailable: return L10n.tr("Can't Open Local Data")
        }
    }

    private var message: String {
        switch reason {
        // Each key must be a single literal: a concatenated one resolves to the same string at
        // runtime, but the static check cannot see it, so a missing translation goes unnoticed.
        case .storageFull:
            return L10n.tr("Your device has no free space left, so Oriveo can't open its local data. Free up some space and try again — your chats are still saved on this device.")
        case .unavailable:
            return L10n.tr("Oriveo couldn't open its local data on this device. Retry, or contact support if this keeps happening.")
        }
    }
}
