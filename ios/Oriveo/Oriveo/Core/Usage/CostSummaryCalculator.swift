import Foundation

struct MonthlyCostSummary: Equatable {
    var totalCost: Double = 0
    var providers: [MonthlyCostSummaryProviderEntry] = []
    var hiddenProviderCount: Int = 0

    var isVisible: Bool {
        totalCost > CostFormatter.costEpsilon && !providers.isEmpty
    }
}

struct MonthlyCostSummaryProviderEntry: Identifiable, Equatable {
    let providerKind: ProviderKind
    let providerID: String
    let displayName: String
    let logoProviderKind: ProviderKind?
    let cost: Double

    var id: String { "\(providerKind.rawValue)|\(providerID)" }
}

struct MonthlyCostAggregate: Equatable, Sendable {
    let providerKind: ProviderKind
    let providerID: UUID
    let cost: Double
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
        for aggregate in aggregates where aggregate.cost > CostFormatter.costEpsilon {
            let key = "\(aggregate.providerKind.rawValue)|\(aggregate.providerID.uuidString)"
            if let previous = groupedCosts[key] {
                groupedCosts[key] = MonthlyCostAggregate(
                    providerKind: previous.providerKind,
                    providerID: previous.providerID,
                    cost: previous.cost + aggregate.cost
                )
            } else {
                groupedCosts[key] = aggregate
            }
        }

        let sortedProviders = groupedCosts.values
            .map { entry in
                MonthlyCostSummaryProviderEntry(
                    providerKind: entry.providerKind,
                    providerID: entry.providerID.uuidString,
                    displayName: providerByID[entry.providerID]?.displayName ?? entry.providerKind.displayName,
                    logoProviderKind: providerByID[entry.providerID].map(ProviderLogoResolver.logoKind(for:)),
                    cost: entry.cost
                )
            }
            .sorted(by: monthlyEntryOrder)

        return MonthlyCostSummary(
            totalCost: sortedProviders.map(\.cost).reduce(0, +),
            providers: Array(sortedProviders.prefix(visibleProviderLimit)),
            hiddenProviderCount: max(0, sortedProviders.count - visibleProviderLimit)
        )
    }

    static func aggregates(from conversations: [Conversation], now: Date = Date()) -> [MonthlyCostAggregate] {
        let window = utcMonthWindow(containing: now)
        var groupedCosts: [String: MonthlyCostAggregate] = [:]

        for conversation in conversations where !conversation.isDraft {
            for message in conversation.messages {
                guard message.role == .assistant,
                      message.state == .delivered,
                      message.estimatedCost > CostFormatter.costEpsilon
                else { continue }

                let occurredAt = message.createdAt ?? conversation.updatedAt
                guard isWithinWindow(occurredAt, window: window) else { continue }

                let providerID = message.providerID ?? conversation.providerID
                let key = "\(message.providerKind.rawValue)|\(providerID.uuidString)"
                if let previous = groupedCosts[key] {
                    groupedCosts[key] = MonthlyCostAggregate(
                        providerKind: previous.providerKind,
                        providerID: previous.providerID,
                        cost: previous.cost + message.estimatedCost
                    )
                } else {
                    groupedCosts[key] = MonthlyCostAggregate(
                        providerKind: message.providerKind,
                        providerID: providerID,
                        cost: message.estimatedCost
                    )
                }
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

    static func monthlyCostByProvider(from aggregates: [MonthlyCostAggregate]) -> [UUID: Double] {
        var costs: [UUID: Double] = [:]
        for aggregate in aggregates where aggregate.cost > CostFormatter.costEpsilon {
            costs[aggregate.providerID, default: 0] += aggregate.cost
        }
        return costs
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
