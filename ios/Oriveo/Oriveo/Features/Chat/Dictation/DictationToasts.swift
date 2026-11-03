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

    /// Language-pack card Download: calls download(); when the prompt switches to downloading, shows once "Downloading X recognition pack" with no action.
    static func languagePackDownloading(_ controller: DictationController) {
        guard let prompt = controller.languagePackPrompt, !prompt.downloading else { return }
        controller.download()
        guard controller.languagePackPrompt?.downloading == true else { return }
        let toast = DictationPresentation.languagePackDownloadingToast(displayName: prompt.displayName)
        ToastManager.shared.show(toast.message, duration: toast.duration.map(seconds) ?? 4)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
