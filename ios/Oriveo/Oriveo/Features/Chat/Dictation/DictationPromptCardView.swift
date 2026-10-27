import SwiftUI

/// Inline dictation card above the input field: display only, with actions delegated to two closures.
/// White rounded card; icon on the left (red exclamation mark for failure / permission, purple waveform otherwise), semibold title + subtitle;
/// bottom right holds a text secondary button and a purple capsule primary button.
struct DictationPromptCardView: View {
    let card: DictationCard
    let onSecondary: () -> Void
    let onPrimary: () -> Void

    static let minimumHitSize: CGFloat = 44
    static let cornerRadius: CGFloat = 18

    /// Failure and permission cards use the alert icon: their primary action is Retry / Check Connection / Open Settings.
    static func isAlert(_ card: DictationCard) -> Bool {
        switch card.primary {
        case .retry, .checkConnection, .openSettings: return true
        case .discard, .transcribeRecording, .transcribeFirst, .discardAndRerecord, .notNow: return false
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            .padding(.top, 12)
            .padding(.horizontal, 14)

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                secondaryButton
                primaryButton
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
        .background(OriveoTheme.Palette.surfaceElevated, in: shape)
        .overlay {
            shape.strokeBorder(OriveoTheme.Palette.textPrimary.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)
    }

    private var icon: some View {
        let alert = Self.isAlert(card)
        return Image(systemName: alert ? "exclamationmark.circle" : "waveform")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(alert ? OriveoTheme.Palette.danger : OriveoTheme.Palette.primary)
            .frame(width: 22, height: 22)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }

    private var secondaryButton: some View {
        let action = card.secondary
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSecondary()
        } label: {
            Text(action.localizedTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .frame(minWidth: Self.minimumHitSize, minHeight: Self.minimumHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.localizedTitle)
    }

    private var primaryButton: some View {
        let action = card.primary
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onPrimary()
        } label: {
            Text(action.localizedTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.onPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Capsule().fill(OriveoTheme.Palette.primaryGradient))
                .frame(minWidth: Self.minimumHitSize, minHeight: Self.minimumHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.localizedTitle)
    }
}
