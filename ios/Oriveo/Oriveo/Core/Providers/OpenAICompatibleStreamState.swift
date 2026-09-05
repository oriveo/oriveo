import Foundation
import OriveoProviderKit

struct OpenAICompatibleStreamState {
    private(set) var accumulatedText = ""
    private(set) var accumulatedReasoning = ""
    private(set) var usage: ProviderTokenUsage?
    private(set) var toolCalls: [ProviderToolCall] = []

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
            case .finished:
                break
            }
        }
        if !batchedToolCalls.isEmpty {
            events.append(.toolCallDeltas(batchedToolCalls))
        }
        return events
    }

    var usageBreakdown: UsageBreakdown {
        Self.usageBreakdown(from: usage)
    }

    static func usageBreakdown(from usage: ProviderTokenUsage?) -> UsageBreakdown {
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
