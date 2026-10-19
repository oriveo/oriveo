package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.double
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** L3 recall contract: each *Cases group of memory-recall.v1 runs case by case through the production pure functions; failure messages start with the case id. */
class ContextContractMemoryRecallTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("memory-recall.v1.json") }

    /** Case groups must be non-empty so a renamed fixture cannot pass vacuously. */
    private fun group(key: String): List<JsonObject> =
        ContextContractFixture.cases(fixture, key).also { assertTrue("$key is empty", it.isNotEmpty()) }

    private fun strings(el: JsonElement): List<String> = el.jsonArray.map { it.jsonPrimitive.content }

    /** Fixture entry (missing keys take production defaults) to MemoryItem. */
    private fun item(o: JsonObject): MemoryItem {
        val base = MemoryItem(
            id = o.stringOrNull("id")!!,
            kind = MemoryKind.fromWire(o.stringOrNull("kind")!!)!!,
            content = o.stringOrNull("content")!!,
            mutationId = o.stringOrNull("mutationId")!!,
            deviceId = o.stringOrNull("deviceId")!!,
        )
        val scope = o.objOrNull("scope")?.let {
            MemoryItemScope(MemoryScopeType.fromWire(it.stringOrNull("type")!!)!!, it.stringOrNull("id"))
        }
        val source = o.objOrNull("source")?.let { s ->
            MemoryItemSource(
                type = s.stringOrNull("type")?.let { MemorySourceType.fromWire(it)!! } ?: MemorySourceType.MANUAL,
                conversationId = s.stringOrNull("conversationId"),
                messageIds = s["messageIds"]?.let(::strings).orEmpty(),
                observedAt = s.stringOrNull("observedAt"),
            )
        }
        return base.copy(
            layer = o.stringOrNull("layer")?.let { MemoryLayer.fromWire(it)!! } ?: base.layer,
            status = o.stringOrNull("status")?.let { MemoryStatus.fromWire(it)!! } ?: base.status,
            scope = scope ?: base.scope,
            source = source ?: base.source,
            confidence = o["confidence"]?.let { o.double("confidence") } ?: base.confidence,
            pinned = o["pinned"]?.let { o.bool("pinned") } ?: base.pinned,
            conflictGroupId = o.stringOrNull("conflictGroupId"),
            occurredAt = o.stringOrNull("occurredAt"),
            expiresAt = o.stringOrNull("expiresAt"),
            supersedes = o["supersedes"]?.let(::strings) ?: base.supersedes,
        )
    }

    private fun items(el: JsonElement?): List<MemoryItem> = el?.jsonArray.orEmpty().map { item(it.jsonObject) }

    @Test
    fun constants_match_fixture() {
        val c = fixture["constants"]!!.jsonObject
        assertEquals(c.double("k1"), MemoryRecall.K1, 0.0)
        assertEquals(c.double("b"), MemoryRecall.B, 0.0)
        assertEquals(c.int("topK"), MemoryRecall.TOP_K)
        assertEquals(c.double("coverageMin"), MemoryRecall.COVERAGE_MIN, 0.0)
        assertEquals(c.int("minMatchedTerms"), MemoryRecall.MIN_MATCHED_TERMS)
        assertEquals(c.int("idfPriorDocs"), MemoryRecall.IDF_PRIOR_DOCS)
        val scope = c.objOrNull("scopeFactor")!!
        assertEquals(scope.double("conversation"), MemoryRecall.SCOPE_FACTOR_CONVERSATION, 0.0)
        assertEquals(scope.double("folder"), MemoryRecall.SCOPE_FACTOR_FOLDER, 0.0)
        assertEquals(scope.double("global"), MemoryRecall.SCOPE_FACTOR_GLOBAL, 0.0)
        assertEquals(c.double("pinnedFactor"), MemoryRecall.PINNED_FACTOR, 0.0)
        assertEquals(c.double("halfLifeDays"), MemoryRecall.HALF_LIFE_DAYS, 0.0)
        assertEquals(c.double("timeFloor"), MemoryRecall.TIME_FLOOR, 0.0)
        assertEquals(c.double("confidenceFloor"), MemoryRecall.CONFIDENCE_FLOOR, 0.0)
        assertEquals(c.int("maxQueryCodePoints"), MemoryRecall.MAX_QUERY_CODE_POINTS)
        assertEquals(c.double("conflictJaccardMin"), MemoryRecall.CONFLICT_JACCARD_MIN, 0.0)
        assertEquals(c.stringOrNull("joiners"), MemoryRecall.JOINERS)
        val ranges = c["cjkRanges"]!!.jsonArray.map { r -> r.jsonArray.map { it.jsonPrimitive.content.toInt() } }
        assertEquals(ranges, MemoryRecall.CJK_RANGES.map { listOf(it.first, it.last) })
    }

    @Test
    fun tokenizeCases() {
        val failures = group("tokenizeCases").mapNotNull { c ->
            val expected = strings(c["expected"]!!)
            val actual = MemoryRecall.tokens(c.stringOrNull("text")!!)
            if (expected == actual) null else "${c.id()}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun recallCases() {
        val failures = group("recallCases").mapNotNull { c ->
            val input = c["input"]!!.jsonObject
            val ctx = input["context"]!!.jsonObject
            val index = MemoryRecall.buildIndex(items(input["items"]))
            val hits = MemoryRecall.recall(
                index,
                input.stringOrNull("query")!!,
                conversationId = ctx.stringOrNull("conversationId")!!,
                folderId = ctx.stringOrNull("folderId"),
                now = Instant.parse(ctx.stringOrNull("now")!!),
            )
            val expected = c["expected"]!!.jsonArray.map { e ->
                val o = e.jsonObject
                MemoryRecallHit(
                    id = o.stringOrNull("id")!!,
                    text = o.stringOrNull("text")!!,
                    date = o.stringOrNull("date"),
                    score = MemoryRecall.round6(o.double("score")),
                    coverage = MemoryRecall.round6(o.double("coverage")),
                )
            }
            if (expected == hits) null else "${c.id()}: expected $expected, got $hits"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun conflictCases() {
        val failures = group("conflictCases").mapNotNull { c ->
            val input = c["input"]!!.jsonObject
            val expected = c["expected"]!!.jsonObject.stringOrNull("conflictWith")
            val actual = MemoryRecall.conflict(item(input["saved"]!!.jsonObject), items(input["items"]))
            if (expected == actual) null else "${c.id()}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun resolveCases() {
        val failures = group("resolveCases").mapNotNull { c ->
            val input = c["input"]!!.jsonObject
            val patches = MemoryRecall.resolve(
                item(input["newer"]!!.jsonObject),
                item(input["older"]!!.jsonObject),
                MemoryConflictResolution.fromWire(input.stringOrNull("resolution")!!)!!,
            )
            val expected = c["expected"]!!.jsonArray.map { e ->
                val o = e.jsonObject
                MemoryConflictPatch(
                    id = o.stringOrNull("id")!!,
                    status = MemoryStatus.fromWire(o.stringOrNull("status")!!)!!,
                    conflictGroupId = o.stringOrNull("conflictGroupId"),
                    supersedes = strings(o["supersedes"]!!),
                )
            }
            if (expected == patches) null else "${c.id()}: expected $expected, got $patches"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }
}
