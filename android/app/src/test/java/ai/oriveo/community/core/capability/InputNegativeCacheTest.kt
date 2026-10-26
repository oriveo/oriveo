package ai.oriveo.community.core.capability

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Input-capability negative cache v2; verdictRevision is driven by `shared/test-fixtures/capability/negative-cache.v1.json`. */
class InputNegativeCacheTest {

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/capability/negative-cache.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private fun verdictOf(raw: kotlinx.serialization.json.JsonElement?): InputNegativeCache.Verdict? {
        if (raw == null || raw is JsonNull) return null
        val obj = raw.jsonObject
        fun str(name: String) = obj[name]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
        return InputNegativeCache.Verdict(
            state = str("state")!!,
            reasonCode = str("reasonCode"),
            wireFamily = str("wireFamily"),
            sourceRefs = obj["sourceRefs"]?.takeUnless { it is JsonNull }?.jsonArray?.map { it.jsonPrimitive.content },
        )
    }

    @Test
    fun verdictRevisionMatchesSharedFixture() {
        val cases = fixture.getValue("verdictRevisionCases").jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val id = case.getValue("id").jsonPrimitive.content
            val verdict = verdictOf(case["verdict"])
            assertEquals(id, case.getValue("canonical").jsonPrimitive.content, InputNegativeCache.canonicalVerdictJson(verdict))
            assertEquals(id, case.getValue("revision").jsonPrimitive.content, InputNegativeCache.verdictRevision(verdict))
        }
    }

    private val verdict = InputNegativeCache.Verdict(state = "unavailable", reasonCode = "r", wireFamily = "openai_chat", sourceRefs = listOf("b", "a"))
    private val t0 = 1_760_000_000L

    @Test
    fun hitsWithinSevenDaysAndExpiresAfterwardDeletingEntry() {
        val store = InputNegativeCache.MemoryStore()
        val cache = InputNegativeCache(store)
        cache.record("c1", "m1", "openai_chat", "vision_input", "sig-1", verdict, t0)
        val entry = cache.entries().single()
        assertEquals(t0, entry.second.recordedAt)
        assertEquals("sig-1", entry.second.signatureId)
        assertEquals(InputNegativeCache.verdictRevision(verdict), entry.second.verdictRevision)
        assertTrue(cache.isHit("c1", "m1", "openai_chat", "vision_input", verdict, t0 + InputNegativeCache.TTL_SECONDS - 1))
        assertEquals(1, store.snapshot().size)
        assertFalse(cache.isHit("c1", "m1", "openai_chat", "vision_input", verdict, t0 + InputNegativeCache.TTL_SECONDS + 1))
        assertTrue(store.snapshot().isEmpty())
    }

    @Test
    fun changedVerdictRevisionMissesButKeepsEntry() {
        val store = InputNegativeCache.MemoryStore()
        val cache = InputNegativeCache(store)
        cache.record("c1", "m1", "openai_chat", "vision_input", "sig-1", verdict, t0)
        assertFalse(cache.isHit("c1", "m1", "openai_chat", "vision_input", verdict.copy(reasonCode = "r2"), t0 + 60))
        assertEquals(1, store.snapshot().size)
        assertTrue(cache.isHit("c1", "m1", "openai_chat", "vision_input", verdict, t0 + 60))
    }

    @Test
    fun paramKeyAndVisionKeyAreIndependent() {
        val cache = InputNegativeCache(InputNegativeCache.MemoryStore())
        val param = InputNegativeCache.paramCapabilityKey("temperature")
        assertEquals("param:temperature", param)
        cache.record("c1", "m1", null, param, "sig-p", null, t0)
        assertTrue(cache.isHit("c1", "m1", "", param, null, t0 + 1))
        assertFalse(cache.isHit("c1", "m1", "", "vision_input", null, t0 + 1))
        cache.record("c1", "m1", "", "vision_input", "sig-v", null, t0)
        assertFalse(cache.isHit("c1", "m1", "", param, verdict, t0 + 2))
        assertTrue(cache.isHit("c1", "m1", "", "vision_input", null, t0 + 2))
        cache.clearConnection("c1")
        assertTrue(cache.entries().isEmpty())
    }
    /** Reading an entry looks up by key only and does not copy the whole table; writes and deletions advance the revision, expiry deletions do not. */
    @Test
    fun read_uses_single_key_lookup() {
        class CountingStore : InputNegativeCache.Store {
            val memory = InputNegativeCache.MemoryStore()
            var snapshots = 0
            var gets = 0
            override fun snapshot(): Map<String, String> { snapshots += 1; return memory.snapshot() }
            override fun get(name: String): String? { gets += 1; return memory.get(name) }
            override fun put(name: String, value: String) = memory.put(name, value)
            override fun remove(names: Collection<String>) = memory.remove(names)
        }
        val store = CountingStore()
        val t0 = 1_700_000_000L
        val cache = InputNegativeCache(store) { t0 }
        cache.record("c1", "m1", "", "vision_input", "sig", null, t0)
        val afterRecord = cache.revision.value
        store.snapshots = 0
        assertTrue(cache.isHit("c1", "m1", "", "vision_input", null, t0 + 1))
        assertFalse(cache.isHit("c1", "m1", "", "file_input", null, t0 + 1))
        assertEquals(0, store.snapshots)
        assertEquals(2, store.gets)
        assertEquals(afterRecord, cache.revision.value)
        cache.clearConnection("c1")
        assertTrue(cache.revision.value > afterRecord)
    }
}
