package ai.oriveo.community.core.provider.relay

import java.nio.file.Files
import java.nio.file.Paths
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure selection for automatic web probe triggers (`shared/test-fixtures/relay/web-probe.v1.json` triggers / triggerCases).
 * The clock is injected per case; candidates are built per the production convention: save = enabled list x event snippet hash, other events = the one model whose protocol has a stored snippet.
 */
class RelayWebProbeTriggerTest {
    private val fixture: JsonObject by lazy {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/web-probe.v1.json")
            if (Files.exists(candidate)) {
                return@lazy Json.parseToJsonElement(String(Files.readAllBytes(candidate), Charsets.UTF_8)).jsonObject
            }
            dir = dir.parent ?: return@repeat
        }
        error("fixture web-probe.v1.json not found")
    }

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.strings(key: String): List<String> = getValue(key).jsonArray.map { it.jsonPrimitive.content }
    private fun millis(iso: String): Long = Instant.parse(iso).toEpochMilli()

    @Test
    fun `RL2-WEBPROBE-TRIG limit and window constants match the fixture`() {
        val triggers = fixture.getValue("triggers").jsonObject
        assertEquals(triggers.string("perSave").toInt(), RelayWebProbeTrigger.PER_SAVE)
        assertEquals(triggers.string("perConnectionPerWindow").toInt(), RelayWebProbeTrigger.PER_CONNECTION_PER_WINDOW)
        assertEquals(triggers.string("windowSeconds").toLong(), RelayWebProbeTrigger.WINDOW_SECONDS)
        assertEquals(listOf("connectionId", "modelId", "transport", "fragmentHash"), triggers.strings("dedupeKey"))
    }

    @Test
    fun `RL2-WEBPROBE-TRIG per-case selection`() {
        val failures = mutableListOf<String>()
        val cases = fixture.getValue("triggerCases").jsonArray.map { it.jsonObject }
        cases.forEach { case ->
            val caseId = case.string("caseId")
            try {
                check(case)
            } catch (error: AssertionError) {
                failures += "RL2-WEBPROBE-TRIG-$caseId: ${error.message}"
            } catch (error: Exception) {
                failures += "RL2-WEBPROBE-TRIG-$caseId: ${error::class.simpleName} ${error.message}"
            }
        }
        assertTrue("${failures.size}/${cases.size} failed\n" + failures.joinToString("\n"), failures.isEmpty())
    }

    private fun check(case: JsonObject) {
        val event = case.getValue("event").jsonObject
        val type = event.string("type")
        val connectionId = case.string("connectionId")
        val history = case.getValue("autoHistory").jsonArray.map { it.jsonObject }.map {
            RelayWebProbeAutoEntry(
                connectionId = it.string("connectionId"),
                modelId = it.string("modelId"),
                transport = it.string("transport"),
                fragmentHash = it.string("fragmentHash"),
                sentAt = millis(it.string("sentAt")),
            )
        }
        val candidates = when (type) {
            "saveFragment" -> {
                val transport = event.string("transport")
                val hash = RelayWebProbe.fragmentHash(event.getValue("fragment").jsonObject)
                case.strings("enabledOnTransport").map { RelayWebProbeCandidate(it, transport, hash) }
            }
            else -> {
                val fragments = case["fragments"]?.jsonObject.orEmpty()
                val transport = event["transport"]?.jsonPrimitive?.content
                val fragment = transport?.let { fragments[it]?.jsonObject }
                if (fragment == null) emptyList() else listOf(RelayWebProbeCandidate(event.string("modelId"), transport, RelayWebProbe.fragmentHash(fragment)))
            }
        }
        val triggerEvent = when (type) {
            "saveFragment" -> RelayWebProbeTriggerEvent.SaveFragment
            "enableModel" -> RelayWebProbeTriggerEvent.EnableModel(lazyVerifyPassed = event.string("lazyVerify") == "passed")
            "manualTest" -> RelayWebProbeTriggerEvent.ManualTest
            "retest" -> RelayWebProbeTriggerEvent.Retest
            else -> RelayWebProbeTriggerEvent.Other
        }
        val selection = RelayWebProbeTrigger.select(
            isRelayForm = case.string("form") == "RELAY",
            event = triggerEvent,
            candidates = candidates,
            history = history,
            now = millis(case.string("now")),
            connectionId = connectionId,
        )
        val expect = case.getValue("expect").jsonObject
        assertEquals("probe", expect.strings("probe"), selection.probe)
        assertEquals("untested", expect.strings("untested"), selection.untested)
        expect["countsTowardCap"]?.let { assertEquals("countsTowardCap", it.jsonPrimitive.content.toBoolean(), selection.countsTowardCap) }
    }

    @Test
    fun `RL2-WEBPROBE-TRIG auto history pruning and connection deletion`() {
        val now = millis("2026-10-13T12:00:00Z")
        val history = RelayWebProbeAutoHistory(RelayWebProbeRecordStore.MemoryStore())
        val old = now - RelayWebProbeTrigger.WINDOW_MILLIS
        history.add(RelayWebProbeAutoEntry("conn-1", "stale", "anthropic_messages", "old-hash", old))
        history.add(RelayWebProbeAutoEntry("conn-1", "current", "anthropic_messages", "cur-hash", old))
        history.add(RelayWebProbeAutoEntry("conn-1", "recent", "anthropic_messages", "old-hash", now - 1))
        history.add(RelayWebProbeAutoEntry("conn-2", "other", "anthropic_messages", "old-hash", old))
        history.prune("conn-1", now, mapOf("anthropic_messages" to "cur-hash"))
        assertEquals(setOf("current", "recent", "other"), history.entries().map { it.modelId }.toSet())
        history.clearConnection("conn-1")
        assertEquals(listOf("other"), history.entries().map { it.modelId })
    }
}
