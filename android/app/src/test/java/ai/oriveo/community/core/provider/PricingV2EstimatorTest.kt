package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** Shared fixture pricing-v2-estimate.v1: run case by case, test name = case.name. */
@RunWith(Parameterized::class)
class PricingV2EstimatorTest(private val name: String, private val case: JsonObject) {

    @Test
    fun sharedCase() {
        val pricing = PricingV2Estimator.parse(case.getValue("pricingV2"))
        assertNotNull("$name: fixture pricingV2 should parse", pricing)
        val usage = case.getValue("usage").jsonObject
        fun tokens(key: String) = usage.getValue(key).jsonPrimitive.content.toLong()
        val result = PricingV2Estimator.estimate(
            pricing!!,
            PricingV2Usage(
                uncachedInput = tokens("uncachedInputTokens"),
                cacheRead = tokens("cacheReadTokens"),
                cacheWrite5m = tokens("cacheWrite5mTokens"),
                cacheWrite1h = tokens("cacheWrite1hTokens"),
                output = tokens("outputTokens"),
            ),
            Instant.parse(case.getValue("at").jsonPrimitive.content),
        )
        val expected = case.getValue("expected").jsonObject
        when (val status = expected.getValue("status").jsonPrimitive.content) {
            "estimated" -> {
                val estimated = result as? PricingV2Estimate.Estimated
                    ?: throw AssertionError("$name: expected estimated, got $result")
                assertEquals("$name: amount", expected.getValue("amount").jsonPrimitive.content.toDouble(), estimated.amount, 1e-9)
                val currency = expected["currencyCode"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content
                assertEquals("$name: currencyCode", currency, estimated.currencyCode)
            }
            "unavailable" -> assertEquals("$name: status", PricingV2Estimate.Unavailable, result)
            "not_applicable" -> assertEquals("$name: status", PricingV2Estimate.NotApplicable, result)
            else -> throw AssertionError("$name: unknown status $status")
        }
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = PricingV2Fixture.cases().map { arrayOf(it.getValue("name").jsonPrimitive.content, it) }
    }
}

/** Decoding rules are shared by all four clients: only shapes matching `$defs/pricingV2` of metadata_payload.v2.schema.json are accepted, and a violation drops the whole pricingV2. */
@RunWith(Parameterized::class)
class PricingV2SchemaShapeTest(private val name: String, private val json: String, private val accepted: Boolean) {

    @Test
    fun shape() {
        val parsed = PricingV2Estimator.parse(Json.parseToJsonElement(json))
        if (accepted) assertNotNull("$name: a conforming shape should be kept", parsed) else assertNull("$name: a violating shape should drop the whole pricingV2", parsed)
    }

    companion object {
        private const val BASE = """"base":{"inputPerMToken":2,"outputPerMToken":8}"""
        private const val TIER = """"aboveInputTokens":1000,"semantics":"whole_request""""
        private const val WINDOW = """"timezone":"UTC","start":"00:00","end":"24:00""""

        private fun v2(members: String) = """{"unit":"per_token",$BASE${if (members.isEmpty()) "" else ",$members"}}"""

        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = listOf(
            arrayOf("valid-minimal", v2(""), true),
            arrayOf("negative-price-accepted", """{"unit":"per_token","base":{"inputPerMToken":-1,"outputPerMToken":8},"contextTiers":[{$TIER,"inputPerMToken":-2}]}""", true),
            arrayOf("end-24-00-accepted", v2(""""timeWindows":[{$WINDOW}]"""), true),
            arrayOf("full-valid-accepted", v2(""""currencyCode":"USD","cache":{"readPerMToken":0.5,"writes":[{"ttl":"5m","perMToken":2.5},{"ttl":"1h","perMToken":4}]},"timeWindows":[{$WINDOW,"days":["monday"],"holidayCalendar":"cn_statutory","multiplier":0.5}],"regionSurcharges":[{"regionScope":"cn","multiplier":1.1}],"perUnit":0.1"""), true),
            arrayOf("unknown-ttl", v2(""""cache":{"writes":[{"ttl":"30m","perMToken":2.5}]}"""), false),
            arrayOf("start-24-00", v2(""""timeWindows":[{"timezone":"UTC","start":"24:00","end":"24:00"}]"""), false),
            arrayOf("start-one-digit-hour", v2(""""timeWindows":[{"timezone":"UTC","start":"8:00","end":"09:00"}]"""), false),
            arrayOf("end-bad-format", v2(""""timeWindows":[{"timezone":"UTC","start":"08:00","end":"9:00"}]"""), false),
            arrayOf("unknown-unit", """{"unit":"per_call",$BASE}""", false),
            arrayOf("unknown-semantics", v2(""""contextTiers":[{"aboveInputTokens":1000,"semantics":"stepwise"}]"""), false),
            arrayOf("unknown-holiday-calendar", v2(""""timeWindows":[{$WINDOW,"holidayCalendar":"us_federal"}]"""), false),
            arrayOf("unknown-day", v2(""""timeWindows":[{$WINDOW,"days":["Monday"]}]"""), false),
            arrayOf("unknown-top-key", v2(""""discount":0.1"""), false),
            arrayOf("unknown-base-key", """{"unit":"per_token","base":{"inputPerMToken":2,"outputPerMToken":8,"reasoningPerMToken":1}}""", false),
            arrayOf("unknown-cache-key", v2(""""cache":{"readPerMToken":0.5,"storagePerMToken":1}"""), false),
            arrayOf("unknown-write-key", v2(""""cache":{"writes":[{"ttl":"5m","perMToken":2.5,"note":"x"}]}"""), false),
            arrayOf("unknown-tier-key", v2(""""contextTiers":[{$TIER,"label":"long"}]"""), false),
            arrayOf("unknown-window-key", v2(""""timeWindows":[{$WINDOW,"cacheWritePerMToken":1}]"""), false),
            arrayOf("unknown-region-key", v2(""""regionSurcharges":[{"regionScope":"cn","multiplier":1.1,"note":"x"}]"""), false),
            arrayOf("missing-unit", """{$BASE}""", false),
            arrayOf("missing-tier-aboveInputTokens", v2(""""contextTiers":[{"semantics":"whole_request"}]"""), false),
            arrayOf("missing-tier-semantics", v2(""""contextTiers":[{"aboveInputTokens":1000}]"""), false),
            arrayOf("missing-window-timezone", v2(""""timeWindows":[{"start":"00:00","end":"24:00"}]"""), false),
            arrayOf("missing-window-start", v2(""""timeWindows":[{"timezone":"UTC","end":"24:00"}]"""), false),
            arrayOf("missing-window-end", v2(""""timeWindows":[{"timezone":"UTC","start":"00:00"}]"""), false),
            arrayOf("missing-region-scope", v2(""""regionSurcharges":[{"multiplier":1.1}]"""), false),
            arrayOf("missing-region-multiplier", v2(""""regionSurcharges":[{"regionScope":"cn"}]"""), false),
            arrayOf("missing-write-ttl", v2(""""cache":{"writes":[{"perMToken":2.5}]}"""), false),
            arrayOf("missing-write-perMToken", v2(""""cache":{"writes":[{"ttl":"5m"}]}"""), false),
        )
    }
}

/** Real metadata JSON -> MetadataClient decoding -> CostCalculator.calcCost production entry. */
class PricingV2ProductionPathTest {

    @Test
    fun `shared fixture runs all 24 cases`() {
        assertEquals(24, PricingV2Fixture.cases().size)
    }

    @Test
    fun `decoded pricingV2 drives calcCost with tier and window`() {
        val meta = resolve(
            """
            "pricingV2":{"currencyCode":"USD","unit":"per_token",
              "base":{"inputPerMToken":2.0,"outputPerMToken":8.0},
              "cache":{"readPerMToken":0.5,"writes":[{"ttl":"5m","perMToken":2.5},{"ttl":"1h","perMToken":4.0}]},
              "contextTiers":[{"aboveInputTokens":1000,"semantics":"whole_request","inputPerMToken":4.0,"outputPerMToken":12.0}],
              "timeWindows":[{"timezone":"UTC","start":"10:00","end":"14:00","multiplier":0.5}]}
            """,
        )
        assertNotNull("pricingV2 should decode into ResolvedModelMetadata", meta.pricingV2)
        val breakdown = UsageBreakdown(promptTokens = 1500, cachedInputTokens = 1000, completionTokens = 1000)
        // Tier: input 2500 > 1000 -> in 4 / out 12 / read 0.5 (inherited from base); window x0.5
        val (inWindow, source) = CostCalculator.calcCost(breakdown, meta, at = Instant.parse("2026-10-19T12:00:00Z"))
        assertEquals(CostSource.LOCAL_ESTIMATE, source)
        assertEquals((1500 * 4.0 + 1000 * 0.5 + 1000 * 12.0) * 0.5 / 1e6, inWindow, 1e-12)
        val (outWindow, _) = CostCalculator.calcCost(breakdown, meta, at = Instant.parse("2026-10-19T15:00:00Z"))
        assertEquals((1500 * 4.0 + 1000 * 0.5 + 1000 * 12.0) / 1e6, outWindow, 1e-12)
    }

    @Test
    fun `pricingV2 without output price reports unknown not zero`() {
        val meta = resolve(""""pricingV2":{"currencyCode":"USD","unit":"per_token","base":{"inputPerMToken":2.0}}""")
        val (_, source) = CostCalculator.calcCost(UsageBreakdown(promptTokens = 10, completionTokens = 10), meta, at = Instant.parse("2026-10-19T12:00:00Z"))
        assertEquals(CostSource.UNKNOWN, source)
    }

    @Test
    fun `unknown legacy pricingStatus ignores pricingV2 and reports unknown`() {
        val meta = resolve(
            """"pricingV2":{"currencyCode":"USD","unit":"per_token","base":{"inputPerMToken":2.0,"outputPerMToken":8.0}}""",
            pricingStatus = "unknown",
        )
        assertNotNull(meta.pricingV2)
        val (cost, source) = CostCalculator.calcCost(UsageBreakdown(promptTokens = 1000, completionTokens = 1000), meta, at = Instant.parse("2026-10-19T12:00:00Z"))
        assertEquals(CostSource.UNKNOWN, source)
        assertEquals(0.0, cost, 0.0)
    }

    @Test
    fun `malformed pricingV2 keeps the model and falls back to legacy pricing`() {
        val meta = resolve(""""pricingV2":{"unit":"per_token","base":[1,2]}""")
        assertNull(meta.pricingV2)
        val (cost, source) = CostCalculator.calcCost(UsageBreakdown(promptTokens = 1000, completionTokens = 1000), meta, at = Instant.parse("2026-10-19T12:00:00Z"))
        assertEquals(CostSource.LOCAL_ESTIMATE, source)
        assertEquals((1000 * 1.0 + 1000 * 3.0) / 1e6, cost, 1e-12)
    }

    @Test
    fun `non per_token pricingV2 prices per unit from pricingV2`() {
        // Per-unit pricing unit and price read pricingV2 first: the legacy per_token price does not take part and nothing is priced per token.
        val meta = resolve(""""pricingV2":{"currencyCode":"USD","unit":"per_image","perUnit":0.04}""")
        assertEquals(0.04, meta.pricingV2?.perUnit)
        val estimate = CostCalculator.estimate(
            UsageBreakdown(promptTokens = 1000, completionTokens = 1000), meta, at = Instant.parse("2026-10-19T12:00:00Z"), units = 2,
        )
        assertEquals(CostSource.LOCAL_ESTIMATE, estimate.source)
        assertEquals(0.08, estimate.amount, 1e-12)
    }

    private fun resolve(pricingV2Member: String, pricingStatus: String = "priced"): MetadataClient.ResolvedModelMetadata {
        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(
            """
            {"version":1,"providers":{"openAI":{"resolveMap":{"pv2-model":"pv2-model"},"models":{"pv2-model":{
              "canonicalModelId":"pv2-model","pricingUnit":"per_token","pricingStatus":"$pricingStatus",
              "pricing":{"promptPerMToken":1.0,"completionPerMToken":3.0},
              ${pricingV2Member.trim()}
            }}}}}
            """.trimIndent(),
            "\"pricing-v2-production\"",
        )
        return client.resolveCatalogModel("pv2-model", ProviderKind.OpenAI)
            ?: throw AssertionError("the model should stay usable whether pricingV2 is good or bad")
    }
}

private object PricingV2Fixture {
    fun cases(): List<JsonObject> =
        Json.parseToJsonElement(workspaceFile("shared/test-fixtures/provider-pricing/pricing-v2-estimate.v1.json").readText())
            .jsonObject.getValue("cases").jsonArray.map { it.jsonObject }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("not found: $relative")
    }
}
