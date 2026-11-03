import Combine
import SwiftUI

/// Dictation host: binds the shared controller to the host's slot and turns controller events into insert / send / toast.
/// The slot key is computed by the host and passed in.
@MainActor
final class DictationHostBinding {
    typealias ToastPresenter = @MainActor (DictationToast) -> Void

    /// Whether the host can send right now; when it cannot, a send event only inserts.
    var canSend: () -> Bool
    /// Inserts the transcript into the input field at the selection.
    var onInsert: (String) -> Void
    /// Sends the current input.
    var onSend: () -> Void
    /// Exit that writes live text into the input field.
    var live: DictationLiveHooks

    private let presentToast: ToastPresenter
    /// Light haptic on recording start and on finalize.
    private let haptics: DictationHaptics
    /// The controller and slot key from the most recent attach, used by activate / detach.
    private weak var controller: DictationController?
    private(set) var slotKey: String?

    /// Subscribes to the controller state (records the original text and selection on record start) and the live-text snapshot; takes effect only while this host owns the events.
    private var liveSubscriptions: [AnyCancellable] = []

    /// The host currently receiving each controller's events: detach clears only the onEvent this host set.
    private static let eventOwners = NSMapTable<DictationController, DictationHostBinding>.weakToWeakObjects()

    init(
        canSend: @escaping () -> Bool = { false },
        onInsert: @escaping (String) -> Void = { _ in },
        onSend: @escaping () -> Void = {},
        toast: @escaping ToastPresenter = DictationHostBinding.showDefaultToast,
        live: DictationLiveHooks = .none,
        haptics: DictationHaptics = .live
    ) {
        self.canSend = canSend
        self.onInsert = onInsert
        self.onSend = onSend
        self.live = live
        self.presentToast = toast
        self.haptics = haptics
    }

    /// Binds to this host's slot and takes over events; the host that attaches last wins and earlier hosts stop receiving.
    func attach(controller: DictationController, slotKey: String) {
        self.controller = controller
        self.slotKey = slotKey
        controller.bind(slotKey: slotKey)
        controller.onEvent = { [weak self] event in self?.handle(event) }
        Self.eventOwners.setObject(self, forKey: controller)
        subscribeLive(to: controller)
    }

    /// Live text is written under the liveText generation: on a generation change the input re-reads the original text and selection, so the old generation's text never overwrites what the user typed afterward.
    /// On entering recording, a light haptic fires and the previous generation's original text is cleared; it is cleared on returning to idle / entering failed (except the idle after a successful transcription:
    /// the controller sets idle first and then sends insert / send; finalization uses this generation's original text to replace the live range, and it clears itself after the replacement).
    /// Setting liveText to nil leaves the text untouched: finalization relies on the insert / send that follows to replace it, and discarding relies on liveDiscarded to revert.
    private func subscribeLive(to controller: DictationController) {
        liveSubscriptions = [
            // @Published emits before the assignment: at this point controller.state is still the old value.
            controller.$state.dropFirst().sink { [weak self, weak controller] next in
                guard let self, let controller, self.ownsEvents(of: controller) else { return }
                switch (controller.state, next) {
                case (.recording, .recording), (.transcribing, .idle):
                    break
                case (_, .recording):
                    self.live.clear()
                    self.haptics.light()
                case (_, .idle), (_, .failed):
                    self.live.clear()
                default:
                    break
                }
            },
            controller.liveText.$value.dropFirst().sink { [weak self, weak controller] value in
                guard let self, let controller, let value, self.ownsEvents(of: controller) else { return }
                self.live.write(value, controller.liveText.generation)
            },
        ]
    }

    private func ownsEvents(of controller: DictationController) -> Bool {
        Self.eventOwners.object(forKey: controller) === self
    }

    /// Mic tapped on this host: pulls the controller back to this host's slot and takes over events.
    func activate() {
        guard let controller, let slotKey else { return }
        attach(controller: controller, slotKey: slotKey)
    }

    /// Host going away: if the controller is still bound to this key, an in-progress recording / transcription ends as interrupted; only an onEvent set by this host is cleared.
    func detach() {
        defer { liveSubscriptions = [] }
        guard let controller, let slotKey, controller.slotKey == slotKey else { return }
        controller.interrupt()
        if Self.eventOwners.object(forKey: controller) === self {
            controller.onEvent = nil
            Self.eventOwners.removeObject(forKey: controller)
        }
    }

    func handle(_ event: DictationEvent) {
        switch DictationPresentation.reaction(to: event, canSend: canSend()) {
        case .insert(let text):
            // System-engine finalization: the host's insert goes through the selection exit and replaces the live range per liveInsert; the cloud engine inserts as usual.
            haptics.light()
            onInsert(text)
        case .insertAndSend(let text):
            haptics.light()
            onInsert(text)
            onSend()
        case .toast(let toast):
            presentToast(toast)
        case .restoreLive:
            live.restore()
        case .ignore:
            break
        }
    }

    static func showDefaultToast(_ toast: DictationToast) {
        guard let duration = toast.duration else {
            ToastManager.shared.show(toast.message, actionTitle: toast.undoTitle)
            return
        }
        let parts = duration.components
        let seconds = TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
        ToastManager.shared.show(toast.message, duration: seconds, actionTitle: toast.undoTitle)
    }
}

private struct DictationHostModifier: ViewModifier {
    let controller: DictationController
    let slotKey: String
    let canSend: () -> Bool
    let onInsert: (String) -> Void
    let onSend: () -> Void
    let live: DictationLiveHooks

    @State private var binding = DictationHostBinding()

    func body(content: Content) -> some View {
        refreshClosures()
        return content
            .onAppear {
                refreshClosures()
                binding.attach(controller: controller, slotKey: slotKey)
            }
            .onChange(of: slotKey) { _, newKey in
                refreshClosures()
                binding.attach(controller: controller, slotKey: newKey)
            }
            .onDisappear { binding.detach() }
            .environment(\.dictationHost, DictationHostContext(slotKey: slotKey) { [binding] in binding.activate() })
    }

    /// Swaps in the latest closures on every host recompute so captured host state does not go stale.
    private func refreshClosures() {
        binding.canSend = canSend
        binding.onInsert = onInsert
        binding.onSend = onSend
        binding.live = live
    }
}

/// Host exit that writes live text into the input field: writes the snapshot under its generation (re-reads the original text and selection on a generation change), reverts on discard, and clears the original text at the end.
/// Finalization does not go through here: the host's onInsert inserts via the selection exit, and when live text was written it replaces the live range per liveInsert.
@MainActor
struct DictationLiveHooks {
    var write: (LiveDictationText, Int) -> Void
    var restore: () -> Void
    var clear: () -> Void

    static let none = DictationLiveHooks(write: { _, _ in }, restore: {}, clear: {})

    /// Writes through the input field's selection exit; the written original text is backfilled into the host's draft binding.
    static func probe(_ probe: ComposerSelectionProbe, text: Binding<String>) -> DictationLiveHooks {
        DictationLiveHooks(
            write: { live, generation in
                if let updated = probe.writeLive(live, generation: generation, currentText: text.wrappedValue) {
                    text.wrappedValue = updated
                }
            },
            restore: {
                if let restored = probe.restoreLive() { text.wrappedValue = restored }
            },
            clear: { probe.clearLive() }
        )
    }
}

/// Dictation haptics (host layer, injectable): light haptic on record start and finalize; error haptic when the failure card appears.
@MainActor
struct DictationHaptics {
    var light: () -> Void
    var error: () -> Void

    static let live = DictationHaptics(light: { OriveoHaptic.tap() }, error: { OriveoHaptic.error() })
}

/// Context the dictation host injects into the subtree: the host key plus the action that pulls the controller back to this host (called first when the mic key is tapped).
struct DictationHostContext {
    let slotKey: String
    let activate: @MainActor () -> Void

    /// The recording bar and card are drawn only on the host the controller is currently bound to; outside any host (no environment value) there is nothing to compare.
    static func isBound(_ host: DictationHostContext?, controllerSlotKey: String?) -> Bool {
        guard let host else { return true }
        return host.slotKey == controllerSlotKey
    }
}

extension EnvironmentValues {
    @Entry var dictationHost: DictationHostContext? = nil
}

extension View {
    /// Makes this view the dictation host: attach on appear and on slotKey change, detach on disappear; injects dictationHost into the subtree.
    /// live writes the system engine's live text into the input field.
    func dictationHost(
        controller: DictationController,
        slotKey: String,
        canSend: @escaping () -> Bool,
        onInsert: @escaping (String) -> Void,
        onSend: @escaping () -> Void,
        live: DictationLiveHooks
    ) -> some View {
        modifier(DictationHostModifier(
            controller: controller, slotKey: slotKey, canSend: canSend, onInsert: onInsert, onSend: onSend, live: live
        ))
    }
}
