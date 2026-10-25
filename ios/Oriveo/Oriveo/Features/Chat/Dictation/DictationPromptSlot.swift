import SwiftUI
import UIKit

/// Dictation card slot above the input field: maps the controller state to a card and dispatches button taps to the controller.
/// Draws nothing when there is no card; the card moves in from and out to the top. Also draws nothing when this host is not the one the controller is currently bound to.
struct DictationPromptSlot: View {
    @ObservedObject var controller: DictationController
    /// Check Connection: the host opens that connection's details; when nil, opens the provider list.
    let onCheckConnection: (UUID?) -> Void

    @Environment(\.dictationHost) private var host

    var body: some View {
        let card = DictationHostContext.isBound(host, controllerSlotKey: controller.slotKey)
            ? DictationPresentation.card(for: controller.state, savedDuration: controller.pendingDurationSec)
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
    }

    private func dispatch(_ action: DictationCardAction) {
        let controller = controller
        let onCheckConnection = onCheckConnection
        Task {
            await Self.perform(action, controller: controller,
                               onCheckConnection: onCheckConnection,
                               openSettings: Self.openSystemSettings)
        }
    }

    /// Card action → controller method. Discard goes through DictationToasts and shows the undo toast on an undoable result.
    static func perform(
        _ action: DictationCardAction,
        controller: DictationController,
        onCheckConnection: (UUID?) -> Void,
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
            controller.dismissDenied()
        case .openSettings:
            openSettings()
        case .checkConnection:
            onCheckConnection(controller.engineInfo?.providerID)
        }
    }

    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
