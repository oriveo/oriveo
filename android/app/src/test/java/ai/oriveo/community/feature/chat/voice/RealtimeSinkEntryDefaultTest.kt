package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.model.ProviderKind
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

// A create-conversation callback without a home / draft marker is treated as a chat page entry: when the entry can't be told, prefer not deleting.
@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeSinkEntryDefaultTest {
    @Test
    fun bare_creator_is_chat_entry_never_creates_early_or_deletes() = runTest {
        val sinkScope = TestScope(StandardTestDispatcher(testScheduler))
        var creates = 0
        var deleted = false
        val sink = RepositoryRealtimeTranscriptSink(
            conversationId = null,
            attribution = RealtimeMessageAttribution("p", ProviderKind.OpenAI, "OpenAI", "gpt-realtime"),
            add = { _, _ -> },
            update = { _, _ -> },
            scope = sinkScope,
            createConversation = { creates++; "c1" },
            delete = { deleted = true; true },
        )
        sink.ensureConversation()
        sink.close()
        testScheduler.advanceUntilIdle()
        sink.drain()
        assertEquals(0, creates)
        assertFalse(deleted)
        sinkScope.cancel()
    }
}
