import SwiftUI
import UIKit

/// Dictation card slot above the input field: maps the controller state to a card and dispatches button taps to the controller.
/// Draws nothing when there is no card; the card moves in from and out to the top. Also draws nothing when this host is not the one the controller is currently bound to.
struct DictationPromptSlot: View {
    @ObservedObject var controller: DictationController
    /// Check Connection: the host opens that connection's details; when nil, opens the provider list.
    let onCheckConnection: (UUID?) -> Void
    /// Change Dictation Engine: the host opens the voice settings page (changing the recognition language shows a form on that page, not here).
    let onOpenVoiceSettings: () -> Void
    /// Haptic fired when a failure card appears; injected by tests.
    var haptics: DictationHaptics = .live

    @Environment(\.dictationHost) private var host
    /// Whether the recognition language sheet is open. The sheet is modal, so while it is open the input field cannot be reached and no new dictation starts.
    @State private var languageSheetOpen = false

    var body: some View {
        let card = DictationHostContext.isBound(host, controllerSlotKey: controller.slotKey)
            ? DictationPresentation.card(
                for: controller.state, savedDuration: controller.pendingDurationSec, recognitionLanguageName: controller.recognitionLanguageName,
                languagePack: controller.languagePackPrompt
            )
            : nil
        Group {
            if let card {
                DictationPromptCardView(
                    card: card,
                    onSecondary: { dispatch(card.secondary) },
                    onPrimary: { dispatch(card.primary) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: card)
        .onChange(of: card) { old, new in
            Self.cardChanged(from: old, to: new, state: controller.state, haptics: haptics)
        }
        .oriveoSheet(isPresented: $languageSheetOpen) {
            RecognitionLanguageSheet(current: VoiceEngineSettings().recognitionLanguage) { changed in
                languageSheetOpen = false
                let controller = controller
                Task { await Self.languageSheetDone(changed: changed, controller: controller) }
            }
        }
    }

    private func dispatch(_ action: DictationCardAction) {
        let controller = controller
        let onCheckConnection = onCheckConnection
        let onOpenVoiceSettings = onOpenVoiceSettings
        Task {
            await Self.perform(action, controller: controller,
                               onCheckConnection: onCheckConnection,
                               onOpenVoiceSettings: onOpenVoiceSettings,
                               openLanguageSheet: { languageSheetOpen = true },
                               openSettings: Self.openSystemSettings)
        }
    }

    /// Card action → controller method (item 5). Discard goes through DictationToasts and shows an undo prompt when the
    /// result is undoable; Download goes through DictationToasts and shows a downloading prompt once when the download starts.
    static func perform(
        _ action: DictationCardAction,
        controller: DictationController,
        onCheckConnection: (UUID?) -> Void,
        onOpenVoiceSettings: () -> Void,
        openLanguageSheet: () -> Void,
        openSettings: () -> Void
    ) async {
        switch action {
        case .discard:
            await DictationToasts.discard(controller)
        case .retry, .transcribeRecording:
            await controller.finish(.insert)
        case .transcribeFirst:
            await controller.transcribeOccupied()
        case .discardAndRerecord:
            await controller.discardAndRerecord()
        case .notNow:
            // The permission card takes precedence over the language-pack card: Not Now in the denied state belongs to the permission card.
            if case .denied = controller.state {
                controller.dismissDenied()
            } else {
                controller.dismissLanguagePack()
            }
        case .openSettings:
            openSettings()
        case .checkConnection:
            onCheckConnection(controller.engineInfo?.providerID)
        case .changeLanguage:
            openLanguageSheet()
        case .switchEngine:
            onOpenVoiceSettings()
        case .download:
            DictationToasts.languagePackDownloading(controller)
        }
    }

    /// Recognition language sheet closed: if the language changed, take the same path as Retry (the language is read at
    /// transcription time); if the recording is already gone, finish only collapses the card.
    /// Closed without a change: the card stays and the controller is untouched.
    static func languageSheetDone(changed: Bool, controller: DictationController) async {
        guard changed else { return }
        await controller.finish(.insert)
    }

    /// Haptic on card change: error fires once when a failure card replaces the current one (controller in failed);
    /// redrawing the same card, the card disappearing, or a non-failure card do not fire.
    static func cardChanged(from old: DictationCard?, to new: DictationCard?, state: DictationState,
                            haptics: DictationHaptics) {
        guard let new, new != old, case .failed = state else { return }
        haptics.error()
    }

    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
