import Foundation

/// ```swift
/// let pricing = await MetadataClient.shared.resolveCatalogModel(...)
/// let breakdown = UsageBreakdown(promptTokens: 1500, cachedInputTokens: 500, completionTokens: 200)
/// let (cost, source) = CostCalculator.calcCost(breakdown: breakdown, pricing: pricing)
/// ```
nonisolated enum CostCalculator {
    nonisolated static let cachedReadFallbackRatio: Double = 0.5
    nonisolated static let cacheWrite5mFallbackRatio: Double = 1.25
    nonisolated static let cacheWrite1hFallbackRatio: Double = 2.0

    /// Local price estimate: prompt × input + cached × cached-read
    ///   + cache5m × write5m + cache1h × write1h + completion × output
    ///
    /// An upstream-reported cost always wins; this only runs when the response carried none.
    nonisolated static func calcCost(
        breakdown: UsageBreakdown,
        pricing: MetadataClient.ResolvedModelMetadata?
    ) -> (cost: Double, source: CostSource) {
        if let upstream = breakdown.upstreamCost {
            return (upstream, .upstream)
        }

        guard let pricing else {
            return (0, .unknown)
        }
        if pricing.pricingStatus == "free" || pricing.pricingStatus == "unknown" {
            return (0, .unknown)
        }
        if pricing.pricingUnit != "per_token" {
            return (pricing.costPerUnit ?? 0, .localEstimate)
        }

        guard let inputPerToken = pricing.promptPerToken,
              let outputPerToken = pricing.completionPerToken else {
            return (0, .unknown)
        }

        let cachedReadPerToken = pricing.cacheReadInputPerMToken.map { $0 / 1_000_000 }
            ?? inputPerToken * Self.cachedReadFallbackRatio
        let cache5mPerToken = pricing.cacheWrite5mPerMToken.map { $0 / 1_000_000 }
            ?? pricing.cacheCreationInputPerMToken.map { $0 / 1_000_000 }
            ?? inputPerToken * Self.cacheWrite5mFallbackRatio
        let cache1hPerToken = pricing.cacheWrite1hPerMToken.map { $0 / 1_000_000 }
            ?? inputPerToken * Self.cacheWrite1hFallbackRatio

        let cost = Double(breakdown.promptTokens) * inputPerToken
            + Double(breakdown.cachedInputTokens) * cachedReadPerToken
            + Double(breakdown.cacheCreation5mTokens) * cache5mPerToken
            + Double(breakdown.cacheCreation1hTokens) * cache1hPerToken
            + Double(breakdown.completionTokens) * outputPerToken

        return (cost, .localEstimate)
    }

    nonisolated static func calcCost(
        breakdown: UsageBreakdown,
        promptPerToken: Double,
        completionPerToken: Double
    ) -> Double {
        if let upstream = breakdown.upstreamCost {
            return upstream
        }
        let normalInput = Double(breakdown.promptTokens) * promptPerToken
        let cacheRead = Double(breakdown.cachedInputTokens)
            * promptPerToken * Self.cachedReadFallbackRatio
        let cacheWrite5m = Double(breakdown.cacheCreation5mTokens)
            * promptPerToken * Self.cacheWrite5mFallbackRatio
        let cacheWrite1h = Double(breakdown.cacheCreation1hTokens)
            * promptPerToken * Self.cacheWrite1hFallbackRatio
        let output = Double(breakdown.completionTokens) * completionPerToken
        return normalInput + cacheRead + cacheWrite5m + cacheWrite1h + output
    }
}
