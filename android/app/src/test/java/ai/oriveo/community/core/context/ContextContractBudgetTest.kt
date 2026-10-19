package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.double
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Cross-platform contract for budget / rho calibration / estimation / pHat / ring display: runs the shared budget.v1 fixture case by case. */
class ContextContractBudgetTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("budget.v1.json") }

    @Test
    fun constants_match_fixture() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c.double("rho0"), ContextBudget.RHO0, 0.0)
        assertEquals(c.double("ewmaAlpha"), ContextBudget.EWMA_ALPHA, 0.0)
        assertEquals(c.double("safetyFactor"), ContextBudget.SAFETY_FACTOR, 0.0)
        assertEquals(c.int("minSamples"), ContextBudget.MIN_SAMPLES)
        assertEquals(c.int("messageOverheadTokens"), ContextBudget.MESSAGE_OVERHEAD_TOKENS)
        assertEquals(c.int("minKnownWindow"), ContextBudget.MIN_KNOWN_WINDOW)
        assertEquals(c.int("defaultMaxOutput"), ContextBudget.DEFAULT_MAX_OUTPUT)
        assertEquals(
            c["budgetCapOptions"]!!.jsonArray.map { it.jsonPrimitive.content },
            ContextBudgetCap.OPTIONS.map { it.wire },
        )
        assertEquals(c.stringOrNull("budgetCapDefault"), ContextBudgetCap.DEFAULT.wire)
        assertEquals(c.int("customCapMin"), ContextBudget.CUSTOM_CAP_MIN)
        assertEquals(c.int("customCapMax"), ContextBudget.CUSTOM_CAP_MAX)
        assertEquals(c.int("autoCapDefault"), ContextBudget.AUTO_CAP_DEFAULT)
        assertEquals(c.int("priceLineCapMin"), ContextBudget.PRICE_LINE_CAP_MIN)
        assertEquals(c["capTickLadder"]!!.jsonArray.map { it.jsonPrimitive.content.toInt() }, ContextBudget.CAP_TICK_LADDER)
    }

    @Test
    fun windowCases() {
        val cases = ContextContractFixture.cases(fixture, "windowCases")
        assertEquals(34, cases.size)
        cases.forEach { case ->
            val id = case.id()
            val input = case["input"]!!.jsonObject
            val maxOut = input["maxOutput"]!!.jsonObject
            val cap = ContextBudgetCap.parse(input["budgetCap"].raw())
                ?: throw AssertionError("$id budgetCap parse rejected")
            val got = ContextBudget.window(
                ContextWindowInput(
                    W = input.intOrNull("W"),
                    windowKind = ContextWindowKind.fromWire(input.stringOrNull("windowKind")!!),
                    maxOutput = ContextMaxOutput(
                        user = maxOut.intOrNull("user"),
                        recipe = maxOut.intOrNull("recipe"),
                        model = maxOut.intOrNull("model"),
                    ),
                    budgetCap = cap,
                    priceLineTokens = input.intOrNull("priceLineTokens"),
                ),
            )
            val e = case["expected"]!!.jsonObject
            assertEquals("$id expected key set", WINDOW_KEYS, e.keys)
            e.objOrNull("derived")?.let { assertEquals("$id derived key set", DERIVED_KEYS, it.keys) }
            val expected = ContextWindowBudget(
                known = e.bool("known"),
                W = e.intOrNull("W"),
                O = e.int("O"),
                R = e.intOrNull("R"),
                U = e.intOrNull("U"),
                B = e.intOrNull("B"),
                limitedBy = e.stringOrNull("limitedBy")?.let { w ->
                    ContextBudgetLimit.entries.firstOrNull { it.wire == w } ?: throw AssertionError("$id unknown limitedBy $w")
                },
                oWire = e.int("oWire"),
                derived = e.objOrNull("derived")?.let { ed ->
                    ContextDerivedBudget(
                        preCompactAt = ed.int("preCompactAt"),
                        sendCompactAt = ed.int("sendCompactAt"),
                        compactTargetMax = ed.int("compactTargetMax"),
                        reminderAt = ed.int("reminderAt"),
                        tail = ed.int("tail"),
                        userMessagesMax = ed.int("userMessagesMax"),
                        summaryMax = ed.int("summaryMax"),
                        systemMax = ed.int("systemMax"),
                        recallMax = ed.int("recallMax"),
                    )
                },
                proactiveCompaction = e.bool("proactiveCompaction"),
            )
            assertEquals(id, expected, got)
        }
    }

    @Test
    fun capCases() {
        val cases = ContextContractFixture.cases(fixture, "capCases")
        assertEquals(19, cases.size)
        cases.forEach { case ->
            val id = case.id()
            val raw = case["input"].raw()
            val got = ContextBudgetCap.parse(raw)
            val e = case["expected"]!!.jsonObject
            if (e["rejected"]?.jsonPrimitive?.booleanOrNull == true) {
                assertNull("$id should be rejected", got)
                return@forEach
            }
            val expected = when (val w = e["cap"].raw()) {
                "auto" -> ContextBudgetCap.Auto
                "unlimited" -> ContextBudgetCap.Unlimited
                is Int -> ContextBudgetCap.Custom(w)
                else -> throw AssertionError("$id unknown expected cap $w")
            }
            assertEquals("$id parse", expected, got)
            assertEquals("$id wire", e["cap"].raw(), got!!.wire)
            assertEquals("$id wire round trip", got, ContextBudgetCap.parse(got.wire))
        }
    }

    @Test
    fun capTickCases() {
        val cases = ContextContractFixture.cases(fixture, "capTickCases")
        assertEquals(13, cases.size)
        cases.forEach { case ->
            val id = case.id()
            val input = case["input"]!!.jsonObject
            val got = ContextBudget.capTicks(input.intOrNull("U"), input.intOrNull("priceLineTokens"))
            val expected = case["expected"]!!.jsonObject["ticks"]!!.jsonArray.map { it.jsonPrimitive.content.toInt() }
            assertEquals(id, expected, got)
        }
    }

    private companion object {
        /** Expected keys compared field by field in windowCases; keep in sync when the fixture adds fields. */
        val WINDOW_KEYS = setOf(
            "known", "W", "O", "R", "U", "B", "limitedBy", "oWire", "derived", "proactiveCompaction",
        )
        val DERIVED_KEYS = setOf(
            "preCompactAt", "sendCompactAt", "compactTargetMax", "reminderAt", "tail",
            "userMessagesMax", "summaryMax", "systemMax", "recallMax",
        )
    }

    /** Restores the raw JSON value: string / integer (Long when beyond Int) / decimal (source has a decimal point or exponent, including 64000.0) / bool / null, so parse can tell the types apart. */
    private fun JsonElement?.raw(): Any? {
        if (this == null || this is JsonNull) return null
        val p = jsonPrimitive
        if (p.isString) return p.content
        p.booleanOrNull?.let { return it }
        val text = p.content
        if (text.any { it == '.' || it == 'e' || it == 'E' }) return text.toDouble()
        p.longOrNull?.let { l -> return if (l in Int.MIN_VALUE..Int.MAX_VALUE) l.toInt() else l }
        return text.toDouble()
    }

    @Test
    fun rhoCases() {
        val cases = ContextContractFixture.cases(fixture, "rhoCases")
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val id = case.id()
            val events = case["events"]!!.jsonArray.map { it.jsonObject }
            val expected = case["expected"]!!.jsonArray.map { it.jsonObject }
            assertEquals("$id events vs expected count", events.size, expected.size)
            var cal = RhoCalibration()
            events.forEachIndexed { i, ev ->
                cal = when (val type = ev["type"]!!.jsonPrimitive.content) {
                    "sample" -> cal.recordingSample(
                        observedInput = ev.intOrNull("observedInput"),
                        mediaTokens = ev.int("mediaTokens"),
                        textBytes = ev.int("textBytes"),
                    )
                    "overflowMiss" -> cal.recordingOverflowMiss()
                    else -> throw AssertionError("$id unknown event $type")
                }
                val e = expected[i]
                assertEquals("$id[$i] n", e.int("n"), cal.n)
                assertEquals("$id[$i] rho", e.double("rho"), cal.rho, 1e-12)
                assertEquals("$id[$i] rhoHi", e.double("rhoHi"), cal.rhoHi, 1e-12)
            }
        }
    }

    @Test
    fun estimateCases() {
        val cases = ContextContractFixture.cases(fixture, "estimateCases")
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val id = case.id()
            val input = case["input"]!!.jsonObject
            val text = input.stringOrNull("text")!!
            val rhoHi = input.double("rhoHi")
            val e = case["expected"]!!.jsonObject
            assertEquals("$id utf8Bytes", e.int("utf8Bytes"), ContextBudget.utf8Bytes(text))
            assertEquals("$id textTokens", e.int("textTokens"), ContextBudget.estimateText(text, rhoHi))
            assertEquals("$id messageTokens", e.int("messageTokens"), ContextBudget.estimateMessage(text, rhoHi))
        }
    }

    @Test
    fun observedCases() {
        val cases = ContextContractFixture.cases(fixture, "observedCases")
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val id = case.id()
            val input = case["input"]!!.jsonObject
            val got = ContextBudget.pHat(
                PHatInput(
                    observedPrevious = input.intOrNull("observedPrevious"),
                    estDynamicPrevious = input.int("estDynamicPrevious"),
                    estAnswerPrevious = input.int("estAnswerPrevious"),
                    estNewMessages = input["estNewMessages"]!!.jsonArray.map { it.jsonPrimitive.content.toInt() },
                    estDynamicNow = input.int("estDynamicNow"),
                    compactedSincePrevious = input.bool("compactedSincePrevious"),
                    estimatedFull = input.int("estimatedFull"),
                ),
            )
            val e = case["expected"]!!.jsonObject
            assertEquals("$id pHat", e.int("pHat"), got.pHat)
            assertEquals("$id basis", e.stringOrNull("basis"), got.basis.wire)
        }
    }

    @Test
    fun displayCases() {
        val cases = ContextContractFixture.cases(fixture, "displayCases")
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val id = case.id()
            val input = case["input"]!!.jsonObject
            val got = ContextBudget.display(
                ContextDisplayInput(
                    windowKnown = input.bool("windowKnown"),
                    pHat = input.int("pHat"),
                    B = input.intOrNull("B"),
                    basis = ContextBasis.fromWire(input.stringOrNull("basis")!!),
                    observedEver = input.bool("observedEver"),
                    overflowed = input.bool("overflowed"),
                ),
            )
            val e = case["expected"]!!.jsonObject
            assertEquals("$id display", e.stringOrNull("display"), got.display.wire)
            assertEquals("$id percent", e.intOrNull("percent"), got.percent)
            assertEquals("$id tone", e.stringOrNull("tone"), got.tone?.wire)
            assertEquals("$id estimatedPercent", e.intOrNull("estimatedPercent"), got.estimatedPercent)
        }
    }
}
