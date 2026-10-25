import Foundation
import os

/// One opening-history entry (role is "user" / "assistant"); converted from RealtimeTransportInput by the transport layer.
nonisolated struct GeminiLiveHistoryTurn: Sendable, Equatable {
    let role: String
    let text: String
}

/// Pure functions for the gemini_live wire shapes, following the shared realtime event fixtures.
nonisolated enum GeminiLiveWire {
    static let inputMimeType = "audio/pcm;rate=16000"
    static let outputSampleRateHz = 24_000

    /// Session-opening messages: setup is sent right after connecting (beforeReady), clientContent waits for setupComplete (afterReady).
    struct OpeningMessages {
        let beforeReady: [[String: Any]]
        let afterReady: [[String: Any]]
    }

    /// Connection address without auth: wss://{host}{path}.
    static func connectURL(host: String, path: String) -> String {
        "wss://\(host)\(path)"
    }

    /// Authenticated address: connectURL + ?key=; every character of the key outside RFC 3986 unreserved is percent-encoded with uppercase hex.
    static func authenticatedURL(host: String, path: String, key: String) -> String {
        connectURL(host: host, path: path) + "?key=" + percentEncodeUnreserved(key)
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

    /// With a resumption handle: setup.sessionResumption carries the handle and no history is sent. Without a handle but with history: enable historyConfig and send one clientContent afterReady.
    static func openingMessages(
        instructions: String,
        history: [GeminiLiveHistoryTurn],
        model: String,
        voice: String,
        resumeHandle: String?
    ) -> OpeningMessages {
        let resuming = (resumeHandle?.isEmpty == false)
        let withHistory = !resuming && !history.isEmpty
        let empty: [String: Any] = [:]
        let prebuiltVoice: [String: Any] = ["voiceName": voice]
        let speechConfig: [String: Any] = ["voiceConfig": ["prebuiltVoiceConfig": prebuiltVoice] as [String: Any]]
        let generationConfig: [String: Any] = ["responseModalities": ["AUDIO"], "speechConfig": speechConfig]
        let instructionPart: [String: Any] = ["text": instructions]
        var resumption: [String: Any] = [:]
        if resuming, let resumeHandle { resumption["handle"] = resumeHandle }
        var setup: [String: Any] = [:]
        setup["model"] = "models/\(model)"
        setup["generationConfig"] = generationConfig
        setup["systemInstruction"] = ["parts": [instructionPart]] as [String: Any]
        setup["inputAudioTranscription"] = empty
        setup["outputAudioTranscription"] = empty
        setup["sessionResumption"] = resumption
        setup["contextWindowCompression"] = ["slidingWindow": empty] as [String: Any]
        if withHistory { setup["historyConfig"] = ["initialHistoryInClientContent": true] as [String: Any] }
        var after: [[String: Any]] = []
        if withHistory {
            let turns: [[String: Any]] = history.map { turn in
                let part: [String: Any] = ["text": turn.text]
                return ["role": turn.role == "assistant" ? "model" : "user", "parts": [part]]
            }
            let clientContent: [String: Any] = ["turns": turns, "turnComplete": true]
            after.append(["clientContent": clientContent])
        }
        return OpeningMessages(beforeReady: [["setup": setup]], afterReady: after)
    }

    /// Append a chunk of 16 kHz PCM16 microphone audio.
    static func audioAppendMessage(base64: String) -> [String: Any] {
        ["realtimeInput": ["audio": ["data": base64, "mimeType": inputMimeType]]]
    }

    /// protobuf Duration JSON ("1.5s" / "10s" / "0.250s") to milliseconds; nil when unrecognized.
    static func durationMs(_ value: Any?) -> Int? {
        guard let text = value as? String, text.hasSuffix("s") else { return nil }
        let body = text.dropLast()
        let pieces = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = pieces[0]
        guard !whole.isEmpty, whole.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var fraction = Substring("")
        if pieces.count == 2 {
            fraction = pieces[1]
            guard (1...9).contains(fraction.count), fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        }
        // Exact integer math: seconds * 1000 + the fraction rounded to milliseconds (half rounds up); overflow at any step yields nil
        guard let seconds = Int(whole) else { return nil }
        let nanosText = String(fraction) + String(repeating: "0", count: 9 - fraction.count)
        guard let nanos = Int(nanosText) else { return nil }
        let fractionMs = (nanos + 500_000) / 1_000_000
        let (wholeMs, mulOverflow) = seconds.multipliedReportingOverflow(by: 1000)
        guard !mulOverflow else { return nil }
        let (total, addOverflow) = wholeMs.addingReportingOverflow(fractionMs)
        return addOverflow ? nil : total
    }
}

/// Maps each Gemini server message to unified events; mirrors mapGemini in the shared event fixtures. One fresh mapper per connection.
nonisolated struct GeminiLiveEventMapper {
    private var userText = ""
    /// User transcript that arrived after the reply started (barge-in / speaker echo); belongs to the next turn.
    private var nextUserText = ""
    private var assistantText = ""
    /// The model has produced output this turn (audio or transcript); the user final is closed from here on.
    private var assistantStarted = false
    /// New speech was detected after the reply started (ACTIVITY_START).
    private var speechSinceReply = false
    private var userFinal = false
    private var interrupted = false
    /// Any transcript / audio / interrupted has arrived this turn and turnComplete has not yet.
    private(set) var midTurn = false

    init() {}

    mutating func map(_ message: [String: Any]) -> [RealtimeSessionEvent] {
        Self.logKinds(message)
        var out: [RealtimeSessionEvent] = []
        if message["setupComplete"] != nil { out.append(.ready) }
        let activity = (message["voiceActivity"] as? [String: Any])?["type"] as? String
        if activity == "ACTIVITY_START" {
            if assistantStarted { speechSinceReply = true }
            out.append(.userSpeechStarted(itemId: nil))
        }
        if activity == "ACTIVITY_END" { out.append(.userSpeechStopped(itemId: nil)) }
        if let content = message["serverContent"] as? [String: Any] {
            if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                midTurn = true
                if assistantStarted, userFinal || speechSinceReply {
                    // The user already closed this turn, or new speech was detected after the reply started (barge-in / speaker echo): this text belongs to the next turn
                    // No new speech since the reply started and the user has not closed this turn: a late transcript of this turn, still counted here (closed before the assistant at turnComplete)
                    nextUserText += text
                    out.append(.userTranscript(itemId: nil, text: nextUserText, final: false))
                } else {
                    userText += text
                    out.append(.userTranscript(itemId: nil, text: userText, final: false))
                }
            }
            // First model output of the turn (audio or transcript) means the user finished speaking: close the user final first so the user message is persisted before the assistant
            let parts = ((content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            let hasAudio = parts.contains { ((($0["inlineData"] as? [String: Any])?["data"] as? String) ?? "").isEmpty == false }
            let outputText = (content["outputTranscription"] as? [String: Any])?["text"] as? String
            if (hasAudio || !(outputText ?? "").isEmpty), !assistantStarted {
                appendUserFinal(&out)
                assistantStarted = true
            }
            for part in parts {
                if let data = (part["inlineData"] as? [String: Any])?["data"] as? String, !data.isEmpty {
                    midTurn = true
                    out.append(.assistantAudio(
                        itemId: nil, contentIndex: 0, base64: data, sampleRateHz: GeminiLiveWire.outputSampleRateHz
                    ))
                }
            }
            if let text = outputText, !text.isEmpty {
                assistantText += text
                midTurn = true
                out.append(.assistantTranscript(itemId: nil, text: assistantText, final: false))
            }
            if Self.isTrue(content["interrupted"]) {
                interrupted = true
                midTurn = true
                out.append(.interrupted)
            }
            if Self.isTrue(content["turnComplete"]) {
                appendUserFinal(&out)
                if !assistantText.isEmpty {
                    out.append(.assistantTranscript(itemId: nil, text: assistantText, final: true))
                }
                out.append(.assistantTurnDone(
                    itemId: nil, status: interrupted ? .interrupted : .completed, text: assistantText
                ))
                userText = nextUserText
                nextUserText = ""
                assistantText = ""
                assistantStarted = false
                speechSinceReply = false
                userFinal = false
                interrupted = false
                midTurn = !userText.isEmpty
            }
        }
        if let goAway = message["goAway"] as? [String: Any] {
            out.append(.goAway(timeLeftMs: GeminiLiveWire.durationMs(goAway["timeLeft"])))
        }
        if let update = message["sessionResumptionUpdate"] as? [String: Any], Self.isTrue(update["resumable"]),
           let handle = update["newHandle"] as? String, !handle.isEmpty {
            out.append(.resumable(handle: handle))
        }
        return out
    }

    /// Call before switching connections: in order, finalize the unfinished user text of this turn and the user text carried into the next turn (each only when non-empty), then clear them; an unfinished assistant reply is not finalized.
    mutating func flushPendingUser() -> [RealtimeSessionEvent] {
        var out: [RealtimeSessionEvent] = []
        appendUserFinal(&out)
        if !nextUserText.isEmpty {
            out.append(.userTranscript(itemId: nil, text: nextUserText, final: true))
        }
        userText = ""
        nextUserText = ""
        userFinal = false
        return out
    }

    private mutating func appendUserFinal(_ out: inout [RealtimeSessionEvent]) {
        guard !userFinal, !userText.isEmpty else { return }
        userFinal = true
        out.append(.userTranscript(itemId: nil, text: userText, final: true))
    }

    /// Kind of the raw server message (top-level keys and serverContent sub-keys; modelTurn records only the audio part count and byte length), never the audio content.
    private static func logKinds(_ message: [String: Any]) {
        var kinds = message.keys.filter { $0 != "serverContent" }.sorted()
        if let content = message["serverContent"] as? [String: Any] {
            let inner = content.keys.sorted().map { key -> String in
                guard key == "modelTurn" else { return key }
                let parts = ((content[key] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
                let audio = parts.compactMap { ($0["inlineData"] as? [String: Any])?["data"] as? String }
                return "modelTurn(audio=\(audio.count) b64len=\(audio.reduce(0) { $0 + $1.count }))"
            }
            kinds.append("serverContent{\(inner.joined(separator: ","))}")
        }
        let summary = kinds.isEmpty ? "empty" : kinds.joined(separator: " ")
        RealtimeVoiceLog.logger.debug("gemini server \(summary, privacy: .public)")
    }

    /// JSON boolean true (=== true); the number 1 does not count as true.
    private static func isTrue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
        }
        return (value as? Bool) == true
    }
}
