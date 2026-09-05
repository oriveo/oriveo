import Foundation

nonisolated struct UsageBreakdown: Equatable, Sendable {
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
