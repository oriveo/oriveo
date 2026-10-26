package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.CostFormatter
import ai.oriveo.community.core.model.NonUsdCost
import ai.oriveo.community.core.usage.CostPart
import ai.oriveo.community.core.usage.CostParts
import java.io.File
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Shared fixture `shared/test-fixtures/provider-pricing/cost-currency.v1.json`:
 * totalCases feed the production grouping [CostParts.messageAmounts] + [CostParts.split]: totals accumulate per currency, USD first and the rest ascending, zero amounts are omitted.
 * displayCases see [assertDisplayCase].
 * The costSource vocabulary of the fixture (estimated / unknown) maps to the local [CostSource] names (LOCAL_ESTIMATE / UNKNOWN).
 */
class CostCurrencyContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture: JsonObject by lazy { readJson("shared/test-fixtures/provider-pricing/cost-currency.v1.json") }

    @Test
    fun `fixture ids are exactly the tests`() {
        val ids = listOf("totalCases", "displayCases").flatMap { key ->
            fixture.getValue(key).jsonArray.map { it.jsonObject.getValue("id").jsonPrimitive.content }
        }.toSet()
        val tests = javaClass.declaredMethods.map { it.name }.filter { it.startsWith("COST_CURRENCY_") }
            .map { it.removePrefix("COST_CURRENCY_") }.toSet()
        assertEquals(ids, tests)
    }

    @Test fun COST_CURRENCY_mixed_totals_split_by_currency() = assertTotalCase("mixed_totals_split_by_currency")
    @Test fun COST_CURRENCY_cny_only() = assertTotalCase("cny_only")
    @Test fun COST_CURRENCY_order_usd_then_code_ascending() = assertTotalCase("order_usd_then_code_ascending")
    @Test fun COST_CURRENCY_zero_currency_omitted() = assertTotalCase("zero_currency_omitted")
    @Test fun COST_CURRENCY_mixed_message_split_into_both_totals() = assertTotalCase("mixed_message_split_into_both_totals")
    @Test fun COST_CURRENCY_nothing_recorded_is_empty() = assertTotalCase("nothing_recorded_is_empty")
    @Test fun COST_CURRENCY_tiny_parts_summed_before_epsilon() = assertTotalCase("tiny_parts_summed_before_epsilon")
    @Test fun COST_CURRENCY_negative_parts_not_added() = assertTotalCase("negative_parts_not_added")
    @Test fun COST_CURRENCY_total_equal_to_epsilon_omitted() = assertTotalCase("total_equal_to_epsilon_omitted")

    @Test fun COST_CURRENCY_en_us_mixed() = assertDisplayCase("en_us_mixed")
    @Test fun COST_CURRENCY_zh_hans_mixed() = assertDisplayCase("zh_hans_mixed")
    @Test fun COST_CURRENCY_zh_hans_cny_only() = assertDisplayCase("zh_hans_cny_only")
    @Test fun COST_CURRENCY_en_us_usd_only_unchanged() = assertDisplayCase("en_us_usd_only_unchanged")
    @Test fun COST_CURRENCY_zh_hans_small_cny_own_tier() = assertDisplayCase("zh_hans_small_cny_own_tier")
    @Test fun COST_CURRENCY_mixed_message_two_parts() = assertDisplayCase("mixed_message_two_parts")
    @Test fun COST_CURRENCY_second_non_usd_currency_part_not_available() = assertDisplayCase("second_non_usd_currency_part_not_available")
    @Test fun COST_CURRENCY_cny_half_rounds_away_from_zero() = assertDisplayCase("cny_half_rounds_away_from_zero")

    /**
     * displayCases feed the production [CostFormatter.formatParts]: USD keeps the `$` notation, non-USD uses the currency format of the UI locale;
     * the decimal places of each part follow [CostFormatter.fractionDigits] by its own amount; cases with a message first split into parts through the production
     * [CostParts.messageParts] / [CostParts.messageNotAvailableCodes]. A part with an unknown amount shows the existing "not available" text passed in by the caller.
     */
    private fun assertDisplayCase(id: String) {
        val case = fixture.getValue("displayCases").jsonArray.map { it.jsonObject }.single { it.getValue("id").jsonPrimitive.content == id }
        val locale = Locale.forLanguageTag(case.getValue("locale").jsonPrimitive.content)
        val expectedParts = case.getValue("parts").jsonArray.map { it.jsonObject }
        val notAvailable = case["notAvailableParts"]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty()
        val parts = case["message"]?.jsonObject?.let { message ->
            val nonUsd = parseNonUsd(message["nonUsdCost"])
            assertEquals(id, notAvailable, CostParts.messageNotAvailableCodes(nonUsd))
            CostParts.messageParts(message.getValue("estimatedCost").jsonPrimitive.double, nonUsd)
        } ?: expectedParts.map { CostPart(it.getValue("currencyCode").jsonPrimitive.content, it.getValue("amount").jsonPrimitive.double) }
        assertEquals(id, expectedParts.map { it.getValue("currencyCode").jsonPrimitive.content }, parts.map { it.currencyCode })
        expectedParts.zip(parts).forEach { (want, got) ->
            assertEquals(id, want.getValue("amount").jsonPrimitive.double, got.amount, 1e-9)
            assertEquals(id, want.getValue("fractionDigits").jsonPrimitive.int, CostFormatter.fractionDigits(got.amount))
        }
        val expect = case.getValue("expect").jsonPrimitive.content
        assertEquals(id, expect, CostFormatter.formatParts(parts, locale))
        val withUnavailable = CostFormatter.formatParts(parts, locale, notAvailable, NOT_AVAILABLE)
        assertEquals(id, (listOf(expect) + notAvailable.map { NOT_AVAILABLE }).joinToString(" + "), withUnavailable)
    }

    private fun parseNonUsd(element: JsonElement?): NonUsdCost? =
        element?.takeUnless { it is JsonNull }?.jsonObject?.let {
            NonUsdCost(
                currencyCode = it.getValue("currencyCode").jsonPrimitive.content,
                amount = it.getValue("amount").jsonPrimitive.double,
                costSource = costSourceName(it.getValue("costSource").jsonPrimitive.content),
            )
        }

    private fun assertTotalCase(id: String) {
        val case = fixture.getValue("totalCases").jsonArray.map { it.jsonObject }.single { it.getValue("id").jsonPrimitive.content == id }
        val amounts = case.getValue("messages").jsonArray.map { it.jsonObject }.flatMap { message ->
            val nonUsd = parseNonUsd(message["nonUsdCost"])
            CostParts.messageAmounts(message.getValue("estimatedCost").jsonPrimitive.double, nonUsd)
        }
        val parts = CostParts.split(amounts)
        val expected = case.getValue("expect").jsonObject.getValue("parts").jsonArray.map { it.jsonObject }
        assertEquals(id, expected.map { it.getValue("currencyCode").jsonPrimitive.content }, parts.map { it.currencyCode })
        expected.zip(parts).forEach { (want, got) ->
            assertEquals(id, want.getValue("amount").jsonPrimitive.double, got.amount, 1e-9)
        }
    }

    private fun costSourceName(fixtureValue: String): String = when (fixtureValue) {
        "estimated" -> CostSource.LOCAL_ESTIMATE.name
        "unknown" -> CostSource.UNKNOWN.name
        "upstream" -> CostSource.UPSTREAM.name
        "subscription" -> CostSource.SUBSCRIPTION.name
        else -> error("unmapped costSource $fixtureValue")
    }

    private companion object {
        /** Placeholder standing in for the existing "not available" texts; no new text key is added. */
        const val NOT_AVAILABLE = "Not available"
    }

    private fun repoRoot(): File = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

    private fun readJson(relativePath: String): JsonObject =
        json.parseToJsonElement(File(repoRoot(), relativePath).readText()).jsonObject
}
