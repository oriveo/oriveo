import Foundation
import Testing
@testable import Oriveo

@Suite("ProviderBalanceStore")
@MainActor
struct ProviderBalanceStoreTests {
    @Test("Last balance stays available for display past the TTL until the key or endpoint changes")
    func cachedBalanceIgnoresTTLButNotCredentials() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let service = StubBalanceService(
            balance: ProviderBalance(currency: "USD", total: 12.34, fetchedAt: now)
        )
        let store = ProviderBalanceStore(now: { now }, serviceFactory: { _ in service })
        let providerID = UUID()

        _ = try await store.load(
            providerID: providerID,
            kind: .deepseek,
            apiKey: "key-a",
            baseURL: "https://api.deepseek.com"
        )
        now = now.addingTimeInterval(60 * 60)

        #expect(store.cachedBalance(
            providerID: providerID,
            apiKey: " key-a ",
            baseURL: " https://api.deepseek.com "
        )?.total == 12.34)
        #expect(store.cachedBalance(providerID: providerID, apiKey: "key-b", baseURL: "https://api.deepseek.com") == nil)
        #expect(store.cachedBalance(providerID: providerID, apiKey: "key-a", baseURL: nil) == nil)
        #expect(store.cachedBalance(providerID: UUID(), apiKey: "key-a", baseURL: "https://api.deepseek.com") == nil)
    }

    @Test("Display refresh keeps the last balance on network errors and drops it once the key is rejected")
    func loadForDisplayFallsBackOnlyForTransientErrors() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let service = StubBalanceService(
            balance: ProviderBalance(currency: "CNY", total: 88, fetchedAt: now)
        )
        let store = ProviderBalanceStore(now: { now }, serviceFactory: { _ in service })
        let providerID = UUID()

        #expect(await store.loadForDisplay(
            providerID: providerID, kind: .deepseek, apiKey: "key", baseURL: nil
        )?.total == 88)

        // Expired and offline: keep showing the last balance, and keep it cached
        now = now.addingTimeInterval(10 * 60)
        service.error = .network(detail: "offline")
        #expect(await store.loadForDisplay(
            providerID: providerID, kind: .deepseek, apiKey: "key", baseURL: nil
        )?.total == 88)
        #expect(store.cachedBalance(providerID: providerID, apiKey: "key", baseURL: nil) != nil)

        // Key rejected: stop showing the old balance and drop it from the cache
        service.error = .keyInvalid(detail: "401")
        #expect(await store.loadForDisplay(
            providerID: providerID, kind: .deepseek, apiKey: "key", baseURL: nil
        ) == nil)
        #expect(store.cachedBalance(providerID: providerID, apiKey: "key", baseURL: nil) == nil)
        #expect(service.requests.count == 3)
    }

    private final class StubBalanceService: BalanceQueryable {
        struct Request {
            let apiKey: String
            let baseURL: String?
        }

        let balance: ProviderBalance
        var error: BalanceQueryError?
        private(set) var requests: [Request] = []

        init(balance: ProviderBalance) {
            self.balance = balance
        }

        func fetchBalance(apiKey: String, baseURL: String?) async throws -> ProviderBalance {
            requests.append(Request(apiKey: apiKey, baseURL: baseURL))
            if let error { throw error }
            return balance
        }
    }
}
