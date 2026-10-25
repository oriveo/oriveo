import Foundation

/// Transport identifiers for realtime voice sessions; rawValue is the wire name.
nonisolated enum RealtimeTransportKind: String, CaseIterable, Sendable {
    case openaiRealtime = "openai_realtime"
    case xaiRealtime = "xai_realtime"
    case geminiLive = "gemini_live"
}

/// Terminal status of an assistant turn; rawValue is the wire name.
nonisolated enum RealtimeTurnStatus: String, CaseIterable, Sendable {
    case completed
    case interrupted
    case incomplete
    case failed
}

/// Unified realtime session event (closed set of 12), shared across transports.
/// JSON keys match the shared realtime event contract fixtures (mapCases.expected).
nonisolated enum RealtimeSessionEvent: Sendable, Equatable {
    case ready
    case userSpeechStarted(itemId: String?)
    case userSpeechStopped(itemId: String?)
    case userTranscript(itemId: String?, text: String, final: Bool)
    case assistantAudio(itemId: String?, contentIndex: Int, base64: String, sampleRateHz: Int)
    case assistantTranscript(itemId: String?, text: String, final: Bool)
    case interrupted
    case assistantTurnDone(itemId: String?, status: RealtimeTurnStatus, text: String)
    case goAway(timeLeftMs: Int?)
    case resumable(handle: String)
    case sessionEnded(reason: String)
    case error(code: String, message: String)

    /// Wire names of all event types, in contract order.
    static let typeNames: [String] = [
        "ready", "userSpeechStarted", "userSpeechStopped", "userTranscript", "assistantAudio",
        "assistantTranscript", "interrupted", "assistantTurnDone", "goAway", "resumable",
        "sessionEnded", "error",
    ]

    var typeName: String {
        switch self {
        case .ready: "ready"
        case .userSpeechStarted: "userSpeechStarted"
        case .userSpeechStopped: "userSpeechStopped"
        case .userTranscript: "userTranscript"
        case .assistantAudio: "assistantAudio"
        case .assistantTranscript: "assistantTranscript"
        case .interrupted: "interrupted"
        case .assistantTurnDone: "assistantTurnDone"
        case .goAway: "goAway"
        case .resumable: "resumable"
        case .sessionEnded: "sessionEnded"
        case .error: "error"
        }
    }

    /// Decodes a unified event dictionary; unknown type or missing keys yield nil.
    init?(json: [String: Any]) {
        func string(_ key: String) -> String? { json[key] as? String }
        // itemId is nullable (Gemini has no item ids) but the key is required; a non-string
        // value only fails events that carry itemId, so ready / goAway are unaffected.
        let itemId = json["itemId"] as? String
        let hasItemId = json["itemId"] is String || json["itemId"] is NSNull
        func int(_ key: String) -> Int? {
            // Integral floats (2.0) are accepted; 1.5, strings and Bool are rejected.
            guard let number = json[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            guard CFNumberIsFloatType(number) else { return number.intValue }
            return Int(exactly: number.doubleValue)
        }
        func bool(_ key: String) -> Bool? {
            guard let number = json[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        guard let type = string("type") else { return nil }
        switch type {
        case "ready":
            self = .ready
        case "userSpeechStarted":
            guard hasItemId else { return nil }
            self = .userSpeechStarted(itemId: itemId)
        case "userSpeechStopped":
            guard hasItemId else { return nil }
            self = .userSpeechStopped(itemId: itemId)
        case "userTranscript":
            guard hasItemId, let text = string("text"), let final = bool("final") else { return nil }
            self = .userTranscript(itemId: itemId, text: text, final: final)
        case "assistantAudio":
            guard hasItemId, let contentIndex = int("contentIndex"),
                  let base64 = string("base64"), let sampleRateHz = int("sampleRateHz") else { return nil }
            self = .assistantAudio(itemId: itemId, contentIndex: contentIndex, base64: base64, sampleRateHz: sampleRateHz)
        case "assistantTranscript":
            guard hasItemId, let text = string("text"), let final = bool("final") else { return nil }
            self = .assistantTranscript(itemId: itemId, text: text, final: final)
        case "interrupted":
            self = .interrupted
        case "assistantTurnDone":
            guard hasItemId, let text = string("text"),
                  let status = string("status").flatMap(RealtimeTurnStatus.init(rawValue:)) else { return nil }
            self = .assistantTurnDone(itemId: itemId, status: status, text: text)
        case "goAway":
            // timeLeftMs is nullable but the key is required.
            guard let raw = json["timeLeftMs"] else { return nil }
            if raw is NSNull {
                self = .goAway(timeLeftMs: nil)
            } else {
                guard let ms = int("timeLeftMs") else { return nil }
                self = .goAway(timeLeftMs: ms)
            }
        case "resumable":
            guard let handle = string("handle") else { return nil }
            self = .resumable(handle: handle)
        case "sessionEnded":
            guard let reason = string("reason") else { return nil }
            self = .sessionEnded(reason: reason)
        case "error":
            guard let code = string("code"), let message = string("message") else { return nil }
            self = .error(code: code, message: message)
        default:
            return nil
        }
    }

    /// Encodes to the unified event dictionary; null itemId / timeLeftMs keys are kept.
    var jsonObject: [String: Any] {
        var out: [String: Any] = ["type": typeName]
        switch self {
        case .ready, .interrupted:
            break
        case let .userSpeechStarted(itemId), let .userSpeechStopped(itemId):
            out["itemId"] = itemId.map { $0 as Any } ?? NSNull()
        case let .userTranscript(itemId, text, final), let .assistantTranscript(itemId, text, final):
            out["itemId"] = itemId.map { $0 as Any } ?? NSNull()
            out["text"] = text
            out["final"] = final
        case let .assistantAudio(itemId, contentIndex, base64, sampleRateHz):
            out["itemId"] = itemId.map { $0 as Any } ?? NSNull()
            out["contentIndex"] = contentIndex
            out["base64"] = base64
            out["sampleRateHz"] = sampleRateHz
        case let .assistantTurnDone(itemId, status, text):
            out["itemId"] = itemId.map { $0 as Any } ?? NSNull()
            out["status"] = status.rawValue
            out["text"] = text
        case let .goAway(timeLeftMs):
            out["timeLeftMs"] = timeLeftMs.map { $0 as Any } ?? NSNull()
        case let .resumable(handle):
            out["handle"] = handle
        case let .sessionEnded(reason):
            out["reason"] = reason
        case let .error(code, message):
            out["code"] = code
            out["message"] = message
        }
        return out
    }
}
