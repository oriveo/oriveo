package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataPayloadSchemaValidator
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import java.io.File
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Shared fixture `shared/test-fixtures/provider-pricing/region-pricing.v1.json`:
 * the model JSON first passes the production schema 2 validation (a bad regionPricing item drops only that item, the model stays), then production metadata decoding yields
 * [MetadataClient.ResolvedModelMetadata], [RegionPricingSelector] picks the price by the connection's effective region, and finally [CostCalculator.estimate] estimates the cost.
 */
class RegionPricingContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture: JsonObject by lazy { readJson("shared/test-fixtures/provider-pricing/region-pricing.v1.json") }
    private val validator by lazy {
        MetadataPayloadSchemaValidator(readJson("shared/model-contracts/metadata_payload.v2.schema.json"))
    }

    @Test
    fun `fixture ids are exactly the tests`() {
        val ids = fixture.getValue("cases").jsonArray.map { it.jsonObject.getValue("id").jsonPrimitive.content }.toSet()
        val tests = javaClass.declaredMethods.map { it.name }.filter { it.startsWith("REGION_PRICING_") }
            .map { it.removePrefix("REGION_PRICING_") }.toSet()
        assertEquals(ids, tests)
    }

    @Test fun REGION_PRICING_cn_connection_uses_cny_entry() = assertCase("cn_connection_uses_cny_entry")
    @Test fun REGION_PRICING_intl_connection_uses_model_level() = assertCase("intl_connection_uses_model_level")
    @Test fun REGION_PRICING_no_stored_choice_matches_base_url() = assertCase("no_stored_choice_matches_base_url")
    @Test fun REGION_PRICING_no_choice_no_match_takes_first_option() = assertCase("no_choice_no_match_takes_first_option")
    @Test fun REGION_PRICING_malformed_entry_dropped_model_kept() = assertCase("malformed_entry_dropped_model_kept")
    @Test fun REGION_PRICING_unlisted_region_falls_back_to_model_level() = assertCase("unlisted_region_falls_back_to_model_level")
    @Test fun REGION_PRICING_cn_only_entry_prices_otherwise_unknown_model() = assertCase("cn_only_entry_prices_otherwise_unknown_model")
    @Test fun REGION_PRICING_cn_only_model_outside_cn_is_unavailable() = assertCase("cn_only_model_outside_cn_is_unavailable")
    @Test fun REGION_PRICING_relay_connection_ignores_region_pricing() = assertCase("relay_connection_ignores_region_pricing")
    @Test fun REGION_PRICING_unknown_payload_keys_ignored() = assertCase("unknown_payload_keys_ignored")

    // ── helpers ──

    private fun assertCase(id: String) {
        val case = fixture.getValue("cases").jsonArray.map { it.jsonObject }.single { it.getValue("id").jsonPrimitive.content == id }
        val model = modelJson(case)
        val resolved = decode(id, model)
        val kind = if (case["connectionKind"]?.jsonPrimitive?.content == "relay") ProviderKind.Relay else ProviderKind.Moonshot
        val regionOptions = (case["regionOptions"] as? JsonArray).orEmpty().map {
            val option = it.jsonObject
            val optionId = option.getValue("id").jsonPrimitive.content
            RegionOption(optionId, optionId, option.getValue("baseURL").jsonPrimitive.content)
        }
        val selected = RegionPricingSelector.select(
            model = resolved,
            regionOptions = regionOptions,
            endpointSource = (case["connectionRegion"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
                ?.let(OfficialEndpointSource::region),
            baseUrl = (case["connectionBaseURL"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content,
            kind = kind,
        )
        val usage = case.getValue("usage").jsonObject
        val estimate = CostCalculator.estimate(
            breakdown = UsageBreakdown(
                promptTokens = usage["inputTokens"]?.jsonPrimitive?.int ?: 0,
                completionTokens = usage["outputTokens"]?.jsonPrimitive?.int ?: 0,
            ),
            pricing = selected,
            at = Instant.now(),
            units = usage["images"]?.jsonPrimitive?.int ?: 1,
        )
        val expect = case.getValue("expect").jsonObject
        when (expect.getValue("status").jsonPrimitive.content) {
            "estimated" -> {
                assertEquals(id, CostSource.LOCAL_ESTIMATE, estimate.source)
                assertEquals(id, expect.getValue("amount").jsonPrimitive.double, estimate.amount, 1e-9)
                assertEquals(id, expect.getValue("currencyCode").jsonPrimitive.content, estimate.currencyCode)
            }
            // Price unknown (shown as "not available"), not zero cost.
            "unavailable" -> assertEquals(id, CostSource.UNKNOWN, estimate.source)
            else -> error("$id: unknown status")
        }
    }

    /** A fixture model overrides / appends the first regionPricing item per case; fills in the displayName that the schema requires. */
    private fun modelJson(case: JsonObject): JsonObject {
        val base = fixture.getValue(case.getValue("modelRef").jsonPrimitive.content).jsonObject
        val entries = base.getValue("regionPricing").jsonArray.map { it.jsonObject }.toMutableList()
        case["entryOverride"]?.let { entries[0] = it.jsonObject }
        case["entryExtraKeys"]?.let { entries[0] = JsonObject(entries[0] + it.jsonObject) }
        return JsonObject(base + mapOf("displayName" to JsonPrimitive(MODEL), "regionPricing" to JsonArray(entries)))
    }

    /** Production schema 2 validation (the model must be kept) + production metadata decoding. */
    private fun decode(id: String, model: JsonObject): MetadataClient.ResolvedModelMetadata {
        val catalog = buildJsonObject {
            put("view", "catalog")
            put("provider", "moonshot")
            put("metadataSchema", 2)
            put("metadataRevision", 7)
            put("generatedAt", "2026-10-19T00:00:00Z")
            put("catalogRevision", "sha256:" + "0".repeat(64))
            put("models", buildJsonObject { put(MODEL, model) })
        }
        val result = validator.decode(catalog)
        assertEquals("$id: envelope", null, result.envelopeError)
        assertEquals("$id: model kept", listOf(MODEL), result.keptModels)
        val payload = buildJsonObject {
            put("version", 1)
            put("providers", buildJsonObject { put("openAI", buildJsonObject {
                put("resolveMap", buildJsonObject { put(MODEL, MODEL) })
                put("models", buildJsonObject { put(MODEL, model) })
            }) })
        }
        val client = MetadataClient().apply { loadNetworkPayloadForTesting(payload.toString(), "\"region-pricing\"") }
        return requireNotNull(client.resolveCatalogModel(MODEL, ProviderKind.OpenAI)) { id }
    }

    private fun repoRoot(): File = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

    private fun readJson(relativePath: String): JsonObject =
        json.parseToJsonElement(File(repoRoot(), relativePath).readText()).jsonObject

    private companion object {
        const val MODEL = "region-pricing-model"
    }
}
