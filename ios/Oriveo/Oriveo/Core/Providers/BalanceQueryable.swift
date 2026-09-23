import Foundation

protocol BalanceQueryable {
    /// - Parameters:
    func fetchBalance(apiKey: String, baseURL: String?) async throws -> ProviderBalance
}

let balanceCapableProviderKinds: Set<ProviderKind> = [
    .openRouter, .siliconFlow, .deepseek, .moonshot,
]

func balanceOriginFrom(_ baseURL: String?, fallback: String) -> String {
    let candidate = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !candidate.isEmpty {
        let normalized = (candidate.hasPrefix("http://") || candidate.hasPrefix("https://"))
            ? candidate
            : "https://\(candidate)"
        if let url = URL(string: normalized),
           let scheme = url.scheme,
           let host = url.host {
            if let port = url.port {
                return "\(scheme)://\(host):\(port)"
            }
            return "\(scheme)://\(host)"
        }
    }
    if let url = URL(string: fallback),
       let scheme = url.scheme,
       let host = url.host {
        return "\(scheme)://\(host)"
    }
    return fallback
}

struct ProviderBalance: Sendable, Equatable {
    var currency: String
    var total: Double
    var granted: Double?
    var topUp: Double?
    var fetchedAt: Date

    var totalUsage: Double?

    init(
        currency: String,
        total: Double,
        granted: Double? = nil,
        topUp: Double? = nil,
        fetchedAt: Date = Date(),
        totalUsage: Double? = nil
    ) {
        self.currency = currency
        self.total = total
        self.granted = granted
        self.topUp = topUp
        self.fetchedAt = fetchedAt
        self.totalUsage = totalUsage
    }
}

enum BalanceQueryError: Error, Sendable {
    case keyInvalid(detail: String)
    case silentHidden(detail: String)
    case network(detail: String)
    case decoding(detail: String)
}

@MainActor
final class ProviderBalanceStore {
    typealias ServiceFactory = @MainActor (ProviderKind) -> (any BalanceQueryable)?

    static let shared = ProviderBalanceStore()

    private struct CacheEntry {
        let apiKey: String
        let baseURL: String
        let balance: ProviderBalance
    }

    private let cacheTTL: TimeInterval
    private let now: () -> Date
    private let serviceFactory: ServiceFactory
    private var entries: [UUID: CacheEntry] = [:]

    init(
        cacheTTL: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init,
        serviceFactory: @escaping ServiceFactory = ProviderBalanceStore.makeService
    ) {
        self.cacheTTL = cacheTTL
        self.now = now
        self.serviceFactory = serviceFactory
    }

    func load(
        providerID: UUID,
        kind: ProviderKind,
        apiKey: String,
        baseURL: String?,
        forceRefresh: Bool = false
    ) async throws -> ProviderBalance {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKey.isEmpty == false else {
            throw BalanceQueryError.keyInvalid(detail: "Missing API key.")
        }
        let normalizedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if forceRefresh == false,
           let cached = entries[providerID],
           cached.apiKey == normalizedKey,
           cached.baseURL == normalizedBaseURL,
           now().timeIntervalSince(cached.balance.fetchedAt) < cacheTTL {
            return cached.balance
        }

        guard let service = serviceFactory(kind) else {
            throw BalanceQueryError.silentHidden(detail: "Balance is not supported for \(kind.rawValue).")
        }
        let balance: ProviderBalance
        do {
            balance = try await service.fetchBalance(
                apiKey: normalizedKey,
                baseURL: normalizedBaseURL.isEmpty ? nil : normalizedBaseURL
            )
        } catch let error as BalanceQueryError {
            // A rejected key, or a key that cannot read its balance, makes the last balance meaningless
            switch error {
            case .keyInvalid, .silentHidden:
                entries[providerID] = nil
            case .network, .decoding:
                break
            }
            throw error
        }
        entries[providerID] = CacheEntry(
            apiKey: normalizedKey,
            baseURL: normalizedBaseURL,
            balance: balance
        )
        return balance
    }

    /// The last balance fetched with the same key and endpoint, ignoring the TTL. The list shows it
    /// on the first frame and replaces it in place once the refresh lands.
    func cachedBalance(providerID: UUID, apiKey: String, baseURL: String?) -> ProviderBalance? {
        guard let cached = entries[providerID],
              cached.apiKey == apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
              cached.baseURL == (baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
            return nil
        }
        return cached.balance
    }

    /// Refresh for the provider list: network and decoding failures keep the last good balance,
    /// a rejected key yields nil.
    func loadForDisplay(
        providerID: UUID,
        kind: ProviderKind,
        apiKey: String,
        baseURL: String?
    ) async -> ProviderBalance? {
        do {
            return try await load(providerID: providerID, kind: kind, apiKey: apiKey, baseURL: baseURL)
        } catch {
            return cachedBalance(providerID: providerID, apiKey: apiKey, baseURL: baseURL)
        }
    }

    func removeMissingProviders(validIDs: Set<UUID>) {
        entries = entries.filter { validIDs.contains($0.key) }
    }

    func resetForTesting() {
        entries.removeAll()
    }

    private static func makeService(for kind: ProviderKind) -> (any BalanceQueryable)? {
        switch kind {
        case .openRouter: return OpenRouterService()
        case .siliconFlow: return SiliconFlowService()
        case .deepseek: return DeepSeekService()
        case .moonshot: return MoonshotService()
        default: return nil
        }
    }
}
