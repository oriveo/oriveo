import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Shared fixture `shared/test-fixtures/provider-pricing/cost-currency.v1.json`:
/// totalCases / migrationCases / displayCases, one `COST_CURRENCY_<id>` test per case.
/// Totals go through the production `CostSummaryCalculator` and `ConversationStore`, display goes through the
/// production `CostFormatter`, and migrations run the production migrator against a real GRDB database.
@Suite("CostCurrencyContract", .serialized, .sharedProcessState)
struct CostCurrencyContractTests {
    @Test("fixture ids match the COST_CURRENCY_ tests one to one")
    func fixtureIDsMatchTests() throws {
        let fixture = try Self.fixture()
        let ids = Set([
            "totalCases", "migrationCases", "displayCases",
        ].flatMap { group in
            (fixture[group]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        })
        let tests: Set<String> = [
            "mixed_totals_split_by_currency", "cny_only", "order_usd_then_code_ascending", "zero_currency_omitted",
            "mixed_message_split_into_both_totals", "nothing_recorded_is_empty",
            "tiny_parts_summed_before_epsilon", "negative_parts_not_added", "total_equal_to_epsilon_omitted",
            "existing_row_defaults_usd", "dropped_cny_stays_unknown", "legacy_currency_column_moved",
            "en_us_mixed", "zh_hans_mixed", "zh_hans_cny_only", "en_us_usd_only_unchanged", "zh_hans_small_cny_own_tier",
            "cny_half_rounds_away_from_zero", "mixed_message_two_parts", "second_non_usd_currency_part_not_available",
        ]
        #expect(ids == tests)
    }

    // MARK: totalCases

    @Test func COST_CURRENCY_mixed_totals_split_by_currency() throws { try assertTotals("mixed_totals_split_by_currency") }
    @Test func COST_CURRENCY_cny_only() throws { try assertTotals("cny_only") }
    @Test func COST_CURRENCY_order_usd_then_code_ascending() throws { try assertTotals("order_usd_then_code_ascending") }
    @Test func COST_CURRENCY_zero_currency_omitted() throws { try assertTotals("zero_currency_omitted") }
    @Test func COST_CURRENCY_mixed_message_split_into_both_totals() throws { try assertTotals("mixed_message_split_into_both_totals") }
    @Test func COST_CURRENCY_nothing_recorded_is_empty() throws { try assertTotals("nothing_recorded_is_empty") }
    @Test func COST_CURRENCY_tiny_parts_summed_before_epsilon() throws { try assertTotals("tiny_parts_summed_before_epsilon") }
    @Test func COST_CURRENCY_negative_parts_not_added() throws { try assertTotals("negative_parts_not_added") }
    @Test func COST_CURRENCY_total_equal_to_epsilon_omitted() throws { try assertTotals("total_equal_to_epsilon_omitted") }

    // MARK: migrationCases

    @Test func COST_CURRENCY_existing_row_defaults_usd() async throws { try await assertMigration("existing_row_defaults_usd") }
    @Test func COST_CURRENCY_dropped_cny_stays_unknown() async throws { try await assertMigration("dropped_cny_stays_unknown") }

    /// iOS never stored the single-currency `estimatedCostCurrency` shape: before the migration the message table has no
    /// such column, so there are no rows to move; after the migration the new shape (three columns) round-trips
    /// through the production store as expectAfter.
    @Test func COST_CURRENCY_legacy_currency_column_moved() async throws {
        let item = try Self.item("migrationCases", "legacy_currency_column_moved")
        let database = try LegacyDatabase()
        defer { database.cleanup() }
        let columns = try await database.pool.read { db in try db.columns(in: "message").map(\.name) }
        #expect(!columns.contains("estimatedCostCurrency"))
        try database.migrator.migrate(database.pool)

        let expectAfter = try #require(item["expectAfter"])
        var message = TestFactories.makeMessage(role: .assistant, estimatedCost: try #require(expectAfter["estimatedCost"]?.doubleValue))
        message.costSource = Self.costSource(expectAfter["costSource"])
        message.nonUsdCost = try Self.nonUsdCost(expectAfter["nonUsdCost"])
        let conversation = TestFactories.makeConversation(messages: [message])
        try database.store.upsertConversation(conversation)
        let restored = try #require(try database.store.fetchMessages(for: conversation.id).first)
        try Self.expectMessage(restored, matches: expectAfter, "legacy_currency_column_moved")
        let summary = try #require(try database.store.fetchConversationSummary(id: conversation.id))
        #expect(summary.nonUsdCostTotals == ["CNY": 0.0039])
        #expect(summary.estimatedCost == 0)
    }

    // MARK: displayCases

    @Test func COST_CURRENCY_en_us_mixed() throws { try assertDisplay("en_us_mixed") }
    @Test func COST_CURRENCY_zh_hans_mixed() throws { try assertDisplay("zh_hans_mixed") }
    @Test func COST_CURRENCY_zh_hans_cny_only() throws { try assertDisplay("zh_hans_cny_only") }
    @Test func COST_CURRENCY_en_us_usd_only_unchanged() throws { try assertDisplay("en_us_usd_only_unchanged") }
    @Test func COST_CURRENCY_zh_hans_small_cny_own_tier() throws { try assertDisplay("zh_hans_small_cny_own_tier") }
    @Test func COST_CURRENCY_cny_half_rounds_away_from_zero() throws { try assertDisplay("cny_half_rounds_away_from_zero") }
    @Test func COST_CURRENCY_mixed_message_two_parts() throws { try assertDisplay("mixed_message_two_parts") }
    @Test func COST_CURRENCY_second_non_usd_currency_part_not_available() throws {
        try assertDisplay("second_non_usd_currency_part_not_available")
    }

    // MARK: - Helpers

    private func assertDisplay(_ id: String) throws {
        let item = try Self.item("displayCases", id)
        let parts = try #require(item["parts"]?.arrayValue)
        for part in parts {
            let amount = try #require(part["amount"]?.doubleValue)
            #expect(CostFormatter.fractionDigits(amount) == part["fractionDigits"]?.intValue, "\(id): digits of \(amount)")
        }
        let nonUsd: NonUsdCost?
        let usd: Double
        if let message = item["message"] {
            usd = try #require(message["estimatedCost"]?.doubleValue)
            nonUsd = try Self.nonUsdCost(message["nonUsdCost"])
        } else {
            usd = parts.first { $0["currencyCode"]?.stringValue == "USD" }?["amount"]?.doubleValue ?? 0
            nonUsd = try parts.first { $0["currencyCode"]?.stringValue != "USD" }.map { part in
                NonUsdCost(
                    currencyCode: try #require(part["currencyCode"]?.stringValue),
                    amount: try #require(part["amount"]?.doubleValue),
                    costSource: .localEstimate
                )
            }
        }
        let locale = Locale(identifier: try #require(item["locale"]?.stringValue))
        let text = CostFormatter.format(parts: CostFormatter.parts(estimatedCost: usd, nonUsdCost: nonUsd), locale: locale)
        #expect(text == item["expect"]?.stringValue, "\(id): got \(text)")
        let notAvailable = item["notAvailableParts"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(CostFormatter.notAvailableParts(nonUsd) == notAvailable, "\(id)")

        // Totals use the same formatting (conversation row / summary / provider card): the non-USD parts go into nonUsdTotals.
        if item["message"] == nil {
            let totals = Dictionary(uniqueKeysWithValues: parts
                .filter { $0["currencyCode"]?.stringValue != "USD" }
                .compactMap { part in part["currencyCode"]?.stringValue.map { ($0, part["amount"]?.doubleValue ?? 0) } })
            let totalsText = CostFormatter.format(parts: CostFormatter.parts(usd: usd, nonUsdTotals: totals), locale: locale)
            #expect(totalsText == item["expect"]?.stringValue, "\(id): totals got \(totalsText)")
        }
    }

    private func assertTotals(_ id: String) throws {
        let item = try Self.item("totalCases", id)
        var messages: [ChatMessage] = []
        for raw in item["messages"]?.arrayValue ?? [] {
            var message = TestFactories.makeMessage(role: .assistant, estimatedCost: try #require(raw["estimatedCost"]?.doubleValue))
            message.costSource = Self.costSource(raw["costSource"])
            message.nonUsdCost = try Self.nonUsdCost(raw["nonUsdCost"])
            messages.append(message)
        }
        let totals = CostSummaryCalculator.conversationTotals(of: messages)
        let parts = (totals.estimatedCost > 0 ? [CurrencyAmount(currencyCode: CostCalculator.usd, amount: totals.estimatedCost)] : [])
            + totals.nonUsdCostTotals.sorted { $0.key < $1.key }.map { CurrencyAmount(currencyCode: $0.key, amount: $0.value) }
        let expected = try #require(item["expect"]?["parts"]?.arrayValue)
        #expect(parts.map(\.currencyCode) == expected.compactMap { $0["currencyCode"]?.stringValue }, "\(id): got \(parts)")
        for (part, want) in zip(parts, expected) {
            let amount = try #require(want["amount"]?.doubleValue)
            #expect(abs(part.amount - amount) < 1e-9, "\(id): \(part.currencyCode) got \(part.amount), want \(amount)")
        }

        // Conversation row: the USD total reads estimatedCost, and the non-USD totals are recomputed per currency from the local messages and stored.
        let database = try LegacyDatabase(migrateAll: true)
        defer { database.cleanup() }
        let conversation = TestFactories.makeConversation(messages: messages)
        try database.store.upsertConversation(conversation)
        let summary = try #require(try database.store.fetchConversationSummary(id: conversation.id))
        let usd = parts.first { $0.currencyCode == "USD" }?.amount ?? 0
        #expect(abs(summary.estimatedCost - usd) < 1e-9, "\(id): conversation USD \(summary.estimatedCost)")
        let nonUsd = Dictionary(uniqueKeysWithValues: parts.filter { $0.currencyCode != "USD" }.map { ($0.currencyCode, $0.amount) })
        #expect(summary.nonUsdCostTotals.keys.sorted() == nonUsd.keys.sorted(), "\(id): \(summary.nonUsdCostTotals)")
        for (code, amount) in nonUsd {
            #expect(abs((summary.nonUsdCostTotals[code] ?? -1) - amount) < 1e-9, "\(id): \(code)")
        }
    }

    /// Inserts one row shaped as `before` into a database at the pre-v43 schema (v42), migrates to the latest, then reads it back through the production store.
    private func assertMigration(_ id: String) async throws {
        let item = try Self.item("migrationCases", id)
        let before = try #require(item["before"])
        let database = try LegacyDatabase()
        defer { database.cleanup() }
        let conversationID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation (id, title, providerID, providerKind, modelID, createdAt, updatedAt)
                    VALUES (?, 'Legacy Cost', ?, 'openAI', 'gpt-4.1', 1, 1)
                    """,
                arguments: [conversationID.uuidString, UUID().uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO message (id, conversationID, role, text, providerKind, providerName, modelName, state,
                                         providerMode, estimatedCost, costSource)
                    VALUES (?, ?, 'assistant', 'legacy', 'openAI', 'OpenAI', 'GPT-4.1', 'delivered', 'byok', ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, conversationID.uuidString,
                    before["estimatedCost"]?.doubleValue ?? 0,
                    Self.costSource(before["costSource"])?.rawValue,
                ]
            )
        }
        try database.migrator.migrate(database.pool)
        let restored = try #require(try database.store.fetchMessages(for: conversationID).first)
        try Self.expectMessage(restored, matches: try #require(item["expectAfter"]), id)
    }

    private static func expectMessage(_ message: ChatMessage, matches expect: JSONValue, _ id: String) throws {
        let estimatedCost = try #require(expect["estimatedCost"]?.doubleValue)
        #expect(abs(message.estimatedCost - estimatedCost) < 1e-12, "\(id)")
        if expect["costSource"] != nil {
            #expect(message.costSource == costSource(expect["costSource"]), "\(id): got \(String(describing: message.costSource))")
        }
        try expectNonUsdCost(message.nonUsdCost, matches: expect["nonUsdCost"], id)
    }

    private static func expectNonUsdCost(_ actual: NonUsdCost?, matches expect: JSONValue?, _ id: String) throws {
        guard let want = try nonUsdCost(expect) else {
            #expect(actual == nil, "\(id): got \(String(describing: actual))")
            return
        }
        let got = try #require(actual, "\(id): nonUsdCost missing")
        #expect(got.currencyCode == want.currencyCode, "\(id)")
        #expect(abs(got.amount - want.amount) < 1e-12, "\(id): got \(got.amount)")
        #expect(got.costSource == want.costSource, "\(id)")
    }

    /// Fixture source vocabulary: `estimated` = this client's local estimate (`.localEstimate`).
    private static func costSource(_ value: JSONValue?) -> CostSource? {
        switch value?.stringValue {
        case "estimated": return .localEstimate
        case "unknown": return .unknown
        case "upstream": return .upstream
        case "subscription": return .subscription
        default: return nil
        }
    }

    private static func nonUsdCost(_ value: JSONValue?) throws -> NonUsdCost? {
        guard let value, value.objectValue != nil else { return nil }
        return NonUsdCost(
            currencyCode: try #require(value["currencyCode"]?.stringValue),
            amount: try #require(value["amount"]?.doubleValue),
            costSource: try #require(costSource(value["costSource"]))
        )
    }

    private static func fixture() throws -> JSONValue {
        try JSONValue(data: Data(contentsOf: sharedFixtureURL("provider-pricing/cost-currency.v1.json")))
    }

    private static func item(_ group: String, _ id: String) throws -> JSONValue {
        try #require(try fixture()[group]?.arrayValue?.first { $0["id"]?.stringValue == id }, "\(group).\(id)")
    }
}

/// Temporary database: by default migrated only to v42 (the shape before v43); `migrateAll` migrates to the latest.
private struct LegacyDatabase {
    let rootURL: URL
    let pool: DatabasePool
    let migrator: DatabaseMigrator
    let store: ConversationStore

    init(migrateAll: Bool = false, upTo target: String? = nil) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-db-cost-currency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        pool = try DatabasePool(
            path: rootURL.appendingPathComponent(DatabaseSchema.fileName).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        // Attachments live in a subdirectory: replaceAllConversations prunes the attachment root, and sharing the directory with the database file would delete the database.
        let fileStore = AttachmentFileStore(rootDirectory: rootURL.appendingPathComponent("files", isDirectory: true))
        migrator = DatabaseSchema.makeMigrator(attachmentFileStore: fileStore)
        if migrateAll {
            try migrator.migrate(pool)
        } else if let target {
            try migrator.migrate(pool, upTo: target)
        } else {
            try migrator.migrate(pool, upTo: "v42_tool_call_memory_facts_revision")
        }
        store = ConversationStore(dbPool: pool, attachmentFileStore: fileStore)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
