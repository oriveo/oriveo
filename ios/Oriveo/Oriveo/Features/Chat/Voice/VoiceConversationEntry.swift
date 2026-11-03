import Foundation

/// The three states of the composer's primary button: empty draft ≋, text ↑, generating ■; when voice conversation is unavailable an empty draft still shows a grey ↑.
enum ComposerPrimaryAction: Equatable {
    /// Empty draft: enter voice conversation (≋).
    case voice
    /// ↑: enabled = can send.
    case send(enabled: Bool)
    /// Generating: ■ stop.
    case stop
    /// A realtime voice model is selected in the picker: the input area becomes the persistent voice console (idle orb stays still + "Tap to start talking").
    case voiceStage
    /// Realtime selected and the user switched to typing with an empty draft: the ≋ slot becomes a button back to the voice console.
    case backToStage
}

/// Pure decisions for entering a voice conversation, shared by the chat page and the home page.
enum VoiceConversationEntry {

    /// Whether the model can produce a text reply: image-only models (metadata has imageGen but no text, or a dedicated image-generation model) cannot.
    static func modelProducesText(_ model: AIModel?) -> Bool {
        guard let model else { return false }
        return !CapabilityEvidenceFacade.isImageOnlyModel(model)
    }

    /// Primary button shape. voiceAvailable = this page can enter a voice conversation (not read-only, model not removed, dictation engine available).
    /// realtimeSelected = this page (conversation / home) has a realtime selection: it does not swap the whole block for the voice console while generating, and ignores the draft and text-model capability.
    /// realtimeTyping = with a realtime selection, the user switched from the voice console to typing: an empty draft returns to the voice console, with text it shows ↑; no effect without a realtime selection.
    /// realtimeReadOnly = the check only the realtime branch uses (page read-only): realtime does not use the dictation engine, and the text-model-removed banner is meaningless for realtime models
    /// (realtime delisting goes through model_gone); when nil, falls back to !voiceAvailable.
    static func primaryAction(
        isSending: Bool,
        hasContent: Bool,
        sendEnabled: Bool,
        voiceAvailable: Bool,
        modelProducesText: Bool,
        realtimeSelected: Bool = false,
        realtimeTyping: Bool = false,
        realtimeReadOnly: Bool? = nil
    ) -> ComposerPrimaryAction {
        if isSending { return .stop }
        if realtimeSelected && !(realtimeReadOnly ?? !voiceAvailable) {
            guard realtimeTyping else { return .voiceStage }
            return hasContent ? .send(enabled: sendEnabled) : .backToStage
        }
        if hasContent { return .send(enabled: sendEnabled) }
        if canEnterVoice(hasContent: hasContent, voiceAvailable: voiceAvailable, modelProducesText: modelProducesText) {
            return .voice
        }
        return .send(enabled: false)
    }

    /// Home input card: the primary key is always ↑ (sends with text; an empty draft enters the conversation page without creating a session); ≋ appears as a secondary button only when a voice conversation is possible.
    /// isSending = sending on home, or a managed privacy confirmation is pending; with text or when unavailable, ≋ is hidden rather than shown grayed out (same as the conversation page).
    /// realtimeSelected / realtimeTyping work as in primaryAction: on home in realtime typing mode with an empty draft, the ≋ slot becomes the button back to the voice console; with text, only ↑ appears.
    static func homeComposer(
        isSending: Bool,
        hasContent: Bool,
        voiceAvailable: Bool,
        modelProducesText: Bool,
        realtimeSelected: Bool = false,
        realtimeTyping: Bool = false,
        realtimeReadOnly: Bool? = nil
    ) -> HomeComposerActions {
        let backToStage = primaryAction(
            isSending: isSending,
            hasContent: hasContent,
            sendEnabled: !isSending,
            voiceAvailable: voiceAvailable,
            modelProducesText: modelProducesText,
            realtimeSelected: realtimeSelected,
            realtimeTyping: realtimeTyping,
            realtimeReadOnly: realtimeReadOnly
        ) == .backToStage
        return HomeComposerActions(
            sendEnabled: !isSending,
            showsVoice: !isSending && !backToStage && canEnterVoice(
                hasContent: hasContent, voiceAvailable: voiceAvailable, modelProducesText: modelProducesText
            ),
            showsBackToStage: backToStage
        )
    }

    /// Availability rule shared by the chat page primary button and the home ≋: empty draft, this page can enter voice conversation, and the model can produce text.
    private static func canEnterVoice(hasContent: Bool, voiceAvailable: Bool, modelProducesText: Bool) -> Bool {
        !hasContent && voiceAvailable && modelProducesText
    }
}

/// State of the two home input card keys: whether ↑ is tappable, whether the ≋ secondary button appears, and whether the ≋ slot becomes the button back to the voice console (realtime typing mode, empty draft).
struct HomeComposerActions: Equatable {
    let sendEnabled: Bool
    let showsVoice: Bool
    var showsBackToStage = false
}

/// For `stopToVoiceGuardMs` after ■ turns back into ≋, ≋ ignores taps (mic opened by mistake
/// right as generation ends). Clock is injected.
struct VoiceEntryTapGuard: Equatable {
    static let quietMs = VoiceConversationLogic.Constants.stopToVoiceGuardMs

    private var stoppedAtMs: Int?

    init() {}

    /// Generating → not generating: records the moment ■ turned back into ≋.
    mutating func generationEnded(atMs nowMs: Int) {
        stoppedAtMs = nowMs
    }

    func acceptsTap(atMs nowMs: Int) -> Bool {
        guard let stoppedAtMs else { return true }
        return nowMs - stoppedAtMs >= Self.quietMs
    }

    /// Production clock: milliseconds since system boot (same source as VoiceConversationClock).
    static func nowMs() -> Int {
        Int(ProcessInfo.processInfo.systemUptime * 1000)
    }
}

/// Gate before entering a voice conversation: the provider's first-use disclosure, as on the send path
/// (both the chat page and the home ≋ pass it; pass nil to skip).
enum ChatVoiceConversationGate: Equatable {
    case providerDisclosure(ProviderKind)
    case open

    static func evaluate(
        providerKind: ProviderKind?,
        providerDisclosureAccepted: ((ProviderKind) -> Bool)?
    ) -> ChatVoiceConversationGate {
        if let providerDisclosureAccepted, let kind = providerKind,
           kind.requiresVendorDisclosure, !providerDisclosureAccepted(kind) {
            return .providerDisclosure(kind)
        }
        return .open
    }
}

/// When ≋ is held back by the disclosure gate, the pending entry is remembered: it proceeds after confirmation, and declining neither enters the conversation nor creates a session.
struct PendingVoiceEntry: Equatable {
    private(set) var provider: ProviderKind?

    init() {}

    var isPending: Bool { provider != nil }

    mutating func hold(_ kind: ProviderKind) { provider = kind }

    /// The user accepted the disclosure; records the acceptance here. Returns whether to enter the conversation.
    mutating func accept(_ kind: ProviderKind, markAccepted: (ProviderKind) -> Void) -> Bool {
        guard provider == kind else { return false }
        provider = nil
        markAccepted(kind)
        return true
    }

    mutating func decline() { provider = nil }
}
