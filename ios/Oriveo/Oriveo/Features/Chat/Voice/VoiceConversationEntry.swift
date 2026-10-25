import Foundation

/// The three states of the composer's primary button: empty draft ≋, text ↑, generating ■; when voice conversation is unavailable an empty draft still shows a grey ↑.
enum ComposerPrimaryAction: Equatable {
    /// Empty draft: enter voice conversation (≋).
    case voice
    /// ↑: enabled = can send.
    case send(enabled: Bool)
    /// Generating: ■ stop.
    case stop
}

/// Pure decisions for entering a voice conversation, shared by the chat page and the home page.
enum VoiceConversationEntry {

    /// Whether the model can produce a text reply: image-only models (metadata has imageGen but no text, or a dedicated image-generation model) cannot.
    static func modelProducesText(_ model: AIModel?) -> Bool {
        guard let model else { return false }
        return !CapabilityEvidenceFacade.isImageOnlyModel(model)
    }

    /// Primary button form. voiceAvailable = this page can enter voice conversation (not read-only, model not removed, dictation engine present).
    static func primaryAction(
        isSending: Bool,
        hasContent: Bool,
        sendEnabled: Bool,
        voiceAvailable: Bool,
        modelProducesText: Bool
    ) -> ComposerPrimaryAction {
        if isSending { return .stop }
        if hasContent { return .send(enabled: sendEnabled) }
        if canEnterVoice(hasContent: hasContent, voiceAvailable: voiceAvailable, modelProducesText: modelProducesText) {
            return .voice
        }
        return .send(enabled: false)
    }

    /// Home input card: the primary key is always ↑ (sends with text, opens the chat page without creating a conversation on an empty draft); ≋ is a secondary button that appears only when voice conversation is available.
    /// isSending = the home page is sending; with text or when unavailable ≋ is hidden outright rather than shown grey (same as the chat page).
    static func homeComposer(
        isSending: Bool,
        hasContent: Bool,
        voiceAvailable: Bool,
        modelProducesText: Bool
    ) -> HomeComposerActions {
        HomeComposerActions(
            sendEnabled: !isSending,
            showsVoice: !isSending && canEnterVoice(
                hasContent: hasContent, voiceAvailable: voiceAvailable, modelProducesText: modelProducesText
            )
        )
    }

    /// Availability rule shared by the chat page primary button and the home ≋: empty draft, this page can enter voice conversation, and the model can produce text.
    private static func canEnterVoice(hasContent: Bool, voiceAvailable: Bool, modelProducesText: Bool) -> Bool {
        !hasContent && voiceAvailable && modelProducesText
    }
}

/// State of the two keys on the home input card: whether ↑ is tappable and whether the ≋ secondary button appears.
struct HomeComposerActions: Equatable {
    let sendEnabled: Bool
    let showsVoice: Bool
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
