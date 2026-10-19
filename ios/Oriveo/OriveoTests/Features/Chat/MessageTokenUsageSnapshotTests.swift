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
}
