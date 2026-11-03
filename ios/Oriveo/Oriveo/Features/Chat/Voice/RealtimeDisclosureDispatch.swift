import Foundation

/// Where the realtime disclosure was presented from: each page has only one such source; it is written just before presenting the disclosure and taken when answered.
/// The home screen has no capability selection; the voice panel and migration sources carry nil.
enum RealtimeDisclosureOrigin: Hashable {
    /// Realtime row selected in the picker: only record the reply.
    case picker
    /// Voice panel tapped while the selected state is not yet agreed: after consent, continue to start this session.
    case voiceStart(ChatCapabilitySelection?)
    /// Disclosure shown after "switch" in the migration sheet: on reject, cascade into ≋ as usual.
    case migration(ChatCapabilitySelection?)
    /// Realtime typed input cold start hit the selected state without consent: after consent, continue to send this sentence.
    case typedSend(String)
}

/// What to do after the disclosure reply; applying the reply (resolve) is done by the caller, this only decides what happens next.
enum RealtimeDisclosureAction: Hashable {
    /// Only apply the reply; do not open ≋ or send text.
    case resolve(accepted: Bool)
    /// Consent applied; open this session only if it was applied.
    case resolveThenStartVoice(ChatCapabilitySelection?)
    /// Consent applied; send this sentence only if it was applied.
    case resolveThenSendTyped(String)
    /// Hand the reply to migration; if migration did not switch to realtime (rejected), enter ≋ as usual.
    case resolveMigration(accepted: Bool, capabilitySelection: ChatCapabilitySelection?)
}

enum RealtimeDisclosureDispatch {
    /// Source × reply → action. Dropdown dismissal is passed as reject.
    static func action(origin: RealtimeDisclosureOrigin, accepted: Bool) -> RealtimeDisclosureAction {
        switch origin {
        case .picker:
            return .resolve(accepted: accepted)
        case .voiceStart(let selection):
            return accepted ? .resolveThenStartVoice(selection) : .resolve(accepted: false)
        case .typedSend(let text):
            return accepted ? .resolveThenSendTyped(text) : .resolve(accepted: false)
        case .migration(let selection):
            return .resolveMigration(accepted: accepted, capabilitySelection: selection)
        }
    }
}

/// One pending disclosure per page: `present` overwrites (the old source is invalidated), `take` retrieves and clears; the reply takes effect only once.
struct RealtimeDisclosurePending: Hashable {
    private(set) var request: RealtimeModelDisclosureRequest?
    private(set) var origin: RealtimeDisclosureOrigin?

    mutating func present(_ request: RealtimeModelDisclosureRequest, origin: RealtimeDisclosureOrigin) {
        self.request = request
        self.origin = origin
    }

    /// Takes the pending disclosure and its action; nil if none is pending (e.g., onDismiss fires again after onAnswer).
    mutating func take(accepted: Bool) -> (request: RealtimeModelDisclosureRequest, action: RealtimeDisclosureAction)? {
        defer { clear() }
        guard let request, let origin else { return nil }
        return (request, RealtimeDisclosureDispatch.action(origin: origin, accepted: accepted))
    }

    mutating func clear() {
        request = nil
        origin = nil
    }
}
