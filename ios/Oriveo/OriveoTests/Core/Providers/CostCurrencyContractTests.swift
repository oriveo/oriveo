import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Shared fixture `shared/test-fixtures/provider-pricing/cost-currency.v1.json`:
/// recordCases / totalCases / migrationCases / displayCases / ledgerAmountCases / relayPricingCases / multiLegCostCases: one `COST_CURRENCY_<id>` test per case.
/// Recorded amounts all come from real metadata JSON through the production `MetadataClient.calcCost` (service basis) and
/// `ChatDeliveryAccounting.generationCost` / `record`; totals go through the production `CostSummaryCalculator` and `ConversationStore`;
/// display goes through the production `CostFormatter`.
@Suite("CostCurrencyContract", .serialized, .sharedProcessState)
struct CostCurrencyContractTests {
    @Test("fixture ids match the COST_CURRENCY_ tests one to one")
    func fixtureIDsMatchTests() throws {
        let fixture = try Self.fixture()
        let ids = Set([
            "recordCases", "totalCases", "migrationCases", "displayCases", "relayPricingCases", "multiLegCostCases",
            "ledgerAmountCases",
        ].flatMap { group in
            (fixture[group]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        })
        // Community build: no library / skill retrieval part and no multi-leg runner, so these fixture cases have no test here.
        let unsupported: Set<String> = [
            "mixed_cny_generation_usd_retrieval", "second_non_usd_currency_marks_unknown",
            "all_legs_reported_sum", "one_leg_without_usage_is_unknown", "tail_leg_upstream_cost_added",
            "legs_in_two_currencies_record_both_parts", "cached_tokens_in_tool_leg_priced_as_cache",
            "subscription_connection_legs_are_subscription", "two_non_usd_currencies_marks_non_usd_unknown",
            "all_legs_upstream_is_upstream", "per_image_counted_once_across_legs",
            "per_image_partial_upstream_estimates_by_units", "per_image_relay_legs_with_upstream_estimated_once",
        ]
        let tests: Set<String> = [
            "usd_estimate_recorded", "missing_currency_is_usd", "cny_estimate_recorded_in_cny", "lowercase_code_normalized",
            "unavailable_not_recorded", "mixed_totals_split_by_currency",
            "cny_only", "order_usd_then_code_ascending", "zero_currency_omitted", "mixed_message_split_into_both_totals",
            "nothing_recorded_is_empty", "existing_row_defaults_usd", "dropped_cny_stays_unknown", "legacy_currency_column_moved",
            "en_us_mixed", "zh_hans_mixed", "zh_hans_cny_only", "en_us_usd_only_unchanged",
            "zh_hans_small_cny_own_tier", "mixed_message_two_parts", "second_non_usd_currency_part_not_available", "de_usd_small_locale_currency",
            "de_usd_grouping", "fr_usd_no_us_suffix", "ja_usd", "ar_usd_latin_digits",
            "pt_br_usd_no_us_prefix", "de_mixed_usd_cny", "usd_half_rounds_away_from_zero", "relay_matched_usd_uses_pricing_v2",
            "relay_matched_cny_records_native_currency", "relay_unmatched_uses_local_price", "relay_unmatched_without_price_is_unknown", "relay_ignores_upstream_cost",
            "official_upstream_cost_zero_is_upstream_zero", "relay_matched_without_price_is_unknown", "relay_matched_time_window", "relay_matched_cache_fallback_ratio",
            "relay_matched_via_canonical_id", "relay_without_usage_is_unknown", "official_v2_unavailable_no_local_fallback", "relay_matched_usd_time_window",
            "relay_zero_token_usage_is_zero_estimate", "official_per_image_without_usage_estimates_by_units", "official_matched_without_price_is_unknown", "official_matched_status_unknown_with_v2_is_unknown",
            "per_image_zero_units_is_unknown", "per_image_upstream_cost_wins", "per_image_free_entry_is_zero",
            "tiny_parts_summed_before_epsilon", "cny_half_rounds_away_from_zero",
            "negative_parts_not_added", "total_equal_to_epsilon_omitted", "ledger_en_purchase", "ledger_en_small_charge",
            "ledger_en_zero", "ledger_en_one_micro_charge", "ledger_en_whole_dollars", "ledger_en_grouping_negative",
            "ledger_de_purchase", "ledger_de_small_charge", "ledger_de_zero", "ledger_de_one_micro_charge",
            "ledger_de_whole_dollars", "ledger_de_grouping_negative", "ledger_ar_purchase", "ledger_ar_small_charge",
            "ledger_ar_zero", "ledger_ar_one_micro_charge", "ledger_ar_whole_dollars", "ledger_ar_grouping_negative",
            "ledger_en_grouping_positive", "ledger_en_six_digits", "ledger_de_grouping_positive", "ledger_de_six_digits",
            "ledger_ar_grouping_positive", "ledger_ar_six_digits",
        ]
        #expect(ids.subtracting(unsupported) == tests)
    }

    // MARK: recordCases

    @Test func COST_CURRENCY_usd_estimate_recorded() async throws { try await assertRecord("usd_estimate_recorded") }
    @Test func COST_CURRENCY_missing_currency_is_usd() async throws { try await assertRecord("missing_currency_is_usd") }
    @Test func COST_CURRENCY_cny_estimate_recorded_in_cny() async throws { try await assertRecord("cny_estimate_recorded_in_cny") }
    @Test func COST_CURRENCY_lowercase_code_normalized() async throws { try await assertRecord("lowercase_code_normalized") }
    @Test func COST_CURRENCY_unavailable_not_recorded() async throws { try await assertRecord("unavailable_not_recorded") }

    // MARK: relayPricingCases

    @Test func COST_CURRENCY_relay_matched_usd_uses_pricing_v2() async throws { try await assertRelay("relay_matched_usd_uses_pricing_v2") }
    @Test func COST_CURRENCY_relay_matched_cny_records_native_currency() async throws {
        try await assertRelay("relay_matched_cny_records_native_currency")
    }
    @Test func COST_CURRENCY_relay_unmatched_uses_local_price() async throws { try await assertRelay("relay_unmatched_uses_local_price") }
    @Test func COST_CURRENCY_relay_unmatched_without_price_is_unknown() async throws {
        try await assertRelay("relay_unmatched_without_price_is_unknown")
    }
    @Test func COST_CURRENCY_relay_ignores_upstream_cost() async throws { try await assertRelay("relay_ignores_upstream_cost") }
    @Test func COST_CURRENCY_official_upstream_cost_zero_is_upstream_zero() async throws {
        try await assertRelay("official_upstream_cost_zero_is_upstream_zero")
    }

    @Test func COST_CURRENCY_relay_matched_without_price_is_unknown() async throws {
        try await assertRelay("relay_matched_without_price_is_unknown")
    }
    @Test func COST_CURRENCY_relay_matched_time_window() async throws { try await assertRelay("relay_matched_time_window") }
    @Test func COST_CURRENCY_relay_matched_cache_fallback_ratio() async throws {
        try await assertRelay("relay_matched_cache_fallback_ratio")
    }
    @Test func COST_CURRENCY_relay_matched_via_canonical_id() async throws { try await assertRelay("relay_matched_via_canonical_id") }
    @Test func COST_CURRENCY_relay_without_usage_is_unknown() async throws { try await assertRelay("relay_without_usage_is_unknown") }
    @Test func COST_CURRENCY_official_v2_unavailable_no_local_fallback() async throws {
        try await assertRelay("official_v2_unavailable_no_local_fallback")
    }
    @Test func COST_CURRENCY_official_matched_without_price_is_unknown() async throws {
        try await assertRelay("official_matched_without_price_is_unknown")
    }
    @Test func COST_CURRENCY_official_matched_status_unknown_with_v2_is_unknown() async throws {
        try await assertRelay("official_matched_status_unknown_with_v2_is_unknown")
    }
    @Test func COST_CURRENCY_relay_zero_token_usage_is_zero_estimate() async throws {
        try await assertRelay("relay_zero_token_usage_is_zero_estimate")
    }
    @Test func COST_CURRENCY_relay_matched_usd_time_window() async throws { try await assertRelay("relay_matched_usd_time_window") }
    @Test func COST_CURRENCY_official_per_image_without_usage_estimates_by_units() async throws {
        try await assertRelay("official_per_image_without_usage_estimates_by_units")
    }
    @Test func COST_CURRENCY_per_image_zero_units_is_unknown() async throws { try await assertRelay("per_image_zero_units_is_unknown") }
    @Test func COST_CURRENCY_per_image_upstream_cost_wins() async throws { try await assertRelay("per_image_upstream_cost_wins") }
    @Test func COST_CURRENCY_per_image_free_entry_is_zero() async throws { try await assertRelay("per_image_free_entry_is_zero") }

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

    /// iOS never stored the single-currency `estimatedCostCurrency` shape (that is the Android DB 46 shape): the pre-migration message table has no such column,
    /// so no rows need moving; the new three-column shape after migration round-trips through the production store, which is expectAfter.
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
    @Test func COST_CURRENCY_de_usd_small_locale_currency() throws { try assertDisplay("de_usd_small_locale_currency") }
    @Test func COST_CURRENCY_de_usd_grouping() throws { try assertDisplay("de_usd_grouping") }
    @Test func COST_CURRENCY_fr_usd_no_us_suffix() throws { try assertDisplay("fr_usd_no_us_suffix") }
    @Test func COST_CURRENCY_ja_usd() throws { try assertDisplay("ja_usd") }
    @Test func COST_CURRENCY_ar_usd_latin_digits() throws { try assertDisplay("ar_usd_latin_digits") }
    @Test func COST_CURRENCY_pt_br_usd_no_us_prefix() throws { try assertDisplay("pt_br_usd_no_us_prefix") }
    @Test func COST_CURRENCY_de_mixed_usd_cny() throws { try assertDisplay("de_mixed_usd_cny") }
    @Test func COST_CURRENCY_usd_half_rounds_away_from_zero() throws { try assertDisplay("usd_half_rounds_away_from_zero") }

    // MARK: ledgerAmountCases

    @Test func COST_CURRENCY_ledger_en_purchase() throws { try assertLedgerAmount("ledger_en_purchase") }
    @Test func COST_CURRENCY_ledger_en_small_charge() throws { try assertLedgerAmount("ledger_en_small_charge") }
    @Test func COST_CURRENCY_ledger_en_zero() throws { try assertLedgerAmount("ledger_en_zero") }
    @Test func COST_CURRENCY_ledger_en_one_micro_charge() throws { try assertLedgerAmount("ledger_en_one_micro_charge") }
    @Test func COST_CURRENCY_ledger_en_whole_dollars() throws { try assertLedgerAmount("ledger_en_whole_dollars") }
    @Test func COST_CURRENCY_ledger_en_grouping_negative() throws { try assertLedgerAmount("ledger_en_grouping_negative") }
    @Test func COST_CURRENCY_ledger_de_purchase() throws { try assertLedgerAmount("ledger_de_purchase") }
    @Test func COST_CURRENCY_ledger_de_small_charge() throws { try assertLedgerAmount("ledger_de_small_charge") }
    @Test func COST_CURRENCY_ledger_de_zero() throws { try assertLedgerAmount("ledger_de_zero") }
    @Test func COST_CURRENCY_ledger_de_one_micro_charge() throws { try assertLedgerAmount("ledger_de_one_micro_charge") }
    @Test func COST_CURRENCY_ledger_de_whole_dollars() throws { try assertLedgerAmount("ledger_de_whole_dollars") }
    @Test func COST_CURRENCY_ledger_de_grouping_negative() throws { try assertLedgerAmount("ledger_de_grouping_negative") }
    @Test func COST_CURRENCY_ledger_ar_purchase() throws { try assertLedgerAmount("ledger_ar_purchase") }
    @Test func COST_CURRENCY_ledger_ar_small_charge() throws { try assertLedgerAmount("ledger_ar_small_charge") }
    @Test func COST_CURRENCY_ledger_ar_zero() throws { try assertLedgerAmount("ledger_ar_zero") }
    @Test func COST_CURRENCY_ledger_ar_one_micro_charge() throws { try assertLedgerAmount("ledger_ar_one_micro_charge") }
    @Test func COST_CURRENCY_ledger_ar_whole_dollars() throws { try assertLedgerAmount("ledger_ar_whole_dollars") }
    @Test func COST_CURRENCY_ledger_ar_grouping_negative() throws { try assertLedgerAmount("ledger_ar_grouping_negative") }
    @Test func COST_CURRENCY_ledger_en_grouping_positive() throws { try assertLedgerAmount("ledger_en_grouping_positive") }
    @Test func COST_CURRENCY_ledger_en_six_digits() throws { try assertLedgerAmount("ledger_en_six_digits") }
    @Test func COST_CURRENCY_ledger_de_grouping_positive() throws { try assertLedgerAmount("ledger_de_grouping_positive") }
    @Test func COST_CURRENCY_ledger_de_six_digits() throws { try assertLedgerAmount("ledger_de_six_digits") }
    @Test func COST_CURRENCY_ledger_ar_grouping_positive() throws { try assertLedgerAmount("ledger_ar_grouping_positive") }
    @Test func COST_CURRENCY_ledger_ar_six_digits() throws { try assertLedgerAmount("ledger_ar_six_digits") }

    @Test func v44MigrationDefaultsLocalThreadIncomplete() async throws {
        let database = try LegacyDatabase(upTo: "v43_message_non_usd_cost")
        defer { database.cleanup() }
        let conversationID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation (id, title, providerID, providerKind, modelID, createdAt, updatedAt)
                    VALUES (?, 'Legacy Thread', ?, 'openAI', 'gpt-4.1', 1, 1)
                    """,
                arguments: [conversationID.uuidString, UUID().uuidString]
            )
        }
        try database.migrator.migrate(database.pool)
        let summary = try #require(try database.store.fetchConversationSummary(id: conversationID))
        #expect(summary.localThreadComplete == false)
    }

    /// A backup carries nonUsdCostTotals without the thread-complete marker: totals survive the round trip and the marker reads as false; merging an older backup that lacks the key leaves local data untouched.
    @Test func backupCarriesNonUsdTotalsAndRestoresIncomplete() throws {
        var conversation = TestFactories.makeConversation(estimatedCost: 1.0)
        conversation.nonUsdCostTotals = ["CNY": 2.0]
        let encoded = try JSONEncoder().encode(BackupConversation(from: conversation))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["nonUsdCostTotals"] as? [String: Double] == ["CNY": 2.0])
        #expect(object["localThreadComplete"] == nil)
        let restored = try JSONDecoder().decode(BackupConversation.self, from: encoded).toConversation()
        #expect(restored.nonUsdCostTotals == ["CNY": 2.0])

        var legacy = try JSONDecoder().decode(BackupConversation.self, from: encoded)
        legacy.nonUsdCostTotals = nil
        legacy.updatedAt = Date.distantFuture
        var local = TestFactories.makeConversation(estimatedCost: 0.5)
        local.nonUsdCostTotals = ["CNY": 9.0]
        BackupService.applyMergeMetadata(from: legacy, localUpdatedAt: local.updatedAt, into: &local)
        #expect(local.nonUsdCostTotals == ["CNY": 9.0])
        #expect(local.estimatedCost == 1.0)
    }

    // MARK: - Helpers

    /// The USD part goes through `CostFormatter.format` ("$" with current precision); non-USD parts go through `.currency(code:)` (UI locale, standard symbols).
    /// Fixture comparison normalization: drop bidi marks (U+200E / U+200F / U+061C) and turn
    /// NBSP / narrow NBSP into a plain space.
    static func normalizedDisplay(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            switch scalar.value {
            case 0x200E, 0x200F, 0x061C: return nil
            case 0x00A0, 0x202F: return " "
            default: return scalar
            }
        }))
    }

    /// Wallet ledger row amount via production `CostFormatter.managedLedgerMicroUSD`, normalized like displayCases.
    private func assertLedgerAmount(_ id: String) throws {
        let item = try Self.item("ledgerAmountCases", id)
        let micro = try #require(item["amountMicrousd"]?.doubleValue, "\(id).amountMicrousd")
        let locale = Locale(identifier: try #require(item["locale"]?.stringValue))
        let text = Self.normalizedDisplay(CostFormatter.managedLedgerMicroUSD(Int64(micro), locale: locale))
        #expect(text == item["expect"]?.stringValue, "\(id): got \(text)")
    }

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
        let raw = CostFormatter.format(parts: CostFormatter.parts(estimatedCost: usd, nonUsdCost: nonUsd), locale: locale)
        let text = Self.normalizedDisplay(raw)
        #expect(text == item["expect"]?.stringValue, "\(id): got \(text)")
        let notAvailable = item["notAvailableParts"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(CostFormatter.notAvailableParts(nonUsd) == notAvailable, "\(id)")

        // Totals (conversation row / summary / provider card) use the same formatting: non-USD parts go into nonUsdTotals.
        if item["message"] == nil {
            let totals = Dictionary(uniqueKeysWithValues: parts
                .filter { $0["currencyCode"]?.stringValue != "USD" }
                .compactMap { part in part["currencyCode"]?.stringValue.map { ($0, part["amount"]?.doubleValue ?? 0) } })
            let totalsText = Self.normalizedDisplay(
                CostFormatter.format(parts: CostFormatter.parts(usd: usd, nonUsdTotals: totals), locale: locale)
            )
            #expect(totalsText == item["expect"]?.stringValue, "\(id): totals got \(totalsText)")
        }
    }

    /// Each generated part is one real delivered leg: a model in metadata (model-level currencyCode + a 1M-input price of amount/M),
    /// the service basis goes through `MetadataClient.calcCost`, and delivery goes through `ChatDeliveryAccounting.generationCost`;
    /// The legs are added and then composed into the stored shape through `record`.
    private func assertRecord(_ id: String) async throws {
        let item = try Self.item("recordCases", id)
        let estimates = try item["estimates"]?.arrayValue ?? [#require(item["estimate"])]
        var legs: [(id: String, estimate: JSONValue)] = []
        for (index, estimate) in estimates.enumerated() {
            legs.append(("leg-\(index)", estimate))
        }
        let client = try await Self.loadCatalog(legs)
        let provider = TestFactories.makeProvider(kind: .anthropic, models: [])
        let breakdown = UsageBreakdown(promptTokens: 1_000_000, completionTokens: 0)
        var delivered = DeliveredCost()
        for leg in legs {
            let (cost, source) = await client.calcCost(breakdown: breakdown, modelID: leg.id, providerKind: .anthropic, at: Date())
            delivered = delivered + ChatDeliveryAccounting.generationCost(
                result: ProviderChatResult(
                    text: "answer",
                    promptTokens: 1_000_000,
                    completionTokens: 0,
                    estimatedCost: cost,
                    usageBreakdown: breakdown,
                    usageReported: true,
                    costSource: source
                ),
                model: TestFactories.makeModel(id: leg.id),
                provider: provider,
                at: Date()
            )
        }
        let record = ChatDeliveryAccounting.record(delivered)

        let expect = try #require(item["expect"])
        if expect["recorded"]?.boolValue == false {
            // Not recorded = price unknown (shown as "unavailable"), not 0, and it produces no non-USD part.
            #expect(record == MessageCostRecord(estimatedCost: 0, costSource: .unknown, nonUsdCost: nil), "\(id): got \(record)")
            return
        }
        let estimatedCost = try #require(expect["estimatedCost"]?.doubleValue)
        #expect(abs(record.estimatedCost - estimatedCost) < 1e-12, "\(id): got \(record.estimatedCost)")
        #expect(record.costSource == Self.costSource(expect["costSource"]), "\(id): got \(String(describing: record.costSource))")
        try Self.expectNonUsdCost(record.nonUsdCost, matches: expect["nonUsdCost"], id)
    }

    /// A real delivery over a Relay connection: the matched entry is placed in the metadata of the allowlisted official provider (openAI), and the Relay model id defaults to its
    /// canonicalModelId (literal match); when relayModelId is given, the model stores that id and canonicalModelId records the matched entry; the local price lives on
    /// the Relay model. With connection = official, the same record goes through the matched provider's (openAI) official connection. The service basis goes through
    /// `MetadataClient.calcCost`, and delivery goes through `ChatDeliveryAccounting.generationCost` (the pricing time is injected from the fixture `at`) and `record` composes the stored shape.
    private func assertRelay(_ id: String) async throws {
        let item = try Self.rawItem("relayPricingCases", id)
        let match = item["catalogMatch"] as? [String: Any]
        let client = try await Self.loadRelayMatchCatalog(match)
        let canonicalID = match?["canonicalModelId"] as? String
        let modelID = (item["relayModelId"] as? String) ?? canonicalID ?? "relay-local-model"
        let official = item["connection"] as? String == "official"
        let kind: ProviderKind = official ? .openAI : .relay
        var model = TestFactories.makeModel(id: modelID)
        if modelID != canonicalID { model.canonicalModelId = canonicalID }
        model.promptPrice = nil
        model.completionPrice = nil
        if let local = item["localPrice"] as? [String: Any] {
            model.promptPrice = try #require(local["inputPerMToken"] as? Double) / 1_000_000
            model.completionPrice = try #require(local["outputPerMToken"] as? Double) / 1_000_000
        }
        let usage = item["usage"] as? [String: Any]
        func tokens(_ key: String) throws -> Int { usage == nil ? 0 : try #require(usage?[key] as? Int, "\(id).\(key)") }
        let upstream = item["upstreamCost"] as? [String: Any]
        let breakdown = UsageBreakdown(
            promptTokens: try tokens("uncachedInputTokens"),
            cachedInputTokens: try tokens("cacheReadTokens"),
            cacheCreation5mTokens: try tokens("cacheWrite5mTokens"),
            cacheCreation1hTokens: try tokens("cacheWrite1hTokens"),
            completionTokens: try tokens("outputTokens"),
            upstreamCost: upstream?["amount"] as? Double
        )
        let atText = try #require(item["at"] as? String)
        let at = try #require(ISO8601DateFormatter().date(from: atText))
        let (cost, source) = await client.calcCost(breakdown: breakdown, modelID: modelID, providerKind: kind, at: at)
        let relay = TestFactories.makeProvider(kind: kind, models: [model])
        // The upstream gave no usage object: the response body goes through production decoding and usage parsing, and "usage received" comes from the parser's explicit signal;
        // the parsed empty breakdown is still handed to the delivery layer (same shape as production).
        let parsedWithoutUsage = usage == nil
            ? try OpenAIService.chatCompletionUsageForTesting(
                responseBody: Data(#"{"choices":[{"message":{"content":"answer"}}]}"#.utf8)
            )
            : nil
        // Per-unit pricing: units = the number of images generated this time (production `billedUnits` counts them from the result attachments).
        let generatedImages = ((item["units"] as? Int).map { units in
            (0 ..< units).map { Attachment(id: UUID(), kind: .image, fileName: "image-\($0).png", mimeType: "image/png") }
        })
        let record = ChatDeliveryAccounting.record(ChatDeliveryAccounting.generationCost(
            result: ProviderChatResult(
                text: "answer",
                promptTokens: breakdown.promptTokens,
                completionTokens: breakdown.completionTokens,
                estimatedCost: cost,
                attachments: generatedImages,
                usageBreakdown: parsedWithoutUsage?.breakdown ?? breakdown,
                usageReported: parsedWithoutUsage?.reported ?? true,
                costSource: source
            ),
            model: model,
            provider: relay,
            metadata: client,
            at: at
        ))
        #expect(
            (ChatDeliveryAccounting.catalogModel(model: model, provider: relay, metadata: client) != nil) == (match != nil),
            "\(id): relay official match"
        )

        let expect = try JSONValue(data: JSONSerialization.data(withJSONObject: try #require(item["expect"])))
        let estimatedCost = try #require(expect["estimatedCost"]?.doubleValue)
        #expect(abs(record.estimatedCost - estimatedCost) < 1e-12, "\(id): got \(record.estimatedCost)")
        #expect(record.costSource == Self.costSource(expect["costSource"]), "\(id): got \(String(describing: record.costSource))")
        try Self.expectNonUsdCost(record.nonUsdCost, matches: expect["nonUsdCost"], id)
    }

    /// Matched entry = the catalog model under the allowlisted official provider openAI (pricingStatus priced, currency taken from pricingV2); when nothing matches, an unrelated model is placed.
    /// `extraMatches`: more entries placed in the same catalog (one model id per leg when each leg carries its own entry); `providerKey`: the official provider the entry belongs to.
    private static func loadRelayMatchCatalog(
        _ match: [String: Any]?,
        extraMatches: [[String: Any]] = [],
        providerKey: String = "openAI"
    ) async throws -> MetadataClient {
        var models: [String: Any] = [
            "unrelated-official": [
                "canonicalModelId": "unrelated-official",
                "displayName": "unrelated-official",
                "pricingUnit": "per_token",
                "pricingStatus": "unknown",
                "capabilities": ["text"],
            ] as [String: Any],
        ]
        var resolveMap: [String: String] = ["unrelated-official": "unrelated-official"]
        for match in ([match].compactMap { $0 } + extraMatches) {
            let id = try #require(match["canonicalModelId"] as? String)
            // The matched entry may be entirely unpriced (pricingV2 = null, with pricingStatus given by the fixture).
            var entry: [String: Any] = [
                "canonicalModelId": id,
                "displayName": id,
                "pricingUnit": (match["pricingUnit"] as? String) ?? "per_token",
                "pricingStatus": (match["pricingStatus"] as? String) ?? "priced",
                "capabilities": ["text"],
            ]
            // Legacy per-unit price (catalogMatch.perUnitPrice) = catalog pricing.costPerUnit.
            if let perUnitPrice = match["perUnitPrice"] as? Double { entry["pricing"] = ["costPerUnit": perUnitPrice] }
            if let pricingV2 = match["pricingV2"] as? [String: Any] {
                entry["currencyCode"] = try #require(pricingV2["currencyCode"] as? String)
                entry["pricingV2"] = pricingV2
            }
            models[id] = entry
            resolveMap[id] = id
        }
        let payload: [String: Any] = [
            "version": 1,
            "updatedAt": "2026-10-19T00:00:00Z",
            "providers": [
                providerKey: [
                    "displayName": providerKey,
                    "defaultModelId": "unrelated-official",
                    "resolveMap": resolveMap,
                    "models": models,
                ],
            ],
        ]
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        return client
    }

    private static func rawItem(_ group: String, _ id: String) throws -> [String: Any] {
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sharedFixtureURL("provider-pricing/cost-currency.v1.json")))
                as? [String: Any]
        )
        let items = try #require(root[group] as? [[String: Any]], "\(group)")
        return try #require(items.first { $0["id"] as? String == id }, "\(group).\(id)")
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

        // Conversation row: the USD total reads estimatedCost; non-USD totals are recomputed from local messages per currency and then stored.
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

    /// Inserts a row shaped like `before` into a pre-migration (v42) database, migrates to the latest version, then reads it back through the production store.
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

    /// Fixture source vocabulary: `estimated` = local estimate on this device (`.localEstimate`).
    private static func costSource(_ value: JSONValue?) -> CostSource? {
        switch value?.stringValue {
        case "estimated": return .localEstimate
        case "unknown": return .unknown
        case "upstream": return .upstream
        case "subscription": return .subscription
        case "managed": return .managed
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

    /// One model per leg; a leg with `status: unavailable` has pricing status unknown.
    private static func loadCatalog(_ legs: [(id: String, estimate: JSONValue)]) async throws -> MetadataClient {
        var models: [String: Any] = [:]
        var resolveMap: [String: String] = [:]
        for leg in legs {
            var model: [String: Any] = [
                "canonicalModelId": leg.id,
                "displayName": leg.id,
                "pricingUnit": "per_token",
                "capabilities": ["text"],
            ]
            if leg.estimate["status"]?.stringValue == "estimated" {
                model["pricingStatus"] = "priced"
                model["pricing"] = [
                    "promptPerMToken": try #require(leg.estimate["amount"]?.doubleValue),
                    "completionPerMToken": 0,
                ]
            } else {
                model["pricingStatus"] = "unknown"
            }
            if let code = leg.estimate["currencyCode"]?.stringValue {
                model["currencyCode"] = code
            }
            models[leg.id] = model
            resolveMap[leg.id] = leg.id
        }
        let payload: [String: Any] = [
            "version": 1,
            "updatedAt": "2026-10-19T00:00:00Z",
            "providers": [
                "anthropic": [
                    "displayName": "Anthropic",
                    "defaultModelId": legs.first?.id ?? "",
                    "resolveMap": resolveMap,
                    "models": models,
                ],
            ],
        ]
        let client = MetadataClient()
        await client.resetForTesting()
        try await client.loadForTesting(json: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        return client
    }

    private static func fixture() throws -> JSONValue {
        try JSONValue(data: Data(contentsOf: sharedFixtureURL("provider-pricing/cost-currency.v1.json")))
    }

    private static func item(_ group: String, _ id: String) throws -> JSONValue {
        try #require(try fixture()[group]?.arrayValue?.first { $0["id"]?.stringValue == id }, "\(group).\(id)")
    }
}

/// Temporary database: by default migrates only to v42 (the shape before v43); `migrateAll` migrates to the latest.
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
        // Attachments go in a subdirectory: replaceAllConversations prunes the attachment root, which would delete the database if it sat in the same directory.
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
        // Close the pool before deleting the directory so SQLite/WAL descriptors are not
        // left pointing at unlinked vnodes in tmp.
        try? pool.close()
        try? FileManager.default.removeItem(at: rootURL)
    }
}
