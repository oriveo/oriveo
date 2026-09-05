package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DeliveredCostResolverTest {

    @Test
    fun `resolve keeps upstream estimated cost when provider already returned one`() {
        val cost = DeliveredCostResolver.resolve(
            result = ProviderChatResult(
                text = "done",
                promptTokens = 100,
                completionTokens = 50,
                estimatedCost = 0.0123,
            ),
            model = AIModel(
                id = "gpt-5.4",
                name = "GPT-5.4",
                promptPrice = 0.0000025,
                completionPrice = 0.000015,
            ),
            providerKind = ProviderKind.OpenAI,
        )

        assertEquals(0.0123, cost, 1e-12)
    }

    @Test
    fun `resolve recomputes cost from model pricing when upstream returns zero`() {
        val cost = DeliveredCostResolver.resolve(
            result = ProviderChatResult(
                text = "done",
                promptTokens = 1000,
                completionTokens = 500,
                estimatedCost = 0.0,
            ),
            model = AIModel(
                id = "gpt-5.4-2026-03-05",
                name = "GPT-5.4",
                promptPrice = 0.0000025,
                completionPrice = 0.000015,
                canonicalModelId = "gpt-5.4",
            ),
            providerKind = ProviderKind.OpenAI,
        )

        assertEquals(0.01, cost, 1e-12)
    }

    @Test
    fun `resolve stays zero when no token usage is available`() {
        val cost = DeliveredCostResolver.resolve(
            result = ProviderChatResult(
                text = "done",
                promptTokens = 0,
                completionTokens = 0,
                estimatedCost = 0.0,
            ),
            model = AIModel(
                id = "gpt-5.4",
                name = "GPT-5.4",
                promptPrice = 0.0000025,
                completionPrice = 0.000015,
            ),
            providerKind = ProviderKind.OpenAI,
        )

        assertEquals(0.0, cost, 1e-12)
    }

    @Test
    fun `isUnknownPricing is true when token usage exists but no pricing source exists`() {
        val isUnknown = DeliveredCostResolver.isUnknownPricing(
            result = ProviderChatResult(
                text = "done",
                promptTokens = 1000,
                completionTokens = 500,
                estimatedCost = 0.0,
            ),
            model = AIModel(id = "custom-model", name = "Custom Model"),
            providerKind = ProviderKind.Relay,
        )

        assertEquals(true, isUnknown)
    }

    /**
     * The fallback used when there is no catalog pricing entry still has to bucket by cache:
     * cache prices reuse the same fallback ratios as the main path (read x0.5, 5m write x1.25,
     * 1h write x2.0) so the two paths agree.
     *
     * ProviderChatResult.promptTokens is the **total input including cache**
     * (RelayTransportCoordinator fills it as input + cache_read + cache_create), so multiplying
     * it by the full price nearly doubles the estimate for a request that hits cache almost
     * entirely.
     */
    @Test
    fun `relay fallback prices cache reads at half rate instead of full input rate`() {
        val model = AIModel(
            id = "relay-model",
            name = "Relay Model",
            promptPrice = 0.000001,
            completionPrice = 0.000002,
        )
        val result = ProviderChatResult(
            text = "done",
            promptTokens = 10_000,
            completionTokens = 100,
            estimatedCost = 0.0,
            cachedInputTokens = 9_000,
        )

        val cost = DeliveredCostResolver.resolve(result, model, ProviderKind.Relay)

        // Bucketed: 1000x1e-6 + 9000x(1e-6 x 0.5) + 100x2e-6 = 0.001 + 0.0045 + 0.0002
        assertEquals(0.0057, cost, 1e-12)
        // Contrast with the wrong arithmetic (total input including cache at full price):
        // 10000x1e-6 + 100x2e-6 = 0.0102. This assertion exists to stop anyone changing it back.
        val fullPriceOnTotalInput = 10_000 * 0.000001 + 100 * 0.000002
        assertEquals(0.0102, fullPriceOnTotalInput, 1e-12)
        assertTrue(cost < fullPriceOnTotalInput)
    }

    @Test
    fun `relay fallback prices 5m and 1h cache writes at their own multipliers`() {
        val model = AIModel(
            id = "relay-anthropic",
            name = "Relay Claude",
            promptPrice = 0.000001,
            completionPrice = 0.000002,
        )
        val result = ProviderChatResult(
            text = "done",
            promptTokens = 3_000,
            completionTokens = 0,
            estimatedCost = 0.0,
            cacheCreation5mTokens = 1_000,
            cacheCreation1hTokens = 1_000,
        )

        // 1000x1e-6 + 1000x1.25e-6 + 1000x2e-6 = 0.00425
        assertEquals(0.00425, DeliveredCostResolver.resolve(result, model, ProviderKind.Relay), 1e-12)
    }

    @Test
    fun `relay fallback without any cache buckets keeps the old plain result`() {
        val model = AIModel(
            id = "relay-plain",
            name = "Relay Plain",
            promptPrice = 0.0000025,
            completionPrice = 0.000015,
        )
        val result = ProviderChatResult(
            text = "done",
            promptTokens = 1_000,
            completionTokens = 500,
            estimatedCost = 0.0,
        )

        // With no cache buckets present, bucketing degrades to the original two-term product
        // and existing behaviour is unchanged.
        assertEquals(1_000 * 0.0000025 + 500 * 0.000015, DeliveredCostResolver.resolve(result, model, ProviderKind.Relay), 1e-12)
    }
}
