package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.double
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.model.ChatRole
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** Checkpoint contract (span / userMessages / truncate / serialize / fallback / validate / ids / concurrency groups): runs the shared checkpoint.v1 fixture case by case; failure messages start with the case id. */
class ContextContractCheckpointTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("checkpoint.v1.json") }

    private fun JsonObject.flag(key: String): Boolean =
        this[key]?.jsonPrimitive?.content?.toBooleanStrict() ?: false

    private fun JsonObject.strings(key: String): List<String> =
        this[key]?.jsonArray.orEmpty().map { it.jsonPrimitive.content }

    private fun spanMessages(input: JsonObject): List<CheckpointSpanMessage> =
        input["messages"]!!.jsonArray.map { el ->
            val m = el.jsonObject
            CheckpointSpanMessage(
                id = m.id(),
                role = ChatRole.fromRawValue(m.stringOrNull("role")!!)!!,
                estTokens = m.int("estTokens"),
            )
        }

    private fun fallbackMessages(input: JsonObject): List<CheckpointFallbackMessage> =
        input["messages"]!!.jsonArray.map { el ->
            val m = el.jsonObject
            CheckpointFallbackMessage(
                id = m.id(),
                role = ChatRole.fromRawValue(m.stringOrNull("role")!!)!!,
                estTokens = m.int("estTokens"),
                text = m.stringOrNull("text"),
                isDirective = m.flag("isDirective"),
            )
        }

    private fun assertNoFailures(failures: List<String>) {
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun constants_equal_fixture() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c.stringOrNull("note"), ContextCheckpoint.NOTE)
        assertEquals(c.stringOrNull("truncationMark"), ContextCheckpoint.TRUNCATION_MARK)
        assertEquals(c.int("shortTruncationCodePoints"), ContextCheckpoint.SHORT_TRUNCATION_CODE_POINTS)
        assertEquals(c.strings("headings"), ContextCheckpoint.HEADINGS)
        assertEquals(c.stringOrNull("packerVersion"), ContextCheckpoint.PACKER_VERSION)
        assertEquals(c["uuidNamespace"]!!.jsonObject.stringOrNull("value"), ContextCheckpoint.UUID_NAMESPACE)
        val sb = c["sentenceBoundary"]!!.jsonObject
        val table = ContextCheckpoint.SentenceBoundary
        assertEquals(sb.strings("terminators"), table.TERMINATORS)
        assertEquals(sb.strings("closers"), table.CLOSERS)
        assertEquals(sb.strings("lineBreaks"), table.LINE_BREAKS)
        assertEquals(sb.strings("spaces"), table.SPACES)
        assertEquals(sb.strings("extend"), table.EXTEND)
        assertEquals(sb.strings("joiners"), table.JOINERS)
        assertEquals(sb.stringOrNull("regionalIndicator"), table.REGIONAL_INDICATOR)
        assertEquals(sb.keys, setOf("terminators", "closers", "lineBreaks", "spaces", "extend", "joiners", "regionalIndicator"))
    }

    @Test
    fun span() {
        val cases = ContextContractFixture.cases(fixture, "spanCases")
        assertEquals(8, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val got = ContextCheckpoint.selectSpan(
                    messages = spanMessages(input),
                    B = input.int("B"),
                    previousCoversTo = input.stringOrNull("previousCoversTo"),
                )
                val e = case["expected"]!!.jsonObject
                val action = e.stringOrNull("action")!!
                val ok = if (action == "noop") {
                    got.action.wire == action && got.tailStartId == e.stringOrNull("tailStartId") && got.spanIds.isEmpty()
                } else {
                    got.action.wire == action &&
                        got.tailStartId == e.stringOrNull("tailStartId") &&
                        got.spanIds == e.strings("spanIds") &&
                        got.coversFrom == e.stringOrNull("coversFrom") &&
                        got.coversTo == e.stringOrNull("coversTo") &&
                        got.messagesCovered == e.int("messagesCovered")
                }
                if (ok) null else "${case.id()}: expected $e, got $got"
            },
        )
    }

    @Test
    fun userMessages() {
        val cases = ContextContractFixture.cases(fixture, "userMessageCases")
        assertEquals(3, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val got = ContextCheckpoint.pickUserMessages(
                    candidates = input["candidates"]!!.jsonArray.map { el ->
                        val c = el.jsonObject
                        CheckpointCandidate(c.id(), c.stringOrNull("text")!!, c.flag("isDirective"))
                    },
                    B = input.int("B"),
                    rhoHi = input.double("rhoHi"),
                    userMessagesMax = input.intOrNull("userMessagesMax"),
                )
                val expected = case["expected"]!!.jsonArray.map { el ->
                    val k = el.jsonObject
                    CheckpointKeptMessage(k.id(), k.stringOrNull("text")!!, k.flag("truncated"))
                }
                if (got == expected) null else "${case.id()}: expected $expected, got $got"
            },
        )
    }

    @Test
    fun truncate() {
        val cases = ContextContractFixture.cases(fixture, "truncateCases")
        assertEquals(53, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val got = ContextCheckpoint.truncate(input.stringOrNull("text")!!, input.int("head"), input.intOrNull("tail"))
                val expected = case["expected"]!!.jsonPrimitive.content
                if (got == expected) null else "${case.id()}: expected\n$expected\ngot\n$got"
            },
        )
    }

    @Test
    fun normalizeHeadings() {
        val cases = ContextContractFixture.cases(fixture, "normalizeHeadingCases")
        assertEquals(12, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val got = ContextCheckpoint.normalizeHeadings(case["input"]!!.jsonObject.stringOrNull("summary")!!)
                val expected = case["expected"]!!.jsonObject.stringOrNull("summary")!!
                if (got == expected) null else "${case.id()}: expected\n$expected\ngot\n$got"
            },
        )
    }

    @Test
    fun serialize() {
        val cases = ContextContractFixture.cases(fixture, "serializeCases")
        assertEquals(2, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val got = ContextCheckpoint.serialize(
                    coversFrom = input.stringOrNull("coversFrom")!!,
                    coversTo = input.stringOrNull("coversTo")!!,
                    messagesCovered = input.int("messagesCovered"),
                    kept = input["kept"]!!.jsonArray.map { el ->
                        val k = el.jsonObject
                        CheckpointKeptMessage(k.id(), k.stringOrNull("text")!!, k.flag("truncated"))
                    },
                    summary = input.stringOrNull("summary"),
                )
                val expected = case["expected"]!!.jsonPrimitive.content
                if (got == expected) null else "${case.id()}: expected\n$expected\ngot\n$got"
            },
        )
    }

    @Test
    fun fallback() {
        val cases = ContextContractFixture.cases(fixture, "fallbackCases")
        assertEquals(5, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val got = ContextCheckpoint.fallback(
                    messages = fallbackMessages(input),
                    B = input.int("B"),
                    rhoHi = input.double("rhoHi"),
                    fixedTokens = input.int("fixedTokens"),
                    oldSummary = input.stringOrNull("oldSummary"),
                )
                val e = case["expected"]!!.jsonObject
                val ok = got.tailStartId == e.stringOrNull("tailStartId") &&
                    got.keptUserIds == e.strings("keptUserIds") &&
                    got.total == e.int("total") &&
                    got.targetMet == e.flag("targetMet") &&
                    got.stages == e.strings("stages") &&
                    (!e.containsKey("checkpointText") || got.checkpointText == e.stringOrNull("checkpointText"))
                if (ok) null else "${case.id()}: expected $e, got $got"
            },
        )
    }


    @Test
    fun validate() {
        val cases = ContextContractFixture.cases(fixture, "validateCases")
        assertEquals(10, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val got = ContextCheckpoint.validateSummary(
                    summary = input.stringOrNull("summary")!!,
                    summaryMax = input.int("summaryMax"),
                    spanTokens = input.int("spanTokens"),
                    rhoHi = input.double("rhoHi"),
                )
                val e = case["expected"]!!.jsonObject
                val ok = got.valid == e.flag("valid") && got.reasons == e.strings("reasons")
                if (ok) null else "${case.id()}: expected $e, got $got"
            },
        )
    }

    @Test
    fun ids() {
        val cases = ContextContractFixture.cases(fixture, "idCases")
        assertEquals(4, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                val e = case["expected"]!!.jsonObject
                val failures = mutableListOf<String>()
                input["messages"]?.jsonArray?.map { el ->
                    val m = el.jsonObject
                    CheckpointCoveredMessage(m.id(), m.stringOrNull("text")!!)
                }?.let { messages ->
                    val hashes = messages.map { ContextCheckpoint.textHash(it.text) }
                    if (hashes != e.strings("textHashes")) failures += "textHashes $hashes"
                    val digest = ContextCheckpoint.coversDigest(messages)
                    if (digest != e.stringOrNull("coversDigest")) failures += "coversDigest $digest"
                }
                e.stringOrNull("checkpointId")?.let { expected ->
                    val got = ContextCheckpoint.checkpointId(
                        conversationId = input.stringOrNull("conversationId")!!,
                        coversTo = input.stringOrNull("coversTo")!!,
                        packerVersion = input.stringOrNull("packerVersion")!!,
                    )
                    if (got != expected) failures += "checkpointId $got"
                }
                if (failures.isEmpty()) null else "${case.id()}: expected $e, got ${failures.joinToString("; ")}"
            },
        )
    }

    @Test
    fun concurrency() {
        val cases = ContextContractFixture.cases(fixture, "concurrencyCases")
        assertEquals(3, cases.size)
        assertNoFailures(
            cases.mapNotNull { case ->
                val input = case["input"]!!.jsonObject
                fun entry(key: String): CheckpointConcurrencyEntry {
                    val o = input[key]!!.jsonObject
                    return CheckpointConcurrencyEntry(
                        checkpointId = o.stringOrNull("checkpointId")!!,
                        coversToIndex = o.int("coversToIndex"),
                        createdAtMillis = Instant.parse(o.stringOrNull("createdAt")!!).toEpochMilli(),
                    )
                }
                val a = entry("a")
                val b = entry("b")
                val winner = ContextCheckpoint.resolveConcurrency(a, b)
                val expected = case["expected"]!!.jsonPrimitive.content
                val got = when (winner) {
                    a -> "a"
                    b -> "b"
                    else -> "neither"
                }
                if (got == expected) null else "${case.id()}: expected $expected, got $got ($winner)"
            },
        )
    }

    /** Not from the fixture: the minimal stage also carries the old summary (cross-platform convention), XML-escaped. */
    @Test
    fun fallback_minimal_keeps_old_summary() {
        val case = ContextContractFixture.cases(fixture, "fallbackCases")
            .first { it.id() == "minimal_set_when_nothing_else_fits" }
        val input = case["input"]!!.jsonObject
        val got = ContextCheckpoint.fallback(
            messages = fallbackMessages(input),
            B = input.int("B"),
            rhoHi = input.double("rhoHi"),
            fixedTokens = input.int("fixedTokens"),
            oldSummary = "## Goal\nKeep <tags> & go\n## Style & Language\nEnglish > none",
        )
        assertEquals("minimal", got.stages.last())
        val text = got.checkpointText!!
        assertTrue(
            text,
            text.contains("<summary>## Goal\nKeep &lt;tags&gt; &amp; go\n## Style &amp; Language\nEnglish &gt; none</summary>"),
        )
        assertTrue(text, text.endsWith("</oriveo-context-checkpoint>"))
    }
}
