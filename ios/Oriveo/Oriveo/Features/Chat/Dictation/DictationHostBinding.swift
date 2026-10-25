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

    private let presentToast: ToastPresenter
    /// The controller and slot key from the most recent attach, used by activate / detach.
    private weak var controller: DictationController?
    private(set) var slotKey: String?

    /// The host currently receiving each controller's events: detach only clears an onEvent this host set.
    private static let eventOwners = NSMapTable<DictationController, DictationHostBinding>.weakToWeakObjects()

    init(
        canSend: @escaping () -> Bool = { false },
        onInsert: @escaping (String) -> Void = { _ in },
        onSend: @escaping () -> Void = {},
        toast: @escaping ToastPresenter = DictationHostBinding.showDefaultToast
    ) {
        self.canSend = canSend
        self.onInsert = onInsert
        self.onSend = onSend
        self.presentToast = toast
    }

    /// Binds to this host's slot and takes over events; the host that attaches last wins and earlier hosts stop receiving.
    func attach(controller: DictationController, slotKey: String) {
        self.controller = controller
        self.slotKey = slotKey
        controller.bind(slotKey: slotKey)
        controller.onEvent = { [weak self] event in self?.handle(event) }
        Self.eventOwners.setObject(self, forKey: controller)
    }

    /// Mic tapped on this host: pulls the controller back to this host's slot and takes over events.
    func activate() {
        guard let controller, let slotKey else { return }
        attach(controller: controller, slotKey: slotKey)
    }

    /// Host going away: if the controller is still bound to this key, an in-progress recording / transcription ends as interrupted; only an onEvent set by this host is cleared.
    func detach() {
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
            onInsert(text)
        case .insertAndSend(let text):
            onInsert(text)
            onSend()
        case .toast(let toast):
            presentToast(toast)
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
    }
}

/// Context the dictation host injects into its subtree: the host key plus the action that pulls the controller back to this host (called first when the mic button is tapped).
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
    /// Makes this view a dictation host: attaches on appear and when slotKey changes, detaches on disappear, and injects dictationHost into the subtree.
    func dictationHost(
        controller: DictationController,
        slotKey: String,
        canSend: @escaping () -> Bool,
        onInsert: @escaping (String) -> Void,
        onSend: @escaping () -> Void
    ) -> some View {
        modifier(DictationHostModifier(
            controller: controller, slotKey: slotKey, canSend: canSend, onInsert: onInsert, onSend: onSend
        ))
    }
}
