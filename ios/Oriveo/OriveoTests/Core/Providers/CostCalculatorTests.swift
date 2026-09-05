import Testing
@testable import Oriveo

@Suite("CostCalculator")
struct CostCalculatorTests {
    // MARK: - Upstream cost path

    @Test("Upstream Cost Short Circuit")
    func upstreamCostShortCircuit() {
        let breakdown = UsageBreakdown(
            promptTokens: 1000,
            completionTokens: 500,
            upstreamCost: 0.0042
        )
        let (cost, source) = CostCalculator.calcCost(breakdown: breakdown, pricing: nil)
        #expect(cost == 0.0042)
        #expect(source == .upstream)
    }


    @Test("Grok Ticks Conversion")
    func grokTicksConversion() {
        let usd = Double(37_756_000) / GrokService.grokTicksPerUSD
        #expect(abs(usd - 0.0037756) < 1e-9)
        let wrongUsd = Double(37_756_000) / 100_000_000
        #expect(abs(wrongUsd - 0.37756) < 1e-6)
        #expect(wrongUsd / usd > 99 && wrongUsd / usd < 101)
    }

    // MARK: - Anthropic 5m/1h split

    @Test("Anthropic5m And1h Split")
    func anthropic5mAnd1hSplit() {
        let pricing = makePricing(
            promptPerM: 1.0,
            completionPerM: 5.0
        )
        let breakdown = UsageBreakdown(
            promptTokens: 0,
            cachedInputTokens: 0,
            cacheCreation5mTokens: 1000,
            cacheCreation1hTokens: 500,
            completionTokens: 0
        )
        let (cost, source) = CostCalculator.calcCost(breakdown: breakdown, pricing: pricing)
        #expect(abs(cost - 0.00225) < 1e-9, "Got \(cost)")
        #expect(source == .localEstimate)
    }

    // MARK: - cachedRead fallback

    @Test("Cached Read Fallback")
    func cachedReadFallback() {
        let pricing = makePricing(promptPerM: 1.0, completionPerM: 5.0)
        let breakdown = UsageBreakdown(
            promptTokens: 0,
            cachedInputTokens: 1000,
            completionTokens: 0
        )
        let (cost, _) = CostCalculator.calcCost(breakdown: breakdown, pricing: pricing)
        // 1000 × 0.000001 × 0.5 = 0.0005
        #expect(abs(cost - 0.0005) < 1e-9)
    }

    @Test("Cached Read Explicit")
    func cachedReadExplicit() {
        let pricing = makePricing(
            promptPerM: 1.0,
            completionPerM: 5.0,
            cachedReadPerM: 0.1
        )
        let breakdown = UsageBreakdown(
            promptTokens: 0,
            cachedInputTokens: 1000,
            completionTokens: 0
        )
        let (cost, _) = CostCalculator.calcCost(breakdown: breakdown, pricing: pricing)
        // 1000 × 0.0000001 = 0.0001
        #expect(abs(cost - 0.0001) < 1e-9)
    }


    @Test("Full Sum Formula")
    func fullSumFormula() {
        let pricing = makePricing(
            promptPerM: 2.0,    // input $2/1M
            completionPerM: 8.0,
            cachedReadPerM: 0.2,
            cacheWrite5mPerM: 2.5,
            cacheWrite1hPerM: 4.0
        )
        let breakdown = UsageBreakdown(
            promptTokens: 1_000_000,   // → 2.0
            cachedInputTokens: 500_000, // → 0.1
            cacheCreation5mTokens: 200_000, // → 0.5
            cacheCreation1hTokens: 100_000, // → 0.4
            completionTokens: 300_000  // → 2.4
        )
        let (cost, _) = CostCalculator.calcCost(breakdown: breakdown, pricing: pricing)
        // 2.0 + 0.1 + 0.5 + 0.4 + 2.4 = 5.4
        #expect(abs(cost - 5.4) < 1e-6, "Got \(cost)")
    }

    // MARK: - Unknown pricing

    @Test("Nil Pricing Returns Unknown")
    func nilPricingReturnsUnknown() {
        let breakdown = UsageBreakdown(promptTokens: 100, completionTokens: 50)
        let (cost, source) = CostCalculator.calcCost(breakdown: breakdown, pricing: nil)
        #expect(cost == 0)
        #expect(source == .unknown)
    }


    @Test("Open AICached Deducted")
    func openAICachedDeducted() {
        var usage = OpenAIServiceTestProxy.makeUsage(
            promptTokens: 1500,
            completionTokens: 200,
            cachedTokens: 1000,
            reasoningTokens: nil
        )
        let breakdown = OpenAIServiceTestProxy.parseUsage(&usage)
        #expect(breakdown.promptTokens == 500)   // 1500 - 1000
        #expect(breakdown.cachedInputTokens == 1000)
        #expect(breakdown.completionTokens == 200)
    }

    @Test("Deep Seek Hit Miss Identity")
    func deepSeekHitMissIdentity() {
        var usage = DeepSeekServiceTestProxy.makeUsage(
            promptTokens: 2000,
            completionTokens: 100,
            cacheHit: 1500,
            cacheMiss: 500
        )
        let breakdown = DeepSeekServiceTestProxy.parseUsage(&usage)
        #expect(breakdown.promptTokens == 500)
        #expect(breakdown.cachedInputTokens == 1500)
        #expect(breakdown.promptTokens + breakdown.cachedInputTokens == 2000)
    }

    @Test("Gemini Completion Is Candidates Plus Thoughts")
    func geminiCompletionIsCandidatesPlusThoughts() {
        let usage = GeminiServiceTestProxy.makeUsage(
            promptTokenCount: 1695,
            candidatesTokenCount: 31,
            thoughtsTokenCount: 78,
            cachedContentTokenCount: nil
        )
        let breakdown = GeminiServiceTestProxy.parseUsage(usage)
        #expect(breakdown.completionTokens == 109)
        #expect(breakdown.reasoningTokens == 78)
        #expect(breakdown.promptTokens == 1695)
        #expect(breakdown.cachedInputTokens == 0)
    }

    @Test("Gemini Cached Content Deducted")
    func geminiCachedContentDeducted() {
        let usage = GeminiServiceTestProxy.makeUsage(
            promptTokenCount: 2000,
            candidatesTokenCount: 100,
            thoughtsTokenCount: 0,
            cachedContentTokenCount: 1500
        )
        let breakdown = GeminiServiceTestProxy.parseUsage(usage)
        #expect(breakdown.promptTokens == 500)
        #expect(breakdown.cachedInputTokens == 1500)
    }

    @Test("Moonshot Cached At Top Level")
    func moonshotCachedAtTopLevel() {
        var usage = MoonshotServiceTestProxy.makeUsage(
            promptTokens: 2000,
            completionTokens: 100,
            cachedTokensTopLevel: 1500
        )
        let breakdown = MoonshotServiceTestProxy.parseUsage(&usage)
        #expect(breakdown.promptTokens == 500)
        #expect(breakdown.cachedInputTokens == 1500)
    }

    @Test("Anthropic Cache Creation Nested")
    func anthropicCacheCreationNested() {
        let nestedUsage = AnthropicServiceTestProxy.makeUsage(
            inputTokens: 200,
            outputTokens: 50,
            cacheRead: 0,
            ephemeral5m: 148,
            ephemeral1h: 100,
            legacyCacheCreation: nil
        )
        let nestedBreakdown = AnthropicServiceTestProxy.parseUsage(nestedUsage)
        #expect(nestedBreakdown.cacheCreation5mTokens == 148)
        #expect(nestedBreakdown.cacheCreation1hTokens == 100)

        let legacyUsage = AnthropicServiceTestProxy.makeUsage(
            inputTokens: 200,
            outputTokens: 50,
            cacheRead: 0,
            ephemeral5m: nil,
            ephemeral1h: nil,
            legacyCacheCreation: 88
        )
        let legacyBreakdown = AnthropicServiceTestProxy.parseUsage(legacyUsage)
        #expect(legacyBreakdown.cacheCreation5mTokens == 88)
        #expect(legacyBreakdown.cacheCreation1hTokens == 0)
    }

    @Test("Open Router Upstream Cost")
    func openRouterUpstreamCost() {
        var usage = OpenRouterServiceTestProxy.makeUsage(
            promptTokens: 1000,
            completionTokens: 200,
            cost: 0.00026985,
            cachedTokens: 300,
            cacheWriteTokens: 100
        )
        let breakdown = OpenRouterServiceTestProxy.parseUsage(&usage)
        #expect(breakdown.upstreamCost == 0.00026985)
        #expect(breakdown.promptTokens == 600)
        #expect(breakdown.totalInputTokens == 1000)
    }

    @Test("Grok cost_in_usd_ticks → upstreamCost = ticks / 1e10")
    func grokUpstreamCostFromTicks() {
        var usage = GrokServiceTestProxy.makeUsage(
            promptTokens: 1000,
            completionTokens: 200,
            costInUsdTicks: 28_093_500,
            cachedTokens: 0,
            reasoningTokens: 281
        )
        let breakdown = GrokServiceTestProxy.parseUsage(&usage)
        #expect(breakdown.upstreamCost != nil)
        if let cost = breakdown.upstreamCost {
            #expect(abs(cost - 0.00280935) < 1e-9)
        }
        #expect(breakdown.reasoningTokens == 281)
    }

    @Test("Qwen Dual Fallback")
    func qwenDualFallback() {
        var withDetails = QwenServiceTestProxy.makeUsage(
            promptTokens: 1000,
            completionTokens: 100,
            cachedInDetails: 600,
            cachedAtTopLevel: 200
        )
        let bd1 = QwenServiceTestProxy.parseUsage(&withDetails)
        #expect(bd1.cachedInputTokens == 600)
        #expect(bd1.promptTokens == 400)

        var topLevelOnly = QwenServiceTestProxy.makeUsage(
            promptTokens: 1000,
            completionTokens: 100,
            cachedInDetails: nil,
            cachedAtTopLevel: 300
        )
        let bd2 = QwenServiceTestProxy.parseUsage(&topLevelOnly)
        #expect(bd2.cachedInputTokens == 300)
        #expect(bd2.promptTokens == 700)
    }

    @Test("Zhipu Reasoning Tokens")
    func zhipuReasoningTokens() {
        var usage = ZhipuServiceTestProxy.makeUsage(
            promptTokens: 1649,
            completionTokens: 108,
            cachedTokens: 0,
            reasoningTokens: 83
        )
        let breakdown = ZhipuServiceTestProxy.parseUsage(&usage)
        #expect(breakdown.completionTokens == 108)
        #expect(breakdown.reasoningTokens == 83)
    }

    @Test("Mini Max Reasoning Tokens")
    func miniMaxReasoningTokens() {
        var usage = MiniMaxServiceTestProxy.makeUsage(
            promptTokens: 1657,
            completionTokens: 107,
            cachedTokens: 0,
            reasoningTokens: 77
        )
        let breakdown = MiniMaxServiceTestProxy.parseUsage(&usage)
        #expect(breakdown.completionTokens == 107)
        #expect(breakdown.reasoningTokens == 77)
    }

    // MARK: - Helpers

    private func makePricing(
        promptPerM: Double,
        completionPerM: Double,
        cachedReadPerM: Double? = nil,
        cacheWrite5mPerM: Double? = nil,
        cacheWrite1hPerM: Double? = nil
    ) -> MetadataClient.ResolvedModelMetadata {
        MetadataClient.ResolvedModelMetadata(
            canonicalModelId: "test-model",
            modelRef: nil,
            displayName: "Test",
            contextLength: 100_000,
            maxOutputTokens: nil,
            supportsTemperature: nil,
            billingSku: nil,
            pricingUnit: "per_token",
            sourceSummary: nil,
            pricingStatus: "priced",
            capabilities: [],
            promptPerToken: promptPerM / 1_000_000,
            completionPerToken: completionPerM / 1_000_000,
            costPerUnit: nil,
            costInputBatches: nil,
            costOutputBatches: nil,
            costInputPriority: nil,
            costOutputPriority: nil,
            cacheReadInputPerMToken: cachedReadPerM,
            cacheCreationInputPerMToken: nil,
            cacheWrite5mPerMToken: cacheWrite5mPerM,
            cacheWrite1hPerMToken: cacheWrite1hPerM,
            profiles: (nil, nil, nil),
            generationProfile: nil,
            supportsPdfInput: false,
            supportsServiceTier: false,
            uiHints: (nil, nil, nil, false, nil),
            isDefault: false,
            vendorKey: nil,
            vendorName: nil,
            toolCall: false,
            libraryAgentic: nil,
            capabilityContractVersion: nil,
            transport: nil
        )
    }
}
