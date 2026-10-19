package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.double
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.int
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.tools.ToolWireProtocolAdapter
import ai.oriveo.community.core.tools.ToolWireProtocol
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** propose_memory contract: runs the shared memory-propose.v2 fixture case by case; failure messages start with the case id. */
class ContextContractMemoryProposeTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("memory-propose.v2.json") }

    /** Case groups must be non-empty so a renamed fixture cannot pass vacuously. */
    private fun group(key: String): List<JsonObject> =
        ContextContractFixture.cases(fixture, key).also { assertTrue("$key is empty", it.isNotEmpty()) }

    private fun JsonObject.strings(key: String): List<String> = this[key]!!.jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.long(key: String): Long = stringOrNull(key)!!.toLong()

    private fun JsonObject.longOrNull(key: String): Long? = stringOrNull(key)?.toLong()

    private fun scope(json: JsonObject): MemoryItemScope =
        MemoryItemScope(MemoryScopeType.fromWire(json.stringOrNull("type")!!)!!, json.stringOrNull("id"))

    private fun record(json: JsonObject): MemoryCandidate {
        val source = json.objOrNull("source")!!
        return MemoryCandidate(
            id = json.stringOrNull("id")!!,
            status = MemoryCandidateStatus.fromWire(json.stringOrNull("status")!!)!!,
            proposedLayer = MemoryLayer.fromWire(json.stringOrNull("proposedLayer")!!)!!,
            proposedKind = MemoryKind.fromWire(json.stringOrNull("proposedKind")!!)!!,
            content = json.stringOrNull("content")!!,
            scope = scope(json.objOrNull("scope")!!),
            source = MemoryCandidateSource(
                type = MemorySourceType.fromWire(source.stringOrNull("type")!!)!!,
                conversationId = source.stringOrNull("conversationId"),
                messageIds = source.strings("messageIds"),
                observedAtMs = source.longOrNull("observedAtMs"),
            ),
            sensitivity = MemorySensitivity.fromWire(json.stringOrNull("sensitivity")!!)!!,
            confidence = json.double("confidence"),
            fingerprint = json.stringOrNull("fingerprint")!!,
            createdAtMs = json.long("createdAtMs"),
            expiresAtMs = json.long("expiresAtMs"),
            resolvedAtMs = json.longOrNull("resolvedAtMs"),
        )
    }

    private fun context(json: JsonObject): MemoryProposeContext = MemoryProposeContext(
        conversationId = json.stringOrNull("conversationId")!!,
        folderId = json.stringOrNull("folderId"),
        messageId = json.stringOrNull("messageId")!!,
        nowMs = json.long("nowMs"),
        activeContents = json.strings("activeContents"),
        records = json["records"]!!.jsonArray.map { record(it.jsonObject) },
        userText = json.stringOrNull("userText")!!,
    )

    private fun str(v: String?): JsonElement = v?.let(::JsonPrimitive) ?: JsonNull

    private fun num(v: Long?): JsonElement = v?.let(::JsonPrimitive) ?: JsonNull

    private fun obj(vararg pairs: Pair<String, JsonElement>): JsonObject = JsonObject(linkedMapOf(*pairs))

    private fun json(r: MemoryCandidate): JsonObject = obj(
        "id" to str(r.id),
        "status" to str(r.status.wire),
        "proposedLayer" to str(r.proposedLayer.wire),
        "proposedKind" to str(r.proposedKind.wire),
        "content" to str(r.content),
        "scope" to obj("type" to str(r.scope.type.wire), "id" to str(r.scope.id)),
        "source" to obj(
            "type" to str(r.source.type.wire),
            "conversationId" to str(r.source.conversationId),
            "messageIds" to JsonArray(r.source.messageIds.map(::JsonPrimitive)),
            "observedAtMs" to num(r.source.observedAtMs),
        ),
        "sensitivity" to str(r.sensitivity.wire),
        "confidence" to JsonPrimitive(r.confidence),
        "fingerprint" to str(r.fingerprint),
        "createdAtMs" to num(r.createdAtMs),
        "expiresAtMs" to num(r.expiresAtMs),
        "resolvedAtMs" to num(r.resolvedAtMs),
    )

    private fun json(d: MemoryProposeDecision): JsonObject = obj(
        "action" to str(d.action.wire),
        "reason" to str(d.reason?.wire),
        "candidate" to (d.candidate?.let(::json) ?: JsonNull),
    )

    /** Describes the path of the first difference; numbers compare as Double (fixture 1 equals output 1.0), everything else compares strictly by JSON type and content. */
    private fun treeDiff(path: String, expected: JsonElement, actual: JsonElement): String? = when {
        expected is JsonObject && actual is JsonObject ->
            if (expected.keys != actual.keys) {
                "$path keys: expected ${expected.keys}, got ${actual.keys}"
            } else {
                expected.keys.firstNotNullOfOrNull { k -> treeDiff("$path.$k", expected[k]!!, actual[k]!!) }
            }
        expected is JsonArray && actual is JsonArray ->
            if (expected.size != actual.size) {
                "$path size: expected ${expected.size}, got ${actual.size}"
            } else {
                expected.indices.firstNotNullOfOrNull { i -> treeDiff("$path[$i]", expected[i], actual[i]) }
            }
        expected is JsonNull || actual is JsonNull ->
            if (expected is JsonNull && actual is JsonNull) null else "$path: expected $expected, got $actual"
        expected is JsonPrimitive && actual is JsonPrimitive -> {
            val en = expected.content.toDoubleOrNull()
            val an = actual.content.toDoubleOrNull()
            val same = if (!expected.isString && !actual.isString && en != null && an != null) {
                en == an
            } else {
                expected.isString == actual.isString && expected.content == actual.content
            }
            if (same) null else "$path: expected $expected, got $actual"
        }
        else -> "$path: expected $expected, got $actual"
    }

    /** shared test-fixtures/provider-toolcall/tool-unsupported-4xx.json: id to expect. */
    private val toolUnsupported: Map<String, Boolean> by lazy {
        var dir: File? = File("").absoluteFile
        var file: File? = null
        while (dir != null && file == null) {
            file = File(dir, "shared/test-fixtures/provider-toolcall/tool-unsupported-4xx.json").takeIf { it.exists() }
            dir = dir.parentFile
        }
        val root = Json.parseToJsonElement(file!!.readText()).jsonObject
        root["cases"]!!.jsonArray.associate { it.jsonObject.id() to it.jsonObject.bool("expect") }
    }

    @Test
    fun tool_and_tool_result_match_fixture_byte_for_byte() {
        assertEquals(fixture["tool"].toString(), MemoryPropose.TOOL_JSON.toString())
        assertEquals(fixture.stringOrNull("toolResult"), MemoryPropose.TOOL_RESULT)
        assertEquals(MemoryPropose.TOOL_NAME, MemoryPropose.tool.function.name)
        val params = fixture["tool"]!!.jsonObject["function"]!!.jsonObject["parameters"]!!.jsonObject["properties"]!!.jsonObject
        assertEquals(params["kind"]!!.jsonObject.strings("enum"), MemoryPropose.KINDS.map { it.wire })
        assertEquals(params["scope"]!!.jsonObject.strings("enum"), MemoryPropose.SCOPES.map { it.wire })
        assertEquals(fixture.strings("scopes"), MemoryPropose.SCOPES.map { it.wire })
        assertEquals(fixture.strings("skipReasons"), MemoryProposeSkipReason.entries.map { it.wire })
        assertEquals(fixture.strings("modes"), MemoryProposeMode.entries.map { it.wire })
        assertEquals(fixture.strings("episodicKinds").toSet(), MemoryPropose.EPISODIC_KINDS.map { it.wire }.toSet())
        assertEquals(fixture.objOrNull("constants")!!.int("maxProposalsPerTurn"), MemoryPropose.MAX_PROPOSALS_PER_TURN)
    }

    @Test
    fun projections_match_fixture() {
        val projections = fixture.objOrNull("projections")!!
        val protocols = ToolWireProtocol.entries
        assertEquals(projections.keys, protocols.map { it.wireValue }.toSet())
        val failures = protocols.mapNotNull { p ->
            val expected = projections[p.wireValue]!!
            val actual = ToolWireProtocolAdapter.toolsJson(p, listOf(MemoryPropose.tool))
            if (expected == actual) null else "${p.wireValue}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun proposeCases() {
        val failures = group("proposeCases").mapNotNull { c ->
            val e = c["expected"]!!.jsonObject
            val actual = MemoryPropose.propose(
                argumentsJson = c.stringOrNull("arguments")!!,
                context = context(c["context"]!!.jsonObject),
                priorInTurn = c.int("priorInTurn"),
            )
            treeDiff("expected", e, json(actual))?.let { "${c.id()}: $it" }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun modeCases() {
        val failures = group("modeCases").mapNotNull { c ->
            val i = c["input"]!!.jsonObject
            val expected = MemoryProposeMode.fromWire(c.stringOrNull("expected")!!)!!
            val actual = MemoryPropose.mode(
                MemoryProposeModeInput(
                    purpose = MemoryProposePurpose.fromWire(i.stringOrNull("purpose")!!)!!,
                    freshSend = i.bool("freshSend"),
                    memoryEnabled = i.bool("memoryEnabled"),
                    autoSuggest = i.bool("autoSuggest"),
                    connectionSupportsTools = i.bool("connectionSupportsTools"),
                    degraded = i.bool("degraded"),
                ),
            )
            if (actual == expected) null else "${c.id()}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun degradeCases() {
        val failures = group("degradeCases").mapNotNull { c ->
            val rejection = c.stringOrNull("rejection")!!
            val qualifies = toolUnsupported[rejection] ?: return@mapNotNull "${c.id()}: unknown rejection $rejection"
            val expected = c.objOrNull("expected")!!.bool("degrade")
            val actual = MemoryPropose.degrade(
                rejectionQualifies = qualifies,
                legIndex = c.int("legIndex"),
                streamStarted = c.bool("streamStarted"),
                receivedStructuredToolCalls = c.bool("receivedStructuredToolCalls"),
            )
            if (actual == expected) null else "${c.id()}: expected $expected, got $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun degraded_key_joins_connection_and_model_with_newline() {
        assertEquals("conn-1\ngpt-4o", MemoryPropose.degradedKey("conn-1", "gpt-4o"))
    }
}
