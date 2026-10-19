package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.double
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.model.ChatRole
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Compactor contract (summaryPrompt / summaryRequest / compact / breaker groups): runs the shared checkpoint.v1 fixture case by case; failure messages start with group name + case id. */
class ContextContractCompactorTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("checkpoint.v1.json") }

    private fun JsonObject.flag(key: String): Boolean =
        this[key]?.jsonPrimitive?.content?.toBooleanStrict() ?: false

    private fun JsonObject.strings(key: String): List<String> =
        this[key]?.jsonArray.orEmpty().map { it.jsonPrimitive.content }

    private fun role(o: JsonObject): ChatRole = ChatRole.fromRawValue(o.stringOrNull("role")!!)!!

    private fun assertNoFailures(failures: List<String>) {
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    /** Field-by-field comparison: fields present in expected must be equal, all others must be null (empty for list fields). */
    private fun diff(label: String, expected: Map<String, Any?>, actual: Map<String, Any?>): String? {
        val keys = (expected.keys + actual.keys).distinct()
        val missing = expected.keys - actual.keys
        if (missing.isNotEmpty()) return "$label: result has no field $missing"
        val want = keys.associateWith { key ->
            if (key in expected) expected[key] else (actual[key] as? List<*>)?.let { emptyList<Any?>() }
        }
        val bad = keys.filter { want[it] != actual[it] }
        if (bad.isEmpty()) return null
        return "$label: " + bad.joinToString("; ") { "$it expected ${want[it]}, got ${actual[it]}" }
    }

    @Test
    fun constants_equal_fixture() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c.stringOrNull("summaryPromptTemplate"), ContextCompactor.SUMMARY_PROMPT_TEMPLATE)
        assertEquals(c.stringOrNull("languageFallback"), ContextCompactor.LANGUAGE_FALLBACK)
        assertEquals(c.stringOrNull("serializedSystem"), ContextCompactor.SERIALIZED_SYSTEM)
        assertEquals(c.stringOrNull("attachmentPlaceholder"), ContextCompactor.ATTACHMENT_PLACEHOLDER)
        assertEquals(c.int("maxSummaryAttempts"), ContextCompactor.MAX_SUMMARY_ATTEMPTS)
        val breaker = c["breaker"]!!.jsonObject
        assertEquals(breaker.int("failuresToTrip"), ContextCompactionBreaker.FAILURES_TO_TRIP)
        assertEquals(breaker.int("fallbackTurns"), ContextCompactionBreaker.FALLBACK_TURNS)
    }

    @Test
    fun summaryPrompt() {
        val cases = ContextContractFixture.cases(fixture, "summaryPromptCases")
        assertEquals(3, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val got = ContextCompactor.summaryPrompt(input.stringOrNull("language"), input.int("summaryMax"))
                val expected = case.stringOrNull("expected")!!
                if (got == expected) null else "summaryPrompt ${case.id()}: expected <$expected>, got <$got>"
            },
        )
    }

    @Test
    fun summaryRequest() {
        val cases = ContextContractFixture.cases(fixture, "summaryRequestCases")
        assertEquals(6, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val request = ContextCompactor.summaryRequest(
                    SummaryRequestInput(
                        U = input.int("U"),
                        prefixTokens = input.int("prefixTokens"),
                        rhoHi = input.double("rhoHi"),
                        language = input.stringOrNull("language"),
                        summaryMax = input.int("summaryMax"),
                        previousCheckpointText = input.stringOrNull("previousCheckpointText"),
                        previousSummary = input.stringOrNull("previousSummary"),
                        span = input["span"]!!.jsonArray.map { el ->
                            val m = el.jsonObject
                            SummarySpanMessage(
                                id = m.id(),
                                role = role(m),
                                text = m.stringOrNull("text").orEmpty(),
                                attachments = m["attachments"]?.jsonArray.orEmpty().map { a ->
                                    val ao = a.jsonObject
                                    SummaryAttachment(
                                        kind = SummaryAttachmentKind.fromWire(ao.stringOrNull("kind")!!),
                                        name = ao.stringOrNull("name")!!,
                                    )
                                },
                            )
                        },
                    ),
                )
                val e = case["expected"]!!.jsonObject
                val expected = e.keys.associateWith { key ->
                    when (key) {
                        "messages" -> e[key]!!.jsonArray.map { m ->
                            val o = m.jsonObject
                            o.stringOrNull("role") to o.stringOrNull("text")
                        }
                        "shape", "system", "toolChoice" -> e.stringOrNull(key)
                        else -> e.intOrNull(key)
                    }
                }
                val actual = mapOf(
                    "shape" to request.shape.wire,
                    "system" to request.system,
                    "toolChoice" to request.toolChoice,
                    "maxOutputTokens" to request.maxOutputTokens,
                    "messages" to request.messages.map { it.role.rawValue to it.text },
                    "estInputTokens" to request.estInputTokens,
                    "appendedTokens" to request.appendedTokens,
                    "serializedTokens" to request.serializedTokens,
                )
                diff("summaryRequest ${case.id()}", expected, actual)
            },
        )
    }

    @Test
    fun compact() {
        val cases = ContextContractFixture.cases(fixture, "compactCases")
        assertEquals(6, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val previous = input.objOrNull("previous")
                val result = ContextCompactor.compact(
                    CompactInput(
                        conversationId = input.stringOrNull("conversationId")!!,
                        B = input.int("B"),
                        rhoHi = input.double("rhoHi"),
                        messages = input["messages"]!!.jsonArray.map { el ->
                            val m = el.jsonObject
                            CompactMessage(
                                id = m.id(),
                                role = role(m),
                                text = m.stringOrNull("text").orEmpty(),
                                estTokens = m.int("estTokens"),
                                isDirective = m.flag("isDirective"),
                            )
                        },
                        previous = previous?.let {
                            CompactPrevious(coversTo = it.stringOrNull("coversTo")!!, summary = it.stringOrNull("summary"))
                        },
                        summaryOutputs = input["summaryOutputs"]!!.jsonArray.map { o ->
                            if (o is JsonNull) null else o.jsonPrimitive.content
                        },
                    ),
                )
                val e = case["expected"]!!.jsonObject
                val expected = e.keys.associateWith { key ->
                    when (key) {
                        "failures" -> e[key]!!.jsonArray.map { f -> f.jsonArray.map { it.jsonPrimitive.content } }
                        "keptUserIds" -> e.strings(key)
                        "attempts", "spanTokens", "messagesCovered" -> e.intOrNull(key)
                        else -> e.stringOrNull(key)
                    }
                }
                val actual = mapOf(
                    "outcome" to result.outcome.wire,
                    "attempts" to result.attempts,
                    "failures" to result.failures,
                    "spanTokens" to result.spanTokens,
                    "coversFrom" to result.coversFrom,
                    "coversTo" to result.coversTo,
                    "messagesCovered" to result.messagesCovered,
                    "keptUserIds" to result.keptUserIds,
                    "checkpointId" to result.checkpointId,
                    "coversDigest" to result.coversDigest,
                    "text" to result.text,
                )
                diff("compact ${case.id()}", expected, actual)
            },
        )
    }

    @Test
    fun breaker() {
        val cases = ContextContractFixture.cases(fixture, "breakerCases")
        assertEquals(4, cases.size)
        assertNoFailures(
            cases.flatMap { case ->
                var state = ContextCompactionBreaker()
                val events = case.strings("events")
                val expected = case["expected"]!!.jsonArray.map { it.jsonObject }
                assertEquals(case.id(), events.size, expected.size)
                events.zip(expected).mapIndexedNotNull { i, (event, want) ->
                    state = state.apply(ContextCompactionEvent.fromWire(event))
                    val wantTriple = Triple(want.stringOrNull("mode"), want.int("failures"), want.int("turnsLeft"))
                    val got = Triple(state.mode.wire, state.failures, state.turnsLeft)
                    if (got == wantTriple) null else "breaker ${case.id()} #$i $event: expected $wantTriple, got $got"
                }
            },
        )
    }
}
