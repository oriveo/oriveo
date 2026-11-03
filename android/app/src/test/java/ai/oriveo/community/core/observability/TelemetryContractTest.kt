package ai.oriveo.community.core.observability

import ai.oriveo.community.core.performance.ChatPerformanceMonitor
import java.io.File
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G1 metric-finish contract: every key transaction in the fixture whose platforms include android must have at least one begin call and one finish call in production source,
 * and the transaction names / tags / measurements / units / timeouts used by the facade must match the fixture verbatim.
 *
 * This guards against the original iOS P3 incident: during a refactor the finish calls were removed, every transaction ended by timeout or cancellation, and the metrics silently failed for months before anyone noticed.
 */
class TelemetryContractTest {

    private val transactions: List<JsonObject> = ObservabilityFixture.json["transactions"]!!.jsonArray
        .map { it.jsonObject }
        .filter { tx -> tx["platforms"]!!.jsonArray.any { it.jsonPrimitive.content == "android" } }

    private fun JsonObject.str(key: String) = this[key]!!.jsonPrimitive.content

    /** Transaction name → (production begin call, production finish call). Call sites are searched outside ChatPerformanceMonitor. */
    private val productionCalls = mapOf(
        "chat.open" to (".beginChatOpen(" to ".finishChatOpen("),
        "chat.send" to (".beginChatSend(" to ".finishChatSend("),
        "chat.firstToken" to (".beginChatSend(" to ".markFirstOutputVisible("),
        "sync.cycle" to ("syncCycleMonitor.begin(" to "syncCycleMonitor.finish("),
    )

    /**
     * Transactions registered in the fixture that Android has not wired up yet (currently empty). When a new transaction enters the fixture before Android wires it,
     * register it here with its unlock criterion; once wired, add the call site to [productionCalls] and remove it from here.
     */
    private val pending = emptyMap<String, String>()

    private val mainSources: List<File> by lazy {
        ObservabilityFixture.workspaceFile("android/app/src/main/java").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .toList()
    }

    private val monitorSource: File by lazy { mainSources.single { it.name == "ChatPerformanceMonitor.kt" } }

    @Test
    fun `every android transaction is either wired or explicitly pending`() {
        val names = transactions.map { it.str("name") }.toSet()
        assertEquals(names, productionCalls.keys + pending.keys)
        assertTrue("pending and wired transactions must not overlap", productionCalls.keys.intersect(pending.keys).isEmpty())
        transactions.forEach { tx -> assertEquals("fixture convention name = op", tx.str("name"), tx.str("op")) }
    }

    @Test
    fun `every wired transaction has production begin and finish call sites`() {
        val callers = mainSources.filter { it != monitorSource }.map { it.readText() }
        productionCalls.forEach { (name, calls) ->
            val (begin, finish) = calls
            assertTrue("$name is missing production begin call $begin", callers.any { begin in it })
            assertTrue("$name is missing production finish call $finish", callers.any { finish in it })
        }
    }

    @Test
    fun `monitor constants equal the fixture`() {
        val byName = transactions.associateBy { it.str("name") }
        assertEquals(setOf("chat.open", "chat.send", "chat.firstToken"),
            setOf(ChatPerformanceMonitor.CHAT_OPEN, ChatPerformanceMonitor.CHAT_SEND, ChatPerformanceMonitor.CHAT_FIRST_TOKEN))
        assertEquals(byName.getValue("chat.open")["deadline_s"]!!.jsonPrimitive.int * 1000L, ChatPerformanceMonitor.CHAT_OPEN_DEADLINE_MS)
        assertEquals(byName.getValue("chat.send")["deadline_s"]!!.jsonPrimitive.int * 1000L, ChatPerformanceMonitor.CHAT_SEND_DEADLINE_MS)
        assertEquals(byName.getValue("chat.firstToken")["deadline_s"]!!.jsonPrimitive.int * 1000L, ChatPerformanceMonitor.CHAT_FIRST_TOKEN_DEADLINE_MS)

        val sendMeasurements = byName.getValue("chat.send")["measurements"]!!.jsonObject
        assertEquals(sendMeasurements[ChatPerformanceMonitor.MEASUREMENT_TTFT_MS]!!.jsonPrimitive.content, ChatPerformanceMonitor.UNIT_MILLISECOND)
        assertEquals(sendMeasurements[ChatPerformanceMonitor.MEASUREMENT_OUTPUT_CHARS]!!.jsonPrimitive.content, ChatPerformanceMonitor.UNIT_NONE)

        fun tagsOf(name: String) = byName.getValue(name)["tags"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
        assertTrue(ChatPerformanceMonitor.TAG_OPEN_KIND in tagsOf("chat.open"))
        assertTrue(ChatPerformanceMonitor.TAG_MESSAGE_COUNT_BUCKET in tagsOf("chat.open"))
        listOf("chat.send", "chat.firstToken").forEach { name ->
            assertTrue(name, ChatPerformanceMonitor.TAG_ROUTE in tagsOf(name))
            assertTrue(name, ChatPerformanceMonitor.TAG_PROVIDER_KIND in tagsOf(name))
            assertTrue(name, ChatPerformanceMonitor.TAG_ERROR_CODE in tagsOf(name))
        }
        assertTrue(ChatPerformanceMonitor.TAG_FIRST_OUTPUT in tagsOf("chat.firstToken"))

        val enums = ObservabilityFixture.json["tags"]!!.jsonObject["enums"]!!.jsonObject
        fun enumOf(tag: String) = enums[tag]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
        assertEquals(enumOf("chat.open.kind"), ChatPerformanceMonitor.OpenKind.entries.map { it.wireValue }.toSet())
        assertEquals(enumOf("chat.first_output"), ChatPerformanceMonitor.FirstOutput.entries.map { it.wireValue }.toSet())
        assertTrue(enumOf("chat.route").containsAll(listOf("byok", "free", "managed")))
    }

    @Test
    fun `every chat literal in the monitor is registered in the fixture`() {
        val registered = transactions.flatMap { tx ->
            listOf(tx.str("name")) +
                tx["tags"]!!.jsonArray.map { it.jsonPrimitive.content } +
                tx["measurements"]!!.jsonObject.keys
        }.toSet()
        val literals = Regex("\"(chat\\.[A-Za-z_.]+)\"").findAll(monitorSource.readText()).map { it.groupValues[1] }.toSet()
        assertTrue("no chat.* literal found in the monitor; the scan is broken", literals.isNotEmpty())
        assertEquals("names not registered in the fixture must not appear in code", emptySet<String>(), literals - registered)
    }

    @Test
    fun `pending transactions are still in the fixture`() {
        val names = transactions.map { it.str("name") }.toSet()
        pending.keys.forEach { assertTrue("$it is no longer in the fixture; remove the pending entry", it in names) }
    }

    @Test
    fun `sync cycle monitor constants equal the fixture`() {
        val tx = transactions.single { it.str("name") == "sync.cycle" }
        assertEquals(tx.str("name"), ai.oriveo.community.core.performance.SyncCycleMonitor.SYNC_CYCLE)
        assertEquals(tx["deadline_s"]!!.jsonPrimitive.int * 1000L, ai.oriveo.community.core.performance.SyncCycleMonitor.SYNC_CYCLE_DEADLINE_MS)
        assertEquals(listOf(ai.oriveo.community.core.performance.SyncCycleMonitor.TAG_TRIGGER), tx["tags"]!!.jsonArray.map { it.jsonPrimitive.content })
        val measurements = tx["measurements"]!!.jsonObject
        assertEquals("none", measurements[ai.oriveo.community.core.performance.SyncCycleMonitor.MEASUREMENT_DOCS_WRITTEN]!!.jsonPrimitive.content)
        assertEquals("none", measurements[ai.oriveo.community.core.performance.SyncCycleMonitor.MEASUREMENT_DOCS_READ]!!.jsonPrimitive.content)
        val triggers = ObservabilityFixture.json["tags"]!!.jsonObject["enums"]!!.jsonObject["sync.trigger"]!!.jsonArray
            .map { it.jsonPrimitive.content }.toSet()
        assertEquals(triggers, ai.oriveo.community.core.performance.SyncCycleMonitor.Trigger.entries.map { it.wireValue }.toSet())
    }

    @Test
    fun `db long write metric and labels are registered in the fixture`() {
        val metric = ObservabilityFixture.json["metrics"]!!.jsonArray.map { it.jsonObject }
            .single { it.str("name") == ai.oriveo.community.core.data.database.LONG_WRITE_METRIC }
        assertTrue(metric["platforms"]!!.jsonArray.any { it.jsonPrimitive.content == "android" })
        assertEquals("millisecond", metric.str("unit"))
        assertEquals(listOf(ai.oriveo.community.core.data.database.WRITE_LABEL_TAG), metric["tags"]!!.jsonArray.map { it.jsonPrimitive.content })
        val heavy = ObservabilityFixture.json["heavy_write_labels"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
        val used = Regex("withDatabaseWriteLabel\\(\"([^\"]+)\"").findAll(mainSources.joinToString("\n") { it.readText() })
            .map { it.groupValues[1] }.toSet()
        assertTrue("no write label found; the scan is broken", used.isNotEmpty())
        assertEquals("write labels must be registered in the fixture heavy_write_labels", emptySet<String>(), used - heavy)
    }
}
