package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.id
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Compact number contract: runs the shared compact-number.v1 fixture case by case; the production table equals the fixture entry by entry. */
class ContextContractCompactNumberTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("compact-number.v1.json") }

    @Test
    fun cases() {
        val cases = ContextContractFixture.cases(fixture, "cases")
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val input = case["input"]!!.jsonObject
            val value = input["value"]!!.jsonPrimitive.content.toLong()
            val locale = input["locale"]!!.jsonPrimitive.content
            val expected = case["expected"]!!.jsonPrimitive.content
            assertEquals(case.id(), expected, ContextCompactNumber.format(value, locale))
        }
    }

    @Test
    fun locale_cases() {
        val cases = ContextContractFixture.cases(fixture, "localeCases")
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val input = case["input"]!!.jsonPrimitive.content
            val expected = case["expected"]!!.jsonPrimitive.content
            assertEquals(case.id(), expected, ContextCompactNumber.resolveLocale(input))
        }
    }

    @Test
    fun table_equals_fixture() {
        val locales = fixture["locales"]!!.jsonObject
        val table = ContextCompactNumber.TABLE
        assertEquals("language keys and order", locales.keys.toList(), table.keys.toList())
        locales.forEach { (code, el) ->
            val loc = el.jsonObject
            val got = table.getValue(code)
            assertEquals("$code key set", setOf("decimal", "group", "tiers"), loc.keys)
            assertEquals("$code decimal", loc["decimal"]!!.jsonPrimitive.content, got.decimal)
            assertEquals("$code group", loc["group"]!!.jsonPrimitive.content, got.group)
            val tiers = loc["tiers"]!!.jsonArray.map { it.jsonObject }
            assertEquals("$code tier count", tiers.size, got.tiers.size)
            tiers.forEachIndexed { i, t ->
                val g = got.tiers[i]
                assertTrue("$code[$i] key set ${t.keys}", t.keys == setOf("min", "pattern") || t.keys == setOf("min", "pattern", "few"))
                assertEquals("$code[$i] min", t["min"]!!.jsonPrimitive.content.toLong(), g.min)
                assertEquals("$code[$i] pattern", t["pattern"]!!.jsonPrimitive.content, g.pattern)
                val few = t["few"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content
                assertEquals("$code[$i] few", few, g.few)
            }
        }
    }
}
