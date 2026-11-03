import Foundation
import Testing
@testable import Oriveo

/// Data derivation logic for the token usage sheet.
///
/// These checks used to live in the View with no assertions: the visibility rule of the cost row,
/// and the contract invariant that cached tokens are a subset of input. The sheet redesign moved them onto the snapshot; these tests pin the semantics.
@Suite("MessageTokenUsageSnapshot")
struct MessageTokenUsageSnapshotTests {

    // MARK: - Cost row

    @Test("Cost Hidden For Platform Paid")
    func costHiddenForPlatformPaid() {
        let free = MessageTokenUsageSnapshot(
            inputTokens: 10, outputTokens: 5, estimatedCost: 0, isPlatformPaid: true
        )
        #expect(free.showsCost == false)

        let freeWithCost = MessageTokenUsageSnapshot(
            inputTokens: 10, outputTokens: 5, estimatedCost: 0.004, isPlatformPaid: true
        )
        #expect(freeWithCost.showsCost == false)
    }

    @Test("Cost Hidden When Zero")
    func costHiddenWhenZero() {
        #expect(MessageTokenUsageSnapshot(estimatedCost: 0).showsCost == false)
        #expect(MessageTokenUsageSnapshot(estimatedCost: 0.000001).showsCost == false)
        #expect(CostFormatter.format(0.000001).isEmpty)
    }

    @Test("Estimated Tag Follows Cost Source")
    func estimatedTagFollowsCostSource() {
        let upstream = MessageTokenUsageSnapshot(estimatedCost: 0.01, costSource: .upstream)
        #expect(upstream.showsCost)
        #expect(upstream.isCostEstimated == false)

        let local = MessageTokenUsageSnapshot(estimatedCost: 0.01, costSource: .localEstimate)
        #expect(local.isCostEstimated)

        #expect(MessageTokenUsageSnapshot(estimatedCost: 0.01, costSource: .unknown).isCostEstimated)
        #expect(MessageTokenUsageSnapshot(estimatedCost: 0.01, costSource: nil).isCostEstimated)
    }

    /// Cross-platform cost row contract (shared fixture `provider-pricing/token-usage-cost-row.v1.json`):
    /// each case builds a persisted assistant message and runs it through production
    /// `MessageTokenUsageSnapshot(message:)` and `CostFormatter.messageText`.
    @Test("Cost row follows the shared token usage fixture")
    @MainActor
    func costRowFixtureCases() throws {
        let cases = try Self.costRowFixture()
        #expect(cases.count == 11)
        let noData = L10n.tr("No data", table: .chat)
        for item in cases {
            let id = try #require(item["id"] as? String)
            let fields = try #require(item["message"] as? [String: Any], "\(id) message")
            let expect = try #require(item["expect"] as? [String: Any], "\(id) expect")
            let kindRaw = try #require(fields["providerKind"] as? String, "\(id) providerKind")
            let kind = try #require(ProviderKind(rawValue: kindRaw), "\(id) unknown providerKind \(kindRaw)")

            var message = ChatMessage(
                id: UUID(), role: .assistant, text: "answer",
                providerKind: kind, providerName: kindRaw,
                modelName: "model", state: .delivered
            )
            message.estimatedCost = try #require((fields["estimatedCost"] as? NSNumber)?.doubleValue, "\(id) estimatedCost")
            if let raw = fields["costSource"] as? String {
                message.costSource = try #require(CostSource(rawValue: raw), "\(id) unknown costSource \(raw)")
            } else {
                message.costSource = nil
            }
            if let part = fields["nonUsdCost"] as? [String: Any] {
                let raw = try #require(part["costSource"] as? String, "\(id) nonUsdCost.costSource")
                message.nonUsdCost = NonUsdCost(
                    currencyCode: try #require(part["currencyCode"] as? String, "\(id) currencyCode"),
                    amount: try #require((part["amount"] as? NSNumber)?.doubleValue, "\(id) amount"),
                    costSource: try #require(CostSource(rawValue: raw), "\(id) unknown costSource \(raw)")
                )
            } else {
                message.nonUsdCost = nil
            }

            let usage = MessageTokenUsageSnapshot(message: message)
            let showsCost = try #require(expect["showsCost"] as? Bool, "\(id) showsCost")
            #expect(usage.showsCost == showsCost, "\(id) showsCost")
            guard showsCost else { continue }

            let tagged = try #require(expect["estimatedTag"] as? Bool, "\(id) estimatedTag")
            #expect(usage.isCostEstimated == tagged, "\(id) estimatedTag")

            let text = usage.costRowText
            // A shown amount is never a zero amount ("$0.00" or the zero form of the non-USD currency).
            var zeroAmounts = [String(format: "$%.2f", 0.0)]
            if let code = usage.nonUsdCost?.currencyCode {
                zeroAmounts.append(NonUsdCurrencyFormatters.shared.string(
                    from: 0, locale: AppLocalization.currentLocale, currencyCode: code, digits: 2
                ))
            }
            let textParts = text.components(separatedBy: " + ")
            let showsZeroAmount = zeroAmounts.contains { !$0.isEmpty && textParts.contains($0) }
            switch try #require(expect["value"] as? String, "\(id) value") {
            case "noData":
                #expect(text == noData, "\(id) value: \(text)")
            case "amountPlusNoData":
                #expect(!showsZeroAmount, "\(id) zero amount: \(text)")
                #expect(text.hasSuffix(" + " + noData), "\(id) value: \(text)")
                #expect(text != " + " + noData, "\(id) value: \(text)")
            case "amount":
                #expect(!showsZeroAmount, "\(id) zero amount: \(text)")
                #expect(!text.isEmpty, "\(id) value is empty")
                #expect(!text.contains(noData), "\(id) value: \(text)")
            case let other:
                Issue.record("\(id) unknown value kind \(other)")
            }
        }
    }

    private static func costRowFixture() throws -> [[String: Any]] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/provider-pricing/token-usage-cost-row.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                let root = try #require(object as? [String: Any])
                return try #require(root["cases"] as? [[String: Any]])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    // MARK: - Total and cache subset

    @Test("Total Requires Both And Excludes Cache")
    func totalRequiresBothAndExcludesCache() {
        let usage = MessageTokenUsageSnapshot(
            inputTokens: 6_000, outputTokens: 1_000,
            cacheReadTokens: 5_000, cacheWriteTokens: 200
        )
        #expect(usage.total == 7_000)

        #expect(MessageTokenUsageSnapshot(inputTokens: 100).total == nil)
        #expect(MessageTokenUsageSnapshot(outputTokens: 100).total == nil)
    }

    @Test("Init From Message Maps Fields")
    func initFromMessageMapsFields() {
        var message = ChatMessage(
            id: UUID(), role: .assistant, text: "answer",
            providerKind: .anthropic, providerName: "Anthropic",
            modelName: "claude", state: .delivered
        )
        message.inputTokens = 6_000
        message.outputTokens = 1_000
        message.cachedInputTokens = 5_000
        message.cacheCreationInputTokens = 200
        message.estimatedCost = 0.0004
        message.costSource = .localEstimate

        let usage = MessageTokenUsageSnapshot(message: message)
        #expect(usage.inputTokens == 6_000)
        #expect(usage.outputTokens == 1_000)
        #expect(usage.cacheReadTokens == 5_000)
        #expect(usage.cacheWriteTokens == 200)
        #expect(usage.estimatedCost == 0.0004)
        #expect(usage.costSource == .localEstimate)
        #expect(usage.isPlatformPaid == false)
    }

    @Test func estimated_badge_panel_bg() {
        // The Estimated badge sits on the sheet's panel background, not the inset surface of the cost cell.
        #expect(MessageTokenUsageBadgeStyle.estimatedFill == OriveoTheme.Palette.background)
        #expect(MessageTokenUsageBadgeStyle.estimatedFill != OriveoTheme.Palette.surfaceInset)
        #expect(MessageTokenUsageBadgeStyle.estimatedStroke == OriveoTheme.Palette.border)
        #expect(MessageTokenUsageBadgeStyle.estimatedText == OriveoTheme.Palette.textSecondary)
    }
}
