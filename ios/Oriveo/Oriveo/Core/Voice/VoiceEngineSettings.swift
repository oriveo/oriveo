import Foundation

/// Voice engine settings: one engine selection each for dictation / read-aloud / conversation engine, the dictation recognition language (nil = automatic), and the read-aloud speed.
/// Stored only in local UserDefaults.
nonisolated struct VoiceEngineSettings {
    static let defaultSpeechRate: Double = 1.0

    private enum Key {
        static let sttSelection = "voice.engine.stt"
        static let ttsSelection = "voice.engine.tts"
        static let realtimeSelection = "voice.engine.realtime"
        static let recognitionLanguage = "voice.dictation.language"
        static let speechRate = "voice.readAloud.speechRate"
        static let pendingNoticePrefix = "voice.engine.pendingNotice"
    }

    /// On-disk form of a selection; kind is only system / cloud.
    private struct StoredSelection: Codable {
        let kind: String
        let providerKind: String?
        let connectionID: String?
        let model: String?
        let voice: String?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Engine selection

    /// Nothing stored, or stored content that is not recognized, always means the system engine.
    func selection(for direction: VoiceDirection) -> VoiceEngineSelection {
        guard let data = defaults.data(forKey: Self.selectionKey(direction)),
              let stored = try? JSONDecoder().decode(StoredSelection.self, from: data),
              stored.kind == "cloud",
              let providerKind = stored.providerKind.flatMap(ProviderKind.init(rawValue:)),
              let connectionID = stored.connectionID,
              let model = stored.model else {
            return .system
        }
        return .cloud(VoiceCloudEngine(
            providerKind: providerKind,
            connectionID: connectionID,
            model: model,
            voice: direction == .stt ? nil : stored.voice
        ))
    }

    func setSelection(_ selection: VoiceEngineSelection, for direction: VoiceDirection) {
        let stored: StoredSelection
        switch selection {
        case .system:
            stored = StoredSelection(kind: "system", providerKind: nil, connectionID: nil, model: nil, voice: nil)
        case .cloud(let engine):
            stored = StoredSelection(
                kind: "cloud",
                providerKind: engine.providerKind.rawValue,
                connectionID: engine.connectionID,
                model: engine.model,
                voice: direction == .stt ? nil : engine.voice
            )
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.selectionKey(direction))
    }

    /// Resolves the effective engine from the stored selection; when resolution asks for a rewrite (persist = system) the stored selection becomes the system engine.
    /// site is where the fallback was discovered (settings page / point of use); the other site gets a pending notice once.
    @discardableResult
    func resolve(
        direction: VoiceDirection,
        catalog: VoiceCatalog,
        connections: [VoiceConnection],
        site: VoiceNoticeSite
    ) -> VoiceEngineResolution {
        let resolution = VoiceEngineResolver.resolve(
            direction: direction,
            selection: selection(for: direction),
            catalog: catalog,
            connections: connections
        )
        apply(resolution, for: direction, site: site)
        return resolution
    }

    /// On fallback, rewrites to system and leaves a one-time pending notice for the other site (the discovering site shows its own notice on the spot).
    func apply(_ resolution: VoiceEngineResolution, for direction: VoiceDirection, site: VoiceNoticeSite) {
        if resolution.persist == .system {
            setSelection(.system, for: direction)
        }
        if resolution.notice, case .system(let reason?) = resolution {
            defaults.set(reason.rawValue, forKey: Self.pendingNoticeKey(site.other, direction))
        }
    }

    /// Takes the pending notice for this site and direction; it is cleared once read.
    func takePendingNotice(site: VoiceNoticeSite, direction: VoiceDirection) -> VoiceFallbackReason? {
        let key = Self.pendingNoticeKey(site, direction)
        guard let raw = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return VoiceFallbackReason(rawValue: raw)
    }

    /// Clears the pending notices of both sites (settings page / point of use) for a direction. Call it when the user writes a selection themselves:
    /// the fallback notice of the old selection is stale. The fallback rewrite (apply) itself does not clear them.
    func clearPendingNotices(direction: VoiceDirection) {
        for site in [VoiceNoticeSite.settings, .use] {
            defaults.removeObject(forKey: Self.pendingNoticeKey(site, direction))
        }
    }

    /// Cloud voice disclosure consent on the same defaults; the point of use catches "the selection is cloud but the disclosure was never accepted" (restored backup / old data).
    var disclosures: VoiceDisclosureStore {
        VoiceDisclosureStore(defaults: defaults)
    }

    // MARK: - Recognition language and speed

    /// Dictation recognition language (BCP-47); nil means automatic.
    var recognitionLanguage: String? {
        get {
            guard let value = defaults.string(forKey: Key.recognitionLanguage), !value.isEmpty else { return nil }
            return value
        }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.recognitionLanguage)
            } else {
                defaults.removeObject(forKey: Key.recognitionLanguage)
            }
        }
    }

    /// Read-aloud speed multiplier; 1.0 if never stored or not a positive finite number.
    var speechRate: Double {
        get {
            guard let value = defaults.object(forKey: Key.speechRate) as? NSNumber else { return Self.defaultSpeechRate }
            let rate = value.doubleValue
            return rate.isFinite && rate > 0 ? rate : Self.defaultSpeechRate
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.speechRate)
        }
    }

    private static func pendingNoticeKey(_ site: VoiceNoticeSite, _ direction: VoiceDirection) -> String {
        "\(Key.pendingNoticePrefix).\(site.rawValue).\(direction.rawValue)"
    }

    private static func selectionKey(_ direction: VoiceDirection) -> String {
        switch direction {
        case .stt: return Key.sttSelection
        case .tts: return Key.ttsSelection
        case .realtime: return Key.realtimeSelection
        }
    }
}

/// The two places a fallback notice is shown: the engine row in settings, and the next use (recording / read-aloud).
nonisolated enum VoiceNoticeSite: String, Sendable, Hashable {
    case settings
    case use

    var other: VoiceNoticeSite {
        self == .settings ? .use : .settings
    }
}
