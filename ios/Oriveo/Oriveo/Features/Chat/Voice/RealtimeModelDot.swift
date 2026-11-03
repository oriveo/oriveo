import SwiftUI

/// 6 pt cyan glow dot placed before the model name when a realtime voice model is selected.
/// Shared by the session top bar (regular and Duo columns) and the home model pill; purely decorative, not read by VoiceOver.
/// Inside the button the dot gets merged into the button and its identifier cannot be queried, so the top bar attaches it outside the button via `realtimeModelDotAnchor`.
struct RealtimeModelDot: View {
    static let diameter: CGFloat = 6
    /// Identifier UI tests use to find the cyan dot
    static let accessibilityIdentifier = "realtime_model_dot"

    var body: some View {
        Circle()
            .fill(OriveoTheme.Palette.realtimeDot)
            .frame(width: Self.diameter, height: Self.diameter)
            // Same-color soft glow
            .shadow(color: OriveoTheme.Palette.realtimeDot.opacity(0.8), radius: 3)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The button merges its label children into one accessibility element, so the identifier of a dot inside it cannot be queried:
    /// wrap the button in a contain container outside it and attach the dot identifier when realtime is selected, so UI tests can find it.
    /// VoiceOver does not focus the container, only the button inside, so nothing is read twice; text model containers carry no identifier.
    func realtimeModelDotAnchor(_ realtimeSelected: Bool) -> some View {
        VStack(spacing: 0) { self }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(realtimeSelected ? RealtimeModelDot.accessibilityIdentifier : "")
    }
}
