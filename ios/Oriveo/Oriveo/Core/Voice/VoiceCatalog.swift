import Foundation

/// Voice direction: dictation (stt), read-aloud (tts) or conversation engine (realtime session).
nonisolated enum VoiceDirection: String, Sendable, Hashable, CaseIterable {
    case stt
    case tts
    case realtime
}

/// Upload protocol of a dictation entry; an entry with an unknown value is dropped whole at decode time.
nonisolated enum VoiceSTTTransport: String, Sendable, Hashable {
    case openAITranscriptions = "openai_transcriptions"
    case xaiSTT = "xai_stt"
    case geminiTranscribe = "gemini_transcribe"
    case dashscopeASR = "dashscope_asr"

    /// Whether the auth header uses x-goog-api-key (otherwise Bearer).
    var usesGoogAPIKey: Bool { self == .geminiTranscribe }
}

/// Synthesis protocol of a read-aloud entry; an entry with an unknown value is dropped whole at decode time.
nonisolated enum VoiceTTSTransport: String, Sendable, Hashable {
    case openAISpeech = "openai_speech"
    case xaiTTS = "xai_tts"
    case geminiTTS = "gemini_tts"
    case mistralSpeech = "mistral_speech"
    case dashscopeTTS = "dashscope_tts"

    /// Whether the auth header uses x-goog-api-key (otherwise Bearer).
    var usesGoogAPIKey: Bool { self == .geminiTTS }
}

/// Read-aloud speed range; kept only if 0 < min <= 1 <= max and both are finite.
nonisolated struct VoiceSpeedRange: Sendable, Hashable {
    let min: Double
    let max: Double
}

nonisolated struct VoiceCatalogVoice: Sendable, Hashable {
    let id: String
    let isDefault: Bool
}

/// Dictation entry. The catalog only lists entries that accept m4a, so there is no upload format field.
nonisolated struct VoiceSTTEntry: Sendable, Hashable {
    let model: String
    let transport: VoiceSTTTransport
    let path: String
    let maxBytes: Int
    let maxDurationSec: Int
    let languageField: String?
    let isDefault: Bool
}

/// Read-aloud entry; at least one voice.
nonisolated struct VoiceTTSEntry: Sendable, Hashable {
    let model: String
    let transport: VoiceTTSTransport
    let path: String
    let outputFormat: String
    let maxChars: Int
    let voices: [VoiceCatalogVoice]
    let speedRange: VoiceSpeedRange?
    let isDefault: Bool

    /// Fallback voice: the one marked isDefault, otherwise the first (decoding guarantees voices is non-empty).
    var defaultVoice: VoiceCatalogVoice? {
        voices.first(where: \.isDefault) ?? voices.first
    }
}

/// Conversation engine entry (rules.realtime); at least one voice.
/// openai_realtime / xai_realtime must carry inputTranscriptionModel (otherwise user turns have no transcript to store); gemini_live may omit it.
nonisolated struct VoiceRealtimeEntry: Sendable, Hashable {
    let model: String
    let transport: RealtimeTransportKind
    let path: String
    let contextWindow: Int
    let voices: [VoiceCatalogVoice]
    let maxSessionSec: Int?
    let inputTranscriptionModel: String?
    let isDefault: Bool

    /// Fallback voice: the one marked isDefault, otherwise the first (decoding guarantees voices is non-empty).
    var defaultVoice: VoiceCatalogVoice? {
        voices.first(where: \.isDefault) ?? voices.first
    }
}

nonisolated struct VoiceProviderEntries: Sendable, Hashable {
    var stt: [VoiceSTTEntry] = []
    var tts: [VoiceTTSEntry] = []
    var realtime: [VoiceRealtimeEntry] = []
}

/// Decoded result of the data of `GET /api/metadata?view=voice` (voice-catalog/v2).
/// providers only contains providerKinds that appear in the document and that the client recognizes; a missing provider / direction is treated as an empty array.
nonisolated struct VoiceCatalog: Sendable, Hashable {
    var schemaVersion: Int?
    var revision: String?
    var providers: [ProviderKind: VoiceProviderEntries]

    static let empty = VoiceCatalog(schemaVersion: nil, revision: nil, providers: [:])

    func sttEntries(_ kind: ProviderKind) -> [VoiceSTTEntry] {
        providers[kind]?.stt ?? []
    }

    func ttsEntries(_ kind: ProviderKind) -> [VoiceTTSEntry] {
        providers[kind]?.tts ?? []
    }

    func realtimeEntries(_ kind: ProviderKind) -> [VoiceRealtimeEntry] {
        providers[kind]?.realtime ?? []
    }

    /// (model, isDefault) pairs for a direction, in catalog order.
    func models(_ kind: ProviderKind, direction: VoiceDirection) -> [(model: String, isDefault: Bool)] {
        switch direction {
        case .stt: return sttEntries(kind).map { ($0.model, $0.isDefault) }
        case .tts: return ttsEntries(kind).map { ($0.model, $0.isDefault) }
        case .realtime: return realtimeEntries(kind).map { ($0.model, $0.isDefault) }
        }
    }
}

/// Lenient decoding: unknown keys are ignored, a bad entry is dropped on its own, and a structural anomaly does not fail the whole document.
/// See rules.decode in shared/voice-contracts/engine-resolution.v2.json.
nonisolated enum VoiceCatalogDecoder {

    /// Decodes from JSON bytes; returns nil if it is not valid JSON.
    static func decode(jsonData: Data) -> VoiceCatalog? {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed]) else {
            return nil
        }
        return decode(object)
    }

    /// Decodes from an already parsed data object (JSONSerialization output).
    static func decode(_ object: Any?) -> VoiceCatalog {
        guard let document = object as? [String: Any] else { return .empty }
        var providers: [ProviderKind: VoiceProviderEntries] = [:]
        if let rawProviders = document["providers"] as? [String: Any] {
            for (key, rawProvider) in rawProviders {
                guard let kind = ProviderKind(rawValue: key) else { continue }
                providers[kind] = decodeProvider(rawProvider)
            }
        }
        return VoiceCatalog(
            schemaVersion: positiveInteger(document["schemaVersion"]),
            revision: document["revision"] as? String,
            providers: providers
        )
    }

    // MARK: - Structure

    private static func decodeProvider(_ raw: Any?) -> VoiceProviderEntries {
        guard let provider = raw as? [String: Any] else { return VoiceProviderEntries() }
        let stt = (provider["stt"] as? [Any] ?? []).compactMap(decodeSTTEntry)
        let tts = (provider["tts"] as? [Any] ?? []).compactMap(decodeTTSEntry)
        let realtime = (provider["realtime"] as? [Any] ?? []).compactMap(decodeRealtimeEntry)
        return VoiceProviderEntries(stt: stt, tts: tts, realtime: realtime)
    }

    private static func decodeSTTEntry(_ raw: Any) -> VoiceSTTEntry? {
        guard let entry = raw as? [String: Any],
              let transport = (entry["transport"] as? String).flatMap(VoiceSTTTransport.init(rawValue:)),
              let model = entry["model"] as? String,
              let path = entry["path"] as? String,
              let maxBytes = positiveInteger(entry["maxBytes"]),
              let maxDurationSec = positiveInteger(entry["maxDurationSec"]) else {
            return nil
        }
        return VoiceSTTEntry(
            model: model,
            transport: transport,
            path: path,
            maxBytes: maxBytes,
            maxDurationSec: maxDurationSec,
            languageField: entry["languageField"] as? String,
            isDefault: isTrue(entry["isDefault"])
        )
    }

    private static func decodeTTSEntry(_ raw: Any) -> VoiceTTSEntry? {
        guard let entry = raw as? [String: Any],
              let transport = (entry["transport"] as? String).flatMap(VoiceTTSTransport.init(rawValue:)),
              let model = entry["model"] as? String,
              let path = entry["path"] as? String,
              let outputFormat = entry["outputFormat"] as? String,
              let maxChars = positiveInteger(entry["maxChars"]),
              let rawVoices = entry["voices"] as? [Any] else {
            return nil
        }
        let voices = rawVoices.compactMap(decodeVoice)
        guard !voices.isEmpty else { return nil }
        return VoiceTTSEntry(
            model: model,
            transport: transport,
            path: path,
            outputFormat: outputFormat,
            maxChars: maxChars,
            voices: voices,
            speedRange: decodeSpeedRange(entry["speedRange"]),
            isDefault: isTrue(entry["isDefault"])
        )
    }

    private static func decodeRealtimeEntry(_ raw: Any) -> VoiceRealtimeEntry? {
        guard let entry = raw as? [String: Any],
              let transport = (entry["transport"] as? String).flatMap(RealtimeTransportKind.init(rawValue:)),
              let model = entry["model"] as? String,
              let path = entry["path"] as? String,
              let contextWindow = positiveInteger(entry["contextWindow"]),
              let rawVoices = entry["voices"] as? [Any] else {
            return nil
        }
        let voices = rawVoices.compactMap(decodeVoice)
        guard !voices.isEmpty else { return nil }
        let inputTranscriptionModel = entry["inputTranscriptionModel"] as? String
        // These two protocols do not transcribe user speech by default; without a transcription model the user turn cannot be stored, so the whole entry is dropped.
        if inputTranscriptionModel == nil, transport == .openaiRealtime || transport == .xaiRealtime {
            return nil
        }
        return VoiceRealtimeEntry(
            model: model,
            transport: transport,
            path: path,
            contextWindow: contextWindow,
            voices: voices,
            maxSessionSec: positiveInteger(entry["maxSessionSec"]),
            inputTranscriptionModel: inputTranscriptionModel,
            isDefault: isTrue(entry["isDefault"])
        )
    }

    private static func decodeVoice(_ raw: Any) -> VoiceCatalogVoice? {
        guard let voice = raw as? [String: Any], let id = voice["id"] as? String else { return nil }
        return VoiceCatalogVoice(id: id, isDefault: isTrue(voice["isDefault"]))
    }

    /// An invalid value counts as missing and the entry is kept (just without speed adjustment).
    private static func decodeSpeedRange(_ raw: Any?) -> VoiceSpeedRange? {
        guard let range = raw as? [String: Any],
              let min = finiteNumber(range["min"]),
              let max = finiteNumber(range["max"]),
              min > 0, min <= 1, max >= 1 else {
            return nil
        }
        return VoiceSpeedRange(min: min, max: max)
    }

    // MARK: - Scalars

    /// JSONSerialization also decodes true/false as NSNumber; they are told apart by the CFBoolean type.
    private static func number(_ raw: Any?) -> NSNumber? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    private static func isTrue(_ raw: Any?) -> Bool {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let value = number(raw)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    /// An integer >= 1; 2.5, 0, -1 and strings do not count.
    private static func positiveInteger(_ raw: Any?) -> Int? {
        guard let value = finiteNumber(raw), value >= 1, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }
}
