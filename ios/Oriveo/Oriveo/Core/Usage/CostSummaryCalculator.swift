import Foundation

struct MonthlyCostSummary: Equatable {
    /// USD total (shares, budgets and usage reports are all computed from it only).
    var totalCost: Double = 0
    var providers: [MonthlyCostSummaryProviderEntry] = []
    var hiddenProviderCount: Int = 0
    /// Non-USD totals (currency code -> original-currency amount): not converted and not added to USD.
    var nonUsdTotals: [String: Double] = [:]

    var isVisible: Bool {
        (totalCost > CostFormatter.costEpsilon || !nonUsdTotals.isEmpty) && !providers.isEmpty
    }
}

struct MonthlyCostSummaryProviderEntry: Identifiable, Equatable {
    let providerKind: ProviderKind
    let providerID: String
    let displayName: String
    let logoProviderKind: ProviderKind?
    /// USD amount.
    let cost: Double
    /// Non-USD amounts (currency code -> original-currency amount); a row with only non-USD amounts shows no share.
    var nonUsdCosts: [String: Double] = [:]

    var id: String { "\(providerKind.rawValue)|\(providerID)" }
}

/// The total amount in one currency (never added across currencies, never converted).
nonisolated struct CurrencyAmount: Equatable, Sendable {
    let currencyCode: String
    let amount: Double
}

/// Conversation cost totals: the USD total plus non-USD totals per currency; recomputed from the delivered messages held locally.
nonisolated struct ConversationCostTotals: Equatable, Sendable {
    var estimatedCost: Double
    var nonUsdCostTotals: [String: Double]

    /// Whether two totals are equivalent (USD and every currency differ by no more than costEpsilon): equivalent totals are not written back.
    func isEquivalent(to other: ConversationCostTotals) -> Bool {
        guard abs(estimatedCost - other.estimatedCost) <= CostFormatter.costEpsilon,
              Set(nonUsdCostTotals.keys) == Set(other.nonUsdCostTotals.keys) else { return false }
        return nonUsdCostTotals.allSatisfy { code, amount in
            abs(amount - (other.nonUsdCostTotals[code] ?? 0)) <= CostFormatter.costEpsilon
        }
    }
}

struct MonthlyCostAggregate: Equatable, Sendable {
    let providerKind: ProviderKind
    let providerID: UUID
    /// USD amount (the sum of `estimatedCost`).
    let cost: Double
    /// The recorded non-USD part (currency code -> original-currency amount).
    var nonUsdCosts: [String: Double] = [:]
    /// Billed messages this month (at least one recorded part; a mixed-currency message counts once).
    var billedMessageCount: Int = 0

    nonisolated func adding(_ other: MonthlyCostAggregate) -> MonthlyCostAggregate {
        MonthlyCostAggregate(
            providerKind: providerKind,
            providerID: providerID,
            cost: cost + other.cost,
            nonUsdCosts: nonUsdCosts.merging(other.nonUsdCosts, uniquingKeysWith: +),
            billedMessageCount: billedMessageCount + other.billedMessageCount
        )
    }
}

/// The cost activity of one provider this month (used to rank the featured card on the Providers page).
struct ProviderMonthlyActivity: Equatable, Sendable {
    var billedMessageCount: Int = 0
    var usdCost: Double = 0
    var nonUsdCosts: [String: Double] = [:]
}

enum CostSummaryCalculator {
    static func utcMonthBounds(containing date: Date) -> (start: TimeInterval, end: TimeInterval) {
        let window = utcMonthWindow(containing: date)
        return (window.start.timeIntervalSince1970, window.end.timeIntervalSince1970)
    }

    static func makeMonthlySummary(
        from conversations: [Conversation],
        providers: [Provider],
        now: Date = Date(),
        visibleProviderLimit: Int = 3
    ) -> MonthlyCostSummary {
        makeMonthlySummary(
            from: aggregates(from: conversations, now: now),
            providers: providers,
            visibleProviderLimit: visibleProviderLimit
        )
    }

    static func makeMonthlySummary(
        from aggregates: [MonthlyCostAggregate],
        providers: [Provider],
        visibleProviderLimit: Int = 3
    ) -> MonthlyCostSummary {
        let providerByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        var groupedCosts: [String: MonthlyCostAggregate] = [:]
        for aggregate in aggregates {
            let key = "\(aggregate.providerKind.rawValue)|\(aggregate.providerID.uuidString)"
            groupedCosts[key] = groupedCosts[key].map { $0.adding(aggregate) } ?? aggregate
        }

        // The raw per-message values have already been added up; epsilon only judges each currency total of a provider: USD <= epsilon records 0,
        // non-USD <= epsilon is omitted, and a provider with neither is not listed.
        let sortedProviders = groupedCosts.values
            .compactMap { entry -> MonthlyCostSummaryProviderEntry? in
                let cost = entry.cost > CostFormatter.costEpsilon ? entry.cost : 0
                let nonUsdCosts = entry.nonUsdCosts.filter { $0.value > CostFormatter.costEpsilon }
                guard cost > 0 || !nonUsdCosts.isEmpty else { return nil }
                return MonthlyCostSummaryProviderEntry(
                    providerKind: entry.providerKind,
                    providerID: entry.providerID.uuidString,
                    displayName: providerByID[entry.providerID]?.displayName ?? entry.providerKind.displayName,
                    logoProviderKind: providerByID[entry.providerID].map(ProviderLogoResolver.logoKind(for:)),
                    cost: cost,
                    nonUsdCosts: nonUsdCosts
                )
            }
            .sorted(by: monthlyEntryOrder)

        return MonthlyCostSummary(
            totalCost: sortedProviders.map(\.cost).reduce(0, +),
            providers: Array(sortedProviders.prefix(visibleProviderLimit)),
            hiddenProviderCount: max(0, sortedProviders.count - visibleProviderLimit),
            nonUsdTotals: sortedProviders.reduce(into: [:]) { totals, entry in
                totals.merge(entry.nonUsdCosts, uniquingKeysWith: +)
            }
        )
    }

    static func aggregates(from conversations: [Conversation], now: Date = Date()) -> [MonthlyCostAggregate] {
        let window = utcMonthWindow(containing: now)
        var groupedCosts: [String: MonthlyCostAggregate] = [:]

        for conversation in conversations where !conversation.isDraft {
            for message in conversation.messages {
                // Amounts take only raw values > 0 (epsilon only judges totals); the billed count is still judged per message through isBilled.
                let hasUsd = message.estimatedCost > 0
                let nonUsdPart = message.nonUsdCost.flatMap { part -> NonUsdCost? in
                    (part.costSource == .upstream || part.costSource == .localEstimate) && part.amount > 0 ? part : nil
                }
                guard message.role == .assistant,
                      message.state == .delivered,
                      hasUsd || nonUsdPart != nil
                else { continue }

                let occurredAt = message.createdAt ?? conversation.updatedAt
                guard isWithinWindow(occurredAt, window: window) else { continue }

                let providerID = message.providerID ?? conversation.providerID
                let key = "\(message.providerKind.rawValue)|\(providerID.uuidString)"
                let aggregate = MonthlyCostAggregate(
                    providerKind: message.providerKind,
                    providerID: providerID,
                    cost: hasUsd ? message.estimatedCost : 0,
                    nonUsdCosts: nonUsdPart.map { [$0.currencyCode: $0.amount] } ?? [:],
                    billedMessageCount: message.isBilled ? 1 : 0
                )
                groupedCosts[key] = groupedCosts[key].map { $0.adding(aggregate) } ?? aggregate
            }
        }
        return Array(groupedCosts.values)
    }



    private static func monthlyEntryOrder(
        _ lhs: MonthlyCostSummaryProviderEntry,
        _ rhs: MonthlyCostSummaryProviderEntry
    ) -> Bool {
        if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    static func monthlyCostByProvider(
        from conversations: [Conversation],
        now: Date = Date()
    ) -> [UUID: Double] {
        monthlyCostByProvider(from: aggregates(from: conversations, now: now))
    }

    /// Aggregates this month's cost activity (billed messages / USD / non-USD) by providerID, used to rank the featured card on the Providers page.
    static func monthlyActivityByProvider(from aggregates: [MonthlyCostAggregate]) -> [UUID: ProviderMonthlyActivity] {
        var activity: [UUID: ProviderMonthlyActivity] = [:]
        for aggregate in aggregates {
            var entry = activity[aggregate.providerID] ?? ProviderMonthlyActivity()
            entry.billedMessageCount += aggregate.billedMessageCount
            if aggregate.cost > CostFormatter.costEpsilon { entry.usdCost += aggregate.cost }
            entry.nonUsdCosts.merge(aggregate.nonUsdCosts, uniquingKeysWith: +)
            activity[aggregate.providerID] = entry
        }
        return activity
    }

    static func monthlyCostByProvider(from aggregates: [MonthlyCostAggregate]) -> [UUID: Double] {
        var costs: [UUID: Double] = [:]
        for aggregate in aggregates where aggregate.cost > CostFormatter.costEpsilon {
            costs[aggregate.providerID, default: 0] += aggregate.cost
        }
        return costs
    }

    /// Conversation totals: only delivered messages count; USD adds up the raw positive `estimatedCost` values and non-USD adds up per currency
    /// (recomputed from here after a delete / retry / continue).
    /// Epsilon (costEpsilon) only applies to the totals: the raw per-message values are added first, and only a sum <= epsilon records 0.
    nonisolated static func conversationTotals(of messages: [ChatMessage]) -> ConversationCostTotals {
        let delivered = messages.filter { $0.state == .delivered }
        let usd = delivered
            .filter { $0.estimatedCost > 0 }
            .reduce(0) { $0 + $1.estimatedCost }
        return ConversationCostTotals(
            estimatedCost: usd > CostFormatter.costEpsilon ? usd : 0,
            nonUsdCostTotals: nonUsdCostTotals(of: delivered)
        )
    }

    /// Whether the messages held by the conversation are the whole thread: only a summary projection (an empty `messages` there means "not read") is not.
    nonisolated static func isLocalThreadComplete(_ conversation: Conversation) -> Bool {
        conversation.messagesAreLoaded
    }

    /// The single entry point for conversation totals: finishing a send, regenerate / edit truncation, retry, live append and storage-layer writes all go through here.
    /// - Thread complete: recomputes USD and every currency from `conversation.messages` (after the change).
    /// - Not complete: no full recompute; starting from the totals on the conversation, adds the difference of the locally changed messages per currency
    ///   (`localMessagesBefore` -> `conversation.messages`; a new message counts as 0 before, a deleted one as 0 after), each currency floored at 0,
    ///   and a non-USD currency at 0 is not written. `localMessagesBefore == nil` means there was no local change this time, so the difference is 0.
    nonisolated static func conversationTotals(
        for conversation: Conversation,
        localMessagesBefore: [ChatMessage]? = nil
    ) -> ConversationCostTotals {
        if isLocalThreadComplete(conversation) {
            return conversationTotals(of: conversation.messages)
        }
        var totals = ConversationCostTotals(
            estimatedCost: conversation.estimatedCost,
            nonUsdCostTotals: conversation.nonUsdCostTotals
        )
        if let localMessagesBefore {
            let before = conversationTotals(of: localMessagesBefore)
            let after = conversationTotals(of: conversation.messages)
            totals.estimatedCost += after.estimatedCost - before.estimatedCost
            for code in Set(before.nonUsdCostTotals.keys).union(after.nonUsdCostTotals.keys) {
                totals.nonUsdCostTotals[code, default: 0] +=
                    (after.nonUsdCostTotals[code] ?? 0) - (before.nonUsdCostTotals[code] ?? 0)
            }
        }
        if totals.estimatedCost <= CostFormatter.costEpsilon {
            totals.estimatedCost = 0
        }
        totals.nonUsdCostTotals = totals.nonUsdCostTotals.filter { $0.value > CostFormatter.costEpsilon }
        return totals
    }

    /// Non-USD totals (currency code -> amount): only raw values > 0 are added and a currency whose total <= epsilon is omitted; the conversation row's `nonUsdCostTotals` is recomputed from the local messages with it.
    nonisolated static func nonUsdCostTotals(of messages: [ChatMessage]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for message in messages {
            guard let part = message.nonUsdCost, part.costSource != .unknown, part.amount > 0 else { continue }
            totals[part.currencyCode, default: 0] += part.amount
        }
        return totals.filter { $0.value > CostFormatter.costEpsilon }
    }

    private static func utcMonthWindow(containing date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return DateInterval(start: start, end: end)
    }

    private static func isWithinWindow(_ date: Date, window: DateInterval) -> Bool {
        date >= window.start && date < window.end
    }
}
