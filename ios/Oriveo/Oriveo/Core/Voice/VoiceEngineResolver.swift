import Foundation

/// The voice engine selection the user stored in settings (one per direction). For the conversation engine (realtime) direction, system means follow the current model (cascaded conversation).
nonisolated enum VoiceEngineSelection: Sendable, Hashable {
    case system
    case cloud(VoiceCloudEngine)
}

/// A cloud engine: which provider, which connection, which model; read-aloud and conversation engines also carry a voice, while dictation has a nil voice.
nonisolated struct VoiceCloudEngine: Sendable, Hashable {
    let providerKind: ProviderKind
    let connectionID: String
    let model: String
    let voice: String?

    init(providerKind: ProviderKind, connectionID: String, model: String, voice: String? = nil) {
        self.providerKind = providerKind
        self.connectionID = connectionID
        self.model = model
        self.voice = voice
    }
}

/// Connection view used for resolution; the order is supplied by the caller following `AppState.providers`.
nonisolated struct VoiceConnection: Sendable, Hashable {
    let id: String
    let providerKind: ProviderKind
    let authMode: ProviderAuthMode
    let hasKey: Bool

    init(id: String, providerKind: ProviderKind, authMode: ProviderAuthMode, hasKey: Bool) {
        self.id = id
        self.providerKind = providerKind
        self.authMode = authMode
        self.hasKey = hasKey
    }

    init(provider: Provider) {
        self.init(
            id: provider.id.uuidString,
            providerKind: provider.kind,
            authMode: provider.authMode,
            hasKey: !ProviderCredentialResolver.apiKey(provider: provider, modelID: nil).isEmpty
        )
    }

    /// Usable for cloud voice: API key auth mode with a stored key.
    var isUsable: Bool { authMode == .apiKey && hasKey }
}

/// Reasons for falling back to the system engine; only these three.
nonisolated enum VoiceFallbackReason: String, Sendable, Hashable {
    case connectionMissing = "connection_missing"
    case keyMissing = "key_missing"
    case entryRemoved = "entry_removed"
}

/// Whether the stored selection should be rewritten: keep it, or rewrite it to system.
nonisolated enum VoiceSelectionPersist: String, Sendable, Hashable {
    case keep
    case system
}

/// The engine actually in effect.
nonisolated enum VoiceEngineResolution: Sendable, Hashable {
    /// A nil fallback means the user chose the system engine to begin with.
    case system(fallback: VoiceFallbackReason?)
    case cloud(VoiceCloudEngine)

    /// A fallback needs a notice once (once on the settings row, once on next use).
    var notice: Bool {
        if case .system(.some) = self { return true }
        return false
    }

    /// On fallback the stored selection is rewritten to system (never silently swapped for another model).
    var persist: VoiceSelectionPersist {
        notice ? .system : .keep
    }
}

/// One item in the engine picker.
nonisolated enum VoiceEngineOption: Sendable, Hashable {
    case system
    case cloud(providerKind: ProviderKind, connectionID: String, model: String, isDefault: Bool)
}

/// Settings + catalog + connections → effective engine / engine picker. See rules.resolve and rules.options in shared/voice-contracts/engine-resolution.v2.json.
nonisolated enum VoiceEngineResolver {

    static func resolve(
        direction: VoiceDirection,
        selection: VoiceEngineSelection,
        catalog: VoiceCatalog,
        connections: [VoiceConnection]
    ) -> VoiceEngineResolution {
        guard case .cloud(let selected) = selection else { return .system(fallback: nil) }

        guard let connection = connections.first(where: { $0.id == selected.connectionID }),
              connection.providerKind == selected.providerKind else {
            return .system(fallback: .connectionMissing)
        }
        guard connection.isUsable else { return .system(fallback: .keyMissing) }

        switch direction {
        case .stt:
            guard catalog.sttEntries(selected.providerKind).contains(where: { $0.model == selected.model }) else {
                return .system(fallback: .entryRemoved)
            }
            return .cloud(VoiceCloudEngine(
                providerKind: selected.providerKind,
                connectionID: selected.connectionID,
                model: selected.model
            ))
        case .tts:
            guard let entry = catalog.ttsEntries(selected.providerKind).first(where: { $0.model == selected.model }),
                  let fallbackVoice = entry.defaultVoice else {
                return .system(fallback: .entryRemoved)
            }
            let voice = entry.voices.contains(where: { $0.id == selected.voice }) ? selected.voice : fallbackVoice.id
            return .cloud(VoiceCloudEngine(
                providerKind: selected.providerKind,
                connectionID: selected.connectionID,
                model: selected.model,
                voice: voice
            ))
        case .realtime:
            guard let entry = catalog.realtimeEntries(selected.providerKind).first(where: { $0.model == selected.model }),
                  let fallbackVoice = entry.defaultVoice else {
                return .system(fallback: .entryRemoved)
            }
            let voice = entry.voices.contains(where: { $0.id == selected.voice }) ? selected.voice : fallbackVoice.id
            return .cloud(VoiceCloudEngine(
                providerKind: selected.providerKind,
                connectionID: selected.connectionID,
                model: selected.model,
                voice: voice
            ))
        }
    }

    /// The system engine comes first; then, in connection order, all entries of each usable connection for that direction in catalog order. Unusable combinations are not listed (not greyed out).
    static func options(
        direction: VoiceDirection,
        catalog: VoiceCatalog,
        connections: [VoiceConnection]
    ) -> [VoiceEngineOption] {
        var options: [VoiceEngineOption] = [.system]
        for connection in connections where connection.isUsable {
            for item in catalog.models(connection.providerKind, direction: direction) {
                options.append(.cloud(
                    providerKind: connection.providerKind,
                    connectionID: connection.id,
                    model: item.model,
                    isDefault: item.isDefault
                ))
            }
        }
        return options
    }

    /// Engine picker footnote for "no voice yet": deduplicated in connection order, listing providerKinds that have no entries in the catalog for that direction.
    /// authMode / key are ignored; a providerKind with entries is not listed even if its connection is unusable. An empty array means no footnote.
    static func pendingProviders(
        direction: VoiceDirection,
        catalog: VoiceCatalog,
        connections: [VoiceConnection]
    ) -> [ProviderKind] {
        var seen = Set<ProviderKind>()
        var pending: [ProviderKind] = []
        for connection in connections where catalog.models(connection.providerKind, direction: direction).isEmpty {
            if seen.insert(connection.providerKind).inserted {
                pending.append(connection.providerKind)
            }
        }
        return pending
    }
}
