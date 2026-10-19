package ai.oriveo.community.core.context

import java.time.Instant
import java.util.Locale
import kotlin.math.ceil
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** L3 recall micro benchmark (same method on every platform): 1000 deterministic synthetic items + 200 queries; with the index built, a single recall has p95 < 30 ms. */
class ContextMemoryRecallBenchmarkTest {

    @Test
    fun `recall_1000_items_200_queries_p95`() {
        val buildStart = System.nanoTime()
        val index = MemoryRecall.buildIndex(ITEMS)
        val buildMs = (System.nanoTime() - buildStart) / 1_000_000.0
        assertEquals("every synthetic item is indexed", ITEMS.size, index.size)
        // At least one query must hit, so the benchmark is not measuring an empty run.
        assertTrue("queries must hit", QUERIES.any { recall(index, it).isNotEmpty() })

        repeat(WARMUPS) { recall(index, QUERIES[it % QUERIES.size]) }
        val samples = QUERIES.indices.map { i ->
            val start = System.nanoTime()
            recall(index, QUERIES[i])
            (System.nanoTime() - start) / 1_000_000.0
        }.sorted()
        assertTrue("need ≥ 200 samples", samples.size >= 200)
        val p50 = samples[ceil(0.5 * samples.size).toInt() - 1]
        val p95 = samples[ceil(0.95 * samples.size).toInt() - 1]
        println(
            "ContextMemoryRecallBenchmark recall_1000_items_200_queries_p95 " +
                "build=${"%.2f".format(Locale.ROOT, buildMs)}ms p50=${"%.3f".format(Locale.ROOT, p50)} " +
                "p95=${"%.3f".format(Locale.ROOT, p95)} n=${samples.size}",
        )
        assertTrue("p95=$p95 ms exceeds 30 ms", p95 < 30.0)
    }

    private fun recall(index: MemoryRecallIndex, query: String): List<MemoryRecallHit> =
        MemoryRecall.recall(index, query, CONVERSATION_ID, folderId = null, now = NOW)

    private companion object {
        const val WARMUPS = 30
        const val CONVERSATION_ID = "3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d"
        val NOW: Instant = Instant.parse("2026-10-17T00:00:00Z")

        val SUBJECTS = listOf("saga", "cover", "database", "release", "standup", "chapter", "epilogue", "budget", "invoice", "server")
        val VERBS = listOf("ends in", "moved to", "uses", "ships on", "changed to", "set in", "starts at", "is capped at")
        val PLACES = listOf("Constantinople", "Venice", "PostgreSQL", "October 3", "10am", "Rome", "dark blue", "v2.3", "Kyoto", "1453")
        val ZH = listOf("\u5c0f\u8bf4\u7ed3\u5c40\u5b9a\u57281453\u5e74", "\u5c01\u9762\u7528\u6df1\u84dd\u8272", "\u6570\u636e\u5e93\u9009PostgreSQL", "\u5468\u4f1a\u6539\u5230\u5341\u70b9", "\u5c3e\u58f0\u8bbe\u5728\u5a01\u5c3c\u65af")

        /** Item i: an English sentence (subject x predicate x place rotation) or a Chinese sentence, numbered so every body differs. */
        val ITEMS: List<MemoryItem> = (0 until 1000).map { i ->
            val content = if (i % 5 == 4) {
                "\u51b3\u5b9a${ZH[i % ZH.size]}，\u7b2c${i}\u53f7"
            } else {
                "Decided the ${SUBJECTS[i % SUBJECTS.size]} ${VERBS[i % VERBS.size]} ${PLACES[(i / 3) % PLACES.size]} item$i"
            }
            MemoryItem(
                id = "30000000-0000-4000-8000-%012d".format(i),
                layer = MemoryLayer.EPISODIC,
                kind = if (i % 2 == 0) MemoryKind.DECISION else MemoryKind.EVENT,
                content = content,
                scope = if (i % 7 == 0) MemoryItemScope(MemoryScopeType.CONVERSATION, CONVERSATION_ID) else MemoryItemScope(),
                pinned = i % 50 == 0,
                confidence = if (i % 3 == 0) 0.8 else 1.0,
                mutationId = "00000000-0000-4000-8000-000000000000",
                deviceId = "d",
                occurredAt = "2026-%02d-%02dT09:00:00Z".format(1 + i % 9, 1 + i % 28),
            )
        }

        val QUERIES: List<String> = (0 until 200).map { i ->
            if (i % 4 == 3) {
                "\u6211\u4eec\u5f53\u65f6${ZH[i % ZH.size]}\u662f\u600e\u4e48\u5b9a\u7684？"
            } else {
                "When did we decide the ${SUBJECTS[i % SUBJECTS.size]} ${VERBS[(i + 1) % VERBS.size]} ${PLACES[i % PLACES.size]}?"
            }
        }
    }
}
