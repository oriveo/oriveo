package ai.oriveo.community.core.context

import ai.oriveo.community.core.context.ContextContractFixture.double
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Rho calibration table and manifest log: isolated per key, default rho0, serialization round trip, at most 50 entries per conversation. */
class ContextContractLedgerTest {

    private val rho0: Double by lazy {
        ContextContractFixture.load("budget.v1.json")["constants"]!!.jsonObject.double("rho0")
    }

    private fun seeded(): RhoCalibration = RhoCalibration()
        .recordingSample(observedInput = 300, mediaTokens = 0, textBytes = 1000)
        .recordingSample(observedInput = 280, mediaTokens = 0, textBytes = 1000)
        .recordingSample(observedInput = 320, mediaTokens = 0, textBytes = 1000)

    @Test
    fun `table defaults to rho0 for unknown keys`() {
        val cal = RhoCalibrationTable().calibration(transportInstanceId = "t1", modelId = "m1")
        assertEquals(0, cal.n)
        assertEquals(rho0, cal.rho, 0.0)
        assertEquals(rho0, cal.rhoHi, 0.0)
    }

    @Test
    fun `table isolates by transport and model`() {
        val table = RhoCalibrationTable().updating("t1", "m1") { seeded() }
        assertEquals(3, table.calibration("t1", "m1").n)
        assertEquals(0.3, table.calibration("t1", "m1").rho, 1e-12)
        assertEquals(0.345, table.calibration("t1", "m1").rhoHi, 1e-12)
        // Same model on a different transport instance, or same instance with a different model, are unaffected
        assertEquals(rho0, table.calibration("t2", "m1").rho, 0.0)
        assertEquals(rho0, table.calibration("t1", "m2").rho, 0.0)
        assertEquals(0, table.calibration("t1", "m2").n)
        // updating accumulates starting from the current value
        val next = table.updating("t1", "m1") { it.recordingSample(400, 0, 1000) }
        assertEquals(4, next.calibration("t1", "m1").n)
        assertEquals(0.32999999999999996, next.calibration("t1", "m1").rho, 1e-12)
    }

    @Test
    fun `table round trips through kotlinx serialization`() {
        val partial = RhoCalibration()
            .recordingOverflowMiss()
            .recordingSample(300, 0, 1000)
        val table = RhoCalibrationTable()
            .updating("t1", "m1") { seeded() }
            .updating("t1", "m2") { partial }
        val json = Json.encodeToString(table)
        val back = Json.decodeFromString<RhoCalibrationTable>(json)
        assertEquals(table, back)
        // Seed samples must round trip too: after the 2nd and 3rd samples it is still reset to the mean of 1..3
        val resumed = back.calibration("t1", "m2")
            .recordingSample(280, 0, 1000)
            .recordingSample(320, 0, 1000)
        assertEquals(3, resumed.n)
        assertEquals(0.3, resumed.rho, 1e-12)
    }

    @Test
    fun `table json is versioned flat and sorted`() {
        val table = RhoCalibrationTable()
            .updating("t2", "m1") { seeded() }
            .updating("t1", "m2") { RhoCalibration().recordingSample(300, 0, 1000) }
            .updating("t1", "m1") { it }
        val json = Json.parseToJsonElement(Json.encodeToString(table)).jsonObject
        assertEquals(1, json["version"]!!.jsonPrimitive.int)
        val entries = json["entries"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("t1/m1", "t1/m2", "t2/m1"), entries.map {
            it["transportInstanceId"]!!.jsonPrimitive.content + "/" + it["modelId"]!!.jsonPrimitive.content
        })
        assertEquals(setOf("transportInstanceId", "modelId", "n", "rho", "seeds"), entries[0].keys)
        assertEquals(3, entries[2]["seeds"]!!.jsonArray.size)
        val bad = """{"version":2,"entries":[]}"""
        assertTrue(runCatching { Json.decodeFromString<RhoCalibrationTable>(bad) }.isFailure)
    }

    private fun manifest(conversationId: String, index: Int): ContextManifest = ContextManifest(
        requestId = "$conversationId-r$index",
        conversationId = conversationId,
        purpose = RequestPurpose.CHAT,
        transport = "relay-1",
        model = "model-a",
        W = 128000,
        O = 8000,
        B = 115200,
        basis = ContextBasis.OBSERVED,
        estimatedInput = 1000 + index,
        observedInput = 990 + index,
        segments = listOf(
            ContextManifestSegment(kind = ContextSegmentKind.INSTRUCTIONS, tokens = 120),
            ContextManifestSegment(kind = ContextSegmentKind.MEMORY, tokens = 800, items = 6, omitted = 2),
        ),
        checkpointId = null,
        tailFrom = "m$index",
        unansweredMerged = 0,
        reminder = false,
        stopReason = null,
        createdAt = 1_700_000_000_000L + index,
    )

    @Test
    fun `manifest log keeps latest 50 per conversation`() {
        var log = ContextManifestLog()
        (1..51).forEach { log = log.appending(manifest("c1", it)) }
        (1..3).forEach { log = log.appending(manifest("c2", it)) }
        val c1 = log.manifests("c1")
        assertEquals(ContextManifestLog.MAX_PER_CONVERSATION, c1.size)
        assertEquals(50, c1.size)
        // The 51st entry evicts the oldest (1st); order is oldest to newest
        assertEquals("c1-r2", c1.first().requestId)
        assertEquals("c1-r51", c1.last().requestId)
        assertTrue(c1.none { it.requestId == "c1-r1" })
        assertEquals(listOf("c2-r1", "c2-r2", "c2-r3"), log.manifests("c2").map { it.requestId })
        assertTrue(log.manifests("c3").isEmpty())
        assertEquals("c1-r51", log.latest("c1")?.requestId)
        assertEquals(null, log.latest("c3"))
    }

    @Test
    fun `manifest round trips through kotlinx serialization`() {
        val m = manifest("c1", 7).copy(basis = ContextBasis.UNKNOWN, W = null, B = null, observedInput = null, stopReason = StopReason.LENGTH)
        val back = Json.decodeFromString<ContextManifest>(Json.encodeToString(m))
        assertEquals(m, back)
        assertTrue(Json.encodeToString(m).contains("\"basis\":\"unknown\""))
        assertTrue(Json.encodeToString(m).contains("\"stopReason\":\"length\""))
    }
}
