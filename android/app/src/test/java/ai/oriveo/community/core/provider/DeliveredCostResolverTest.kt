package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.NonUsdCost
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    // -- Delivered cost in the original currency --

    @Test
    fun region_cn_connection_records_cny_entry_price() {
        // The service layer priced 0.01 from the model-level USD price; a cn-region connection should be re-priced with the CNY price of the cn entry.
        val cost = DeliveredCostResolver.resolve(
            result = tokens(estimatedCost = 0.01),
            model = localPricedModel(),
            provider = provider(ProviderKind.Moonshot, endpointSource = OfficialEndpointSource.region("cn")),
            modelId = MODEL,
            at = AT,
            catalog = catalog(currency = "USD", prompt = 0.000002, completion = 0.000004, cnEntry = true),
            regionOptions = REGIONS,
        )

        // 1000×1e-5 + 500×2e-5 = 0.02 CNY
        assertEquals(0.02, cost.amount, 1e-12)
        assertEquals("CNY", cost.currencyCode)
        assertFalse(cost.unknown)
    }

    @Test
    fun non_usd_zero_does_not_fall_back_to_local_price() {
        // The model level is already CNY: the service-layer calcCost only accepts USD and returned 0; the old path would fall back to the AIModel unit price and record it as dollars.
        val cost = DeliveredCostResolver.resolve(
            result = tokens(estimatedCost = 0.0),
            model = localPricedModel(),
            provider = provider(ProviderKind.Moonshot),
            modelId = MODEL,
            at = AT,
            catalog = catalog(currency = "CNY", prompt = 0.00001, completion = 0.00002),
            regionOptions = emptyList(),
        )

        assertEquals(0.02, cost.amount, 1e-12)
        assertEquals("CNY", cost.currencyCode)
        assertFalse(cost.unknown)
        val localUsd = 1_000 * 0.000003 + 500 * 0.000006
        assertTrue(kotlin.math.abs(cost.amount - localUsd) > 1e-9)
    }

    // -- Usage reporting on official connections: a usage with all buckets 0 = a real 0, no usage = unknown --

    private fun officialChatDone(usage: String?): ProviderChatResult {
        val usageField = usage?.let { ""","usage":$it""" }.orEmpty()
        val raw = """{"choices":[{"message":{"content":"hi"}}]$usageField}"""
        return parseOpenAIChatDone(kotlinx.serialization.json.Json { ignoreUnknownKeys = true }, raw).result
    }

    @Test
    fun official_zero_usage_reported_records_true_zero() {
        val result = officialChatDone("""{"prompt_tokens":0,"completion_tokens":0}""")
        assertTrue(result.usageReported)
        val cost = DeliveredCostResolver.resolve(
            result = result,
            model = localPricedModel(),
            provider = provider(ProviderKind.Moonshot),
            modelId = MODEL,
            at = AT,
            catalog = catalog(currency = "CNY", prompt = 0.00001, completion = 0.00002),
            regionOptions = emptyList(),
        )

        assertFalse(cost.unknown)
        assertEquals(0.0, cost.amount, 1e-12)
        assertEquals("CNY", cost.currencyCode)
    }

    @Test
    fun official_missing_usage_records_unknown() {
        val result = officialChatDone(usage = null)
        assertFalse(result.usageReported)
        val cost = DeliveredCostResolver.resolve(
            result = result,
            model = localPricedModel(),
            provider = provider(ProviderKind.Moonshot),
            modelId = MODEL,
            at = AT,
            catalog = catalog(currency = "CNY", prompt = 0.00001, completion = 0.00002),
            regionOptions = emptyList(),
        )

        assertTrue(cost.unknown)
        assertEquals(CostSource.UNKNOWN.name, DeliveredCostResolver.record(listOf(cost)).costSource)
    }

    @Test
    fun usd_without_region_entry_reestimates_from_catalog() {
        // An official USD single leg is also re-estimated at the delivery layer with the catalog price at the injected time, not reusing the service-layer (wall clock) amount 0.0123.
        val cost = DeliveredCostResolver.resolve(
            result = tokens(estimatedCost = 0.0123),
            model = localPricedModel(),
            provider = provider(ProviderKind.Moonshot, endpointSource = OfficialEndpointSource.region("global")),
            modelId = MODEL,
            at = AT,
            catalog = catalog(currency = "USD", prompt = 0.000002, completion = 0.000004, cnEntry = true),
            regionOptions = REGIONS,
        )

        assertEquals(1_000 * 0.000002 + 500 * 0.000004, cost.amount, 1e-12)
        assertEquals("USD", cost.currencyCode)
        assertEquals(CostSource.LOCAL_ESTIMATE.name, cost.costSource)
        assertFalse(cost.unknown)
    }

    @Test
    fun relay_non_usd_catalog_match_records_native_currency() {
        // A Relay matched to the official catalog uses the same estimation entry as official messages; non-USD is recorded in the original currency, never as unknown and never converted; no region selection.
        val cost = DeliveredCostResolver.resolve(
            result = tokens(estimatedCost = 0.0),
            model = localPricedModel(),
            provider = provider(ProviderKind.Relay, endpointSource = OfficialEndpointSource.region("cn")),
            modelId = MODEL,
            at = AT,
            catalog = catalog(currency = "CNY", prompt = 0.00001, completion = 0.00002, cnEntry = true),
            regionOptions = REGIONS,
        )

        // 1000×1e-5 + 500×2e-5 = 0.02 CNY
        assertEquals(0.02, cost.amount, 1e-12)
        assertEquals("CNY", cost.currencyCode)
        assertFalse(cost.unknown)
    }

    @Test
    fun metadata_not_loaded_moonshot_cn_connection_records_cny() {
        // regionOptions is not passed: the production default applies. When metadata is not loaded the delivered regions are empty, and the frozen identity table recognizes the cn address.
        val provider = provider(ProviderKind.Moonshot).copy(baseUrlText = "https://api.moonshot.cn/v1")
        val saved = MetadataClient.instance
        MetadataClient.instance = MetadataClient()
        val cost = try {
            assertTrue(OfficialEndpointSource.metadataCatalog(ProviderKind.Moonshot) == null)
            DeliveredCostResolver.resolve(
                result = tokens(estimatedCost = 0.01),
                model = localPricedModel(),
                provider = provider,
                modelId = MODEL,
                at = AT,
                catalog = catalog(currency = "USD", prompt = 0.000002, completion = 0.000004, cnEntry = true),
            )
        } finally {
            MetadataClient.instance = saved
        }

        assertEquals(0.02, cost.amount, 1e-12)
        assertEquals("CNY", cost.currencyCode)
        assertFalse(cost.unknown)
    }

    // -- When the catalog has no match, the local unit price is a fallback only when the selected currency can be determined to be USD --

    @Test
    fun catalog_miss_with_empty_metadata_moonshot_cn_stays_unknown_not_usd() {
        // Empty metadata: with the production default the catalog has no match and this vendor's currency cannot be determined; the local unit price has no currency, so it cannot be recorded as dollars.
        val provider = provider(ProviderKind.Moonshot).copy(baseUrlText = "https://api.moonshot.cn/v1")
        val saved = MetadataClient.instance
        MetadataClient.instance = MetadataClient()
        val cost = try {
            DeliveredCostResolver.resolve(
                result = tokens(estimatedCost = 0.0),
                model = localPricedModel(),
                provider = provider,
                modelId = MODEL,
                at = AT,
            )
        } finally {
            MetadataClient.instance = saved
        }

        assertTrue(cost.unknown)
        assertEquals(0.0, cost.amount, 1e-12)
        assertEquals(CostSource.UNKNOWN.name, DeliveredCostResolver.record(listOf(cost)).costSource)
    }

    @Test
    fun catalog_miss_in_all_usd_provider_falls_back_to_local_usd_price() {
        // The OpenRouter catalog is all USD prices: when the catalog has no match and the upstream returned no cost, estimate with the local dollar price.
        val saved = MetadataClient.instance
        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(
            """
            {"version":1,"providers":{"openRouter":{"resolveMap":{"listed":"listed"},"models":{"listed":{
              "canonicalModelId":"listed","transport":"openai_chat","currencyCode":"USD","pricingStatus":"priced"
            }}}}}
            """.trimIndent(),
            "etag-usd",
        )
        MetadataClient.instance = client
        val cost = try {
            DeliveredCostResolver.resolve(
                result = tokens(estimatedCost = 0.0),
                model = localPricedModel(),
                provider = provider(ProviderKind.OpenRouter),
                modelId = "not-in-catalog",
                at = AT,
            )
        } finally {
            MetadataClient.instance = saved
        }

        // 1000×3e-6 + 500×6e-6 = 0.006 USD
        assertEquals(0.006, cost.amount, 1e-12)
        assertEquals("USD", cost.currencyCode)
        assertFalse(cost.unknown)
    }

    @Test
    fun relay_catalog_miss_keeps_local_price() {
        val cost = DeliveredCostResolver.resolve(
            result = tokens(estimatedCost = 0.0),
            model = localPricedModel(),
            provider = provider(ProviderKind.Relay),
            modelId = MODEL,
            at = AT,
            catalog = null,
        )

        assertEquals(0.006, cost.amount, 1e-12)
        assertEquals("USD", cost.currencyCode)
        assertFalse(cost.unknown)
    }

    private fun tokens(estimatedCost: Double) = ProviderChatResult(
        text = "done",
        promptTokens = 1_000,
        completionTokens = 500,
        estimatedCost = estimatedCost,
    )

    /** Local unit price (no currency): for non-USD it must never be used as a fallback. */
    private fun localPricedModel() = AIModel(
        id = MODEL,
        name = "Region Model",
        promptPrice = 0.000003,
        completionPrice = 0.000006,
    )

    private fun provider(kind: ProviderKind, endpointSource: String? = null) = Provider(
        id = "p-1",
        kind = kind,
        apiKey = "local-key",
        baseUrlText = "https://api.example.test/v1",
        endpointSource = endpointSource,
    )

    private fun catalog(
        currency: String,
        prompt: Double,
        completion: Double,
        cnEntry: Boolean = false,
    ): MetadataClient.ResolvedModelMetadata {
        val model = MetadataClient.ResolvedModelMetadata(
            canonicalModelId = MODEL,
            pricingStatus = "priced",
            promptPerToken = prompt,
            completionPerToken = completion,
            currencyCode = currency,
        )
        if (!cnEntry) return model
        val cnPrice = MetadataClient.PriceKeys(
            currencyCode = "CNY",
            pricingStatus = "priced",
            pricingUnit = "per_token",
            promptPerToken = 0.00001,
            completionPerToken = 0.00002,
            costPerUnit = null,
            costInputBatches = null,
            costOutputBatches = null,
            costInputPriority = null,
            costOutputPriority = null,
            cacheReadInputPerMToken = null,
            cacheCreationInputPerMToken = null,
            cacheWrite5mPerMToken = null,
            cacheWrite1hPerMToken = null,
            longContext = null,
            pricingV2 = null,
        )
        return model.copy(regionPricing = listOf(MetadataClient.RegionPricingEntry("cn", cnPrice)))
    }

    private companion object {
        const val MODEL = "region-model"
        val AT: java.time.Instant = java.time.Instant.parse("2026-10-19T12:00:00Z")
        val REGIONS = listOf(
            RegionOption("global", "Global", "https://api.example.test/v1"),
            RegionOption("cn", "China", "https://api.example.cn/v1"),
        )
    }

    @Test
    fun record_skips_unknown_parts_and_takes_first_known_usd_source() {
        // Generation cost in USD unknown + search cost > 0: the unknown part is not recorded, and the USD source takes the search cost's LOCAL_ESTIMATE (same as Web roundCostOf)
        val unknownGeneration = DeliveredCost(0.0, "USD", unknown = true, CostSource.UNKNOWN.name)
        val retrieval = DeliveredCostResolver.retrievalPart(0.002)!!
        val mixed = DeliveredCostResolver.record(listOf(unknownGeneration, retrieval))
        assertEquals(0.002, mixed.estimatedCost, 1e-12)
        assertEquals(CostSource.LOCAL_ESTIMATE.name, mixed.costSource)
        assertEquals(null, mixed.nonUsdCost)

        // An unknown CNY generation cost does not become {CNY, 0, UNKNOWN}
        val unknownCny = DeliveredCost(0.0, "CNY", unknown = true, CostSource.UNKNOWN.name)
        val onlyUnknown = DeliveredCostResolver.record(listOf(unknownCny))
        assertEquals(CostSource.UNKNOWN.name, onlyUnknown.costSource)
        assertEquals(null, onlyUnknown.nonUsdCost)
    }

    @Test
    fun merge_non_usd_same_currency_known_plus_unknown_is_unknown() {
        val known = NonUsdCost("CNY", 0.5, CostSource.LOCAL_ESTIMATE.name)
        val unknown = NonUsdCost("CNY", 0.0, CostSource.UNKNOWN.name)
        assertEquals(NonUsdCost("CNY", 0.0, CostSource.UNKNOWN.name), DeliveredCostResolver.mergeNonUsdCost(known, unknown))
        assertEquals(NonUsdCost("CNY", 0.0, CostSource.UNKNOWN.name), DeliveredCostResolver.mergeNonUsdCost(unknown, known))
        assertEquals(NonUsdCost("CNY", 0.8, CostSource.LOCAL_ESTIMATE.name), DeliveredCostResolver.mergeNonUsdCost(known, known.copy(amount = 0.3)))
        assertEquals(
            NonUsdCost("CNY", 0.0, CostSource.UNKNOWN.name),
            DeliveredCostResolver.mergeNonUsdCost(known, NonUsdCost("EUR", 0.1, CostSource.LOCAL_ESTIMATE.name)),
        )
    }

    @Test
    fun continuation_adds_round_cost_to_previous_parts() {
        // Continuation: the placeholder message already has USD 0.01 + CNY 0.2, this turn adds USD 0.02 + CNY 0.3 -> add per part, with the source taken from this turn (same as Web addMessageCost)
        val round = DeliveredCostResolver.record(
            listOf(
                DeliveredCost(0.3, "CNY", unknown = false, CostSource.LOCAL_ESTIMATE.name),
                DeliveredCost(0.02, "USD", unknown = false, CostSource.UPSTREAM.name),
            ),
        )
        val merged = DeliveredCostResolver.addMessageCost(0.01, NonUsdCost("CNY", 0.2, CostSource.LOCAL_ESTIMATE.name), round)
        assertEquals(0.03, merged.estimatedCost, 1e-12)
        assertEquals(CostSource.UPSTREAM.name, merged.costSource)
        assertEquals("CNY", merged.nonUsdCost?.currencyCode)
        assertEquals(0.5, merged.nonUsdCost!!.amount, 1e-12)

        // Originally empty (the first turn was interrupted and recorded no cost) -> equals this turn
        assertEquals(round, DeliveredCostResolver.addMessageCost(0.0, null, round))
    }

    @Test
    fun relay_per_unit_legs_with_upstream_cost_estimated_once() {
        // Relay per-unit multi-leg where every leg reported the actual upstream cost: Relay does not adopt the upstream actual cost and estimates the whole message per unit once (2 images x 0.04), not per leg, which would double it
        val catalog = MetadataClient.ResolvedModelMetadata(
            canonicalModelId = MODEL,
            pricingStatus = "priced",
            pricingUnit = "per_image",
            currencyCode = "USD",
            pricingV2 = PricingV2(
                currencyCode = "USD",
                unit = "per_image",
                base = null,
                contextTiers = emptyList(),
                timeWindows = emptyList(),
                perUnit = 0.04,
            ),
        )
        val leg = ProviderChatResult(
            text = "",
            estimatedCost = 0.03,
            costSource = CostSource.UPSTREAM.name,
            usageReported = false,
        )
        val merged = DeliveredCostResolver.mergeLegs(listOf(leg, leg))
        val parts = DeliveredCostResolver.resolveParts(
            merged,
            AIModel(id = MODEL, name = MODEL),
            Provider(id = "relay-1", kind = ProviderKind.Relay, apiKey = "k"),
            MODEL,
            at = AT,
            units = 2,
            catalog = catalog,
            regionOptions = emptyList(),
        )
        val record = DeliveredCostResolver.record(parts)
        assertEquals(0.08, record.estimatedCost, 1e-12)
        assertEquals(CostSource.LOCAL_ESTIMATE.name, record.costSource)
        assertEquals(null, record.nonUsdCost)
    }
}
