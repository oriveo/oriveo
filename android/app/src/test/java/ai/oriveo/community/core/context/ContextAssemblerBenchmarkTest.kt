package ai.oriveo.community.core.context

import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale
import kotlin.math.ceil

/** Assembler micro benchmark (same method on every platform): deterministic 500-message history, measures p50 / p95 and asserts the gate. */
class ContextAssemblerBenchmarkTest {

    @Test
    fun `assemble_500_messages_100k_tokens_p95`() {
        val input = input(w = 200_000)
        val plan = ContextAssembler.assemble(input)
        assertNull("untrimmed case must not reject", plan.reject)
        assertTrue("untrimmed case keeps all 501 messages", plan.messages?.size == 501)
        val (p50, p95) = measure { ContextAssembler.assemble(input) }
        report("assemble_500_messages_100k_tokens_p95", p50, p95)
        assertTrue("p95=$p95 ms exceeds 8 ms", p95 <= 8.0)
    }

    @Test
    fun `assemble_trimmed_window_p95`() {
        val input = input(w = 64_000)
        val plan = ContextAssembler.assemble(input)
        assertNotNullMessages(plan)
        assertEquals("trimmed window keeps messages and requires compaction", ContextCompactionAdvice.REQUIRED, plan.compaction)
        val (p50, p95) = measure { ContextAssembler.assemble(input) }
        report("assemble_trimmed_window_p95", p50, p95)
        assertTrue("p95=$p95 ms exceeds 8 ms", p95 <= 8.0)
    }

    @Test
    fun `send_path_extra_latency_p95`() {
        val input = input(w = 200_000)
        // Android takes the refusal check from the projection actually sent, so each send assembles once (k = 1)
        val (p50, p95) = measure {
            val plan = ContextAssembler.assemble(input)
            ContextWireAdapter.project(plan, ContextWireFamily.OPENAI_CHAT)
        }
        report("send_path_extra_latency_p95", p50, p95)
        assertTrue("p95=$p95 ms exceeds 15 ms", p95 <= 15.0)
    }

    private fun assertNotNullMessages(plan: ContextPlan): List<ContextPlanMessage> {
        assertNotNull("plan must carry messages", plan.messages)
        return plan.messages!!
    }

    private fun input(w: Int) = ContextAssembleInput(
        purpose = RequestPurpose.CHAT,
        window = ContextWindowInput(
            W = w,
            windowKind = ContextWindowKind.TOTAL,
            maxOutput = ContextMaxOutput(model = 8192),
        ),
        conversation = ContextConversation(
            id = "bench",
            useMemory = false,
            instructions = List(6) { S1 }.joinToString(" "),
        ),
        history = HISTORY,
        current = CURRENT_TEXT,
        currentId = "m500",
    )

    private fun measure(block: () -> Unit): Pair<Double, Double> {
        repeat(WARMUPS) { block() }
        val samples = (1..RUNS).map {
            val start = System.nanoTime()
            block()
            (System.nanoTime() - start) / 1_000_000.0
        }.sorted()
        val p50 = samples[ceil(0.5 * samples.size).toInt() - 1]
        val p95 = samples[ceil(0.95 * samples.size).toInt() - 1]
        return p50 to p95
    }

    private fun report(name: String, p50: Double, p95: Double) {
        println("ContextAssemblerBenchmark $name p50=${"%.2f".format(Locale.ROOT, p50)} p95=${"%.2f".format(Locale.ROOT, p95)} n=$RUNS")
    }

    private companion object {
        const val WARMUPS = 30
        const val RUNS = 200
        const val CURRENT_TEXT = "Summarize the discussion above."
        const val S0 = "\u4e0a\u4e0b\u6587\u7ba1\u7ebf\u5728\u53d1\u9001\u524d\u7ec4\u88c5\u5386\u53f2\u6d88\u606f，\u5e76\u6309\u9884\u7b97\u88c1\u526a\u6700\u65e9\u7684\u8f6e\u6b21。"
        const val S1 = "The assembler trims the oldest turns first and keeps the current user message intact."
        const val S2 = "يقوم المجمّع بقص أقدم الأدوار أولاً ويحافظ على رسالة المستخدم الحالية."
        const val S3 = "```swift\nfunc add(_ a: Int, _ b: Int) -> Int { a + b }\n```"
        val SEGMENTS = listOf(S0, S1, S2, S3)

        val HISTORY: List<ContextMessage> = (0 until 500).map { i ->
            val segment = SEGMENTS[i % 4]
            var text = segment
            while (ContextBudget.estimateMessage(text, ContextBudget.RHO0) < 200) text += "\n" + segment
            ContextMessage(
                id = "m%03d".format(i),
                role = if (i % 2 == 0) ChatRole.User else ChatRole.Assistant,
                text = text,
                state = ChatMessageState.Delivered,
            )
        }.also { history ->
            val total = history.sumOf { ContextBudget.estimateMessage(it.text, ContextBudget.RHO0) }
            check(total in 100_000..120_000) { "dataset estimate $total outside [100000, 120000]" }
        }
    }
}
