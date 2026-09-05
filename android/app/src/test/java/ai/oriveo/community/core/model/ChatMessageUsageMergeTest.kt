package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cross-platform usage merges pick one side's whole group rather than merging field by field.
 *
 * Taking max() per field can stitch together combinations that neither side ever actually
 * produced, e.g. the remote's input with the local's cacheRead; in the worst case that yields
 * cacheRead + creation > input, breaking the invariant that the cache counts are a subset of
 * the input count. Taking max() also lets a positive number from an older snapshot eat an
 * explicitly observed zero in the newer one, erasing the difference between "explicitly zero"
 * and "never observed".
 */
class ChatMessageUsageMergeTest {

    private fun mergeUsage(local: ChatMessage, remote: ChatMessage): ChatMessage =
        ChatMessage.mergeByIdAndCreatedAt(listOf(local), listOf(remote)).single()

    private fun message(
        id: String = "msg-1",
        text: String = "hello",
        inputTokens: Int? = null,
        outputTokens: Int? = null,
        cachedInputTokens: Int? = null,
        cacheCreationInputTokens: Int? = null,
        cacheCreation5mTokens: Int? = null,
        cacheCreation1hTokens: Int? = null,
    ) = ChatMessage(
        id = id,
        role = ChatRole.Assistant,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "model",
        state = ChatMessageState.Delivered,
        inputTokens = inputTokens,
        outputTokens = outputTokens,
        cachedInputTokens = cachedInputTokens,
        cacheCreationInputTokens = cacheCreationInputTokens,
        cacheCreation5mTokens = cacheCreation5mTokens,
        cacheCreation1hTokens = cacheCreation1hTokens,
    )

    @Test
    fun `merged snapshot never lets cache buckets exceed total input`() {
        val local = message(inputTokens = 1000, cachedInputTokens = 900)
        val remote = message(
            inputTokens = 500,
            cachedInputTokens = 100,
            cacheCreationInputTokens = 400,
        )

        val merged = mergeUsage(local, remote)

        val cacheSum = (merged.cachedInputTokens ?: 0) + (merged.cacheCreationInputTokens ?: 0)
        assertTrue(
            "cache buckets sum to $cacheSum, must not exceed total input ${merged.inputTokens}",
            cacheSum <= (merged.inputTokens ?: 0),
        )
        // taking max per field would give {input:1000, cacheRead:900, creation:400}, whose cache sum of 1300 exceeds the 1000 input.
        assertEquals(1000, merged.inputTokens)
        assertEquals(900, merged.cachedInputTokens)
        assertNull(merged.cacheCreationInputTokens)
    }

    @Test
    fun `empty side never erases the other side's synced usage`() {
        val filled = message(
            inputTokens = 1000,
            outputTokens = 120,
            cachedInputTokens = 0,
            cacheCreation5mTokens = 30,
        )
        val empty = message()

        assertEquals(1000, mergeUsage(filled, empty).inputTokens)
        assertEquals(0, mergeUsage(filled, empty).cachedInputTokens)
        assertEquals(1000, mergeUsage(empty, filled).inputTokens)
        assertEquals(30, mergeUsage(empty, filled).cacheCreation5mTokens)
    }

    @Test
    fun `an explicitly observed zero is not eaten by the other side's positive number`() {
        // the remote is the final settlement: larger input, and it explicitly reports zero cache reads.
        val local = message(inputTokens = 400, outputTokens = 10, cachedInputTokens = 300)
        val remote = message(inputTokens = 1000, outputTokens = 120, cachedInputTokens = 0)

        val merged = mergeUsage(local, remote)

        assertEquals(1000, merged.inputTokens)
        // taking max per field would turn this into 300 -- a number the remote never reported.
        assertEquals(0, merged.cachedInputTokens)
    }

    @Test
    fun `5m and 1h buckets travel with the winning group instead of being silently kept local`() {
        val local = message(inputTokens = 100, outputTokens = 10)
        val remote = message(
            inputTokens = 1000,
            outputTokens = 120,
            cacheCreationInputTokens = 50,
            cacheCreation5mTokens = 20,
            cacheCreation1hTokens = 30,
        )

        val merged = mergeUsage(local, remote)

        // these two fields are not in the merge list, so local.copy silently keeps the local value and the remote's copy is discarded.
        assertEquals(20, merged.cacheCreation5mTokens)
        assertEquals(30, merged.cacheCreation1hTokens)
    }

    @Test
    fun `the larger accounted total wins`() {
        val local = message(inputTokens = 400, outputTokens = 10)
        val remote = message(inputTokens = 1000, outputTokens = 120)

        val merged = mergeUsage(local, remote)

        assertEquals(1000, merged.inputTokens)
        assertEquals(120, merged.outputTokens)
    }

    /**
     * Cache buckets and total input/output tokens were added to cross-device sync at different
     * times, so existing rows commonly have cache buckets but no total input. That reflects a gap
     * in what was collected, not a contradiction between the cache and the total. Treating it as
     * a contradiction and clearing it would erase cache data that was already captured.
     */
    @Test
    fun `legacy rows with cache buckets but no input token are not treated as contradictory`() {
        val legacy = message(cachedInputTokens = 1234, cacheCreation5mTokens = 500)

        val fromLocal = mergeUsage(legacy, message())
        assertEquals(1234, fromLocal.cachedInputTokens)
        assertEquals(500, fromLocal.cacheCreation5mTokens)

        val fromRemote = mergeUsage(message(), legacy)
        assertEquals(1234, fromRemote.cachedInputTokens)
        assertEquals(500, fromRemote.cacheCreation5mTokens)
    }

    @Test
    fun `self-contradictory rows left by the old per-field max are trimmed instead of shown`() {
        val dirty = message(
            inputTokens = 1000,
            outputTokens = 120,
            cachedInputTokens = 900,
            cacheCreationInputTokens = 400,
            cacheCreation5mTokens = 400,
        )

        val merged = mergeUsage(dirty, message())

        // input/output are kept -- they're the values the actual settlement is based on, and are not contradictory.
        assertEquals(1000, merged.inputTokens)
        assertEquals(120, merged.outputTokens)
        assertNull(merged.cachedInputTokens)
        assertNull(merged.cacheCreationInputTokens)
        assertNull(merged.cacheCreation5mTokens)
    }
}
