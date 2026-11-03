import SwiftUI

/// Back-to-stage button in the ≋ slot while realtime typing with an empty draft: a 36 pt static orb shared by Home and the chat page (same VoiceOver label; the page passes the accessibility identifier).
/// The page decides what a tap does (Home only returns to the idle stage; the chat page resumes capture first when a realtime session exists).
struct RealtimeBackToStageButton: View {
    static let orbSize: CGFloat = 36
    static var accessibilityLabel: String { VoiceConversationCopy.backToStageA11y }

    /// Accessibility identifier: chat_voice_back_to_stage_button on the chat page, home_voice_back_to_stage_button on Home.
    let accessibilityID: String
    /// Hit area edge: 44 on Home, 40 on the chat page (aligned with the other buttons in each input bar).
    let hitSize: CGFloat
    let namespace: Namespace.ID?
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VoiceAuroraOrb(
                mode: VoiceConversationBarContent.orbMode(statusKey: nil, displayState: nil),
                level: 0,
                size: Self.orbSize
            )
            .frame(width: hitSize, height: hitSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .voiceOrbMatched(namespace, reduceMotion: reduceMotion)
        .accessibilityLabel(Self.accessibilityLabel)
        .accessibilityIdentifier(accessibilityID)
    }
}
