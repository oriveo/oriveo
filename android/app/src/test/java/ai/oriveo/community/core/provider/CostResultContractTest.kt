package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Shared fixture `shared/test-fixtures/provider-pricing/cost-result.v1.json`:
 * the cache-read rate of legacy single-tier pricing resolves as new field > old field > input x 0.5.
 * Each case has one `COST_RESULT_<id>` test, all run through the production [CostCalculator.calcCost]; legacy single-tier cases go through production metadata decoding.
 */
class CostResultContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture: JsonObject by lazy { readJson("shared/test-fixtures/provider-pricing/cost-result.v1.json") }

    private fun case(group: String, id: String): JsonObject =
        fixture.getValue(group).jsonArray.map { it.jsonObject }.single { it["id"]!!.jsonPrimitive.content == id }

    @Test
    fun `fixture ids are exactly the COST_RESULT tests`() {
        val ids = fixture.getValue("legacyCacheReadCases").jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.content }.toSet()
        val tests = javaClass.declaredMethods.map { it.name }.filter { it.startsWith("COST_RESULT_") }
            .map { it.removePrefix("COST_RESULT_") }.toSet()
        assertEquals(ids, tests)
    }

    @Test fun COST_RESULT_new_field_wins() = assertLegacyCacheRead("new_field_wins")
    @Test fun COST_RESULT_old_field_when_new_missing() = assertLegacyCacheRead("old_field_when_new_missing")
    @Test fun COST_RESULT_half_input_when_both_missing() = assertLegacyCacheRead("half_input_when_both_missing")

    // ── helpers ──

    /** Legacy single-tier pricing is decoded through production metadata, then priced at 1M cache-read tokens to get the effective cache-read rate. */
    private fun assertLegacyCacheRead(id: String) {
        val case = case("legacyCacheReadCases", id)
        val payload = buildJsonObject {
            put("version", 1)
            put("providers", buildJsonObject { put("openAI", buildJsonObject {
                put("resolveMap", buildJsonObject { put(MODEL, MODEL) })
                put("models", buildJsonObject { put(MODEL, buildJsonObject {
                    put("canonicalModelId", MODEL)
                    put("pricingStatus", "priced")
                    put("pricingUnit", "per_token")
                    put("pricing", case.getValue("pricing"))
                }) })
            }) })
        }
        val client = MetadataClient().apply { loadNetworkPayloadForTesting(payload.toString(), "\"cost-result\"") }
        val resolved = requireNotNull(client.resolveCatalogModel(MODEL, ProviderKind.OpenAI)) { id }
        val (cost, source) = CostCalculator.calcCost(UsageBreakdown(cachedInputTokens = 1_000_000), resolved, at = Instant.now())
        assertEquals(id, CostSource.LOCAL_ESTIMATE, source)
        assertEquals(id, case.getValue("expect").jsonObject.getValue("cacheReadPerMToken").jsonPrimitive.double, cost, 1e-12)
    }

    private fun repoRoot(): File = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

    private fun readJson(relativePath: String): JsonObject =
        json.parseToJsonElement(File(repoRoot(), relativePath).readText()).jsonObject

    private companion object {
        const val MODEL = "cost-result-model"
    }
}
