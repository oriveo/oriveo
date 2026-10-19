package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Context overflow detection contract: runs the shared overflow-errors.v1 fixture case by case; failure messages start with the case id. */
class ContextContractOverflowTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("overflow-errors.v1.json") }

    /** A string body is passed through as is; an object body is serialized to JSON first. */
    private fun bodyOf(input: JsonObject): String = when (val b = input["body"]!!) {
        is JsonPrimitive -> b.content
        else -> b.toString()
    }

    @Test
    fun default_patterns_equal_fixture() {
        val patterns = fixture["patterns"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }
        assertEquals(patterns, ContextOverflowClassifier.defaultPatterns)
    }

    @Test
    fun `overflow cases`() {
        val cases = ContextContractFixture.cases(fixture, "cases")
        assertEquals(16, cases.size)
        val failures = cases.mapNotNull { case ->
            val id = case.id()
            val input = case["input"]!!.jsonObject
            val got = ContextOverflowClassifier.classify(
                family = OverflowFamily.fromWire(input.stringOrNull("family")!!),
                status = input.int("status"),
                body = bodyOf(input),
            )
            val e = case["expected"]!!.jsonObject
            val expectedOverflow = e["overflow"]!!.jsonPrimitive.content.toBooleanStrict()
            val expectedVia = e.stringOrNull("via")
            if (got.overflow == expectedOverflow && got.via?.wire == expectedVia) {
                null
            } else {
                "$id: expected ($expectedOverflow, $expectedVia), got (${got.overflow}, ${got.via?.wire})"
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun extra_patterns_append() {
        val body = """{"error":{"message":"context budget blown: 9000 > 8192"}}"""
        val before = ContextOverflowClassifier.classify(OverflowFamily.OPENAI_COMPATIBLE, 400, body)
        assertFalse(before.overflow)
        val extra = mapOf("openai_compatible" to listOf("(?i)CONTEXT BUDGET BLOWN"))
        val after = ContextOverflowClassifier.classify(OverflowFamily.OPENAI_CHAT, 400, body, extra)
        assertTrue(after.overflow)
        assertEquals(OverflowVia.STATUS_REGEX, after.via)
        // Additions to other groups do not affect this family
        val other = ContextOverflowClassifier.classify(OverflowFamily.GEMINI, 400, body, extra)
        assertFalse(other.overflow)
        // The default regex still applies (additions are OR-ed)
        val dflt = ContextOverflowClassifier.classify(
            OverflowFamily.OPENAI_COMPATIBLE,
            400,
            """{"error":{"message":"maximum context length is 8192 tokens"}}""",
            extra,
        )
        assertEquals(OverflowVia.STATUS_REGEX, dflt.via)
    }

    @Test
    fun extra_patterns_invalid_skipped() {
        val body = """{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 9 > 8"}}"""
        val extra = mapOf("anthropic" to listOf("(unclosed", "never matches this"))
        val got = ContextOverflowClassifier.classify(OverflowFamily.ANTHROPIC, 400, body, extra)
        assertTrue(got.overflow)
        assertEquals(OverflowVia.TYPE_REGEX, got.via)
        val none = ContextOverflowClassifier.classify(
            OverflowFamily.ANTHROPIC,
            400,
            """{"type":"error","error":{"type":"invalid_request_error","message":"roles must alternate"}}""",
            mapOf("anthropic" to listOf("[")),
        )
        assertFalse(none.overflow)
        assertNull(none.via)
    }

    @Test
    fun free_string_code_not_overflow() {
        // The numeric overflow code only accepts the number 40022; the string "40022" is not the same code (consistent with iOS / Web)
        val got = ContextOverflowClassifier.classify(OverflowFamily.FREE, 400, """{"code":"40022"}""")
        assertFalse(got.overflow)
        assertNull(got.via)
        val numeric = ContextOverflowClassifier.classify(OverflowFamily.FREE, 400, """{"code":40022}""")
        assertTrue(numeric.overflow)
        assertEquals(OverflowVia.CODE, numeric.via)
    }
}
