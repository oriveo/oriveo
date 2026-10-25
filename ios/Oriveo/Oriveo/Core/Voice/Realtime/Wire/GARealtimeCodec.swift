import Foundation
import OriveoProviderKit

/// OpenAI / xAI GA realtime wire codec (pure functions), per the shared realtime event fixtures.
/// No networking, no audio.
nonisolated struct GARealtimeCodec: Sendable {
    static let outputSampleRateHz = 24_000
    static let inputSampleRateHz = 24_000
    /// xAI error types that end the session instead of reporting a non-fatal error.
    static let sessionEndErrorTypes: Set<String> = ["max_duration", "timeout"]

    /// Per-connection mapping state; transcripts are cumulative per item.
    struct State: Sendable, Equatable {
        var userText = ""
        var userItem: String?
        var assistantText = ""
        var assistantItem: String?
        var userFinal = false

        mutating func resetTurn() {
            self = State()
        }
    }

    /// Opening messages: GA transports may send everything right after connecting.
    struct OpeningMessages {
        let beforeReady: [[String: Any]]
        let afterReady: [[String: Any]]
    }

    let transport: RealtimeTransportKind

    /// Only openai_realtime / xai_realtime; gemini_live has its own wire.
    init?(transport: RealtimeTransportKind) {
        guard transport != .geminiLive else { return nil }
        self.transport = transport
    }

    // MARK: - Server events

    /// One server message to zero or more unified events; ignored types yield [].
    func map(_ message: [String: Any], state st: inout State) -> [RealtimeSessionEvent] {
        let itemId = message["item_id"] as? String
        switch message["type"] as? String {
        case "session.created":
            return [.ready]
        case "input_audio_buffer.speech_started":
            return [.userSpeechStarted(itemId: itemId)]
        case "input_audio_buffer.speech_stopped":
            return [.userSpeechStopped(itemId: itemId)]
        case "conversation.item.input_audio_transcription.delta":
            guard transport == .openaiRealtime else { return [] }
            if st.userItem != itemId {
                st.userItem = itemId
                st.userText = ""
                st.userFinal = false
            }
            st.userText += message["delta"] as? String ?? ""
            return [.userTranscript(itemId: itemId, text: st.userText, final: false)]
        case "conversation.item.input_audio_transcription.updated":
            guard transport == .xaiRealtime else { return [] }
            st.userItem = itemId
            st.userText = message["transcript"] as? String ?? ""
            st.userFinal = false
            return [.userTranscript(itemId: itemId, text: st.userText, final: false)]
        case "conversation.item.input_audio_transcription.completed":
            st.userItem = itemId
            st.userText = message["transcript"] as? String ?? ""
            st.userFinal = true
            return st.userText.isEmpty ? [] : [.userTranscript(itemId: itemId, text: st.userText, final: true)]
        case "response.output_audio.delta":
            st.assistantItem = itemId
            let contentIndex = (message["content_index"] as? NSNumber)?.intValue ?? 0
            return [.assistantAudio(
                itemId: itemId,
                contentIndex: contentIndex,
                base64: message["delta"] as? String ?? "",
                sampleRateHz: Self.outputSampleRateHz
            )]
        case "response.output_audio_transcript.delta":
            if st.assistantItem != itemId {
                st.assistantItem = itemId
                st.assistantText = ""
            }
            st.assistantText += message["delta"] as? String ?? ""
            return [.assistantTranscript(itemId: itemId, text: st.assistantText, final: false)]
        case "response.output_audio_transcript.done":
            st.assistantItem = itemId
            if let transcript = message["transcript"] as? String { st.assistantText = transcript }
            return [.assistantTranscript(itemId: itemId, text: st.assistantText, final: true)]
        case "response.done":
            let raw = (message["response"] as? [String: Any])?["status"] as? String
            let status: RealtimeTurnStatus = switch raw {
            case "completed": .completed
            case "cancelled": .interrupted
            case "incomplete": .incomplete
            default: .failed
            }
            let event = RealtimeSessionEvent.assistantTurnDone(itemId: st.assistantItem, status: status, text: st.assistantText)
            st.resetTurn()
            return [event]
        case "error":
            let error = message["error"] as? [String: Any] ?? [:]
            let type = error["type"] as? String
            if transport == .xaiRealtime, let type, Self.sessionEndErrorTypes.contains(type) {
                return [.sessionEnded(reason: type)]
            }
            let code = error["code"] as? String ?? type ?? "unknown"
            return [.error(code: code, message: error["message"] as? String ?? "")]
        default:
            return []
        }
    }

    // MARK: - Client messages

    /// session.update followed by one conversation.item.create per history turn.
    func openingMessages(
        instructions: String,
        history: [RealtimeTransportInput.Turn],
        voice: String,
        inputTranscriptionModel: String?
    ) -> OpeningMessages {
        let pcm: [String: Any] = ["type": "audio/pcm", "rate": Self.inputSampleRateHz]
        let outputFormat: [String: Any] = ["type": "audio/pcm", "rate": Self.outputSampleRateHz]
        var input: [String: Any] = ["format": pcm]
        if let model = inputTranscriptionModel, !model.isEmpty {
            input["transcription"] = ["model": model]
        }
        let session: [String: Any]
        if transport == .openaiRealtime {
            input["turn_detection"] = ["type": "semantic_vad"]
            session = [
                "type": "realtime",
                "instructions": instructions,
                "output_modalities": ["audio"],
                "audio": [
                    "input": input,
                    "output": ["format": outputFormat, "voice": voice] as [String: Any],
                ] as [String: Any],
            ]
        } else {
            session = [
                "instructions": instructions,
                "voice": voice,
                "turn_detection": ["type": "server_vad"],
                "audio": ["input": input, "output": ["format": outputFormat]] as [String: Any],
            ]
        }
        let assistantPart = transport == .openaiRealtime ? "output_text" : "text"
        let items: [[String: Any]] = history.map { turn in
            [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": turn.role.rawValue,
                    "content": [[
                        "type": turn.role == .assistant ? assistantPart : "input_text",
                        "text": turn.text,
                    ]],
                ] as [String: Any],
            ]
        }
        return OpeningMessages(beforeReady: [["type": "session.update", "session": session]] + items, afterReady: [])
    }

    func openingMessages(input: RealtimeTransportInput, voice: String, inputTranscriptionModel: String?) -> OpeningMessages {
        openingMessages(
            instructions: input.instructions,
            history: input.history,
            voice: voice,
            inputTranscriptionModel: inputTranscriptionModel
        )
    }

    /// wss://{host}{path}?model=… (no auth); model is percent-encoded except RFC 3986 unreserved.
    func connectURL(host: String, path: String, model: String) -> String {
        "wss://\(host)\(path)?model=\(Self.percentEncodeUnreserved(model))"
    }

    func append(base64: String) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": base64]
    }

    /// Barge-in truncate; gemini_live never sends one (server already truncated), nor without an item id.
    /// playedMs is floored and clamped at 0.
    static func truncate(
        transport: RealtimeTransportKind,
        itemId: String?,
        contentIndex: Int = 0,
        playedMs: Double
    ) -> [String: Any]? {
        guard transport != .geminiLive, let itemId, !itemId.isEmpty else { return nil }
        return [
            "type": "conversation.item.truncate",
            "item_id": itemId,
            "content_index": contentIndex,
            "audio_end_ms": Int(max(0, playedMs.rounded(.down))),
        ]
    }

    static func percentEncodeUnreserved(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
