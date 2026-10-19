package ai.oriveo.community.core.memory

import ai.oriveo.community.core.context.ContextRecallEntry
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryStatus
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

/** The index is rebuilt only when the set of L3 items changes; memory off -> no retrieval. */
class MemoryRecallIndexCacheTest {

    private val now = Instant.parse("2026-10-17T00:00:00Z")
    private val item = MemoryItem(
        id = "30000000-0000-4000-8000-000000000001",
        layer = MemoryLayer.EPISODIC,
        kind = MemoryKind.DECISION,
        content = "Decided the saga ends in 1453 in Constantinople",
        mutationId = "m-1",
        deviceId = "d",
        occurredAt = "2026-10-01T09:00:00Z",
    )
    private val semantic = MemoryItem(id = "s-1", kind = MemoryKind.FACT, content = "Likes tea", mutationId = "m-2", deviceId = "d")
    private val query = "Where does the saga end, Constantinople?"

    private suspend fun MemoryRecallIndexCache.hits(items: List<MemoryItem>, useMemory: Boolean = true) =
        recall(useMemory, items, query, "conv-1", null, now)

    @Test
    fun rebuilds_only_when_episodic_set_changes() = runBlocking {
        val cache = MemoryRecallIndexCache(Dispatchers.Unconfined)
        val expected = listOf(ContextRecallEntry(item.id, item.content, "2026-10-01"))
        assertEquals(expected, cache.hits(listOf(item, semantic)))
        assertEquals(expected, cache.hits(listOf(item)))
        // Only L2 changed: no rebuild.
        assertEquals(1, cache.builds)
        val conflicted = item.copy(status = MemoryStatus.CONFLICTED, mutationId = "m-3")
        assertEquals(emptyList<ContextRecallEntry>(), cache.hits(listOf(conflicted)))
        assertEquals(2, cache.builds)
    }

    @Test
    fun memory_off_or_blank_query_skips_recall() = runBlocking {
        val cache = MemoryRecallIndexCache(Dispatchers.Unconfined)
        assertEquals(emptyList<ContextRecallEntry>(), cache.hits(listOf(item), useMemory = false))
        assertEquals(emptyList<ContextRecallEntry>(), cache.recall(true, listOf(item), "  ", "conv-1", null, now))
        assertEquals(0, cache.builds)
    }
}
