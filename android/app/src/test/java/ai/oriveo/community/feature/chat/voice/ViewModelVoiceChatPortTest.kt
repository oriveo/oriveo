package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        val amended = mutableListOf<String>()
        val amendTargets = mutableListOf<String?>()

        /** The page rolled the latest turn's user message back at the pre-send confirmation (cancel / stop). */
        val rolledBack = kotlinx.coroutines.flow.MutableSharedFlow<Unit>(extraBufferCapacity = 1)

        /** The blocked exits the port handed to each send, in order. */
        val sendBlocks = mutableListOf<() -> Unit>()

        /** The failure exits the port handed to each amend, in order. */
        val amendFailures = mutableListOf<() -> Unit>()

        /** The user message of the latest turn as the page has it; null = the latest send has not landed yet. */
        val turnUserMessageId = MutableStateFlow<String?>("u0")
        var accept = true
        var stops = 0

        val port = ViewModelVoiceChatPort(
            sendText = { text, onBlocked -> sent += text; sendBlocks += onBlocked; accept },
            streamingText = text,
            streamingMessageId = streamingId,
            approvalPending = approvals,
            replyMessage = { id -> messages.map { list -> list.firstOrNull { it.id == id } } },
            stop = { stops++ },
            amendText = { text, target, onFailed -> amended += text; amendTargets += target; amendFailures += onFailed; accept },
            turnUserMessageId = turnUserMessageId,
            turnRolledBack = rolledBack,
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
    fun `a send or amend still waiting when the port is cancelled is not sent and the next epoch flows`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.port.send("first")
        page.stream(this, "a1", "old")
        runCurrent()
        page.port.cancel()
        val send = async { page.port.send("second") }
        val amend = async { page.port.amend("more") }
        runCurrent()
        // Ended / barged in again while both wait for the cancelled stream.
        page.port.cancel()
        runCurrent()
        assertTrue(send.isCompleted)
        assertTrue(amend.isCompleted)
        assertFalse(send.await())
        assertFalse(amend.await())
        page.finish("a1", ChatMessageState.Interrupted, "old")
        runCurrent()
        assertEquals(listOf("first"), page.sent)
        assertEquals(emptyList<String>(), page.amended)

        // A new turn after that is a normal epoch.
        assertTrue(page.port.send("third"))
        page.stream(this, "a2", "\u65B0\u7684")
        runCurrent()
        page.finish("a2", ChatMessageState.Delivered, "\u65B0\u7684\u56DE\u7B54")
        runCurrent()
        assertEquals(listOf("first", "third"), page.sent)
        assertEquals(
            listOf(
                VoiceReplyEvent.Text("old"),
                VoiceReplyEvent.Text("\u65B0\u7684"),
                VoiceReplyEvent.Text("\u65B0\u7684\u56DE\u7B54"),
                VoiceReplyEvent.Completed(),
            ),
            events,
        )
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
    fun `amend goes to the page and the regenerated reply flows like a send`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.port.send("\u7B2C\u4E8C\u5929\u53BB\u4EAC\u90FD")
        page.stream(this, "a1", "\u597D\u7684")
        runCurrent()
        // Barge-in while thinking: the reducer cancels, then amends; the cancelled reply's end is not this one.
        page.port.cancel()
        val amend = backgroundScope.launch { assertTrue(page.port.amend("\u6362\u6210\u5948\u826F")) }
        runCurrent()
        assertEquals(emptyList<String>(), page.amended)
        page.finish("a1", ChatMessageState.Interrupted, "\u597D\u7684")
        runCurrent()
        assertTrue(amend.isCompleted)
        assertEquals(listOf("\u6362\u6210\u5948\u826F"), page.amended)
        assertEquals(listOf("\u7B2C\u4E8C\u5929\u53BB\u4EAC\u90FD"), page.sent)

        page.stream(this, "a2", "\u5948\u826F")
        runCurrent()
        page.finish("a2", ChatMessageState.Delivered, "\u5948\u826F\u5F88\u8FD1\u3002")
        runCurrent()
        assertEquals(
            listOf(
                VoiceReplyEvent.Text("\u597D\u7684"),
                VoiceReplyEvent.Text("\u5948\u826F"),
                VoiceReplyEvent.Text("\u5948\u826F\u5F88\u8FD1\u3002"),
                VoiceReplyEvent.Completed(),
            ),
            events,
        )
    }

    @Test
    fun `an amend while the send is in flight waits for its user message and rewrites that id`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        collect(page)
        page.turnUserMessageId.value = "u1"
        // The send returned but its user message has not landed: the page still shows u1 (the previous turn) last.
        assertTrue(page.port.send("\u7B2C\u4E8C\u5929\u53BB\u4EAC\u90FD"))
        page.turnUserMessageId.value = null
        val amend = async { page.port.amend("\u6362\u6210\u5948\u826F") }
        runCurrent()
        assertFalse(amend.isCompleted)
        assertEquals(emptyList<String>(), page.amended)

        page.turnUserMessageId.value = "u2"
        runCurrent()
        assertTrue(amend.await())
        assertEquals(listOf("\u6362\u6210\u5948\u826F"), page.amended)
        // The previous turn's u1 is left alone.
        assertEquals(listOf<String?>("u2"), page.amendTargets)
    }

    @Test
    fun `delivery is reported before the page gets the text and never for a turn dropped on cancel`() =
        runTest(timeout = 10.seconds) {
            val page = FakePage()
            collect(page)
            val order = mutableListOf<String>()
            assertTrue(page.port.send("\u7B2C\u4E8C\u5929\u53BB\u4EAC\u90FD") { order += "delivered:${page.sent.size}" })
            assertEquals(listOf("delivered:0"), order)
            assertTrue(page.port.amend("\u6362\u6210\u5948\u826F") { order += "delivered:${page.amended.size}" })
            // Set before the page replaces the user message, synchronously within the call.
            assertEquals(listOf("delivered:0", "delivered:0"), order)
            assertEquals(listOf("\u6362\u6210\u5948\u826F"), page.amended)

            // An amend still waiting for its user message when the port is cancelled is never handed over.
            page.turnUserMessageId.value = null
            val held = async { page.port.amend("\u518D\u52A0\u4E00\u5929") { order += "late" } }
            runCurrent()
            page.port.cancel()
            assertFalse(held.await())
            assertEquals(listOf("delivered:0", "delivered:0"), order)
        }

    @Test
    fun `an amend whose user message never lands goes out untargeted after the settle timeout`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        collect(page)
        assertTrue(page.port.send("first"))
        page.turnUserMessageId.value = null
        val amend = async { page.port.amend("more") }
        advanceTimeBy(ViewModelVoiceChatPort.SETTLE_TIMEOUT_MS - 1)
        runCurrent()
        assertFalse(amend.isCompleted)
        advanceTimeBy(2)
        runCurrent()
        assertTrue(amend.await())
        assertEquals(listOf<String?>(null), page.amendTargets)
    }

    @Test
    fun `an amend waiting for its user message is dropped on cancel`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        collect(page)
        assertTrue(page.port.send("first"))
        page.turnUserMessageId.value = null
        val amend = async { page.port.amend("more") }
        runCurrent()
        page.port.cancel()
        runCurrent()
        assertTrue(amend.isCompleted)
        assertFalse(amend.await())
        page.turnUserMessageId.value = "u1"
        runCurrent()
        assertEquals(emptyList<String>(), page.amended)
    }

    @Test
    fun `an amend that fails after it went out ends Failed and disarms the port`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.amend("more"))
        // The page found nothing to send after the stop: the port must not stay armed in "thinking".
        page.amendFailures.single().invoke()
        runCurrent()
        assertEquals(listOf<VoiceReplyEvent>(VoiceReplyEvent.Failed(ViewModelVoiceChatPort.REPLY_FAILED)), events)

        // Disarmed: someone else's stream ending is not this turn, and a second failure call is a no-op.
        page.amendFailures.single().invoke()
        page.stream(this, "other", "someone else's stream")
        page.finish("other", ChatMessageState.Delivered, "done")
        advanceTimeBy(ViewModelVoiceChatPort.SETTLE_TIMEOUT_MS + 1)
        runCurrent()
        assertEquals(listOf<VoiceReplyEvent>(VoiceReplyEvent.Failed(ViewModelVoiceChatPort.REPLY_FAILED)), events)
    }

    @Test
    fun `a late failure of a replaced amend does not touch the next turn`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.amend("more"))
        page.port.cancel()
        assertTrue(page.port.send("next"))
        page.amendFailures.single().invoke()
        runCurrent()
        assertTrue(events.isEmpty())

        page.stream(this, "a2", "ok")
        page.finish("a2", ChatMessageState.Delivered, "ok")
        runCurrent()
        assertEquals(listOf(VoiceReplyEvent.Text("ok"), VoiceReplyEvent.Completed()), events)
    }

    @Test
    fun `a send blocked after it went out ends Failed and disarms the port`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.send("hi"))
        // The page refused the send on its async path: the turn must end, not stay in "thinking".
        page.sendBlocks.single().invoke()
        runCurrent()
        assertEquals(listOf<VoiceReplyEvent>(VoiceReplyEvent.Failed(ViewModelVoiceChatPort.REPLY_FAILED)), events)

        page.sendBlocks.single().invoke()
        page.stream(this, "other", "someone else's stream")
        page.finish("other", ChatMessageState.Delivered, "done")
        advanceTimeBy(ViewModelVoiceChatPort.SETTLE_TIMEOUT_MS + 1)
        runCurrent()
        assertEquals(listOf<VoiceReplyEvent>(VoiceReplyEvent.Failed(ViewModelVoiceChatPort.REPLY_FAILED)), events)
    }

    @Test
    fun `a send held at the pre-send confirmation waits for the user and a rollback ends Failed once`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.send("hi"))
        // Handed to the send path, then held at the confirmation dialog before any stream starts.
        page.approvals.value = true
        runCurrent()
        page.approvals.value = false
        page.rolledBack.tryEmit(Unit)
        runCurrent()
        val expected = listOf(
            VoiceReplyEvent.ApprovalPending(true),
            VoiceReplyEvent.ApprovalPending(false),
            VoiceReplyEvent.Failed(ViewModelVoiceChatPort.REPLY_FAILED),
        )
        assertEquals(expected, events)

        // Disarmed: a second rollback and someone else's stream add nothing.
        page.rolledBack.tryEmit(Unit)
        page.stream(this, "other", "someone else's stream")
        page.finish("other", ChatMessageState.Delivered, "done")
        advanceTimeBy(ViewModelVoiceChatPort.SETTLE_TIMEOUT_MS + 1)
        runCurrent()
        assertEquals(expected, events)
    }

    @Test
    fun `a rollback reported before the confirmation closes still sends approval resolved before Failed`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.send("hi"))
        page.approvals.value = true
        runCurrent()
        // The page reports the rollback first and clears the pending confirmation after it.
        page.rolledBack.tryEmit(Unit)
        runCurrent()
        page.approvals.value = false
        runCurrent()
        val expected = listOf(
            VoiceReplyEvent.ApprovalPending(true),
            VoiceReplyEvent.ApprovalPending(false),
            VoiceReplyEvent.Failed(ViewModelVoiceChatPort.REPLY_FAILED),
        )
        assertEquals(expected, events)
    }

    @Test
    fun `a rollback after the turn was cancelled does not fail the next turn`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.send("hi"))
        page.port.cancel()
        page.rolledBack.tryEmit(Unit)
        runCurrent()
        assertTrue(events.isEmpty())
    }

    @Test
    fun `a rejection after the turn's stream started is left to the stream's end`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        assertTrue(page.port.send("hi"))
        page.stream(this, "a1", "partial")
        // A late context rejection (re-projection mid-stream) does not end the turn; the stream's own end does.
        page.rolledBack.tryEmit(Unit)
        runCurrent()
        assertTrue(events.none { it is VoiceReplyEvent.Failed })
        page.finish("a1", ChatMessageState.Failed, "partial", errorTitle = "error")
        advanceTimeBy(ViewModelVoiceChatPort.SETTLE_TIMEOUT_MS + 1)
        runCurrent()
        assertEquals(1, events.count { it is VoiceReplyEvent.Failed })
    }

    @Test
    fun `a rejected amend stays disarmed`() = runTest(timeout = 10.seconds) {
        val page = FakePage()
        val events = collect(page)
        page.accept = false
        assertEquals(false, page.port.amend(""))
        assertEquals(listOf(""), page.amended)
        page.stream(this, "other", "someone else's stream")
        runCurrent()
        page.finish("other", ChatMessageState.Delivered, "done")
        advanceTimeBy(ViewModelVoiceChatPort.SETTLE_TIMEOUT_MS + 1)
        runCurrent()
        assertTrue(events.isEmpty())
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
