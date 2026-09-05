package ai.oriveo.community.core.provider.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Observation-flag contract for the four relay usage breakdown builders.
 *
 * What decides the flag is whether the raw field was present at all, not how large its
 * value is. Without a dedicated flag, an upstream that explicitly reports
 * `cached_tokens: 0` gets collapsed into "missing" by the `it > 0` check behind
 * `UsageBreakdown.reportedCachedInputTokens`, and the whole cache row silently disappears
 * from the cost display. The dedicated provider paths (OpenAIService and friends) do set
 * the flag, so relay has to set it as well, otherwise the same upstream response is
 * reported differently depending on which path it came through.
 */
class RelayUsageBreakdownObservationTest {

    @Test
    fun `openAI chat keeps an explicitly reported zero and hides an absent field`() {
        val observed = openAIChatUsageBreakdown(
            promptTokens = 1000,
            completionTokens = 120,
            cachedInputTokens = 0,
            reasoningTokens = null,
        )
        assertTrue(observed.cacheReadObserved)
        assertEquals(0, observed.reportedCachedInputTokens)

        val absent = openAIChatUsageBreakdown(
            promptTokens = 1000,
            completionTokens = 120,
            cachedInputTokens = null,
            reasoningTokens = null,
        )
        assertFalse(absent.cacheReadObserved)
        assertNull(absent.reportedCachedInputTokens)
    }

    @Test
    fun `openAI responses reads input_tokens_details and keeps an explicitly reported zero`() {
        val observed = openAIResponsesUsageBreakdown(
            inputTokens = 1000,
            outputTokens = 120,
            cachedInputTokens = 0,
            reasoningTokens = 64,
        )
        assertTrue(observed.cacheReadObserved)
        assertEquals(0, observed.reportedCachedInputTokens)
        assertEquals(64, observed.reasoningTokens)

        val hit = openAIResponsesUsageBreakdown(
            inputTokens = 1000,
            outputTokens = 120,
            cachedInputTokens = 900,
            reasoningTokens = null,
        )
        // The responses API counts cache reads inside input_tokens, so promptTokens has to
        // subtract them back out.
        assertEquals(100, hit.promptTokens)
        assertEquals(900, hit.cachedInputTokens)
        assertEquals(1000, hit.totalInputTokens)

        assertFalse(
            openAIResponsesUsageBreakdown(
                inputTokens = 1000,
                outputTokens = 120,
                cachedInputTokens = null,
                reasoningTokens = null,
            ).cacheReadObserved,
        )
    }

    @Test
    fun `anthropic marks read and write observability independently`() {
        val readOnly = anthropicUsageBreakdown(
            inputTokens = 100,
            outputTokens = 120,
            cacheReadInputTokens = 0,
            cacheCreation5mInputTokens = null,
            cacheCreation1hInputTokens = null,
        )
        assertTrue(readOnly.cacheReadObserved)
        assertFalse(readOnly.cacheWriteObserved)
        assertEquals(0, readOnly.reportedCachedInputTokens)
        assertNull(readOnly.reportedCacheCreation5mTokens)

        // An older response shape only returns the outer cache_creation_input_tokens, which
        // callers fold into the 5m bucket. That still counts as an observed cache write.
        val legacyWrite = anthropicUsageBreakdown(
            inputTokens = 100,
            outputTokens = 120,
            cacheReadInputTokens = null,
            cacheCreation5mInputTokens = 0,
            cacheCreation1hInputTokens = null,
        )
        assertFalse(legacyWrite.cacheReadObserved)
        assertTrue(legacyWrite.cacheWriteObserved)
        assertEquals(0, legacyWrite.reportedCacheCreation5mTokens)

        // Anthropic's input_tokens already excludes cached tokens, so the total input has to
        // add all three buckets back.
        val full = anthropicUsageBreakdown(
            inputTokens = 100,
            outputTokens = 120,
            cacheReadInputTokens = 900,
            cacheCreation5mInputTokens = 30,
            cacheCreation1hInputTokens = 20,
        )
        assertEquals(100, full.promptTokens)
        assertEquals(1050, full.totalInputTokens)
    }

    @Test
    fun `gemini keeps an explicitly reported zero cached content`() {
        val observed = geminiUsageBreakdown(
            promptTokenCount = 1000,
            candidatesTokenCount = 100,
            thoughtsTokenCount = 20,
            cachedContentTokenCount = 0,
        )
        assertTrue(observed.cacheReadObserved)
        assertEquals(0, observed.reportedCachedInputTokens)
        // completionTokens = candidates + thoughts, confirmed against real responses.
        assertEquals(120, observed.completionTokens)
        assertEquals(20, observed.reasoningTokens)

        assertFalse(
            geminiUsageBreakdown(
                promptTokenCount = 1000,
                candidatesTokenCount = 100,
                thoughtsTokenCount = 20,
                cachedContentTokenCount = null,
            ).cacheReadObserved,
        )
    }
}
