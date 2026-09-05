import Foundation
@testable import Oriveo



enum OpenAIServiceTestProxy {
    struct UsageInput {
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        var reasoningTokens: Int?
    }

    static func makeUsage(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedTokens: cachedTokens,
            reasoningTokens: reasoningTokens
        )
    }

    static func parseUsage(_ input: inout UsageInput) -> UsageBreakdown {
        OpenAIService.parseUsageForTesting(
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            cachedTokens: input.cachedTokens,
            reasoningTokens: input.reasoningTokens
        )
    }
}

enum DeepSeekServiceTestProxy {
    struct UsageInput {
        var promptTokens: Int?
        var completionTokens: Int?
        var cacheHit: Int?
        var cacheMiss: Int?
    }

    static func makeUsage(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cacheHit: Int? = nil,
        cacheMiss: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cacheHit: cacheHit,
            cacheMiss: cacheMiss
        )
    }

    static func parseUsage(_ input: inout UsageInput) -> UsageBreakdown {
        DeepSeekService.parseUsageForTesting(
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            cacheHit: input.cacheHit,
            cacheMiss: input.cacheMiss
        )
    }
}

enum GeminiServiceTestProxy {
    struct UsageInput {
        var promptTokenCount: Int?
        var candidatesTokenCount: Int?
        var thoughtsTokenCount: Int?
        var cachedContentTokenCount: Int?
    }

    static func makeUsage(
        promptTokenCount: Int? = nil,
        candidatesTokenCount: Int? = nil,
        thoughtsTokenCount: Int? = nil,
        cachedContentTokenCount: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokenCount: promptTokenCount,
            candidatesTokenCount: candidatesTokenCount,
            thoughtsTokenCount: thoughtsTokenCount,
            cachedContentTokenCount: cachedContentTokenCount
        )
    }

    static func parseUsage(_ input: UsageInput) -> UsageBreakdown {
        GeminiService.parseUsageForTesting(
            promptTokenCount: input.promptTokenCount,
            candidatesTokenCount: input.candidatesTokenCount,
            thoughtsTokenCount: input.thoughtsTokenCount,
            cachedContentTokenCount: input.cachedContentTokenCount
        )
    }
}

enum MoonshotServiceTestProxy {
    struct UsageInput {
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokensTopLevel: Int?
    }

    static func makeUsage(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedTokensTopLevel: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedTokensTopLevel: cachedTokensTopLevel
        )
    }

    static func parseUsage(_ input: inout UsageInput) -> UsageBreakdown {
        MoonshotService.parseUsageForTesting(
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            cachedTokensTopLevel: input.cachedTokensTopLevel
        )
    }
}

enum AnthropicServiceTestProxy {
    struct UsageInput {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheRead: Int?
        var ephemeral5m: Int?
        var ephemeral1h: Int?
        var legacyCacheCreation: Int?
    }

    static func makeUsage(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheRead: Int? = nil,
        ephemeral5m: Int? = nil,
        ephemeral1h: Int? = nil,
        legacyCacheCreation: Int? = nil
    ) -> UsageInput {
        UsageInput(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheRead: cacheRead,
            ephemeral5m: ephemeral5m,
            ephemeral1h: ephemeral1h,
            legacyCacheCreation: legacyCacheCreation
        )
    }

    static func parseUsage(_ input: UsageInput) -> UsageBreakdown {
        AnthropicService.parseUsageForTesting(
            inputTokens: input.inputTokens,
            outputTokens: input.outputTokens,
            cacheRead: input.cacheRead,
            ephemeral5m: input.ephemeral5m,
            ephemeral1h: input.ephemeral1h,
            legacyCacheCreation: input.legacyCacheCreation
        )
    }
}

enum OpenRouterServiceTestProxy {
    struct UsageInput {
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
        var cachedTokens: Int?
        var cacheWriteTokens: Int?
    }

    static func makeUsage(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil,
        cachedTokens: Int? = nil,
        cacheWriteTokens: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost,
            cachedTokens: cachedTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    static func parseUsage(_ input: inout UsageInput) -> UsageBreakdown {
        OpenRouterService.parseUsageForTesting(
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            cost: input.cost,
            cachedTokens: input.cachedTokens,
            cacheWriteTokens: input.cacheWriteTokens
        )
    }
}

enum GrokServiceTestProxy {
    struct UsageInput {
        var promptTokens: Int?
        var completionTokens: Int?
        var costInUsdTicks: Int64?
        var cachedTokens: Int?
        var reasoningTokens: Int?
    }

    static func makeUsage(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        costInUsdTicks: Int64? = nil,
        cachedTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            costInUsdTicks: costInUsdTicks,
            cachedTokens: cachedTokens,
            reasoningTokens: reasoningTokens
        )
    }

    static func parseUsage(_ input: inout UsageInput) -> UsageBreakdown {
        GrokService.parseUsageForTesting(
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            costInUsdTicks: input.costInUsdTicks,
            cachedTokens: input.cachedTokens,
            reasoningTokens: input.reasoningTokens
        )
    }
}

enum QwenServiceTestProxy {
    struct UsageInput {
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedInDetails: Int?
        var cachedAtTopLevel: Int?
    }

    static func makeUsage(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedInDetails: Int? = nil,
        cachedAtTopLevel: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedInDetails: cachedInDetails,
            cachedAtTopLevel: cachedAtTopLevel
        )
    }

    static func parseUsage(_ input: inout UsageInput) -> UsageBreakdown {
        QwenService.parseUsageForTesting(
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            cachedInDetails: input.cachedInDetails,
            cachedAtTopLevel: input.cachedAtTopLevel
        )
    }
}

enum ZhipuServiceTestProxy {
    struct UsageInput {
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        var reasoningTokens: Int?
    }

    static func makeUsage(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedTokens: cachedTokens,
            reasoningTokens: reasoningTokens
        )
    }

    static func parseUsage(_ input: inout UsageInput) -> UsageBreakdown {
        ZhipuService.parseUsageForTesting(
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            cachedTokens: input.cachedTokens,
            reasoningTokens: input.reasoningTokens
        )
    }
}

enum MiniMaxServiceTestProxy {
    struct UsageInput {
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        var reasoningTokens: Int?
    }

    static func makeUsage(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) -> UsageInput {
        UsageInput(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cachedTokens: cachedTokens,
            reasoningTokens: reasoningTokens
        )
    }

    static func parseUsage(_ input: inout UsageInput) -> UsageBreakdown {
        MiniMaxService.parseUsageForTesting(
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            cachedTokens: input.cachedTokens,
            reasoningTokens: input.reasoningTokens
        )
    }
}
