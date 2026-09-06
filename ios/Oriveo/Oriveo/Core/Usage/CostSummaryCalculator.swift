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

enum CostSummaryCalculator {
    static func makeMonthlySummary(
        from conversations: [Conversation],
        providers: [Provider],
        now: Date = Date(),
        visibleProviderLimit: Int = 3
    ) -> MonthlyCostSummary {
        let window = utcMonthWindow(containing: now)
        let providerByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        var groupedCosts: [String: (kind: ProviderKind, providerID: UUID, cost: Double)] = [:]

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
                let previous = groupedCosts[key]
                groupedCosts[key] = (
                    kind: message.providerKind,
                    providerID: providerID,
                    cost: (previous?.cost ?? 0) + message.estimatedCost
                )
            }
        }

        let sortedProviders = groupedCosts.values
            .map { entry in
                MonthlyCostSummaryProviderEntry(
                    providerKind: entry.kind,
                    providerID: entry.providerID.uuidString,
                    displayName: providerByID[entry.providerID]?.displayName ?? entry.kind.displayName,
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
        let window = utcMonthWindow(containing: now)
        var costs: [UUID: Double] = [:]

        for conversation in conversations where !conversation.isDraft {
            for message in conversation.messages {
                guard message.role == .assistant,
                      message.state == .delivered,
                      message.estimatedCost > CostFormatter.costEpsilon
                else { continue }

                let occurredAt = message.createdAt ?? conversation.updatedAt
                guard isWithinWindow(occurredAt, window: window) else { continue }
                let providerID = message.providerID ?? conversation.providerID
                costs[providerID, default: 0] += message.estimatedCost
            }
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
