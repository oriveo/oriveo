package ai.oriveo.community.core.memory

import ai.oriveo.community.core.context.ContextRecallEntry
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryRecall
import ai.oriveo.community.core.context.MemoryRecallIndex
import java.time.Instant
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * L3 recall for chat sends (memory-recall.v1 rule 9, P7 contract 4): keeps one [MemoryRecallIndex] and rebuilds it
 * off the main thread only when the episodic item set changes. The key is the episodic items themselves (id,
 * revision, status, mutationId and every other field), which is stricter than an id + revision + status fingerprint.
 */
class MemoryRecallIndexCache(
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    private val mutex = Mutex()
    private var key: List<MemoryItem>? = null
    private var index: MemoryRecallIndex? = null

    /** Number of index builds so far (tests check that an unchanged item set reuses the index). */
    @Volatile
    var builds: Int = 0
        private set

    suspend fun index(items: List<MemoryItem>): MemoryRecallIndex {
        val episodic = items.filter { it.layer == MemoryLayer.EPISODIC }
        return mutex.withLock {
            val cached = index
            if (cached != null && key == episodic) return@withLock cached
            withContext(dispatcher) { MemoryRecall.buildIndex(episodic) }.also {
                index = it
                key = episodic
                builds++
            }
        }
    }

    /**
     * Hits for [query] (the user message this turn answers) as [D] recall entries; nothing when [useMemory] is off,
     * the query is blank or there is no episodic item. Any account, Free included: L3 stays on this device.
     */
    suspend fun recall(
        useMemory: Boolean,
        items: List<MemoryItem>,
        query: String,
        conversationId: String,
        folderId: String?,
        now: Instant,
    ): List<ContextRecallEntry> {
        if (!useMemory || query.isBlank() || items.none { it.layer == MemoryLayer.EPISODIC }) return emptyList()
        val index = index(items)
        return withContext(dispatcher) {
            MemoryRecall.recall(index, query, conversationId, folderId, now).map { ContextRecallEntry(it.id, it.text, it.date) }
        }
    }
}
