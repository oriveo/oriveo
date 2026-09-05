import Foundation

struct ChatDeliveredUsageMetrics: Sendable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let cacheCreationInputTokens: Int?

    init(promptTokens: Int, completionTokens: Int, recordsMessageUsage: Bool = true) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        inputTokens = recordsMessageUsage ? promptTokens : nil
        outputTokens = recordsMessageUsage ? completionTokens : nil
        cachedInputTokens = nil
        cacheCreationInputTokens = nil
    }

    init(result: ProviderChatResult) {
        promptTokens = result.promptTokens
        completionTokens = result.completionTokens
        if let usage = result.usageBreakdown {
            inputTokens = result.promptTokens
            outputTokens = result.completionTokens
            cachedInputTokens = usage.cacheReadObserved || usage.cachedInputTokens > 0
                ? usage.cachedInputTokens
                : nil
            let cacheCreation = usage.cacheCreation5mTokens + usage.cacheCreation1hTokens
            cacheCreationInputTokens = usage.cacheWriteObserved || cacheCreation > 0
                ? cacheCreation
                : nil
        } else if result.promptTokens > 0 || result.completionTokens > 0 {
            inputTokens = result.promptTokens
            outputTokens = result.completionTokens
            cachedInputTokens = nil
            cacheCreationInputTokens = nil
        } else {
            inputTokens = nil
            outputTokens = nil
            cachedInputTokens = nil
            cacheCreationInputTokens = nil
        }
    }
}

enum ChatDeliveryAccounting {
    static func deliveredCost(
        result: ProviderChatResult,
        model: AIModel,
        providerKind: ProviderKind
    ) -> Double {
        var finalCost = result.estimatedCost
        if finalCost == 0,
           let promptPrice = model.promptPrice,
           let completionPrice = model.completionPrice,
           promptPrice > 0 || completionPrice > 0 {
            if let breakdown = result.usageBreakdown {
                finalCost = CostCalculator.calcCost(
                    breakdown: breakdown,
                    promptPerToken: promptPrice,
                    completionPerToken: completionPrice
                )
            } else {
                finalCost = (promptPrice * Double(result.promptTokens))
                    + (completionPrice * Double(result.completionTokens))
            }
        }
        return finalCost
    }
}
