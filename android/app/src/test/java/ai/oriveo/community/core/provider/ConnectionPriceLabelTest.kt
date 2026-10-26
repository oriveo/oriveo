package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import ai.oriveo.community.feature.modelpicker.modelPickerPricePresentation
import ai.oriveo.community.ui.component.normalizedPriceTier
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Unit price label by connection region: with a connection context it goes through [pricedForConnection] (the same price-selection entry as delivered cost),
 * picks the price and displays it in the selected currency; without a connection context the model-level price is kept. Prices come from kimi-example / image-cn-only in the region-pricing.v1.json fixture.
 */
class ConnectionPriceLabelTest {

    @Test
    fun moonshot_cn_connection_labels_in_cny() {
        val priced = modelLayer().pricedForConnection(moonshot(region = "cn"), catalog = kimi(), regionOptions = REGIONS)

        assertEquals("CNY", priced.currencyCode)
        assertEquals("¥4/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
        val picker = priced.model.modelPickerPricePresentation(priced.currencyCode, Locale.CHINA)
        assertEquals("¥4/M", picker.input)
        assertEquals("¥16/M", picker.output)
    }

    @Test
    fun moonshot_cn_base_url_without_stored_choice_labels_in_cny() {
        val provider = moonshot(region = null).copy(baseUrlText = "https://api.moonshot.cn/v1")
        val priced = modelLayer().pricedForConnection(provider, catalog = kimi(), regionOptions = REGIONS)

        assertEquals("CNY", priced.currencyCode)
        assertEquals("¥4/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
    }

    @Test
    fun moonshot_intl_connection_labels_in_usd() {
        val model = modelLayer()
        val priced = model.pricedForConnection(moonshot(region = "intl"), catalog = kimi(), regionOptions = REGIONS)

        assertEquals("USD", priced.currencyCode)
        assertSame(model, priced.model)
        assertEquals("$0.6/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
    }

    @Test
    fun no_connection_keeps_model_layer_price() {
        val model = modelLayer()
        val priced = model.pricedForConnection(provider = null, catalog = kimi(), regionOptions = REGIONS)

        assertSame(model, priced.model)
        assertEquals("$0.6/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
    }

    @Test
    fun cn_only_model_outside_cn_is_unknown_not_zero() {
        val model = AIModel(id = CN_ONLY, name = "Image CN Only", priceTier = "Price unknown")
        val priced = model.pricedForConnection(moonshot(region = "intl"), catalog = cnOnly(), regionOptions = REGIONS)

        val label = priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA)
        assertEquals("Price unknown", label)
        assertFalse(label.contains("0"))
    }

    @Test
    fun relay_connection_does_not_select_region() {
        val model = modelLayer()
        val relay = moonshot(region = "cn").copy(kind = ProviderKind.Relay)
        val priced = model.pricedForConnection(relay, catalog = kimi(), regionOptions = REGIONS)

        assertSame(model, priced.model)
        assertEquals("USD", priced.currencyCode)
    }

    @Test
    fun relay_matching_official_cny_model_labels_in_cny() {
        val relay = moonshot(region = "cn").copy(kind = ProviderKind.Relay)
        val cnyModelLayer = kimi().copy(currencyCode = "CNY", promptPerToken = 4e-6, completionPerToken = 16e-6)
        val priced = modelLayer().pricedForConnection(relay, catalog = cnyModelLayer, regionOptions = REGIONS)

        assertEquals("CNY", priced.currencyCode)
        assertEquals("¥4/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
    }

    // -- No connection context: read the catalog model-level price and currency; the stored string is only a fallback when the catalog has no match --

    @Test
    fun no_connection_cny_model_layer_labels_in_cny() {
        MetadataTestFixtures.applyRaw(cnyOnlyCatalog())
        // The stored string is the legacy US-dollar notation: it must not be shown as-is when the catalog matches.
        val model = AIModel(id = CNY_MODEL, name = "Cny Model", priceTier = "$4/M", promptPrice = 4e-6, completionPrice = 16e-6)

        val priced = model.pricedForConnection(provider = null)

        assertEquals("CNY", priced.currencyCode)
        val label = priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA)
        assertEquals("¥4/M", label)
        assertFalse(label.contains("$"))
    }

    @Test
    fun no_connection_model_missing_from_catalog_keeps_stored_tier() {
        MetadataTestFixtures.applyRaw(cnyOnlyCatalog())
        val model = AIModel(id = "relay-hand-typed", name = "Hand Typed", priceTier = "$9/M", promptPrice = 9e-6)

        val priced = model.pricedForConnection(provider = null)

        assertSame(model, priced.model)
        assertEquals("$9/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
    }

    @Test
    fun no_connection_label_refreshes_when_metadata_arrives_late() {
        MetadataTestFixtures.clear()
        val model = AIModel(id = CNY_MODEL, name = "Cny Model", priceTier = "$4/M", promptPrice = 4e-6, completionPrice = 16e-6)
        val before = connectionPriceLabelKey(null, model)
        assertEquals("$4/M", model.pricedForConnection(null).let { it.model.normalizedPriceTier(it.currencyCode, Locale.CHINA) })

        MetadataClient.instance.loadNetworkPayloadForTesting(cnyOnlyCatalog(), responseETag = "no-connection-late")
        val after = connectionPriceLabelKey(null, model)

        assertNotEquals(before, after)
        val priced = model.pricedForConnection(null)
        assertEquals("CNY", priced.currencyCode)
        assertEquals("¥4/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
    }

    @Test
    fun stored_non_usd_price_tier_is_not_usd_spelled() {
        val cny = kimi().copy(currencyCode = "CNY", promptPerToken = 4e-6, completionPerToken = 16e-6)

        val tier = CatalogModelBuilder.pricePresentation(cny).priceTier

        assertFalse(tier, tier.contains("$"))
        assertEquals("$0.6/M", CatalogModelBuilder.pricePresentation(kimi()).priceTier)
    }

    @After
    fun clearGlobalMetadata() = MetadataTestFixtures.clear()

    // -- Divergence: when several Relay catalogs hit the same id, pick the catalog by delivery protocol (same value as the billing relayDeliveredTransport) --

    @Test
    fun relay_anthropic_transport_labels_from_anthropic_catalog_entry() {
        MetadataTestFixtures.applyRaw(dupAcrossProviders())
        val relay = relayProvider()
        val model = AIModel(id = DUP, name = "Dup", promptPrice = 1e-6, completionPrice = 2e-6)
            .copy(relayTransport = RelayTransport.AnthropicMessages)

        val priced = model.pricedForConnection(relay)

        assertEquals("CNY", priced.currencyCode)
        assertEquals("¥4/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
    }

    @Test
    fun relay_chat_completions_transport_labels_from_openai_catalog_entry() {
        MetadataTestFixtures.applyRaw(dupAcrossProviders())
        val model = AIModel(id = DUP, name = "Dup", promptPrice = 1e-6, completionPrice = 2e-6)

        val priced = model.pricedForConnection(relayProvider())

        assertEquals("USD", priced.currencyCode)
        assertSame(model, priced.model)
        assertEquals("$1/M", priced.model.normalizedPriceTier(priced.currencyCode, Locale.CHINA))
    }

    // -- Precision: non-USD and USD per-million prices share the same tier and rounding, each picking its tier by its own amount --

    @Test
    fun non_usd_per_million_uses_usd_precision_tiers() {
        // Integers carry no decimals
        assertEquals("$4/M", ModelPricingFormatter.formatPerMillionValue(4e-6, "USD", Locale.CHINA))
        assertEquals("¥4/M", ModelPricingFormatter.formatPerMillionValue(4e-6, "CNY", Locale.CHINA))
        // >= 0.01: at most 3 decimals; exactly at the midpoint it rounds to even like USD (0.0625 -> 0.062)
        assertEquals("$0.062/M", ModelPricingFormatter.formatPerMillionValue(0.0625e-6, "USD", Locale.CHINA))
        assertEquals("¥0.062/M", ModelPricingFormatter.formatPerMillionValue(0.0625e-6, "CNY", Locale.CHINA))
        assertEquals("$1.235/M", ModelPricingFormatter.formatPerMillionValue(1.23456e-6, "USD", Locale.CHINA))
        assertEquals("¥1.235/M", ModelPricingFormatter.formatPerMillionValue(1.23456e-6, "CNY", Locale.CHINA))
        // < 0.01: at most 8 decimals
        assertEquals("$0.00123457/M", ModelPricingFormatter.formatPerMillionValue(0.00123456789e-6, "USD", Locale.CHINA))
        assertEquals("¥0.00123457/M", ModelPricingFormatter.formatPerMillionValue(0.00123456789e-6, "CNY", Locale.CHINA))
    }

    // -- Latent: the remember key carries the metadata revision, so labels re-pick their price after a catalog refresh --

    @Test
    fun label_key_changes_when_metadata_revision_changes() {
        val relay = relayProvider()
        val model = AIModel(id = DUP, name = "Dup", promptPrice = 1e-6, completionPrice = 2e-6)
            .copy(relayTransport = RelayTransport.AnthropicMessages)
        MetadataTestFixtures.applyRaw(dupAcrossProviders(anthropicCurrency = "USD"))
        val before = connectionPriceLabelKey(relay, model)
        assertEquals("USD", model.pricedForConnection(relay).currencyCode)

        MetadataClient.instance.loadNetworkPayloadForTesting(dupAcrossProviders(), responseETag = "label-revision-2")
        val after = connectionPriceLabelKey(relay, model)

        assertNotEquals(before, after)
        assertEquals("CNY", model.pricedForConnection(relay).currencyCode)
    }

    private fun relayProvider() = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        apiKey = "local-key",
        baseUrlText = "https://relay.example.com/v1",
    )

    /** The same model id appears in both the openAI (USD 1 / 2) and anthropic (default CNY 4 / 16) catalogs. */
    private fun dupAcrossProviders(anthropicCurrency: String = "CNY"): String = """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {
            "openAI": {
              "resolveMap": {"$DUP": "$DUP"},
              "models": {
                "$DUP": {
                  "canonicalModelId": "$DUP",
                  "displayName": "Dup",
                  "currencyCode": "USD",
                  "pricingStatus": "priced",
                  "pricingUnit": "per_token",
                  "pricing": {"promptPerMToken": 1.0, "completionPerMToken": 2.0},
                  "capabilities": ["text"]
                }
              }
            },
            "anthropic": {
              "resolveMap": {"$DUP": "$DUP"},
              "models": {
                "$DUP": {
                  "canonicalModelId": "$DUP",
                  "displayName": "Dup",
                  "currencyCode": "$anthropicCurrency",
                  "pricingStatus": "priced",
                  "pricingUnit": "per_token",
                  "pricing": {"promptPerMToken": 4.0, "completionPerMToken": 16.0},
                  "capabilities": ["text"]
                }
              }
            }
          }
        }
    """.trimIndent()

    /** A model-level CNY price (4 / 16 per million) that exists only in the anthropic catalog; a connection-less lookup is never captured first by another vendor's same id. */
    private fun cnyOnlyCatalog(): String = """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {
            "anthropic": {
              "resolveMap": {"$CNY_MODEL": "$CNY_MODEL"},
              "models": {
                "$CNY_MODEL": {
                  "canonicalModelId": "$CNY_MODEL",
                  "displayName": "Cny Model",
                  "currencyCode": "CNY",
                  "pricingStatus": "priced",
                  "pricingUnit": "per_token",
                  "pricing": {"promptPerMToken": 4.0, "completionPerMToken": 16.0},
                  "capabilities": ["text"]
                }
              }
            }
          }
        }
    """.trimIndent()

    private fun moonshot(region: String?) = Provider(
        id = "moonshot-1",
        kind = ProviderKind.Moonshot,
        apiKey = "local-key",
        baseUrlText = "https://api.moonshot.ai/v1",
        endpointSource = region?.let(OfficialEndpointSource::region),
    )

    /** Local model-level (intl / USD) snapshot: 0.6 / 2.5 USD per million tokens. */
    private fun modelLayer() = AIModel(
        id = MODEL,
        name = "Kimi Example",
        promptPrice = 0.6e-6,
        completionPrice = 2.5e-6,
    )

    private fun kimi(): MetadataClient.ResolvedModelMetadata = MetadataClient.ResolvedModelMetadata(
        canonicalModelId = MODEL,
        pricingStatus = "priced",
        promptPerToken = 0.6e-6,
        completionPerToken = 2.5e-6,
        currencyCode = "USD",
        regionPricing = listOf(
            MetadataClient.RegionPricingEntry(
                "cn",
                priceKeys(currency = "CNY", status = "priced", unit = "per_token", prompt = 4e-6, completion = 16e-6),
            ),
        ),
    )

    private fun cnOnly(): MetadataClient.ResolvedModelMetadata = MetadataClient.ResolvedModelMetadata(
        canonicalModelId = CN_ONLY,
        pricingStatus = "unknown",
        regionPricing = listOf(
            MetadataClient.RegionPricingEntry(
                "cn",
                priceKeys(currency = "CNY", status = "priced", unit = "per_image", costPerUnit = 0.025),
            ),
        ),
    )

    private fun priceKeys(
        currency: String,
        status: String,
        unit: String,
        prompt: Double? = null,
        completion: Double? = null,
        costPerUnit: Double? = null,
    ) = MetadataClient.PriceKeys(
        currencyCode = currency,
        pricingStatus = status,
        pricingUnit = unit,
        promptPerToken = prompt,
        completionPerToken = completion,
        costPerUnit = costPerUnit,
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

    private companion object {
        const val MODEL = "kimi-example"
        const val CN_ONLY = "image-cn-only"
        const val DUP = "dup-model"
        const val CNY_MODEL = "cny-model"
        val REGIONS = listOf(
            RegionOption("intl", "International", "https://api.moonshot.ai/v1"),
            RegionOption("cn", "China", "https://api.moonshot.cn/v1"),
        )
    }
}
