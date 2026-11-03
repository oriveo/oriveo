import SwiftUI

/// Dictation input row phase: the host uses it to decide whether the input field is editable, and the mic and glow edge inside the field.
enum DictationInputPhase: Hashable, Sendable {
    case normal, recording, busy

    init(_ mode: DictationInputRowMode) {
        switch mode {
        case .normal: self = .normal
        case .recording: self = .recording
        case .busy: self = .busy
        }
    }

    /// Recording or transcribing: the input field stays on screen but is not editable.
    var isDictating: Bool { self != .normal }
}

/// The switcher container reports the current phase upward, so hosts that outline it from outside the container
/// (the home glass card) can attach the glow edge.
struct DictationInputPhaseKey: PreferenceKey {
    static let defaultValue: DictationInputPhase = .normal

    static func reduce(value: inout DictationInputPhase, nextValue: () -> DictationInputPhase) {
        let next = nextValue()
        if next != .normal { value = next }
    }
}

/// Layout of the input slot and the button slot.
enum DictationInputRowArrangement: Sendable, Equatable {
    /// Normally the input and buttons sit side by side (bottom-aligned); while dictating, the input sits on top and the
    /// recording bar spans the full width below (chat input bar).
    case sideBySide(spacing: CGFloat, stackedSpacing: CGFloat)
    /// Always stacked vertically (home card).
    case stacked(spacing: CGFloat)
}

/// Input row switcher: by controller state, switches the button slot between the host buttons and the recording bar or
/// busy state; the input slot always stays on screen (contract items 2 and 6).
/// ✕ / Done / ↑ call the controller directly; the availability of ↑ matches the host's send key (canSend).
/// When the host is not the one the controller is currently bound to (iPad two-column layout with two hosts on screen),
/// only the ordinary content is shown.
struct DictationInputSwitcher<Input: View, Buttons: View>: View {
    @ObservedObject var controller: DictationController
    let canSend: Bool
    let arrangement: DictationInputRowArrangement
    @ViewBuilder let input: (DictationInputPhase) -> Input
    @ViewBuilder let buttons: () -> Buttons

    @Environment(\.dictationHost) private var host

    init(
        controller: DictationController,
        canSend: Bool,
        arrangement: DictationInputRowArrangement = .stacked(spacing: 12),
        @ViewBuilder input: @escaping (DictationInputPhase) -> Input,
        @ViewBuilder buttons: @escaping () -> Buttons
    ) {
        self.controller = controller
        self.canSend = canSend
        self.arrangement = arrangement
        self.input = input
        self.buttons = buttons
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
            arrangement: arrangement,
            onDiscard: { Task { await DictationToasts.discard(controller) } },
            onTranscribe: { Task { await controller.finish(.insert) } },
            onTranscribeAndSend: { Task { await controller.finish(.send) } },
            input: input,
            buttons: buttons
        )
    }
}

/// The switch itself: looks only at the mode and does not touch the controller (tests render it directly). The input slot
/// always stays in the same structural position (changing the arrangement does not rebuild the input field); the button
/// slot cross-fades when switching, and there is no animation under Reduce Motion.
struct DictationInputRow<Input: View, Buttons: View>: View {
    let mode: DictationInputRowMode
    let levelMeter: DictationLevelMeter
    let canSend: Bool
    let arrangement: DictationInputRowArrangement
    let onDiscard: () -> Void
    let onTranscribe: () -> Void
    let onTranscribeAndSend: () -> Void
    @ViewBuilder let input: (DictationInputPhase) -> Input
    @ViewBuilder let buttons: () -> Buttons

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Animates only when switching between the three forms; timer and progress changes do not trigger it.
    private var phase: DictationInputPhase { DictationInputPhase(mode) }

    private var layout: AnyLayout {
        switch arrangement {
        case let .sideBySide(spacing, stackedSpacing):
            phase.isDictating
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: stackedSpacing))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: spacing))
        case let .stacked(spacing):
            AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        }
    }

    var body: some View {
        layout {
            input(phase)
            switch mode {
            case .normal:
                buttons()
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
        .preference(key: DictationInputPhaseKey.self, value: phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase)
    }
}
