import Foundation

/// Consent for sending data to a cloud voice service, recorded per (providerKind, direction).
/// Stored separately from the message-sending disclosure (ProviderDisclosureStore): it is only used
/// when a cloud engine is picked in the engine sheet.
/// Device-level, kept in local UserDefaults only.
nonisolated struct VoiceDisclosureStore {
    private static let acceptedListKey = "voice.disclosure.accepted.list"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasAccepted(_ kind: ProviderKind, direction: VoiceDirection) -> Bool {
        acceptedTokens().contains(Self.token(kind, direction))
    }

    func markAccepted(_ kind: ProviderKind, direction: VoiceDirection) {
        var accepted = acceptedTokens()
        guard accepted.insert(Self.token(kind, direction)).inserted else { return }
        defaults.set(accepted.sorted(), forKey: Self.acceptedListKey)
    }

    /// Only for tests or a "reset all consents" flow.
    func reset() {
        defaults.removeObject(forKey: Self.acceptedListKey)
    }

    private func acceptedTokens() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.acceptedListKey) ?? [])
    }

    private static func token(_ kind: ProviderKind, _ direction: VoiceDirection) -> String {
        "\(direction.rawValue).\(kind.rawValue)"
    }
}

/// Result of picking an entry in the engine sheet.
nonisolated enum VoiceEngineChoiceOutcome: Sendable, Hashable {
    /// Written to settings.
    case applied(VoiceEngineSelection)
    /// This (providerKind, direction) has no consent yet: show the disclosure first and leave settings
    /// untouched; call `resolveDisclosure` once the user answers.
    case needsDisclosure(VoiceCloudEngine)
}

/// Selection flow of the engine sheet: system takes effect immediately; a cloud engine needs
/// disclosure consent first, and the disclosure is shown when consent is missing.
nonisolated struct VoiceEngineChooser {
    let settings: VoiceEngineSettings
    let disclosures: VoiceDisclosureStore

    init(
        settings: VoiceEngineSettings = VoiceEngineSettings(),
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) {
        self.settings = settings
        self.disclosures = disclosures
    }

    /// Picks an entry. For read-aloud / conversation engines the voice is set to the entry's default voice.
    func choose(_ option: VoiceEngineOption, direction: VoiceDirection, catalog: VoiceCatalog) -> VoiceEngineChoiceOutcome {
        switch option {
        case .system:
            apply(.system, direction: direction)
            return .applied(.system)
        case .cloud(let providerKind, let connectionID, let model, _):
            let voice: String?
            switch direction {
            case .stt:
                voice = nil
            case .tts:
                voice = catalog.ttsEntries(providerKind).first(where: { $0.model == model })?.defaultVoice?.id
            case .realtime:
                voice = catalog.realtimeEntries(providerKind).first(where: { $0.model == model })?.defaultVoice?.id
            }
            let engine = VoiceCloudEngine(providerKind: providerKind, connectionID: connectionID, model: model, voice: voice)
            guard disclosures.hasAccepted(providerKind, direction: direction) else {
                return .needsDisclosure(engine)
            }
            apply(.cloud(engine), direction: direction)
            return .applied(.cloud(engine))
        }
    }

    /// The answer to the disclosure: accepted -> record consent and write settings; declined (including
    /// dismissing the sheet) -> settings untouched. Returns whether settings were written.
    @discardableResult
    func resolveDisclosure(_ engine: VoiceCloudEngine, direction: VoiceDirection, accepted: Bool) -> Bool {
        guard accepted else { return false }
        disclosures.markAccepted(engine.providerKind, direction: direction)
        apply(.cloud(engine), direction: direction)
        return true
    }

    /// User-initiated selection: write settings and clear the pending notices for both slots of this
    /// direction (the fallback notice for the old selection must not show again).
    private func apply(_ selection: VoiceEngineSelection, direction: VoiceDirection) {
        settings.setSelection(selection, for: direction)
        settings.clearPendingNotices(direction: direction)
    }
}
