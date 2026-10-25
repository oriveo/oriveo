import Foundation

nonisolated struct UsageBreakdown: Codable, Equatable, Sendable {
    var promptTokens: Int
    var cachedInputTokens: Int
    var cacheCreation5mTokens: Int
    var cacheCreation1hTokens: Int
    var completionTokens: Int
    var reasoningTokens: Int
    var upstreamCost: Double?
    var cacheReadObserved: Bool
    var cacheWriteObserved: Bool

    nonisolated init(
        promptTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheCreation5mTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        completionTokens: Int = 0,
        reasoningTokens: Int = 0,
        upstreamCost: Double? = nil,
        cacheReadObserved: Bool = false,
        cacheWriteObserved: Bool = false
    ) {
        self.promptTokens = promptTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.upstreamCost = upstreamCost
        self.cacheReadObserved = cacheReadObserved
        self.cacheWriteObserved = cacheWriteObserved
    }

    nonisolated var totalInputTokens: Int {
        promptTokens + cachedInputTokens + cacheCreation5mTokens + cacheCreation1hTokens
    }
}

nonisolated enum CostSource: String, Codable, Sendable, Equatable {
    case upstream
    case localEstimate
    case unknown
    case subscription
}

/// The only non-USD part of a message's cost: the original currency amount, never converted.
/// `estimatedCost` always holds the USD part only; when a second non-USD currency shows up in one
/// message it is recorded as {first currency, 0, `.unknown`} (the amount is unusable).
nonisolated struct NonUsdCost: Codable, Sendable, Hashable {
    /// Upper-case ISO 4217.
    var currencyCode: String
    var amount: Double
    /// Describes the source of this part only.
    var costSource: CostSource
}
