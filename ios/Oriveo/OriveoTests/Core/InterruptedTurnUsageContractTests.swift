import Foundation
import Testing
@testable import Oriveo

/// Cross-platform contract for the usage of a reply stopped midway
/// (shared fixture `test-fixtures/provider-usage/interrupted-turn.v1.json`, BYOK and trial cases).
/// Tokens come from production `InterruptedTurnUsage.outcome`, cost from `InterruptedTurnUsage.cost`
/// over `ChatDeliveryAccounting.generationCost` with a priced Relay model.
@Suite("InterruptedTurnUsageContractTests", .serialized, .sharedProcessState)
@MainActor
struct InterruptedTurnUsageContractTests {

    private static func fixtureCase(_ id: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("\u{5171}\u{4EAB}/test-fixtures/provider-usage/interrupted-turn.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                let root = try #require(object as? [String: Any])
                let cases = try #require(root["cases"] as? [[String: Any]])
                return try #require(cases.first { $0["id"] as? String == id }, "fixture is missing \(id)")
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func check(_ id: String) throws {
        let item = try Self.fixtureCase(id)
        let input = try #require(item["input"] as? [String: Any])
        let expect = try #require(item["expect"] as? [String: Any])
        let model = TestFactories.makeModel(id: "relay-model", promptPrice: 0.000002, completionPrice: 0.000008)
        let provider = TestFactories.makeProvider(kind: .relay, models: [model])

        let legs = (input["finishedLegs"] as? [[String: Any]] ?? []).map { leg -> ProposeMemoryDeferredDelivery in
            let result = ProviderChatResult(
                text: "leg",
                promptTokens: leg["inputTokens"] as? Int ?? 0,
                completionTokens: leg["outputTokens"] as? Int ?? 0,
                estimatedCost: 0,
                usageReported: leg["usageReported"] as? Bool ?? false
            )
            return ProposeMemoryDeferredDelivery(
                estimatedCost: ChatDeliveryAccounting.generationCost(
                    result: result, model: model, provider: provider, at: Date()
                ),
                usageMetrics: ChatDeliveredUsageMetrics(result: result),
                clearsCitations: false
            )
        }
        let outcome = InterruptedTurnUsage.outcome(
            estimatedInput: input["estimatedInput"] as? Int,
            rhoHi: try #require(input["rhoHi"] as? Double),
            // The stopped leg counts what it added after the text shown before it (one leg separator dropped).
            visibleText: InterruptedTurnUsage.addedText(
                try #require(input["visibleText"] as? String), baseline: input["shownBefore"] as? String ?? ""
            ),
            reasoningText: try #require(input["reasoningText"] as? String),
            finishedLegs: legs.compactMap(\.usageMetrics)
        )

        let recorded = try #require(expect["recorded"] as? Bool)
        #expect((outcome != nil) == recorded, "\(id) recorded")
        #expect(outcome?.usage.inputTokens == expect["inputTokens"] as? Int, "\(id) inputTokens")
        #expect(outcome?.usage.outputTokens == expect["outputTokens"] as? Int, "\(id) outputTokens")

        let cost = outcome.flatMap {
            InterruptedTurnUsage.cost(
                $0, finishedLegs: legs.map { InterruptedTurnUsage.FinishedLeg(delivery: $0, pricing: (model, provider)) },
                model: model, provider: provider, at: Date()
            )
        }
        let costSource: CostSource = cost.flatMap { ChatDeliveryAccounting.record($0).costSource } ?? .unknown
        #expect(costSource.rawValue == expect["costSource"] as? String, "\(id) costSource")

        // The skill list overhead is written only with recorded usage.
        let manifestTokens = outcome == nil ? nil : input["skillManifestTokens"] as? Int
        #expect(manifestTokens == expect["skillManifestTokens"] as? Int, "\(id) skillManifestTokens")
    }

    @Test func interrupted_turn_stopped_with_text() throws {
        try check("stopped-with-text")
    }

    @Test func interrupted_turn_stopped_with_reasoning_and_text() throws {
        try check("stopped-with-reasoning-and-text")
    }

    @Test func interrupted_turn_stopped_before_output() throws {
        try check("stopped-before-output")
    }

    @Test func interrupted_turn_stopped_without_input_estimate() throws {
        try check("stopped-without-input-estimate")
    }

    @Test func interrupted_turn_stopped_after_reported_leg() throws {
        try check("stopped-after-reported-leg")
    }

    @Test func interrupted_turn_stopped_before_output_after_reported_leg() throws {
        try check("stopped-before-output-after-reported-leg")
    }

    @Test func interrupted_turn_trial_stopped_with_text() throws {
        try check("trial-stopped-with-text")
    }

    @Test func interrupted_turn_stopped_without_input_estimate_after_reported_leg() throws {
        try check("stopped-without-input-estimate-after-reported-leg")
    }

    @Test func interrupted_turn_stopped_after_leg_separator() throws {
        try check("stopped-after-leg-separator")
    }
}
