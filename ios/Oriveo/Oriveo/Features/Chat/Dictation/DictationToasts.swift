import Foundation

/// Dictation toasts, shared by the input row and the card.
@MainActor
enum DictationToasts {
    /// ✕ / Discard: calls discard(); on .undoable shows "Recording discarded + Undo", and Undo calls undoDiscard().
    static func discard(_ controller: DictationController) async {
        guard let toast = DictationPresentation.toast(forDiscard: await controller.discard()) else { return }
        ToastManager.shared.show(
            toast.message,
            duration: toast.duration.map(seconds) ?? 4,
            actionTitle: toast.undoTitle,
            action: { [weak controller] in Task { await controller?.undoDiscard() } }
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
