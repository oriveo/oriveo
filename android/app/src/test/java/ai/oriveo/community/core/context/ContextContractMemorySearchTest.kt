package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.double
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.tools.ToolWireProtocolAdapter
import ai.oriveo.community.core.tools.ToolWireProtocol
import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** search_memory contract: memory-search.v1 searchCases / modeCases run case by case through the production pure functions; failure messages start with the case id. */
class ContextContractMemorySearchTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("memory-search.v1.json") }

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
    fun tool_texts_and_constants_match_fixture() {
        assertEquals(fixture["tool"].toString(), MemorySearch.TOOL_JSON.toString())
        assertEquals(MemorySearch.TOOL_NAME, MemorySearch.tool.function.name)
        assertEquals(fixture.stringOrNull("note"), MemorySearch.NOTE)
        assertEquals(fixture.stringOrNull("emptyResult"), MemorySearch.EMPTY_RESULT)
        assertEquals(fixture.stringOrNull("limitResult"), MemorySearch.LIMIT_RESULT)
        assertEquals(strings(fixture["skipReasons"]!!), MemorySearchSkipReason.entries.map { it.wire })
        assertEquals(strings(fixture["modes"]!!), MemorySearchMode.entries.map { it.wire })
        val c = fixture.objOrNull("constants")!!
        assertEquals(c.int("topK"), MemorySearch.TOP_K)
        assertEquals(c.double("coverageMin"), MemorySearch.COVERAGE_MIN, 0.0)
        assertEquals(c.int("minMatchedTerms"), MemorySearch.MIN_MATCHED_TERMS)
        assertEquals(c.int("maxQueryCodePoints"), MemorySearch.MAX_QUERY_CODE_POINTS)
        assertEquals(c.int("maxCallsPerTurn"), MemorySearch.MAX_CALLS_PER_TURN)
    }

    @Test
    fun projections_match_fixture() {
        val projections = fixture.objOrNull("projections")!!
        val protocols = ToolWireProtocol.entries
        assertEquals(projections.keys, protocols.map { it.wireValue }.toSet())
        val failures = protocols.mapNotNull { p ->
            val expected = projections[p.wireValue]!!
            val actual = ToolWireProtocolAdapter.toolsJson(p, listOf(MemorySearch.tool))
            if (expected == actual) null else "${p.wireValue}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun searchCases() {
        val cases = group("searchCases")
        assertEquals(14, cases.size)
        val failures = cases.mapNotNull { c ->
            val input = c["input"]!!.jsonObject
            val ctx = input["context"]!!.jsonObject
            val index = MemoryRecall.buildIndex(items(input["items"]))
            val outcome = MemorySearch.search(
                index,
                input.stringOrNull("arguments")!!,
                MemorySearchContext(
                    conversationId = ctx.stringOrNull("conversationId")!!,
                    folderId = ctx.stringOrNull("folderId"),
                    now = Instant.parse(ctx.stringOrNull("now")!!),
                    excludeIds = strings(ctx["excludeIds"]!!),
                ),
                priorInTurn = input.int("priorInTurn"),
            )
            val e = c["expected"]!!.jsonObject
            val eo = e["outcome"]!!.jsonObject
            val expectedOutcome = MemorySearchOutcome(
                action = MemorySearchAction.entries.first { it.wire == eo.stringOrNull("action") },
                reason = eo.stringOrNull("reason")?.let { MemorySearchSkipReason.fromWire(it)!! },
                hits = eo["hits"]!!.jsonArray.map { h ->
                    val o = h.jsonObject
                    MemoryRecallHit(
                        id = o.stringOrNull("id")!!,
                        text = o.stringOrNull("text")!!,
                        date = o.stringOrNull("date"),
                        score = MemoryRecall.round6(o.double("score")),
                        coverage = MemoryRecall.round6(o.double("coverage")),
                    )
                },
            )
            val maxTokens = input.intOrNull("maxTokens")
            val toolResult = MemorySearch.toolResult(outcome, maxTokens, input.double("rho"))
            val expectedReturned = strings(e["returnedIds"]!!)
            val returned = MemorySearch.returnedHits(outcome, maxTokens, input.double("rho")).map { it.id }
            when {
                expectedOutcome != outcome -> "${c.id()}: expected $expectedOutcome, got $outcome"
                expectedReturned != returned -> "${c.id()}: returnedIds expected $expectedReturned, got $returned"
                e.stringOrNull("toolResult") != toolResult -> "${c.id()}: toolResult expected ${e.stringOrNull("toolResult")}, got $toolResult"
                else -> null
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun modeCases() {
        val cases = group("modeCases")
        assertEquals(8, cases.size)
        val failures = cases.mapNotNull { c ->
            val i = c["input"]!!.jsonObject
            val expected = MemorySearchMode.fromWire(c.stringOrNull("expected")!!)!!
            val actual = MemorySearch.mode(
                MemorySearchModeInput(
                    purpose = MemoryProposePurpose.fromWire(i.stringOrNull("purpose")!!)!!,
                    memoryEnabled = i.bool("memoryEnabled"),
                    connectionSupportsTools = i.bool("connectionSupportsTools"),
                    degraded = i.bool("degraded"),
                    recallableItems = i.int("recallableItems"),
                ),
            )
            if (expected == actual) null else "${c.id()}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }
}
