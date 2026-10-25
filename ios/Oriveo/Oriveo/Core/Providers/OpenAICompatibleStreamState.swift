import Foundation
import OriveoProviderKit

struct OpenAICompatibleStreamState {
    private(set) var accumulatedText = ""
    private(set) var accumulatedReasoning = ""
    private(set) var usage: ProviderTokenUsage?
    private(set) var toolCalls: [ProviderToolCall] = []
    /// The finish_reason handed out when the assembler wraps up (`.finished` only arrives when terminal evidence holds, see `finish(requireTerminalEvidence:)`).
    private(set) var finishReason: String?

    mutating func consume(_ providerEvents: [ProviderStreamEvent]) -> [StreamEvent] {
        var events: [StreamEvent] = []
        var batchedToolCalls: [ProviderToolCall] = []
        for event in providerEvents {
            switch event {
            case .textDelta(let text):
                accumulatedText += text
                events.append(.delta(text))
            case .reasoningDelta(let reasoning):
                accumulatedReasoning += reasoning
                events.append(.reasoning(reasoning))
            case .toolCall(let call):
                toolCalls.append(call)
                batchedToolCalls.append(call)
            case .usage(let usage):
                self.usage = usage
            case .opaqueContinuation:
                break
            case .citations:
                break
            case .finished(let reason):
                finishReason = reason
            }
        }
        if !batchedToolCalls.isEmpty {
            events.append(.toolCallDeltas(batchedToolCalls))
        }
        return events
    }

    /// Stream finish info (openai_chat family): the stream is clean once the assembler has seen `[DONE]` or a non-empty finish_reason.
    func streamFinish(sawDoneMarker: Bool) -> StreamFinish {
        var tracker = StreamFinishTracker(family: .openaiChat)
        if sawDoneMarker { tracker.markDoneMarker() }
        tracker.observeFinishReason(finishReason)
        return tracker.finish()
    }

    var usageBreakdown: UsageBreakdown {
        Self.usageBreakdown(from: usage)
    }

    /// Warning: `cacheWriteObserved` is always false on this path, and that is an honest result, not an omission:
    /// the ProviderKit wire mirror `OpenAICompatibleChunk.Usage` has no field that carries cache writes at all,
    /// and `ProviderTokenUsage` has no matching property either - the providers that come through here (DeepSeek / Moonshot / MiniMax / Groq...)
    /// have no cache-write observation surface on OpenAI-compatible usage. The observed bit means "the upstream explicitly gave this item", so setting it true
    /// when no parse surface exists would render "could not be measured" as "0 written this time", which is exactly the disguise the contract forbids.
    /// When ProviderKit really parses a cache-write number in the future, add it here together, and do not turn on the observed bit alone.
    nonisolated static func usageBreakdown(from usage: ProviderTokenUsage?) -> UsageBreakdown {
        guard let usage else { return UsageBreakdown() }
        let totalInput = max(0, usage.inputTokens)
        let cachedInput = max(0, usage.cachedInputTokens ?? 0)
        return UsageBreakdown(
            promptTokens: Int(clamping: max(0, totalInput - cachedInput)),
            cachedInputTokens: Int(clamping: min(totalInput, cachedInput)),
            completionTokens: Int(clamping: max(0, usage.outputTokens)),
            reasoningTokens: Int(clamping: max(0, usage.reasoningOutputTokens ?? 0)),
            upstreamCost: nil,
            cacheReadObserved: usage.cachedInputTokens != nil
        )
    }
}

extension OpenAICompatibleStreamState {
    /// Tool legs reuse the same parsing as ordinary chat: the usage object of a leg frame is handed to the same ProviderKit assembler
    /// (which finds the cache field positions by the provider profile) and then goes through `usageBreakdown(from:)`; nil when no usage can be parsed.
    nonisolated static func legUsageBreakdown(usageJSON: [String: Any], profile: ProviderWireProfile) -> UsageBreakdown? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["choices": [Any](), "usage": usageJSON]) else { return nil }
        var assembler = OpenAICompatibleStreamAssembler(profile: profile, decodesFunctionNames: false)
        _ = try? assembler.ingest("data: " + String(decoding: data, as: UTF8.self))
        let events = (try? assembler.finish(requireTerminalEvidence: false)) ?? []
        for case let .usage(usage) in events {
            return usageBreakdown(from: usage)
        }
        return nil
    }
}

struct ProviderTokenUsageAccumulator {
    private var inputTokens: Int64 = 0
    private var outputTokens: Int64 = 0
    private var cachedInputTokens: Int64 = 0
    private var reasoningOutputTokens: Int64 = 0
    private var hasUsage = false
    private var hasCachedInputTokens = true
    private var hasReasoningOutputTokens = true

    mutating func add(_ usage: ProviderTokenUsage?) {
        guard let usage else { return }
        hasUsage = true
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        if let cached = usage.cachedInputTokens {
            cachedInputTokens += cached
        } else {
            hasCachedInputTokens = false
        }
        if let reasoning = usage.reasoningOutputTokens {
            reasoningOutputTokens += reasoning
        } else {
            hasReasoningOutputTokens = false
        }
    }

    var combined: ProviderTokenUsage? {
        guard hasUsage else { return nil }
        return ProviderTokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: hasCachedInputTokens ? cachedInputTokens : nil,
            reasoningOutputTokens: hasReasoningOutputTokens ? reasoningOutputTokens : nil
        )
    }
}
