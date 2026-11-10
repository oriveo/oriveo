package ai.oriveo.community.core.studio

import ai.oriveo.community.core.studio.StudioByokTasks.BatchResult
import ai.oriveo.community.core.studio.StudioByokTasks.Phase
import ai.oriveo.community.core.studio.StudioByokTasks.QueueEffect
import ai.oriveo.community.core.studio.StudioByokTasks.QueueEvent
import ai.oriveo.community.core.studio.StudioByokTasks.QueueState
import ai.oriveo.community.core.studio.StudioByokTasks.ReconcileAction
import ai.oriveo.community.core.studio.StudioByokTasks.RoundStatus
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Runs the shared byok_image_tasks.v1.json fixture against the Android BYOK task logic:
 * spec constants, timeout, retry, transport phase (Android table), aggregate, queue and reconcile.
 */
class StudioByokTasksContractTest {
    private val contracts: Path by lazy {
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("shared/studio-contracts") }
            .firstOrNull { Files.exists(it.resolve("byok_image_tasks.v1.json")) }
            ?: error("byok_image_tasks.v1.json not found")
    }

    private fun read(path: Path): JsonElement = Json.parseToJsonElement(path.toFile().readText())

    private val fixture: JsonObject by lazy { read(contracts.resolve("byok_image_tasks.v1.json")).jsonObject }

    private fun group(name: String): List<JsonObject> {
        val cases = fixture.getValue(name).jsonArray.map { it.jsonObject }
        assertTrue("fixture group $name has cases", cases.isNotEmpty())
        return cases
    }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.isNull(key: String): Boolean = this[key] == null || this[key] is JsonNull

    private fun JsonObject.strOrNull(key: String): String? = if (isNull(key)) null else str(key)

    private fun JsonObject.intOrNull(key: String): Int? = if (isNull(key)) null else getValue(key).jsonPrimitive.int

    private fun JsonObject.longOrNull(key: String): Long? = if (isNull(key)) null else getValue(key).jsonPrimitive.long

    private fun JsonObject.bool(key: String): Boolean = getValue(key).jsonPrimitive.boolean

    private fun JsonObject.strings(key: String): List<String> = getValue(key).jsonArray.map { it.jsonPrimitive.content }

    private fun kindOf(wire: String?): StudioImageErrorKind? =
        wire?.let { w -> StudioImageErrorKind.entries.firstOrNull { it.wire == w } ?: error("unknown kind $w") }

    private fun phaseOf(wire: String): Phase = Phase.entries.firstOrNull { it.wire == wire } ?: error("unknown phase $wire")

    @Test
    fun spec() {
        val spec = fixture.getValue("spec").jsonObject
        assertEquals("defaultTimeoutSeconds", spec.getValue("defaultTimeoutSeconds").jsonPrimitive.int, StudioByokTasks.DEFAULT_TIMEOUT_SECONDS)
        assertEquals("maxTimeoutSeconds", spec.getValue("maxTimeoutSeconds").jsonPrimitive.int, StudioByokTasks.MAX_TIMEOUT_SECONDS)
        assertEquals("maxConcurrentRounds", spec.getValue("maxConcurrentRounds").jsonPrimitive.int, StudioByokTasks.MAX_CONCURRENT_ROUNDS)
        assertEquals("maxAutoRetries", spec.getValue("maxAutoRetries").jsonPrimitive.int, StudioByokTasks.MAX_AUTO_RETRIES)
        assertEquals("phases", spec.strings("phases"), Phase.entries.map { it.wire })
        assertEquals("reconcileActions", spec.strings("reconcileActions"), ReconcileAction.entries.map { it.wire })
        assertEquals("roundStatuses", spec.strings("roundStatuses"), RoundStatus.entries.map { it.wire })
    }

    @Test
    fun timeout() {
        val mismatches = group("timeout").mapNotNull { case ->
            val actual = StudioByokTasks.effectiveTimeoutSeconds(case.intOrNull("timeoutSeconds"))
            val expected = case.getValue("expect").jsonPrimitive.int
            if (actual == expected) null else "${case.str("caseId")}: expected $expected, got $actual"
        }
        assertEquals("timeout mismatches", emptyList<String>(), mismatches)
    }

    @Test
    fun retry() {
        val mismatches = group("retry").mapNotNull { case ->
            val actual = StudioByokTasks.retryDecision(phaseOf(case.str("phase")), case.getValue("attempt").jsonPrimitive.int)
            val expect = case.getValue("expect").jsonObject
            val expected = StudioByokTasks.RetryDecision(
                retry = expect.bool("retry"),
                errorKind = kindOf(expect.strOrNull("errorKind")),
                retried = expect.bool("retried"),
                mayBeBilled = expect.bool("mayBeBilled"),
            )
            if (actual == expected) null else "${case.str("caseId")}: expected $expected, got $actual"
        }
        assertEquals("retry mismatches", emptyList<String>(), mismatches)
    }

    private fun throwableOf(className: String, message: String): Throwable =
        Class.forName(className).getConstructor(String::class.java).newInstance(message) as Throwable

    @Test
    fun transportPhase() {
        val cases = fixture.getValue("transportPhase").jsonObject.getValue("android").jsonArray.map { it.jsonObject }
        assertTrue("android transportPhase table has cases", cases.isNotEmpty())
        val covered = cases.map { it.str("expect") }.toSet()
        assertEquals("android table covers every phase", Phase.entries.map { it.wire }.toSet(), covered)
        val mismatches = cases.mapNotNull { case ->
            val error = throwableOf(case.str("exception"), case.str("message"))
            case.strOrNull("cause")?.let { error.initCause(throwableOf(it, "cause")) }
            val actual = StudioByokTasks.transportPhase(error, case.bool("callCanceled")).wire
            val expected = case.str("expect")
            if (actual == expected) null else "${case.str("caseId")}: expected $expected, got $actual"
        }
        assertEquals("transportPhase mismatches", emptyList<String>(), mismatches)
    }

    @Test
    fun aggregate() {
        val mismatches = group("aggregate").mapNotNull { case ->
            val input = case.getValue("input").jsonObject
            val actual = StudioByokTasks.aggregate(
                n = input.getValue("n").jsonPrimitive.int,
                batches = input.getValue("batches").jsonArray.map { it.jsonPrimitive.int },
                results = input.getValue("results").jsonArray.map { it.jsonObject }.map {
                    BatchResult(images = it.getValue("images").jsonPrimitive.int, errorKind = kindOf(it.strOrNull("errorKind")))
                },
                cancelled = input.bool("cancelled"),
            )
            val expect = case.getValue("expect").jsonObject
            val actualWire = listOf(actual.status.wire, actual.delivered.toString(), actual.errorKind?.wire)
            val expectedWire = listOf(expect.str("status"), expect.getValue("delivered").jsonPrimitive.int.toString(), expect.strOrNull("errorKind"))
            if (actualWire == expectedWire) null else "${case.str("caseId")}: expected $expectedWire, got $actualWire"
        }
        assertEquals("aggregate mismatches", emptyList<String>(), mismatches)
    }

    private fun eventOf(json: JsonObject): QueueEvent {
        val id = json.str("id")
        return when (val type = json.str("type")) {
            "submit" -> QueueEvent.Submit(id)
            "finish" -> QueueEvent.Finish(id)
            "cancel" -> QueueEvent.Cancel(id)
            "response" -> QueueEvent.Response(id)
            else -> error("unknown event $type")
        }
    }

    private fun QueueEffect.wire(): String = when (this) {
        is QueueEffect.Start -> "start:$id"
        is QueueEffect.Cancelled -> "cancelled:$id:$mayBeBilled"
        is QueueEffect.Accept -> "accept:$id"
        is QueueEffect.Drop -> "drop:$id"
    }

    private fun JsonObject.effectWire(): String {
        val head = "${str("type")}:${str("id")}"
        return if (isNull("mayBeBilled")) head else "$head:${bool("mayBeBilled")}"
    }

    @Test
    fun queue() {
        val mismatches = group("queue").flatMap { case ->
            var state = QueueState()
            case.getValue("steps").jsonArray.map { it.jsonObject }.mapIndexedNotNull { index, step ->
                val (next, effects) = StudioByokTasks.reduce(state, eventOf(step.getValue("event").jsonObject))
                state = next
                val expect = step.getValue("expect").jsonObject
                val actualWire = listOf(next.running, next.queued, effects.map { it.wire() })
                val expectedWire = listOf(
                    expect.strings("running"),
                    expect.strings("queued"),
                    expect.getValue("effects").jsonArray.map { it.jsonObject.effectWire() },
                )
                if (actualWire == expectedWire) null else "${case.str("caseId")}#$index: expected $expectedWire, got $actualWire"
            }
        }
        assertEquals("queue mismatches", emptyList<String>(), mismatches)
    }

    @Test
    fun reconcile() {
        val mismatches = group("reconcile").mapNotNull { case ->
            val input = case.getValue("input").jsonObject
            val actual = StudioByokTasks.reconcile(
                status = input.str("status"),
                startedAtMs = input.longOrNull("startedAtMs"),
                nowMs = input.getValue("nowMs").jsonPrimitive.long,
                timeoutSeconds = input.intOrNull("timeoutSeconds"),
                responseReceived = input.bool("responseReceived"),
                transferActive = input.bool("transferActive"),
            ).wire
            val expected = case.str("expect")
            if (actual == expected) null else "${case.str("caseId")}: expected $expected, got $actual"
        }
        assertEquals("reconcile mismatches", emptyList<String>(), mismatches)
    }
}
