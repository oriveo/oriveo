import Foundation

/// ```swift
/// let pricing = await MetadataClient.shared.resolveCatalogModel(...)
/// let breakdown = UsageBreakdown(promptTokens: 1500, cachedInputTokens: 500, completionTokens: 200)
/// let (cost, source) = CostCalculator.calcCost(breakdown: breakdown, pricing: pricing, at: Date())
/// ```
nonisolated enum CostCalculator {
    nonisolated static let cachedReadFallbackRatio: Double = 0.5
    nonisolated static let cacheWrite5mFallbackRatio: Double = 1.25
    nonisolated static let cacheWrite1hFallbackRatio: Double = 2.0

    /// Computes the USD cost of an assistant message.
    ///
    /// See `estimate`; when the selected price is not in USD this returns (0, .unknown) - the non-USD
    /// part is not recorded here but recomputed by the delivery accounting for the connection's
    /// effective region and stored in `nonUsdCost`.
    nonisolated static func calcCost(
        breakdown: UsageBreakdown,
        pricing: MetadataClient.ResolvedModelMetadata?,
        at: Date
    ) -> (cost: Double, source: CostSource) {
        let result = estimate(breakdown: breakdown, pricing: pricing, at: at)
        guard result.currencyCode == usd else { return (0, .unknown) }
        return (result.amount, result.source)
    }

    /// Estimates the cost with the selected price; the amount is in that price's currency, never converted.
    ///
    /// - If `breakdown.upstreamCost != nil`, it is returned directly (USD) with source `.upstream`.
    /// - Otherwise the five buckets are summed: promptTokens x input + cachedInput x cachedRead
    ///   + cache5m x write5m + cache1h x write1h + completion x output.
    /// - If pricing is nil or its status is not priced, the price is unknown (amount 0, source `.unknown`).
    /// - If pricing carries a per_token pricingV2, `PricingV2Estimator` estimates it (`at` is the pricing moment).
    /// - Per-unit pricing (per_image / per_second) is costPerUnit x `units`.
    ///
    /// All PerMToken prices in metadata are "selected currency / 1M tokens"; this function divides by
    /// 1_000_000 to get per-token before multiplying by the token counts.
    nonisolated static func estimate(
        breakdown: UsageBreakdown,
        pricing: MetadataClient.ResolvedModelMetadata?,
        at: Date,
        units: Int = 1
    ) -> CostEstimate {
        // The upstream already priced it (all cache discounts included); upstream exact cost is always USD.
        if let upstream = breakdown.upstreamCost {
            return CostEstimate(amount: upstream, currencyCode: usd, source: .upstream)
        }
        guard let pricing else {
            return .unavailable(currencyCode: usd)
        }
        let currency = currencyCode(of: pricing)
        // Pricing v2: for per_token, price by length tier / time window. When it cannot be measured the
        // existing "price unknown" (.unknown) applies, and only "not applicable" falls back to the legacy path.
        // v2 is read only when the legacy pricingStatus is known (priced / free); status unknown means unknown price.
        let legacyStatusKnown = pricing.pricingStatus == "priced" || pricing.pricingStatus == "free"
        if legacyStatusKnown, let pricingV2 = pricing.pricingV2 {
            switch PricingV2Estimator.estimate(pricingV2, usage: PricingV2Usage(breakdown: breakdown), at: at) {
            case .estimated(let amount, let currencyCode):
                // A missing currency means the currency of the selected price (model level or region entry, USD when absent too).
                return CostEstimate(
                    amount: amount,
                    currencyCode: currencyCode.map(normalizedCurrency) ?? currency,
                    source: .localEstimate
                )
            case .unavailable:
                return .unavailable(currencyCode: currency)
            case .notApplicable:
                break
            }
        }
        // A missing pricingUnit (v2 gave no unit either) counts as per_token, not per-unit.
        let perUnit = (pricing.pricingV2?.unit ?? pricing.pricingUnit ?? "per_token") != "per_token"
        // A free per-unit entry is a real 0, not unknown.
        if perUnit, pricing.pricingStatus == "free" {
            return CostEstimate(amount: 0, currencyCode: currency, source: .localEstimate)
        }
        if pricing.pricingStatus == "free" || pricing.pricingStatus == "unknown" {
            return .unavailable(currencyCode: currency)
        }
        if perUnit {
            // Per-unit pricing: unit price (pricingV2.perUnit first) x unit count (images / seconds); 0 units is
            // unknown, with no minimum of one unit. A missing unit price is likewise unknown, not 0.
            guard units > 0, let unitPrice = pricing.pricingV2?.perUnit ?? pricing.costPerUnit else {
                return .unavailable(currencyCode: currency)
            }
            return CostEstimate(
                amount: unitPrice * Double(units),
                currencyCode: currency,
                source: .localEstimate
            )
        }

        guard let inputPerToken = pricing.promptPerToken,
              let outputPerToken = pricing.completionPerToken else {
            return .unavailable(currencyCode: currency)
        }

        // Cache prices on ResolvedModelMetadata are per-M tokens; divide by 1_000_000 here to get per-token.
        // Cache read price: new field > legacy cachedInputPerMToken > input x 0.5.
        let cachedReadPerToken = (pricing.cacheReadInputPerMToken ?? pricing.cachedInputPerMToken)
            .map { $0 / 1_000_000 }
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

        return CostEstimate(amount: cost, currencyCode: currency, source: .localEstimate)
    }

    nonisolated static let usd = "USD"

    /// Currency of the selected price: pricingV2's currency first, otherwise the currencyCode of the model level / region entry; upper case, USD by default.
    nonisolated static func currencyCode(of pricing: MetadataClient.ResolvedModelMetadata) -> String {
        normalizedCurrency(pricing.pricingV2?.currencyCode ?? pricing.currencyCode)
    }

    /// Currency normalization: trim + upper case; empty is USD.
    nonisolated static func normalizedCurrency(_ code: String?) -> String {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return usd
        }
        return trimmed.uppercased()
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

/// One estimate: the amount is in `currencyCode` (upper-case ISO 4217), never converted; `source == .unknown` means the price is unknown (shown as "unavailable", not 0).
nonisolated struct CostEstimate: Sendable, Equatable {
    let amount: Double
    let currencyCode: String
    let source: CostSource

    var isUnavailable: Bool { source == .unknown }

    static func unavailable(currencyCode: String) -> CostEstimate {
        CostEstimate(amount: 0, currencyCode: currencyCode, source: .unknown)
    }
}
