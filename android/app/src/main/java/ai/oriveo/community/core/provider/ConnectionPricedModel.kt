package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.core.provider.relay.RelayFirstSendTransport

/** Model for unit-price labels: the price fields of [model] are already selected per connection, [currencyCode] is the currency of those prices (uppercase ISO 4217). */
data class ConnectionPricedModel(val model: AIModel, val currencyCode: String)

/**
 * Price selection for unit-price labels with a connection context:
 * it shares the entry point [DeliveredCostResolver.connectionPricing] with delivered billing (connection region: saved option > baseURL > first item; Relay / custom do not select a region).
 * When no regional entry is selected and the currency is USD the model is returned as is (model-level price, zero regression); otherwise the price fields are replaced by the selected prices and shown in their currency.
 * Without a connection context ([provider] is null) no region is selected and the catalog model-level price is used; when the catalog lookup fails the local model (including stored strings) is kept.
 */
fun AIModel.pricedForConnection(
    provider: Provider?,
    catalog: MetadataClient.ResolvedModelMetadata? = null,
    regionOptions: List<RegionOption>? = null,
): ConnectionPricedModel {
    val usd = ConnectionPricedModel(this, DeliveredCostResolver.USD)
    // Relay does not select a region (the price selector returns the model-level price as is), but the label still uses the currency of the model-level price: labels only show catalog prices, regardless of whether billing estimates.
    // Without a connection context: no region is selected, use the catalog model-level price and its currency; only fall back to the stored string (e.g. a hand-entered Relay price) when the catalog has no match.
    if (provider == null) {
        val base = catalog ?: MetadataClient.resolveCatalogModelInLoadedCatalogs(id) ?: return usd
        return pricedFrom(base, DeliveredCostResolver.pricingCurrency(base))
    }
    // Relay cross-vendor catalog matching prefers the protocol family: same transport as delivered billing and capability inheritance ([RelayFirstSendTransport.resolve]),
    // otherwise an id shared by several vendors could match different official models for the label and for billing.
    val relayTransport = if (provider.kind == ProviderKind.Relay) RelayFirstSendTransport.resolve(provider, this) else null
    val pricing = when {
        catalog != null && regionOptions != null -> DeliveredCostResolver.connectionPricing(
            provider, id, relayTransport = relayTransport, canonicalModelId = canonicalModelId,
            catalog = catalog, regionOptions = regionOptions,
        )
        catalog != null -> DeliveredCostResolver.connectionPricing(
            provider, id, relayTransport = relayTransport, canonicalModelId = canonicalModelId, catalog = catalog,
        )
        else -> DeliveredCostResolver.connectionPricing(provider, id, relayTransport = relayTransport, canonicalModelId = canonicalModelId)
    } ?: return usd
    if (!pricing.regionEntryChosen && pricing.currencyCode == DeliveredCostResolver.USD) return usd
    return pricedFrom(pricing.selected, pricing.currencyCode)
}

/** Replaces the price fields with [selected] and shows them in [currencyCode]; returns the original model if the result is identical (zero regression). */
private fun AIModel.pricedFrom(
    selected: MetadataClient.ResolvedModelMetadata,
    currencyCode: String,
): ConnectionPricedModel {
    val presentation = CatalogModelBuilder.pricePresentation(selected)
    // Pre-rendered price strings use dollar notation: keep only the sentinels (Free / price unknown / non-standard billing); numeric labels are formatted by the display layer per currency.
    val tier = presentation.priceTier.takeIf { it in PRICE_TIER_SENTINELS }.orEmpty()
    val priced = copy(
        priceTier = tier,
        promptPrice = presentation.promptPrice,
        completionPrice = presentation.completionPrice,
        pricingUnit = selected.pricingUnit,
        costPerUnit = selected.costPerUnit,
        cacheReadInputPerMToken = selected.cacheReadInputPerMToken,
        cacheCreationInputPerMToken = selected.cacheCreationInputPerMToken,
        cacheWrite5mPerMToken = selected.cacheWrite5mPerMToken,
        cacheWrite1hPerMToken = selected.cacheWrite1hPerMToken,
    )
    return ConnectionPricedModel(if (priced == this) this else priced, currencyCode)
}

/**
 * Key for remembering a unit-price label: connection, model and metadata publish revision. When the catalog refreshes the revision changes,
 * so the label re-selects prices from the new catalog instead of reusing prices and currency computed from the old one.
 */
internal fun connectionPriceLabelKey(provider: Provider?, model: AIModel): List<Any?> =
    listOf(provider, model, MetadataClient.instance.currentMetadataRevision())

private val PRICE_TIER_SENTINELS = setOf("Free", "Price unknown", "Non-standard billing")
