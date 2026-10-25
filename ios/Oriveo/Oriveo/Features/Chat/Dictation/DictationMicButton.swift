import SwiftUI

/// Mic button inside the input field: a tap first makes the enclosing host take over the controller, then calls micTapped() (stopping read-aloud, checking the slot and starting a recording all live in the controller).
struct DictationMicButton: View {
    static let minimumHitSize: CGFloat = 44

    @MainActor
    static var accessibilityLabel: String { L10n.tr("Dictate", table: .voice) }

    private let action: @MainActor () -> Void
    /// The enclosing dictation host; when present, a tap first pulls the controller back to this host before recording.
    @Environment(\.dictationHost) private var host

    init(controller: DictationController) {
        self.action = { [weak controller] in
            guard let controller else { return }
            Task { await controller.micTapped() }
        }
    }

    /// For tests and previews: supply the tap action directly.
    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            host?.activate()
            action()
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(width: Self.minimumHitSize, height: Self.minimumHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel)
    }
}
