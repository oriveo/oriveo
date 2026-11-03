package ai.oriveo.community.core.streaming

import ai.oriveo.community.core.performance.ChatPerformanceMonitor.SendOutcome
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Test

/** Outcome of chat.send when the assistant leaves generating (fixture chat.send report_on / discard_on). */
class ChatSendOutcomeTest {

    private fun outputs(started: Boolean = true, failure: String? = null, finalLength: Int = 0, systemInterrupted: Boolean = false) =
        ConversationStreamingOutputs(
            streamingText = MutableStateFlow(""),
            streamingMessageId = MutableStateFlow(null),
        ).apply {
            generationStarted.value = started
            failureCode.set(failure)
            finalVisibleTextLength.set(finalLength)
            this.systemInterrupted.set(systemInterrupted)
        }

    @Test
    fun `completed counts only the new visible text beyond the continue seed`() {
        assertEquals(SendOutcome.Completed(30), sendOutcome(outputs(finalLength = 130), null, cancelled = false, seedTextLength = 100))
        assertEquals(SendOutcome.Completed(0), sendOutcome(outputs(finalLength = 10), null, cancelled = false, seedTextLength = 100))
    }

    @Test
    fun `repository failure code reports a failed send`() {
        assertEquals(SendOutcome.Failed("rate_limited"), sendOutcome(outputs(failure = "rate_limited"), null, cancelled = false, seedTextLength = 0))
    }

    @Test
    fun `exception escaping before the stream also fails the send`() {
        assertEquals(SendOutcome.Failed("network_error"), sendOutcome(outputs(started = false), "network_error", cancelled = false, seedTextLength = 0))
    }

    @Test
    fun `cancellation and system interrupts are discarded`() {
        assertEquals(SendOutcome.Discarded, sendOutcome(outputs(failure = "unknown"), null, cancelled = true, seedTextLength = 0))
        assertEquals(SendOutcome.Discarded, sendOutcome(outputs(systemInterrupted = true), null, cancelled = false, seedTextLength = 0))
    }

    @Test
    fun `context refusal before generation fails the send as refused`() {
        assertEquals(SendOutcome.Failed("refused"), sendOutcome(outputs(started = false, failure = "refused"), null, cancelled = false, seedTextLength = 0))
    }

    /** Only the user cancelling in the budget confirmation: the user chose not to send, which is not a failure. */
    @Test
    fun `ending without entering generation is discarded`() {
        assertEquals(SendOutcome.Discarded, sendOutcome(outputs(started = false), null, cancelled = false, seedTextLength = 0))
    }
}
