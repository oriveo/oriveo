import SwiftUI

/// Inline dictation card above the input field (floating card): display only; the actions are handed to two closures.
/// Left side: a 40pt amber circle with a waveform icon, title + body; bottom right: two capsules of minimum height 40pt, the secondary action on a grey fill and the primary action on a violet gradient.
/// Text scales with Dynamic Type, capped at accessibility2.
struct DictationPromptCardView: View {
    let card: DictationCard
    let onSecondary: () -> Void
    let onPrimary: () -> Void

    static let minimumHitSize: CGFloat = 44
    static let cornerRadius: CGFloat = 24
    static let padding: CGFloat = 18
    static let iconSize: CGFloat = 40
    static let iconSpacing: CGFloat = 14
    static let buttonMinHeight: CGFloat = 40
    /// Card text follows Dynamic Type up to this size; buttons grow past 40pt with the text.
    static let dynamicTypeCap: DynamicTypeSize = .accessibility2
    static let buttonSpacing: CGFloat = 10
    static let buttonHorizontalPadding: CGFloat = 18

    /// Failure and permission cards (the primary action is Retry / Check Connection / Open Settings, etc.).
    static func isAlert(_ card: DictationCard) -> Bool {
        switch card.primary {
        case .retry, .checkConnection, .openSettings, .changeLanguage, .switchEngine: return true
        case .discard, .transcribeRecording, .transcribeFirst, .discardAndRerecord, .notNow, .download: return false
        }
    }

    private static let hairline = Color.dynamic(light: 0x0F172A, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    private static let shadow = Color.dynamic(light: 0x0F172A, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0)
    private static let bodyColor = Color.dynamic(light: 0x52525B, dark: 0xB3B3BA)
    static let iconTint = Color.dynamic(light: 0xC2410C, dark: 0xFCD34D)
    static let iconFillTop = Color.dynamic(light: 0xFFF4E5, dark: 0xF59E0B, lightAlpha: 1, darkAlpha: 0.18)
    private static let iconFillBottom = Color.dynamic(light: 0xFFE7C7, dark: 0xF59E0B, lightAlpha: 1, darkAlpha: 0.18)
    /// Icon stroke: light #B45309 α.18; dark draws nothing (transparent).
    static let iconHairline = Color.dynamic(light: 0xB45309, dark: 0xB45309, lightAlpha: 0.18, darkAlpha: 0)
    private static let secondaryText = Color.dynamic(light: 0x3F3F46, dark: 0xEDEDEF)
    private static let secondaryFill = Color.dynamic(light: 0xF2F2F5, dark: 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.10)
    private static let primaryShadow = Color(hex: 0x7C3AED).opacity(0.28) // capability-ui-lint: allow voice / dictation capsule brand violet, not a capability colour

    var body: some View {
        // The font-size cap sits outside the inner view: @ScaledMetric reads the inner view's own environment, so the cap takes effect only this way.
        Content(card: card, onSecondary: onSecondary, onPrimary: onPrimary)
            .dynamicTypeSize(...Self.dynamicTypeCap)
    }

    private struct Content: View {
        let card: DictationCard
        let onSecondary: () -> Void
        let onPrimary: () -> Void

        /// Title 17pt, body 14.5pt (line height 1.5×, line spacing padded to 1.5× the font size), button 15pt, icon 19pt: all scale with Dynamic Type.
        @ScaledMetric(relativeTo: .headline) private var titleFontSize: CGFloat = 17
        @ScaledMetric(relativeTo: .subheadline) private var bodyFontSize: CGFloat = 14.5
        @ScaledMetric(relativeTo: .subheadline) private var buttonFontSize: CGFloat = 15
        @ScaledMetric(relativeTo: .headline) private var iconGlyphSize: CGFloat = 19

        private var bodyLineSpacing: CGFloat {
            max(0, bodyFontSize * 1.5 - UIFont.systemFont(ofSize: bodyFontSize).lineHeight)
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DictationPromptCardView.cornerRadius, style: .continuous)
            VStack(alignment: .leading, spacing: DictationPromptCardView.padding) {
                HStack(alignment: .top, spacing: DictationPromptCardView.iconSpacing) {
                    icon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title)
                            .font(.system(size: titleFontSize, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !card.subtitle.isEmpty {
                            Text(card.subtitle)
                                .font(.system(size: bodyFontSize))
                                .lineSpacing(bodyLineSpacing)
                                .foregroundStyle(DictationPromptCardView.bodyColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }

                HStack(spacing: DictationPromptCardView.buttonSpacing) {
                    Spacer(minLength: 0)
                    secondaryButton
                    primaryButton
                }
            }
            .padding(DictationPromptCardView.padding)
            .background(OriveoTheme.Palette.surfaceElevated, in: shape)
            .overlay {
                shape.strokeBorder(DictationPromptCardView.hairline, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: DictationPromptCardView.shadow, radius: 17, y: 14)
        }

        private var icon: some View {
            Image(systemName: "waveform")
                .font(.system(size: iconGlyphSize, weight: .semibold))
                .foregroundStyle(DictationPromptCardView.iconTint)
                .frame(width: DictationPromptCardView.iconSize, height: DictationPromptCardView.iconSize)
                .background {
                    Circle()
                        .fill(LinearGradient(colors: [DictationPromptCardView.iconFillTop, DictationPromptCardView.iconFillBottom], startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().strokeBorder(DictationPromptCardView.iconHairline, lineWidth: 0.5))
                }
                .accessibilityHidden(true)
        }

        private func label(_ title: String, color: Color) -> some View {
            Text(title)
                .font(.system(size: buttonFontSize, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, DictationPromptCardView.buttonHorizontalPadding)
                .padding(.vertical, 8)
                .frame(minHeight: DictationPromptCardView.buttonMinHeight)
        }

        private var secondaryButton: some View {
            let action = card.secondary
            return Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSecondary()
            } label: {
                label(action.localizedTitle, color: DictationPromptCardView.secondaryText)
                    .background(Capsule().fill(DictationPromptCardView.secondaryFill))
                    .contentShape(Capsule())
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
                label(action.localizedTitle, color: .white)
                    .background(
                        Capsule()
                            .fill(ComposerDictationBar.primaryGradient)
                            .shadow(color: DictationPromptCardView.primaryShadow, radius: 7, y: 6)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(action.localizedTitle)
        }
    }
}
