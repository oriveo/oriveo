package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for CostCalculator, covering the whole acceptance set for cost-calculation precision.
 */
class CostCalculatorTest {

    private fun pricing(
        input: Double = 0.0,
        output: Double = 0.0,
        cachedInput: Double? = null,
        cacheWrite5m: Double? = null,
        cacheWrite1h: Double? = null,
        cacheCreationOld: Double? = null,
    ): MetadataClient.ResolvedModelMetadata {
        return MetadataClient.ResolvedModelMetadata(
            canonicalModelId = "test-model",
            pricingUnit = "per_token",
            pricingStatus = "priced",
            promptPerToken = input / 1_000_000,
            completionPerToken = output / 1_000_000,
            cacheReadInputPerMToken = cachedInput,
            cacheCreationInputPerMToken = cacheCreationOld,
            cacheWrite5mPerMToken = cacheWrite5m,
            cacheWrite1hPerMToken = cacheWrite1h,
        )
    }

    // ────────────────────────────────────────────────────────────────
    // Grok unit conversion - it reports cost in ticks, not dollars, and getting that wrong poisons every number downstream
    // ────────────────────────────────────────────────────────────────

    @Test
    fun `Grok cost_in_usd_ticks 37756000 converts to 0_0038 USD within 1e-6`() {
        val ticks = 37_756_000L
        val expected = 0.0037756
        val actual = ticks / GrokService.GROK_TICKS_PER_USD
        assertEquals(expected, actual, 1e-6)
    }

    @Test
    fun `an upstream reported cost is taken as-is, and missing pricing does not make it a local estimate`() {
        val breakdown = UsageBreakdown(
            promptTokens = 100,
            completionTokens = 50,
            upstreamCost = 0.00037756,  // derived from 37756 ticks
        )
        val (cost, source) = CostCalculator.calcCost(breakdown, null)
        assertEquals(0.00037756, cost, 1e-9)
        assertEquals(CostSource.UPSTREAM, source)
    }

    @Test
    fun `an upstream reported cost wins over the metadata pricing`() {
        val breakdown = UsageBreakdown(
            promptTokens = 1000,
            completionTokens = 500,
            upstreamCost = 0.00026985,
        )
        // Even when pricing is available, the upstream cost takes precedence
        val (cost, source) = CostCalculator.calcCost(
            breakdown,
            pricing(input = 5.0, output = 15.0),
        )
        assertEquals(0.00026985, cost, 1e-9)
        assertEquals(CostSource.UPSTREAM, source)
    }

    // ────────────────────────────────────────────────────────────────
    // Anthropic mixes 5m and 1h cache writes, which have to be split apart
    // ────────────────────────────────────────────────────────────────

    @Test
    fun `Anthropic 5m and 1h cache writes are billed at their own unit prices`() {
        // claude-sonnet assumed at input = $3 / output = $15 / cached_read = $0_30 / write_5m = $3_75 / write_1h = $6
        val p = pricing(
            input = 3.0, output = 15.0,
            cachedInput = 0.30,
            cacheWrite5m = 3.75,
            cacheWrite1h = 6.0,
        )
        val breakdown = UsageBreakdown(
            promptTokens = 1000,       // uncached input
            cachedInputTokens = 2000,  // cache reads
            cacheCreation5mTokens = 1000,  // 5m writes
            cacheCreation1hTokens = 500,   // 1h writes
            completionTokens = 200,
        )
        // Expected: (1000*3 + 2000*0.3 + 1000*3.75 + 500*6 + 200*15) / 1_000_000
        //     = (3000 + 600 + 3750 + 3000 + 3000) / 1e6 = 0.01335
        val (cost, source) = CostCalculator.calcCost(breakdown, p)
        assertEquals(0.01335, cost, 1e-9)
        assertEquals(CostSource.LOCAL_ESTIMATE, source)
    }

    @Test
    fun `Anthropic falls back to the older cacheCreationOld field when cacheWrite5m is missing`() {
        // Older metadata only filled in cacheCreationInput as a single field and left cacheWrite5m out
        val p = pricing(
            input = 3.0, output = 15.0,
            cachedInput = 0.30,
            cacheCreationOld = 3.75,  // the older single field
        )
        val breakdown = UsageBreakdown(
            promptTokens = 0,
            cacheCreation5mTokens = 1000,
            completionTokens = 0,
        )
        // Expected: 1000 * 3.75 / 1e6 = 0.00375
        val (cost, _) = CostCalculator.calcCost(breakdown, p)
        assertEquals(0.00375, cost, 1e-9)
    }

    @Test
    fun `Anthropic falls back to input x 2_0 when cacheWrite1h is missing`() {
        val p = pricing(input = 3.0, output = 15.0, cachedInput = 0.30, cacheWrite5m = 3.75)
        // cacheWrite1h absent, so fall back to input * 2.0 = 6.0
        val breakdown = UsageBreakdown(cacheCreation1hTokens = 1000)
        val (cost, _) = CostCalculator.calcCost(breakdown, p)
        assertEquals(0.006, cost, 1e-9)  // 1000 * 6 / 1e6
    }

    @Test
    fun `cache read discount fallback - input x 0_5 when cachedInputPerMToken is missing`() {
        val p = pricing(input = 4.0, output = 0.0)  // cachedInput missing
        val breakdown = UsageBreakdown(cachedInputTokens = 1000)
        // fallback: 4.0 * 0.5 = 2.0 per M → 1000 * 2.0 / 1e6 = 0.002
        val (cost, _) = CostCalculator.calcCost(breakdown, p)
        assertEquals(0.002, cost, 1e-9)
    }

    // ────────────────────────────────────────────────────────────────
    // parseUsage unit tests per vendor: DeepSeek / Moonshot / Grok / Gemini / OpenAI
    // ────────────────────────────────────────────────────────────────

    @Test
    fun `DeepSeek hit + miss = prompt_tokens identity, on a measured cache hit`() {
        // On the second request the cache hits: hit=1664, miss=87, total=1751
        val service = DeepSeekService(
            io.ktor.client.HttpClient(),
            kotlinx.serialization.json.Json,
        )
        val usageJson = kotlinx.serialization.json.buildJsonObject {
            put("prompt_tokens", kotlinx.serialization.json.JsonPrimitive(1751))
            put("prompt_cache_hit_tokens", kotlinx.serialization.json.JsonPrimitive(1664))
            put("prompt_cache_miss_tokens", kotlinx.serialization.json.JsonPrimitive(87))
            put("completion_tokens", kotlinx.serialization.json.JsonPrimitive(50))
        }
        val breakdown = invokeParseUsage(service, usageJson)
        assertEquals(87, breakdown.promptTokens)
        assertEquals(1664, breakdown.cachedInputTokens)
        assertEquals(50, breakdown.completionTokens)
        assertEquals(1751, breakdown.promptTokens + breakdown.cachedInputTokens)  // the identity holds
        assertEquals(true, breakdown.cacheReadObserved)
    }

    @Test
    fun `DeepSeek falls back to prompt_tokens when the miss field is absent`() {
        val service = DeepSeekService(
            io.ktor.client.HttpClient(),
            kotlinx.serialization.json.Json,
        )
        val usageJson = kotlinx.serialization.json.buildJsonObject {
            put("prompt_tokens", kotlinx.serialization.json.JsonPrimitive(100))
            put("completion_tokens", kotlinx.serialization.json.JsonPrimitive(20))
        }
        val breakdown = invokeParseUsage(service, usageJson)
        assertEquals(100, breakdown.promptTokens)
        assertEquals(0, breakdown.cachedInputTokens)
        assertEquals(false, breakdown.cacheReadObserved)
    }

    @Test
    fun `Moonshot reports cached_tokens at the top level, where the OpenAI template would read 0`() {
        val service = MoonshotService(
            io.ktor.client.HttpClient(),
            kotlinx.serialization.json.Json,
            ai.oriveo.community.core.provider.transport.TransportRegistry(kotlinx.serialization.json.Json),
        )
        val usageJson = kotlinx.serialization.json.buildJsonObject {
            put("prompt_tokens", kotlinx.serialization.json.JsonPrimitive(2000))
            put("completion_tokens", kotlinx.serialization.json.JsonPrimitive(50))
            put("cached_tokens", kotlinx.serialization.json.JsonPrimitive(1658))  // top level, not nested
        }
        val breakdown = invokeParseUsage(service, usageJson)
        assertEquals(342, breakdown.promptTokens)  // 2000 - 1658
        assertEquals(1658, breakdown.cachedInputTokens)
    }

    @Test
    fun `OpenAI template counts cached_tokens inside prompt_tokens, so they must be subtracted first`() {
        // Exercises the default parseUsage of OpenAICompatibleService (any subclass will do)
        val service = GroqService(
            io.ktor.client.HttpClient(),
            kotlinx.serialization.json.Json,
        )
        val usageJson = kotlinx.serialization.json.buildJsonObject {
            put("prompt_tokens", kotlinx.serialization.json.JsonPrimitive(3000))
            put("completion_tokens", kotlinx.serialization.json.JsonPrimitive(100))
            putJsonObject("prompt_tokens_details") {
                put("cached_tokens", kotlinx.serialization.json.JsonPrimitive(1500))
            }
            putJsonObject("completion_tokens_details") {
                put("reasoning_tokens", kotlinx.serialization.json.JsonPrimitive(50))
            }
        }
        val breakdown = invokeParseUsage(service, usageJson)
        assertEquals(1500, breakdown.promptTokens)   // 3000 - 1500
        assertEquals(1500, breakdown.cachedInputTokens)
        assertEquals(100, breakdown.completionTokens)
        assertEquals(50, breakdown.reasoningTokens)
    }

    // ────────────────────────────────────────────────────────────────
    // Unknown price and free pricing boundaries
    // ────────────────────────────────────────────────────────────────

    @Test
    fun `null pricing with no upstreamCost returns UNKNOWN`() {
        val (cost, source) = CostCalculator.calcCost(
            UsageBreakdown(promptTokens = 100, completionTokens = 50),
            null,
        )
        assertEquals(0.0, cost, 0.0)
        assertEquals(CostSource.UNKNOWN, source)
    }

    @Test
    fun `free pricing returns cost 0_0 plus LOCAL_ESTIMATE`() {
        val p = MetadataClient.ResolvedModelMetadata(
            canonicalModelId = "test",
            pricingUnit = "per_token",
            pricingStatus = "free",
            promptPerToken = 0.0,
            completionPerToken = 0.0,
        )
        val (cost, source) = CostCalculator.calcCost(
            UsageBreakdown(promptTokens = 100, completionTokens = 50),
            p,
        )
        assertEquals(0.0, cost, 0.0)
        assertEquals(CostSource.LOCAL_ESTIMATE, source)
    }

    @Test
    fun `a billing unit other than per_token degrades to costPerUnit`() {
        val p = MetadataClient.ResolvedModelMetadata(
            canonicalModelId = "test",
            pricingUnit = "per_image",
            pricingStatus = "priced",
            costPerUnit = 0.04,
        )
        val (cost, source) = CostCalculator.calcCost(UsageBreakdown(), p)
        assertEquals(0.04, cost, 0.0)
        assertEquals(CostSource.LOCAL_ESTIMATE, source)
    }

    @Test
    fun `cache observations keep a genuine 0 and hide fields that were never reported`() {
        val observed = UsageBreakdown(
            promptTokens = 10,
            cachedInputTokens = 0,
            cacheReadObserved = true,
        )
        assertEquals(0, observed.reportedCachedInputTokens)
        assertEquals(null, observed.reportedCacheCreation5mTokens)

        val missing = UsageBreakdown(promptTokens = 10)
        assertEquals(null, missing.reportedCachedInputTokens)
        assertEquals(null, missing.reportedCacheCreation5mTokens)
    }

    // ────────────────────────────────────────────────────────────────
    // helpers - parseUsage is protected, so tests reach it by reflection
    // ────────────────────────────────────────────────────────────────

    private fun invokeParseUsage(
        service: OpenAICompatibleService,
        usage: kotlinx.serialization.json.JsonObject?,
    ): UsageBreakdown {
        val method = OpenAICompatibleService::class.java.declaredMethods
            .first { it.name == "parseUsage" }
        method.isAccessible = true
        return method.invoke(service, usage) as UsageBreakdown
    }

    // Internal helper: a putJsonObject extension on JsonObjectBuilder, to keep the import list quiet
    private inline fun kotlinx.serialization.json.JsonObjectBuilder.putJsonObject(
        key: String,
        block: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit,
    ) {
        put(key, kotlinx.serialization.json.buildJsonObject(block))
    }
}
