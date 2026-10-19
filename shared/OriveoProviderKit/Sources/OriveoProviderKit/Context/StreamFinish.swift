import Foundation

// Stream end information: the parser attaches it to the done event and hands it to `StopReasonResolver.resolve` when persisting.

/// How one stream ended.
public struct StreamFinish: Codable, Hashable, Sendable {
    public var family: StopFamily
    public var ended: StreamEnding
    /// The raw termination text seen (finish_reason etc.); still carried when the stream is cut off without a termination marker.
    public var finishRaw: String?

    public init(family: StopFamily, ended: StreamEnding, finishRaw: String? = nil) {
        self.family = family
        self.ended = ended
        self.finishRaw = finishRaw
    }
}

/// Records termination signals while reading the stream; call `finish()` when done reading.
///
/// Clean criterion: openai_chat sees `[DONE]` or a non-empty finish_reason; other OpenAI-compatible families recognize only `[DONE]` (finish_reason is recorded as raw text only).
/// Responses / Anthropic / Gemini go through `observeFrame`.
public struct StreamFinishTracker: Sendable {
    public let family: StopFamily
    public private(set) var sawMarker = false
    public private(set) var finishRaw: String?

    public init(family: StopFamily) {
        self.family = family
    }

    /// The protocol's explicit termination marker `[DONE]`.
    public mutating func markDoneMarker() {
        sawMarker = true
    }

    /// Records one finish_reason; nil / empty string is ignored.
    public mutating func observeFinishReason(_ reason: String?) {
        guard let reason, !reason.isEmpty else { return }
        finishRaw = reason
        if family == .openaiChat { sawMarker = true }
    }

    /// Observes one SSE line: a `[DONE]` in a `data:` line records the termination marker, and a JSON payload is read for `choices[*].finish_reason`.
    /// Non-data lines and payloads that are not JSON objects are ignored.
    public mutating func observeSSELine(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        observePayload(payload)
    }

    /// Observes one frame's payload with the `data:` prefix already stripped.
    public mutating func observePayload(_ payload: String) {
        if payload == "[DONE]" {
            markDoneMarker()
            return
        }
        // The vast majority of frames carry no finish_reason, so do a cheap substring check first to avoid decoding JSON again for every frame.
        guard payload.contains("finish_reason"),
              let data = payload.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]]
        else { return }
        for choice in choices {
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                observeFinishReason(reason)
                return
            }
        }
    }

    /// Observes one JSON payload frame of Responses / Anthropic / Gemini (with the `data:` prefix already stripped).
    /// `eventType` is the event name from the SSE `event:` header; when the payload carries its own `type`, the payload wins.
    /// - openai_responses: `response.completed` / `response.incomplete` / `response.failed` record termination,
    ///   and finishRaw uses `responsesFinishRaw(status, incomplete_details.reason)`;
    /// - anthropic: `message_delta.delta.stop_reason` records finishRaw, and `message_stop` records termination;
    /// - gemini: any candidate's non-empty `finishReason` records finishRaw and termination; when there is no candidate finishReason,
    ///   no top-level error, and `promptFeedback.blockReason` is non-empty, "blockReason:" + the value is recorded together with termination;
    /// - gemini_interactions: the terminal status in the `interaction.completed` frame records finishRaw and termination
    ///   (non-terminal states such as in_progress / queued do not count);
    /// - llama_cpp: the last frame with `stop: true` records termination, and finishRaw takes stop_type (older servers are mapped from stopped_*).
    /// Other families are not handled here (openai_chat and the other OpenAI-compatible families use `observePayload`).
    public mutating func observeFrame(_ data: Data, eventType: String? = nil) {
        switch family {
        case .openaiResponses:
            let hinted = eventType.map(Self.responsesTerminalTypes.contains) ?? false
            guard hinted || Self.containsAny(data, Self.responsesTerminalTypes),
                  let root = Self.jsonObject(data) else { return }
            let type = (root["type"] as? String) ?? eventType ?? ""
            guard Self.responsesTerminalTypes.contains(type) else { return }
            let response = root["response"] as? [String: Any]
            let status = (response?["status"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(type.dropFirst("response.".count))
            let reason = ((response?["incomplete_details"] as? [String: Any])?["reason"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            sawMarker = true
            finishRaw = StopReasonResolver.responsesFinishRaw(status: status, incompleteReason: reason)
        case .anthropic:
            guard Self.containsAny(data, ["stop_reason", "message_stop"]),
                  let root = Self.jsonObject(data) else { return }
            switch (root["type"] as? String) ?? eventType {
            case "message_delta":
                if let reason = (root["delta"] as? [String: Any])?["stop_reason"] as? String, !reason.isEmpty {
                    finishRaw = reason
                }
            case "message_stop":
                sawMarker = true
            default:
                break
            }
        case .gemini:
            guard Self.containsAny(data, ["finishReason", "blockReason"]),
                  let root = Self.jsonObject(data) else { return }
            for candidate in (root["candidates"] as? [[String: Any]]) ?? [] {
                if let reason = candidate["finishReason"] as? String, !reason.isEmpty {
                    finishRaw = reason
                    sawMarker = true
                    return
                }
            }
            // The prompt was rejected as a whole: there is no candidate termination reason, and a top-level error takes precedence (that is an error frame, not a block).
            guard (root["error"] as? [String: Any]) == nil,
                  let blockReason = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String,
                  !blockReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            finishRaw = StopReasonResolver.geminiBlockReasonFinishRaw(
                blockReason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            sawMarker = true
        case .geminiInteractions:
            guard Self.containsAny(data, ["interaction.completed"]),
                  let root = Self.jsonObject(data),
                  root["event_type"] as? String == "interaction.completed",
                  let status = (root["interaction"] as? [String: Any])?["status"] as? String,
                  Self.interactionsTerminalStatuses.contains(status) else { return }
            finishRaw = status
            sawMarker = true
        case .llamaCpp:
            guard Self.containsAny(data, ["\"stop\""]),
                  let root = Self.jsonObject(data),
                  root["stop"] as? Bool == true else { return }
            finishRaw = StopReasonResolver.llamaCppFinishRaw(
                stopType: root["stop_type"] as? String,
                stoppedEos: root["stopped_eos"] as? Bool == true,
                stoppedWord: root["stopped_word"] as? Bool == true,
                stoppedLimit: root["stopped_limit"] as? Bool == true
            )
            sawMarker = true
        case .openaiChat, .managed, .free:
            break
        }
    }

    private static let responsesTerminalTypes = ["response.completed", "response.incomplete", "response.failed"]
    private static let interactionsTerminalStatuses: Set<String> = [
        "completed", "incomplete", "requires_action", "failed", "cancelled",
    ]

    /// The vast majority of frames are not termination frames: do a cheap byte-substring check first to avoid decoding JSON again for every frame.
    private static func containsAny(_ data: Data, _ needles: [String]) -> Bool {
        needles.contains { data.range(of: Data($0.utf8)) != nil }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func finish() -> StreamFinish {
        StreamFinish(family: family, ended: sawMarker ? .clean : .eofWithoutMarker, finishRaw: finishRaw)
    }
}
