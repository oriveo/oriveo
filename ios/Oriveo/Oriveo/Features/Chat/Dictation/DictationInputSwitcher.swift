import SwiftUI

/// Input-row switcher: switches between the host's normal input row, the recording bar and the busy state according to the controller state.
/// ✕ / Transcribe / ↑ call the controller directly; ↑ is enabled exactly when the host send button is (canSend).
/// When this host is not the one the controller is currently bound to (two hosts on screen at once on iPad), only the normal content is shown.
struct DictationInputSwitcher<Idle: View>: View {
    @ObservedObject var controller: DictationController
    let canSend: Bool
    @ViewBuilder let idle: () -> Idle

    @Environment(\.dictationHost) private var host

    init(controller: DictationController, canSend: Bool, @ViewBuilder idle: @escaping () -> Idle) {
        self.controller = controller
        self.canSend = canSend
        self.idle = idle
    }

    /// Controller state → input row mode (same as DictationPresentation.inputRow).
    static func rowMode(state: DictationState, engineInfo: DictationEngineInfo?) -> DictationInputRowMode {
        DictationPresentation.inputRow(for: state, engineInfo: engineInfo)
    }

    var body: some View {
        let controller = self.controller
        let bound = DictationHostContext.isBound(host, controllerSlotKey: controller.slotKey)
        DictationInputRow(
            mode: bound ? Self.rowMode(state: controller.state, engineInfo: controller.engineInfo) : .normal,
            levelMeter: controller.levelMeter,
            canSend: canSend,
            onDiscard: { Task { await DictationToasts.discard(controller) } },
            onTranscribe: { Task { await controller.finish(.insert) } },
            onTranscribeAndSend: { Task { await controller.finish(.send) } },
            idle: idle
        )
    }
}

/// The switcher itself: looks only at the mode and never touches the controller (tests render it directly). Switches fade in and out, with no animation under Reduce Motion.
struct DictationInputRow<Idle: View>: View {
    let mode: DictationInputRowMode
    let levelMeter: DictationLevelMeter
    let canSend: Bool
    let onDiscard: () -> Void
    let onTranscribe: () -> Void
    let onTranscribeAndSend: () -> Void
    @ViewBuilder let idle: () -> Idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Animate only when switching between the three forms; timer and progress changes do not trigger it.
    private enum Phase: Hashable { case normal, recording, busy }

    private var phase: Phase {
        switch mode {
        case .normal: return .normal
        case .recording: return .recording
        case .busy: return .busy
        }
    }

    var body: some View {
        ZStack {
            switch mode {
            case .normal:
                idle()
                    .transition(.opacity)
            case .recording, .busy:
                ComposerDictationBar(
                    mode: mode,
                    levelMeter: levelMeter,
                    canSend: canSend,
                    onDiscard: onDiscard,
                    onTranscribe: onTranscribe,
                    onTranscribeAndSend: onTranscribeAndSend
                )
                .id(phase)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase)
    }
}
