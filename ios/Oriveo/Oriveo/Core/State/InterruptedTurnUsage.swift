import Foundation
import OriveoProviderKit

/// Usage of a reply stopped midway (BYOK / Relay / Free).
///
/// The stopped request is estimated like the skill marker interrupted leg: input = that request's input estimate,
/// output = estimateText(visible text) + estimateText(visible reasoning). Usage fragments the stopped request already
/// received are not used. Legs that finished before the stop keep their reported usage and add field by field.
/// Nothing visible means nothing is recorded.
enum InterruptedTurnUsage {
    /// A leg that finished before the stop, with the model / connection it was priced with.
    struct FinishedLeg {
        let delivery: ProposeMemoryDeferredDelivery
        let pricing: (model: AIModel, provider: Provider)?
    }

    struct Outcome {
        /// Token fields to add to the message; `inputTokens` stays nil when any counted leg has no input figure.
        let usage: ChatDeliveredUsageMetrics
        /// Whether the stopped request itself counts (it showed something); otherwise only finished legs count.
        let countsStoppedLeg: Bool
        /// The stopped request as a priced result; nil when it does not count or its input is unknown (its cost is
        /// then unknown).
        let stoppedLeg: ProviderChatResult?
    }

    /// nil = record nothing (no tokens, cost unknown, no usage report, no skill manifest tokens): nothing visible
    /// and no finished leg. Nothing visible with finished legs records only those legs.
    static func outcome(
        estimatedInput: Int?,
        rhoHi: Double,
        visibleText: String,
        reasoningText: String,
        finishedLegs: [ChatDeliveredUsageMetrics] = []
    ) -> Outcome? {
        let countsStoppedLeg = !visibleText.isEmpty || !reasoningText.isEmpty
        guard countsStoppedLeg || !finishedLegs.isEmpty else { return nil }
        let output = ContextBudget.estimateText(visibleText, rhoHi: rhoHi)
            + ContextBudget.estimateText(reasoningText, rhoHi: rhoHi)
        func sum(_ values: [Int?]) -> Int? {
            let present = values.compactMap { $0 }
            return present.isEmpty ? nil : present.reduce(0, +)
        }
        // Input is known only when every counted leg has one (the stopped leg without an estimate included);
        // output is still added.
        let inputs = finishedLegs.map(\.inputTokens) + (countsStoppedLeg ? [estimatedInput] : [])
        let input = inputs.contains { $0 == nil } ? nil : sum(inputs)
        let outputTotal = sum(finishedLegs.map(\.outputTokens) + (countsStoppedLeg ? [output] : []))
        let usage = ChatDeliveredUsageMetrics(
            promptTokens: input ?? 0,
            completionTokens: outputTotal ?? 0,
            inputTokens: input,
            outputTokens: outputTotal
        )
        let stoppedLeg = countsStoppedLeg ? estimatedInput.map {
            ProviderChatResult(
                text: visibleText,
                promptTokens: $0,
                completionTokens: output,
                estimatedCost: 0,
                usageReported: true,
                costSource: .localEstimate
            )
        } : nil
        return Outcome(usage: usage, countsStoppedLeg: countsStoppedLeg, stoppedLeg: stoppedLeg)
    }

    /// Cost of the stopped turn through the existing derivation: finished legs in order, then the stopped request
    /// priced from its estimate when it counts; a leg without a cost makes the whole turn unknown. nil = nothing to
    /// write.
    static func cost(
        _ outcome: Outcome,
        finishedLegs: [FinishedLeg],
        model: AIModel,
        provider: Provider,
        streamedAttachments: [Attachment] = [],
        at date: Date
    ) -> DeliveredCost? {
        var parts: [(cost: DeliveredCost?, pricing: (model: AIModel, provider: Provider), attachments: [Attachment])] =
            finishedLegs.map { ($0.delivery.estimatedCost, $0.pricing ?? (model, provider), $0.delivery.attachments ?? []) }
        if outcome.countsStoppedLeg {
            let stopped = outcome.stoppedLeg.map {
                ChatDeliveryAccounting.generationCost(
                    result: $0, model: model, provider: provider, streamedAttachments: streamedAttachments, at: date
                )
            }
            parts.append((stopped, (model, provider), streamedAttachments))
        }
        guard let first = parts.first else { return nil }
        var total = first.cost
        var produced = first.attachments
        for part in parts.dropFirst() {
            produced += part.attachments
            total = ChatDeliveryAccounting.combiningDeliveries(
                total, part.cost, model: part.pricing.model, provider: part.pricing.provider,
                producedAttachments: produced, at: date
            )
        }
        return total
    }

    /// The part this attempt added on top of the text it started from (continue / retry keeping old text). After the
    /// prefix only one leading blank-line leg separator is removed; nothing else is trimmed.
    static func addedText(_ text: String, baseline: String) -> String {
        guard !baseline.isEmpty, text.hasPrefix(baseline) else { return text }
        let added = text.dropFirst(baseline.count)
        return String(added.hasPrefix("\n\n") ? added.dropFirst(2) : added)
    }
}

extension ChatDeliveredUsageMetrics {
    /// Field-level init for the stopped-reply estimate, where input may be unknown while output is estimated.
    init(promptTokens: Int, completionTokens: Int, inputTokens: Int?, outputTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        cachedInputTokens = nil
        cacheCreationInputTokens = nil
    }
}
