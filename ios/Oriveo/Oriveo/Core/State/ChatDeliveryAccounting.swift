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
    /// Cost of one delivery's generation: priced in the region effective for the connection and
    /// recorded in the original currency.
    ///
    /// Upstream-reported cost wins (not for Relay). A catalog hit selects a region (Relay does not),
    /// and the selected price entry is estimated from the token breakdown (per-unit pricing uses the
    /// unit count and does not depend on usage). An estimate that cannot be produced is unknown and
    /// never falls back to the local price. When the catalog has no entry, the local `AIModel` price
    /// (which has no currency) is used only if the selected currency is known to be USD; otherwise
    /// only the service amount is trusted. A Relay model matched to an official entry shares the
    /// official estimation path: no region selection, the matched entry's pricing, its currency,
    /// and non-USD amounts recorded in the original currency; unmatched models use the local price.
    ///
    /// An official connection whose catalog hit cannot be estimated is unknown (pricingV2 unavailable
    /// means the price is unknown). A missing usage report on per-token pricing is unknown, not 0.
    ///
    /// `streamedAttachments`: attachments received through image parts while streaming (the `.done`
    /// result of a streamed image does not carry them); counted together for per-unit pricing.
    /// `at`: pricing time (time windows select prices by it); production passes the delivery time.
    static func generationCost(
        result: ProviderChatResult,
        model: AIModel,
        provider: Provider,
        metadata: MetadataClient = .shared,
        streamedAttachments: [Attachment] = [],
        at: Date
    ) -> DeliveredCost {
        // One answer can span several upstream requests (Kimi's built-in `$web_search`):
        // price each leg and add them up.
        if let legUsage = result.legUsage, legUsage.perLeg.count > 1 {
            return multiLegCost(
                legUsage, model: model, provider: provider, metadata: metadata,
                producedAttachments: (result.attachments ?? []) + streamedAttachments, at: at
            ) { leg in
                DeliveredCost(parts: [generationPart(
                    result: leg, model: model, provider: provider, metadata: metadata,
                    streamedAttachments: streamedAttachments, at: at
                )])
            }
        }
        return DeliveredCost(parts: [generationPart(
            result: result, model: model, provider: provider, metadata: metadata,
            streamedAttachments: streamedAttachments, at: at
        )])
    }

    /// Combines a delivery's cost parts into the persisted shape.
    static func record(_ cost: DeliveredCost) -> MessageCostRecord {
        record(parts: cost.parts)
    }

    /// Combines the pricing parts of one message into the persisted shape: parts with an unknown
    /// price are skipped (they neither become 0 nor produce a non-USD part); USD parts add into
    /// `estimatedCost`, with `costSource` taken from the first USD part (`.unknown` when there is
    /// none); non-USD parts merge into `nonUsdCost` via `mergeNonUsdCost` without currency conversion.
    static func record(parts: [DeliveredCostPart]) -> MessageCostRecord {
        var usdAmount = 0.0
        var usdSeen = false
        var usdSource: CostSource?
        var nonUsdCost: NonUsdCost?
        for part in parts where !part.unknown && part.costSource != .unknown {
            if part.isUsd {
                usdAmount += part.amount
                if !usdSeen {
                    usdSeen = true
                    usdSource = part.costSource
                }
            } else {
                nonUsdCost = mergeNonUsdCost(
                    nonUsdCost,
                    NonUsdCost(
                        currencyCode: part.currencyCode,
                        amount: part.amount,
                        costSource: part.costSource ?? .localEstimate
                    )
                )
            }
        }
        return MessageCostRecord(
            estimatedCost: usdAmount,
            costSource: usdSeen ? usdSource : .unknown,
            nonUsdCost: nonUsdCost
        )
    }

    /// Merges two non-USD parts: a missing side yields the other; the same currency with both amounts
    /// known adds up (the source of the first wins); different currencies or an unknown amount on
    /// either side give {first currency, 0, `.unknown`}, with no addition and no conversion.
    static func mergeNonUsdCost(_ first: NonUsdCost?, _ second: NonUsdCost?) -> NonUsdCost? {
        guard let first else { return second }
        guard let second else { return first }
        if first.currencyCode != second.currencyCode || first.costSource == .unknown || second.costSource == .unknown {
            return NonUsdCost(currencyCode: first.currencyCode, amount: 0, costSource: .unknown)
        }
        var merged = first
        merged.amount += second.amount
        return merged
    }

    /// Persists a continuation: the cost of the continued leg is added to the message's existing
    /// cost instead of overwriting it. USD adds up (the source of the existing cost wins unless it
    /// is unknown, then the continuation's is used) and non-USD merges via `mergeNonUsdCost`.
    static func addMessageCost(_ existing: MessageCostRecord, _ continuation: MessageCostRecord) -> MessageCostRecord {
        let existingHasUsd = existing.costSource != nil && existing.costSource != .unknown
        return MessageCostRecord(
            estimatedCost: existing.estimatedCost + continuation.estimatedCost,
            costSource: existingHasUsd ? existing.costSource : continuation.costSource,
            nonUsdCost: mergeNonUsdCost(existing.nonUsdCost, continuation.nonUsdCost)
        )
    }

    /// Cost of a multi-leg message (tool loop, MCP, Kimi's built-in multi-request search): a
    /// subscription connection (decided once from the connection's authMode) records the whole message
    /// as subscription; otherwise each leg is priced through `price` (the production delivery entry
    /// point) -- upstream-reported cost for the leg if present, otherwise an estimate from the leg's
    /// usage breakdown (cache buckets) -- and combined per currency through `DeliveredCost.combiningLegs`.
    /// No legs, or any leg without a usage report, makes the whole message unknown.
    /// Per-unit pricing (per_image / per_second) is not split by leg: the whole message is priced once
    /// by the number of images actually produced (`producedAttachments`), upstream cost still wins,
    /// and zero units is unknown.
    static func multiLegCost(
        _ usage: ToolLoopUsage?,
        model: AIModel,
        provider: Provider,
        metadata: MetadataClient = .shared,
        producedAttachments: [Attachment],
        at: Date,
        price: (ProviderChatResult) -> DeliveredCost
    ) -> DeliveredCost {
        if ProviderForm.of(provider) == .subscription {
            return .usd(0, source: .subscription)
        }
        if isPerUnitPriced(model: model, provider: provider, metadata: metadata) {
            return DeliveredCost(parts: [generationPart(
                result: wholeMessageResult(usage), model: model, provider: provider, metadata: metadata,
                streamedAttachments: producedAttachments, at: at
            )])
        }
        let legs = (usage ?? .unreported).perLeg
        var total: DeliveredCost?
        for leg in legs {
            let legCost = leg.allLegsReported ? price(legResult(leg)) : DeliveredCost(parts: [unknownPart])
            total = total.map { DeliveredCost.combiningLegs($0, legCost) } ?? legCost
        }
        return total ?? DeliveredCost(parts: [unknownPart])
    }

    /// Merges two deliveries into one message's generation cost (the first leg and tail of a proposal,
    /// or the first leg and the follow-up answer after an empty-body thinking reply): per-unit pricing
    /// does not count units per segment -- the segments add up only when both are upstream-reported,
    /// otherwise the whole message is estimated once from the images actually produced
    /// (`producedAttachments`; Relay never adopts upstream cost, so it is always estimated once).
    /// Subscription and per-token pricing add up per currency through `DeliveredCost.combiningLegs`,
    /// and a segment without a cost is merged as unknown.
    static func combiningDeliveries(
        _ first: DeliveredCost?,
        _ later: DeliveredCost?,
        model: AIModel,
        provider: Provider,
        metadata: MetadataClient = .shared,
        producedAttachments: [Attachment],
        at: Date
    ) -> DeliveredCost {
        if ProviderForm.of(provider) != .subscription,
           isPerUnitPriced(model: model, provider: provider, metadata: metadata) {
            let segments = [first, later]
            let allUpstream = segments.allSatisfy { segment in
                guard let segment, !segment.parts.isEmpty else { return false }
                return segment.parts.allSatisfy { !$0.unknown && $0.costSource == .upstream }
            }
            if !allUpstream {
                return DeliveredCost(parts: [generationPart(
                    result: wholeMessageResult(nil), model: model, provider: provider, metadata: metadata,
                    streamedAttachments: producedAttachments, at: at
                )])
            }
        }
        return DeliveredCost.combiningLegs(first ?? unknownLeg, later ?? unknownLeg)
    }

    /// Whether the catalog price of this model on this connection is per unit
    /// (pricingV2.unit first, the legacy pricingUnit only when there is no v2).
    private static func isPerUnitPriced(model: AIModel, provider: Provider, metadata: MetadataClient) -> Bool {
        guard let catalog = catalogModel(model: model, provider: provider, metadata: metadata) else { return false }
        return (catalog.pricingV2?.unit ?? catalog.pricingUnit ?? "per_token") != "per_token"
    }

    /// A multi-leg message as one per-unit priced result: upstream cost is adopted only when every
    /// leg reported it (then summed); otherwise the price is estimated from the unit count.
    private static func wholeMessageResult(_ usage: ToolLoopUsage?) -> ProviderChatResult {
        let legs = (usage ?? .unreported).perLeg
        let upstreams = legs.map { $0.breakdown?.upstreamCost }
        let upstream: Double? = upstreams.allSatisfy { $0 != nil } ? upstreams.compactMap { $0 }.reduce(0, +) : nil
        var breakdown = UsageBreakdown(promptTokens: usage?.promptTokens ?? 0, completionTokens: usage?.completionTokens ?? 0)
        breakdown.upstreamCost = upstream
        return ProviderChatResult(
            text: "",
            promptTokens: breakdown.promptTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: upstream ?? 0,
            usageBreakdown: breakdown,
            usageReported: ToolLoopUsage.reported(usage),
            costSource: upstream == nil ? nil : .upstream
        )
    }

    /// The shape one leg's usage takes when handed to delivery pricing: the breakdown comes from the
    /// provider's regular chat usage parser (cache buckets, upstream cost); an upstream cost is used
    /// as-is (`.upstream`), otherwise the breakdown is estimated. A leg with only token counts is
    /// estimated as uncached input.
    static func legResult(_ leg: ToolLoopUsage) -> ProviderChatResult {
        let breakdown = leg.breakdown
            ?? UsageBreakdown(promptTokens: leg.promptTokens ?? 0, completionTokens: leg.completionTokens ?? 0)
        return ProviderChatResult(
            text: "",
            promptTokens: breakdown.totalInputTokens,
            completionTokens: breakdown.completionTokens,
            estimatedCost: breakdown.upstreamCost ?? 0,
            usageBreakdown: breakdown,
            usageReported: true,
            costSource: breakdown.upstreamCost == nil ? nil : .upstream
        )
    }

    /// A leg whose delivery cost the caller did not get: merged into a multi-leg cost as unknown, not 0.
    static let unknownLeg = DeliveredCost(parts: [unknownPart])

    /// One estimate as one pricing part: when the price is unknown the amount is 0, the source is
    /// `.unknown` and the currency is that of the selected price.
    static func part(_ estimate: CostEstimate) -> DeliveredCostPart {
        DeliveredCostPart(
            amount: estimate.isUnavailable ? 0 : estimate.amount,
            currencyCode: estimate.currencyCode,
            unknown: estimate.isUnavailable,
            costSource: estimate.source
        )
    }

    private static func generationPart(
        result: ProviderChatResult,
        model: AIModel,
        provider: Provider,
        metadata: MetadataClient,
        streamedAttachments: [Attachment],
        at: Date
    ) -> DeliveredCostPart {
        let kind = provider.kind
        // Subscription is decided once from the connection's authMode (same as the multi-leg entry),
        // ignoring the cost source a service filled in: paths that bypass services, such as image
        // dispatch, are recorded as subscription too and never priced from local prices.
        if ProviderForm.of(provider) == .subscription { return .usd(0, source: .subscription) }
        // Relay is an arbitrary endpoint: its reported cost (usage.cost) has no trustworthy unit or
        // currency, so it is never adopted and the cost is estimated as usual.
        let result = kind == .relay ? withoutUpstreamCost(result) : result
        // Upstream cost is a real USD number from upstream: it is not recomputed from catalog prices,
        // and a reported 0 is a real 0 (e.g. OpenRouter :free) that never falls back to local prices.
        if let upstream = upstreamAmount(result) {
            return .usd(upstream, source: .upstream)
        }
        let catalog = catalogModel(model: model, provider: provider, metadata: metadata)
        // Without a usage report, per-token pricing cannot be estimated and is unknown (not 0);
        // per-unit pricing does not depend on usage. The unit comes from pricingV2.unit first.
        let pricingUnit = catalog?.pricingV2?.unit ?? catalog?.pricingUnit ?? "per_token"
        if !hasUsage(result), pricingUnit == "per_token" {
            return unknownPart
        }
        guard let catalog else {
            if allowsLocalPriceWithoutCatalog(provider, metadata: metadata) {
                return legacyPart(result: result, model: model)
            }
            // The selected currency cannot be confirmed as USD: do not fall back to the local price
            // (it has no currency, so it would be recorded as dollars); trust only the service amount.
            return servicePart(result)
        }
        let breakdown = result.usageBreakdown
            ?? UsageBreakdown(promptTokens: result.promptTokens, completionTokens: result.completionTokens)
        let units = billedUnits(result, streamedAttachments: streamedAttachments)
        // Relay matched to an official entry: no region selection, estimated directly from the matched
        // entry and recorded in its currency.
        if kind == .relay {
            return part(CostCalculator.estimate(breakdown: breakdown, pricing: catalog, at: at, units: units))
        }
        // Official catalog hit: only the entry's own (region-selected) prices are used; an estimate that
        // cannot be produced is unknown and never falls back to the local price.
        let selection = RegionPricingSelector.select(catalog, provider: provider)
        return part(CostCalculator.estimate(breakdown: breakdown, pricing: selection.pricing, at: at, units: units))
    }

    /// Upstream cost amount: the parser's `upstreamCost` first, then a service amount tagged
    /// `.upstream`; nil when there is neither.
    private static func upstreamAmount(_ result: ProviderChatResult) -> Double? {
        if let upstream = result.usageBreakdown?.upstreamCost { return upstream }
        return result.costSource == .upstream ? result.estimatedCost : nil
    }

    /// The same result without upstream cost (for Relay): an amount the service recorded from the
    /// upstream cost is zeroed too, leaving pricing to the estimate or local price.
    private static func withoutUpstreamCost(_ result: ProviderChatResult) -> ProviderChatResult {
        guard upstreamAmount(result) != nil else { return result }
        var stripped = result
        stripped.usageBreakdown?.upstreamCost = nil
        stripped.estimatedCost = 0
        stripped.costSource = nil
        return stripped
    }

    /// Billable units for per-unit pricing: the images actually generated (result attachments plus
    /// attachments received while streaming, deduplicated by id). No image means 0 units, which
    /// estimates as unknown; there is no minimum of one.
    static func billedUnits(_ result: ProviderChatResult, streamedAttachments: [Attachment] = []) -> Int {
        let imageIDs = Set(((result.attachments ?? []) + streamedAttachments).filter { $0.kind == .image }.map(\.id))
        return imageIDs.count
    }

    /// USD path: when the service amount is 0, compute from the model's local price per bucket; still 0
    /// with tokens present means the price is unknown.
    private static func legacyPart(result: ProviderChatResult, model: AIModel) -> DeliveredCostPart {
        var finalCost = result.estimatedCost
        if finalCost == 0,
           let promptPrice = model.promptPrice,
           let completionPrice = model.completionPrice,
           promptPrice > 0 || completionPrice > 0 {
            if let breakdown = result.usageBreakdown {
                // With a breakdown, price per bucket. `result.promptTokens` is the total input
                // including cache, so multiplying it by the full price would systematically
                // overestimate cache-hit requests; Relay models without an official entry take this
                // fallback, so this rough figure is what those users actually see.
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
        if finalCost <= CostFormatter.costEpsilon, hasTokens(result) {
            return unknownPart
        }
        let source: CostSource = result.estimatedCost > CostFormatter.costEpsilon
            ? (result.costSource ?? .localEstimate)
            : .localEstimate
        return .usd(finalCost, source: source)
    }

    /// Trusts only the USD amount the service already computed, without a local price fallback.
    private static func servicePart(_ result: ProviderChatResult) -> DeliveredCostPart {
        if result.estimatedCost <= CostFormatter.costEpsilon, hasTokens(result) {
            return unknownPart
        }
        return .usd(result.estimatedCost, source: result.costSource ?? .localEstimate)
    }

    private static let unknownPart = DeliveredCostPart(
        amount: 0, currencyCode: CostCalculator.usd, unknown: true, costSource: .unknown
    )

    private static func hasTokens(_ result: ProviderChatResult) -> Bool {
        result.promptTokens > 0 || result.completionTokens > 0
    }

    /// Whether upstream reported usage: only the explicit `usageReported` signal from the service
    /// parser counts. A missing usage object is unreported; a report with all buckets 0 is a real
    /// zero-cost estimate, not unknown.
    private static func hasUsage(_ result: ProviderChatResult) -> Bool {
        result.usageReported
    }

    /// The catalog price used for delivery estimates on this connection: official providers use their
    /// own catalog, Relay matches across providers through the same function as capability
    /// inheritance (`CatalogModelBuilder.connectionPriced` uses it for the unit price label too).
    static func catalogModel(
        model: AIModel,
        provider: Provider,
        metadata: MetadataClient
    ) -> MetadataClient.ResolvedModelMetadata? {
        if provider.kind == .relay {
            return RelayOfficialCatalogResolver.officialMatch(for: model, provider: provider, metadata: metadata)?.metadata
        }
        return metadata.resolveCatalogModel(modelID: model.id, providerKind: provider.kind)
    }

    /// Whether the local price (no currency, recorded as dollars) may back a model the catalog does not
    /// know: only if the selected currency is certain to be USD. Relay and custom endpoints do not
    /// select a region and keep the fallback; for official providers every catalog price of the
    /// provider (model level and per region) must be USD, and when metadata is not loaded or the
    /// provider has no catalog models this cannot be determined, so there is no fallback (unknown).
    private static func allowsLocalPriceWithoutCatalog(_ provider: Provider, metadata: MetadataClient) -> Bool {
        if provider.kind == .relay || provider.endpointSource == .custom { return true }
        let ids = metadata.providerModelIDs(providerKind: provider.kind)
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { id in
            guard let model = metadata.resolveCatalogModel(modelID: id, providerKind: provider.kind) else { return false }
            return CostCalculator.currencyCode(of: model) == CostCalculator.usd
                && model.regionPricing.allSatisfy {
                    CostCalculator.normalizedCurrency($0.pricingV2?.currencyCode ?? $0.currencyCode) == CostCalculator.usd
                }
        }
    }

    /// Plain delivered cost of a result priced from the model's local price, kept for call sites that
    /// only need a USD figure.
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

/// One pricing part of a delivered message: `amount` is in `currencyCode` (uppercase ISO 4217) and is
/// never converted; when `unknown` is true the price is unknown (shown as unavailable, not 0).
struct DeliveredCostPart: Sendable, Equatable {
    let amount: Double
    let currencyCode: String
    let unknown: Bool
    let costSource: CostSource?

    var isUsd: Bool { currencyCode == CostCalculator.usd }

    static func usd(_ amount: Double, source: CostSource? = nil) -> DeliveredCostPart {
        DeliveredCostPart(amount: amount, currencyCode: CostCalculator.usd, unknown: false, costSource: source)
    }
}

/// The cost of one delivery: its pricing parts. The two legs of a continuation or of an
/// empty-body thinking resend are concatenated, and persisting combines them through
/// `ChatDeliveryAccounting.record` (same currency adds up, no conversion).
struct DeliveredCost: Sendable, Equatable {
    var parts: [DeliveredCostPart] = []

    static func usd(_ amount: Double, source: CostSource? = nil) -> DeliveredCost {
        DeliveredCost(parts: [.usd(amount, source: source)])
    }

    static func + (lhs: DeliveredCost, rhs: DeliveredCost) -> DeliveredCost {
        DeliveredCost(parts: lhs.parts + rhs.parts)
    }

    /// Adds the generation costs of the legs of one message: each leg is priced separately and then
    /// added per currency -- the USD part plus the non-USD parts (no conversion, none dropped;
    /// `record` combines them when persisting). If any leg is unknown, the whole message is unknown.
    /// A second non-USD currency follows the single-leg rule: parts are kept as they are and `record`
    /// merges them through `mergeNonUsdCost` into {first non-USD currency, 0, unknown}, with the USD
    /// part still recorded. USD source: `.upstream` only if every USD part is upstream-reported; one
    /// estimated leg makes the whole USD part `.localEstimate`.
    static func combiningLegs(_ lhs: DeliveredCost, _ rhs: DeliveredCost) -> DeliveredCost {
        var parts = lhs.parts + rhs.parts
        guard let first = parts.first else { return DeliveredCost() }
        let unknown = parts.contains { $0.unknown || $0.costSource == .unknown }
        guard !unknown else {
            return DeliveredCost(parts: [
                DeliveredCostPart(amount: 0, currencyCode: first.currencyCode, unknown: true, costSource: .unknown),
            ])
        }
        let usdParts = parts.filter(\.isUsd)
        if usdParts.contains(where: { $0.costSource == .upstream }),
           !usdParts.allSatisfy({ $0.costSource == .upstream }) {
            parts = parts.map { part in
                guard part.isUsd, part.costSource == .upstream else { return part }
                return DeliveredCostPart(
                    amount: part.amount, currencyCode: part.currencyCode, unknown: part.unknown, costSource: .localEstimate
                )
            }
        }
        return DeliveredCost(parts: parts)
    }
}

/// The cost persisted for one message: `estimatedCost` / `costSource` describe only the USD part
/// (0 + `.unknown` when there is none) and `nonUsdCost` is the only non-USD part. Dollar consumers
/// (conversation totals, budgets) read only `estimatedCost`.
struct MessageCostRecord: Sendable, Equatable {
    var estimatedCost: Double
    var costSource: CostSource?
    var nonUsdCost: NonUsdCost?
}
