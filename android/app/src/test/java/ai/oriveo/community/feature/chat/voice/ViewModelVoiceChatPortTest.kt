package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/** The chat page bridge of the voice conversation, on fake view-model flows. */
@OptIn(ExperimentalCoroutinesApi::class)
class ViewModelVoiceChatPortTest {

    private class FakePage {
        val text = MutableStateFlow("")
        val streamingId = MutableStateFlow<String?>(null)
        val approvals = MutableStateFlow(false)
        val messages = MutableStateFlow<List<ChatMessage>>(emptyList())
        val sent = mutableListOf<String>()
        var accept = true
        var stops = 0

        val port = ViewModelVoiceChatPort(
            sendText = { sent += it; accept },
            streamingText = text,
            streamingMessageId = streamingId,
            approvalPending = approvals,
            replyMessage = { id -> messages.map { list -> list.firstOrNull { it.id == id } } },
            stop = { stops++ },
        )

        /** Starts streaming [id]; each chunk is delivered on its own scheduler turn (StateFlows conflate). */
        fun stream(scope: TestScope, id: String, vararg chunks: String) {
            streamingId.value = id
            scope.runCurrent()
            for (c in chunks) {
                text.value = c
                scope.runCurrent()
            }
        }

        fun finish(id: String, state: ChatMessageState, final: String, errorTitle: String? = null) {
            messages.value = messages.value + assistant(id, state, final, errorTitle)
            streamingId.value = null
            text.value = ""
        }
    }

    private fun TestScope.collect(page: FakePage): MutableList<VoiceReplyEvent> {
        val events = mutableListOf<VoiceReplyEvent>()
        backgroundScope.launch { page.port.replies.collect { events += it } }
        runCurrent()
        return events
    }

    @Test
    fun `send goes through the page and a streamed reply ends completed with the final text`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.send("\u4f60\u597d"))
        assertEquals(listOf("\u4f60\u597d"), page.sent)
        page.stream(this, "a1", "\u4eca\u5929", "\u4eca\u5929\u5929\u6c14")
        runCurrent()
        page.finish("a1", ChatMessageState.Delivered, "\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002")
        runCurrent()
        assertEquals(
            listOf(
                VoiceReplyEvent.Text("\u4eca\u5929"),
                VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14"),
                VoiceReplyEvent.Text("\u4eca\u5929\u5929\u6c14\u5f88\u597d\u3002"),
                VoiceReplyEvent.Completed(),
            ),
            events,
        )
    }

    @Test
    fun `an interrupted reply message completes undelivered`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.send("\u4f60\u597d"))
        page.stream(this, "a1", "\u4eca\u5929")
        runCurrent()
        page.finish("a1", ChatMessageState.Interrupted, "\u4eca\u5929")
        runCurrent()
        assertEquals(listOf(VoiceReplyEvent.Text("\u4eca\u5929"), VoiceReplyEvent.Completed(delivered = false)), events)
    }

    @Test
    fun `a failed reply message ends failed`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.port.send("hi")
        page.stream(this, "a1", "partial")
        runCurrent()
        page.finish("a1", ChatMessageState.Failed, "partial", errorTitle = "429")
        runCurrent()
        assertEquals(VoiceReplyEvent.Failed(ViewModelVoiceChatPort.REPLY_FAILED), events.last())
    }

    @Test
    fun `an error title alone also ends failed`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.port.send("hi")
        page.stream(this, "a1", "x")
        runCurrent()
        page.finish("a1", ChatMessageState.Delivered, "x", errorTitle = "Quota used up")
        runCurrent()
        assertEquals(VoiceReplyEvent.Failed(ViewModelVoiceChatPort.REPLY_FAILED), events.last())
    }

    @Test
    fun `after cancel nothing of the cancelled reply is emitted, the next reply flows normally`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.port.send("first")
        page.stream(this, "a1", "old reply")
        runCurrent()
        val before = events.toList()
        page.port.cancel()
        assertEquals(1, page.stops)
        // Late chunks and the end of the cancelled reply.
        page.text.value = "old reply continues"
        runCurrent()
        page.approvals.value = true
        runCurrent()
        page.finish("a1", ChatMessageState.Interrupted, "old reply continues")
        runCurrent()
        // Approval changes are not tied to a reply: they still flow after the cancel.
        val approvals = listOf(VoiceReplyEvent.ApprovalPending(true), VoiceReplyEvent.ApprovalPending(false))
        assertEquals(before + approvals.first(), events)
        page.approvals.value = false
        runCurrent()

        page.port.send("second")
        page.stream(this, "a2", "new")
        runCurrent()
        page.finish("a2", ChatMessageState.Delivered, "new")
        runCurrent()
        assertEquals(before + approvals + listOf(VoiceReplyEvent.Text("new"), VoiceReplyEvent.Completed()), events)
    }

    @Test
    fun `a send right after a barge-in cancel waits for the cancelled stream to end`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.port.send("first")
        page.stream(this, "a1", "old")
        runCurrent()
        page.port.cancel()
        val next = backgroundScope.launch { page.port.send("second") }
        runCurrent()
        assertEquals(listOf("first"), page.sent)
        page.finish("a1", ChatMessageState.Interrupted, "old")
        runCurrent()
        assertTrue(next.isCompleted)
        assertEquals(listOf("first", "second"), page.sent)
        assertEquals(listOf(VoiceReplyEvent.Text("old")), events)
    }

    @Test
    fun `tool approvals surface as approval pending whether or not a reply is armed`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.approvals.value = true
        runCurrent()
        page.approvals.value = false
        runCurrent()
        page.port.send("search")
        page.stream(this, "a1")
        runCurrent()
        page.approvals.value = true
        runCurrent()
        page.approvals.value = false
        runCurrent()
        assertEquals(
            listOf(
                VoiceReplyEvent.ApprovalPending(true),
                VoiceReplyEvent.ApprovalPending(false),
                VoiceReplyEvent.ApprovalPending(true),
                VoiceReplyEvent.ApprovalPending(false),
            ),
            events,
        )
    }

    @Test
    fun `approval resolved after barge in still reaches reducer`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.port.send("delete it")
        page.stream(this, "a1")
        runCurrent()
        page.approvals.value = true
        runCurrent()
        // Barge-in disarms the port; the approval card is still resolved afterwards.
        page.port.cancel()
        page.approvals.value = false
        runCurrent()
        assertEquals(listOf(VoiceReplyEvent.ApprovalPending(true), VoiceReplyEvent.ApprovalPending(false)), events)
    }

    @Test
    fun `a rejected send stays disarmed`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.accept = false
        assertEquals(false, page.port.send("x"))
        page.stream(this, "other", "someone else's stream")
        runCurrent()
        page.finish("other", ChatMessageState.Delivered, "done")
        advanceTimeBy(ViewModelVoiceChatPort.SETTLE_TIMEOUT_MS + 1)
        runCurrent()
        assertTrue(events.isEmpty())
    }

    private companion object {
        fun assistant(id: String, state: ChatMessageState, text: String, errorTitle: String?) = ChatMessage(
            id = id,
            role = ChatRole.Assistant,
            text = text,
            providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI",
            modelName = "GPT",
            state = state,
            errorTitle = errorTitle,
        )
    }
}
