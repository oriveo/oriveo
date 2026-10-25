import Foundation

/// Selection of the featured ("active this month") card on the Providers page.
///
/// Candidates = providers that have billed messages this month (in any currency).
/// Ranking: billed messages this month (regardless of currency) > USD amount this month (non-USD is neither converted nor added) >
/// status (connected > syncing > issue) > the existing list order. When there is no candidate the status rule applies. Only 1 card is taken.
enum ProviderSpotlight {
    static let count = 1

    static func select(providers: [Provider], activity: [UUID: ProviderMonthlyActivity]) -> [Provider] {
        let eligible = Array(providers.enumerated())
        guard !eligible.isEmpty else { return [] }

        let candidates = eligible.filter { isCandidate(activity[$0.element.id]) }
        if !candidates.isEmpty {
            let ranked = candidates.sorted { lhs, rhs in
                let left = activity[lhs.element.id] ?? ProviderMonthlyActivity()
                let right = activity[rhs.element.id] ?? ProviderMonthlyActivity()
                if left.billedMessageCount != right.billedMessageCount {
                    return left.billedMessageCount > right.billedMessageCount
                }
                if abs(left.usdCost - right.usdCost) > CostFormatter.costEpsilon {
                    return left.usdCost > right.usdCost
                }
                return byStatusThenOrder(lhs, rhs)
            }
            return Array(ranked.prefix(count).map(\.element))
        }

        return Array(eligible.sorted(by: byStatusThenOrder).prefix(count).map(\.element))
    }

    /// Only a provider with billed messages on this device this month is a candidate; a new device without local messages falls back to the status rule.
    private static func isCandidate(_ activity: ProviderMonthlyActivity?) -> Bool {
        (activity?.billedMessageCount ?? 0) > 0
    }

    private static func byStatusThenOrder(
        _ lhs: (offset: Int, element: Provider),
        _ rhs: (offset: Int, element: Provider)
    ) -> Bool {
        let left = statusPriority(lhs.element.status)
        let right = statusPriority(rhs.element.status)
        if left != right { return left < right }
        return lhs.offset < rhs.offset
    }

    static func statusPriority(_ status: ProviderConnectionState) -> Int {
        switch status {
        case .connected: return 0
        case .syncing: return 1
        case .issue: return 2
        }
    }
}
