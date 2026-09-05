package ai.oriveo.community.core.streaming

import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.streaming.StreamingTokenBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract test for uninterrupted streaming.
 *
 * Verifies that the key API surface (method names + threshold constants) needed by the
 * multi-layer resilience framework stays intact, so a later refactor doesn't accidentally
 * drop a critical entry point. These are preconditions for ChatStreamingManager to work.
 */
class StreamingResilienceContractTest {

    @Test
    fun `MessageDao exposes L5 sanitize and L4 partial flush queries`() {
        val methods = MessageDao::class.java.methods.map { it.name }.toSet()
        // Startup sanitize: stale Generating rows become Interrupted
        assertTrue("MessageDao must expose sanitizeStaleGenerating for startup sanitize", methods.contains("sanitizeStaleGenerating"))
        // Both the periodic long-stream flush and the ON_STOP flush go through this query
        assertTrue("MessageDao must expose updatePartialText for partial flush persistence", methods.contains("updatePartialText"))
    }

    @Test
    fun `ConversationRepository exposes streaming resilience helpers`() {
        val methods = ConversationRepository::class.java.methods.map { it.name }.toSet()
        assertTrue("ConversationRepository must expose sanitizeStaleGenerating (called on app startup)", methods.contains("sanitizeStaleGenerating"))
        assertTrue("ConversationRepository must expose updatePartialText (forwarded from ChatRepository)", methods.contains("updatePartialText"))
    }

    @Test
    fun `ChatRepository exposes flushPartialToMessage and removed legacy stopGeneration`() {
        val methods = ChatRepository::class.java.methods.map { it.name }.toSet()
        // Shared entry point for the ON_STOP flush and the periodic throttle flush
        assertTrue("ChatRepository must expose flushPartialToMessage", methods.contains("flushPartialToMessage"))
        // Stream job lifecycle is now owned by ChatStreamingManager, not the repository
        // -- guards against a future PR reintroducing these and re-coupling the stream
        // to the ViewModel lifecycle.
        assertTrue(
            "ChatRepository should no longer expose stopGeneration (moved to ChatStreamingManager.stopStream)",
            !methods.contains("stopGeneration"),
        )
        assertTrue(
            "ChatRepository should no longer expose setActiveSendJob (activeJob is owned by ChatStreamingManager)",
            !methods.contains("setActiveSendJob"),
        )
    }

    @Test
    fun `ChatStreamingManager exposes multi-session API surface`() {
        val klass = ChatStreamingManager::class.java
        val methods = klass.methods.toList()
        val methodNames = methods.map { it.name }.toSet()

        // Core multi-session API: start entry point, per-conversation stop, stop-all, flush-all
        assertTrue("startStream -- entry point guarded by a mutex", methodNames.contains("startStream"))
        assertTrue("stopStream -- stops the stream for a given conversationId", methodNames.contains("stopStream"))
        assertTrue("stopAllStreams -- used on sign-out / account deletion / remote kick / workspace switch", methodNames.contains("stopAllStreams"))
        assertTrue(
            "flushAllPartialsToMessage -- walks every session on ON_STOP and persists it",
            methodNames.contains("flushAllPartialsToMessage"),
        )

        // Streaming state queries keyed by conversation id (the old no-arg getters are gone)
        assertTrue("streamingText(convId) -- UI subscribes to tokens for the active conversation", methodNames.contains("streamingText"))
        assertTrue(
            "streamingMessageId(convId) -- UI subscribes to the message id for the active conversation",
            methodNames.contains("streamingMessageId"),
        )
        assertTrue("isBusyStreaming(convId) -- whether this conversation is currently streaming", methodNames.contains("isBusyStreaming"))

        // List-level subscription API (fires only on add/remove -- Compose friendly, no per-token updates)
        assertTrue(
            "getStreamingConversationIds -- list-level subscription to the current set of streaming conversations",
            methodNames.contains("getStreamingConversationIds"),
        )
        assertTrue(
            "getIsAnyStreaming -- whether any conversation is streaming (used by lifecycle / sanitize)",
            methodNames.contains("isAnyStreaming"),
        )

        // The old global single-value API has been removed (guards against regressing to a single-stream model)
        val streamingTextNoArg = methods.firstOrNull {
            it.name == "streamingText" && it.parameterCount == 0
        }
        assertTrue(
            "the no-arg streamingText API has been removed (multi-session requires querying by convID)",
            streamingTextNoArg == null,
        )
        val streamingMessageIdNoArg = methods.firstOrNull {
            it.name == "streamingMessageId" && it.parameterCount == 0
        }
        assertTrue(
            "the no-arg streamingMessageId API has been removed (multi-session requires querying by convID)",
            streamingMessageIdNoArg == null,
        )
        val stopStreamNoArg = methods.firstOrNull {
            it.name == "stopStream" && it.parameterCount == 0
        }
        assertTrue(
            "the no-arg stopStream API has been removed (stop by convID, or stopAllStreams to stop everything)",
            stopStreamNoArg == null,
        )
        // ChatStreamingManager no longer exposes flushPartialToMessage (superseded by
        // flushAllPartialsToMessage for the multi-session model); ChatRepository.flushPartialToMessage
        // is still kept around as the low-level SQL UPDATE helper shared by ChatStreamingManager
        // internals and the web-side partial flush. This assertion only covers ChatStreamingManager's
        // own surface, not the repository.
        assertTrue(
            "ChatStreamingManager should no longer expose flushPartialToMessage (superseded by flushAllPartialsToMessage)",
            !methodNames.contains("flushPartialToMessage"),
        )

        // sessionsVersion -- the UI derives streamingText / streamingMessageId with
        // combine(activeConversationId, sessionsVersion) driving flatMapLatest to resubscribe,
        // covering the case where the same convId regenerates and replaces its session while
        // activeConversationId itself doesn't change. The Kotlin val's JVM getter is getSessionsVersion.
        assertTrue(
            "getSessionsVersion -- lets the UI drive flatMapLatest to resubscribe to a new StateFlow after the same convId is replaced",
            methodNames.contains("getSessionsVersion"),
        )
    }

    @Test
    fun `the in-memory throttle and the persistence flush share one set of thresholds`() {
        // The in-memory throttle (32 chars / newline / 40ms) and persistence (4000 chars / 60s)
        // are the single source of the streaming cadence: any divergence would make the render
        // cadence and heat profile drift between code paths.
        assertEquals(32, StreamingTokenBuffer.FLUSH_CHAR_THRESHOLD)
        assertEquals(40L, StreamingTokenBuffer.FLUSH_INTERVAL_MS)
        assertEquals(4000, ChatRepository.PARTIAL_FLUSH_CHAR_THRESHOLD)
        assertEquals(60_000L, ChatRepository.PARTIAL_FLUSH_TIME_THRESHOLD_MS)
    }

    @Test
    fun `partial flush thresholds align with Web baseline`() {
        // These thresholds match the web implementation to avoid diverging designs; background
        // execution limits make Android need mid-stream persistence more than web does, but
        // keeping the thresholds aligned keeps cross-platform testing and user expectations consistent.
        assertNotNull(ChatRepository.PARTIAL_FLUSH_CHAR_THRESHOLD)
        assertNotNull(ChatRepository.PARTIAL_FLUSH_TIME_THRESHOLD_MS)
        // A 4000-char threshold: a long stream (code, a long essay) triggers one or two mid-flushes; short replies never trigger one
        assertTrue(
            "the char threshold should be >= 1000 to avoid writing to the DB on every chunk",
            ChatRepository.PARTIAL_FLUSH_CHAR_THRESHOLD >= 1000,
        )
        // A 60s threshold: avoids a 10-minute stream going without any persistence at all
        assertTrue(
            "the time threshold should be >= 30s to avoid excessive writes",
            ChatRepository.PARTIAL_FLUSH_TIME_THRESHOLD_MS >= 30_000L,
        )
    }
}
