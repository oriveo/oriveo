package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource

/**
 * Price selection by the connection's effective region (fixture `shared/test-fixtures/provider-pricing/region-pricing.v1.json`).
 *
 * Effective region = saved region option > option matching the connection URL > first option; when it equals an option's regionScope, that option replaces the
 * five model-level price keys as a whole, otherwise the model-level prices are used. Relay and custom endpoints do not select a region. The estimate currency is the currency of the selected prices, with no conversion.
 */
object RegionPricingSelector {

    fun select(
        model: MetadataClient.ResolvedModelMetadata,
        regionOptions: List<RegionOption>,
        endpointSource: String?,
        baseUrl: String?,
        kind: ProviderKind,
        setupValues: Map<String, String>? = null,
    ): MetadataClient.ResolvedModelMetadata {
        if (kind == ProviderKind.Relay || endpointSource == OfficialEndpointSource.CUSTOM) return model
        if (model.regionPricing.isEmpty()) return model
        val region = effectiveRegion(regionOptions, endpointSource, baseUrl, setupValues) ?: return model
        val entry = model.regionPricing.firstOrNull { it.regionScope == region } ?: return model
        return model.withPrice(entry.price)
    }

    /** URL matching follows [OfficialEndpointSource.classify]: option URLs are filled with the locally built values and then compared after normalization. */
    private fun effectiveRegion(
        regionOptions: List<RegionOption>,
        endpointSource: String?,
        baseUrl: String?,
        setupValues: Map<String, String>?,
    ): String? {
        OfficialEndpointSource.regionId(endpointSource)?.let { return it }
        val normalized = OfficialEndpointSource.normalize(baseUrl)
        if (normalized != null) {
            regionOptions.firstOrNull { option ->
                OfficialEndpointSource.fill(option.baseURL, setupValues)?.let(OfficialEndpointSource::normalize) == normalized
            }?.let { return it.id }
        }
        return regionOptions.firstOrNull()?.id
    }
}
