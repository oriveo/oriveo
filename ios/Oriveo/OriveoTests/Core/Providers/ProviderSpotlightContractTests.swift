import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Shared fixture `shared/test-fixtures/provider-catalog/provider-spotlight.v1.json`: one `PROVIDER_SPOTLIGHT_<id>` test per case.
/// Messages become delivered assistant messages of the current month in the fixture's shape, go through the production `CostSummaryCalculator.aggregates` (in memory) and
/// `ConversationStore.fetchMonthlyCostAggregates` (SQL) aggregation paths, and then `ProviderSpotlight.select` picks the featured card.
@Suite("ProviderSpotlightContract", .serialized, .sharedProcessState)
struct ProviderSpotlightContractTests {
    @Test("fixture ids match the PROVIDER_SPOTLIGHT_ tests one to one, and iOS shows 1 spotlight card")
    func fixtureIDsMatchTests() throws {
        let fixture = try Self.fixture()
        let ids = Set((fixture["cases"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        #expect(ids == [
            "cny_only_provider_can_win", "message_count_beats_usd_amount", "tie_breaks_by_usd_then_status",
            "full_tie_keeps_list_order", "no_cost_falls_back_to_status", "unrecorded_messages_not_counted",
        ])
        #expect(fixture["spotlightCount"]?["ios"]?.intValue == ProviderSpotlight.count)
    }

    @Test func PROVIDER_SPOTLIGHT_cny_only_provider_can_win() throws { try assertCase("cny_only_provider_can_win") }
    @Test func PROVIDER_SPOTLIGHT_message_count_beats_usd_amount() throws { try assertCase("message_count_beats_usd_amount") }
    @Test func PROVIDER_SPOTLIGHT_tie_breaks_by_usd_then_status() throws { try assertCase("tie_breaks_by_usd_then_status") }
    @Test func PROVIDER_SPOTLIGHT_full_tie_keeps_list_order() throws { try assertCase("full_tie_keeps_list_order") }
    @Test func PROVIDER_SPOTLIGHT_no_cost_falls_back_to_status() throws { try assertCase("no_cost_falls_back_to_status") }
    @Test func PROVIDER_SPOTLIGHT_unrecorded_messages_not_counted() throws { try assertCase("unrecorded_messages_not_counted") }

    // MARK: - Helpers

    private func assertCase(_ id: String) throws {
        let item = try #require(try Self.fixture()["cases"]?.arrayValue?.first { $0["id"]?.stringValue == id }, "\(id)")
        var providers: [Provider] = []
        var uuidByFixtureID: [String: UUID] = [:]
        for raw in item["providers"]?.arrayValue ?? [] {
            let fixtureID = try #require(raw["id"]?.stringValue)
            let kind = try #require(Self.providerKind(raw["kind"]?.stringValue), "\(id): kind")
            let provider = TestFactories.makeProvider(kind: kind, status: Self.status(raw["status"]?.stringValue))
            uuidByFixtureID[fixtureID] = provider.id
            providers.append(provider)
        }
        let fixtureIDByUUID = Dictionary(uniqueKeysWithValues: uuidByFixtureID.map { ($0.value, $0.key) })
        let kindByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.kind) })

        let now = Date()
        var messages: [ChatMessage] = []
        for raw in item["messages"]?.arrayValue ?? [] {
            let providerID = try #require(uuidByFixtureID[raw["providerId"]?.stringValue ?? ""], "\(id): providerId")
            var message = TestFactories.makeMessage(
                role: .assistant,
                providerID: providerID,
                providerKind: try #require(kindByID[providerID]),
                estimatedCost: try #require(raw["estimatedCost"]?.doubleValue),
                createdAt: now
            )
            message.costSource = Self.costSource(raw["costSource"]?.stringValue)
            if let part = raw["nonUsdCost"], part.objectValue != nil {
                message.nonUsdCost = NonUsdCost(
                    currencyCode: try #require(part["currencyCode"]?.stringValue),
                    amount: try #require(part["amount"]?.doubleValue),
                    costSource: try #require(Self.costSource(part["costSource"]?.stringValue))
                )
            }
            messages.append(message)
        }
        let conversation = TestFactories.makeConversation(
            providerID: providers.first?.id ?? UUID(),
            messages: messages,
            createdAt: now,
            updatedAt: now
        )
        let expected = item["expect"]?["spotlightProviderIds"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        let memory = CostSummaryCalculator.aggregates(from: [conversation], now: now)
        let fromMemory = ProviderSpotlight.select(
            providers: providers,
            activity: CostSummaryCalculator.monthlyActivityByProvider(from: memory)
        )
        #expect(fromMemory.compactMap { fixtureIDByUUID[$0.id] } == expected, "\(id): memory")

        let database = try SpotlightDatabase()
        defer { database.cleanup() }
        try database.store.upsertConversation(conversation)
        let stored = try database.store.fetchMonthlyCostAggregates(now: now)
        let fromStore = ProviderSpotlight.select(
            providers: providers,
            activity: CostSummaryCalculator.monthlyActivityByProvider(from: stored)
        )
        #expect(fromStore.compactMap { fixtureIDByUUID[$0.id] } == expected, "\(id): store")
        // The SQL and in-memory aggregation paths agree on the billed message count (amounts are floating-point sums and are not compared bit by bit).
        #expect(
            CostSummaryCalculator.monthlyActivityByProvider(from: stored).mapValues(\.billedMessageCount)
                == CostSummaryCalculator.monthlyActivityByProvider(from: memory).mapValues(\.billedMessageCount),
            "\(id): SQL and memory billed counts agree"
        )
    }

    /// Fixture wire vocabulary -> this platform's CostSource.
    private static func costSource(_ raw: String?) -> CostSource? {
        switch raw {
        case "upstream": return .upstream
        case "localEstimate", "estimated": return .localEstimate
        case "unknown": return .unknown
        default: return nil
        }
    }

    /// needsKey ranks as issue (iOS has no separate needsKey connection state).
    private static func status(_ raw: String?) -> ProviderConnectionState {
        switch raw {
        case "connected": return .connected
        case "syncing": return .syncing
        default: return .issue("fixture")
        }
    }

    private static func providerKind(_ raw: String?) -> ProviderKind? {
        guard let raw else { return nil }
        return ProviderKind(rawValue: raw) ?? ProviderKind.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
    }

    private static func fixture() throws -> JSONValue {
        try JSONValue(data: Data(contentsOf: sharedFixtureURL("provider-catalog/provider-spotlight.v1.json")))
    }
}

/// Temporary database (migrated to the latest schema) that uses the production `ConversationStore` writes and the monthly aggregation SQL.
private struct SpotlightDatabase {
    let rootURL: URL
    let store: ConversationStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-db-spotlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: rootURL.appendingPathComponent(DatabaseSchema.fileName).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let fileStore = AttachmentFileStore(rootDirectory: rootURL)
        try DatabaseSchema.makeMigrator(attachmentFileStore: fileStore).migrate(pool)
        store = ConversationStore(dbPool: pool, attachmentFileStore: fileStore)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
