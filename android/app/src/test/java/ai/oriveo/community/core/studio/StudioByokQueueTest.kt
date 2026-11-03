package ai.oriveo.community.core.studio

import ai.oriveo.community.core.studio.StudioByokQueue.Event
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Round queue driver over StudioByokTasks.reduce, with a controllable fake run and fake foreground. */
@OptIn(ExperimentalCoroutinesApi::class)
class StudioByokQueueTest {
    private class FakeForeground(private val startResult: Boolean) : StudioByokQueue.Foreground {
        val calls = mutableListOf<String>()

        override fun start(count: Int): Boolean {
            calls += "start:$count"
            return startResult
        }

        override fun update(count: Int) {
            calls += "update:$count"
        }

        override fun stop() {
            calls += "stop"
        }
    }

    private class Harness(scope: CoroutineScope, startResult: Boolean = true) {
        val gates = HashMap<String, CompletableDeferred<String>>()
        val cancels = HashMap<String, CompletableDeferred<Unit>>()
        val invoked = mutableListOf<String>()
        val events = mutableListOf<Pair<String, Event<String>>>()
        val foreground = FakeForeground(startResult)
        val queue = StudioByokQueue<String>(
            scope = scope,
            run = { id, cancel ->
                invoked += id
                cancels[id] = cancel
                gate(id).await()
            },
            onUpdate = { id, event -> events += id to event },
            foreground = foreground,
        )

        fun gate(id: String): CompletableDeferred<String> = gates.getOrPut(id) { CompletableDeferred() }

        fun eventsOf(id: String): List<Event<String>> = events.filter { it.first == id }.map { it.second }
    }

    private fun TestScope.harness(startResult: Boolean = true) = Harness(backgroundScope, startResult)

    private val ids = listOf("r1", "r2", "r3", "r4", "r5")

    @Test
    fun fifthRoundQueues() = runTest {
        val h = harness()
        ids.forEach { h.queue.submit(it, 1) }
        runCurrent()

        assertEquals(StudioByokTasks.QueueState(running = ids.take(4), queued = listOf("r5")), h.queue.snapshot())
        assertEquals(ids.take(4), h.invoked)
        assertEquals(listOf<Event<String>>(Event.Queued), h.eventsOf("r5"))
        assertEquals(listOf<Event<String>>(Event.Started), h.eventsOf("r1"))

        h.gate("r2").complete("ok")
        runCurrent()

        assertEquals(listOf(Event.Started, Event.Result("ok")), h.eventsOf("r2"))
        assertEquals(StudioByokTasks.QueueState(running = listOf("r1", "r3", "r4", "r5")), h.queue.snapshot())
        assertEquals(listOf(Event.Queued, Event.Started), h.eventsOf("r5"))
        assertEquals(ids, h.invoked)
    }

    @Test
    fun cancelQueuedNotBilled() = runTest {
        val h = harness()
        ids.forEach { h.queue.submit(it, 1) }
        runCurrent()

        h.queue.cancel("r5")
        assertEquals(listOf(Event.Queued, Event.Cancelled(mayBeBilled = false)), h.eventsOf("r5"))
        assertEquals(StudioByokTasks.QueueState(running = ids.take(4)), h.queue.snapshot())

        h.gate("r1").complete("ok")
        runCurrent()

        assertFalse("a cancelled queued round must never run", "r5" in h.invoked)
        assertEquals(StudioByokTasks.QueueState(running = listOf("r2", "r3", "r4")), h.queue.snapshot())
    }

    @Test
    fun cancelRunningBilledAndFreesSlot() = runTest {
        val h = harness()
        ids.forEach { h.queue.submit(it, 1) }
        runCurrent()

        h.queue.cancel("r1")

        assertEquals(listOf(Event.Started, Event.Cancelled(mayBeBilled = true)), h.eventsOf("r1"))
        assertTrue("the running round's cancel signal must be completed", h.cancels.getValue("r1").isCompleted)
        assertEquals(StudioByokTasks.QueueState(running = listOf("r2", "r3", "r4", "r5")), h.queue.snapshot())
        assertEquals(listOf(Event.Queued, Event.Started), h.eventsOf("r5"))

        runCurrent()
        assertEquals(ids, h.invoked)
    }

    @Test
    fun lateResultDropped() = runTest {
        val h = harness()
        h.queue.submit("r1", 2)
        runCurrent()
        h.queue.cancel("r1")

        h.gate("r1").complete("late")
        runCurrent()

        assertEquals(listOf(Event.Started, Event.Cancelled(mayBeBilled = true)), h.eventsOf("r1"))
        assertEquals(StudioByokTasks.QueueState(), h.queue.snapshot())
        assertEquals(listOf("start:2", "stop"), h.foreground.calls)
    }

    @Test
    fun serviceCountFollowsRunning() = runTest {
        // start() refusing the foreground must not block execution.
        val h = harness(startResult = false)
        h.queue.submit("r1", 2)
        h.queue.submit("r2", 3)
        h.queue.submit("r3", 1)
        h.queue.submit("r4", 1)
        h.queue.submit("r5", 4)
        runCurrent()
        assertEquals(listOf("start:2", "update:5", "update:6", "update:7"), h.foreground.calls)
        assertEquals(ids.take(4), h.invoked)

        h.gate("r1").complete("ok")
        runCurrent()
        assertEquals("update:9", h.foreground.calls.last())

        h.queue.cancel("r2")
        assertEquals("update:6", h.foreground.calls.last())

        h.gate("r3").complete("ok")
        h.gate("r4").complete("ok")
        runCurrent()
        h.queue.cancel("r5")

        assertEquals(
            listOf("start:2", "update:5", "update:6", "update:7", "update:9", "update:6", "update:5", "update:4", "stop"),
            h.foreground.calls,
        )
        assertEquals(StudioByokTasks.QueueState(), h.queue.snapshot())
    }

    @Test
    fun duplicateSubmitEmitsNothing() = runTest {
        val h = harness()
        ids.forEach { h.queue.submit(it, 1) }
        h.queue.submit("r1", 1)
        h.queue.submit("r5", 1)
        runCurrent()

        assertEquals(listOf<Event<String>>(Event.Started), h.eventsOf("r1"))
        assertEquals(listOf<Event<String>>(Event.Queued), h.eventsOf("r5"))
    }

    @Test
    fun runThrowsEmitsFailedAndFreesSlot() = runTest {
        // backgroundScope fails the test on an uncaught exception, so this also proves the error is not rethrown.
        val h = harness()
        ids.forEach { h.queue.submit(it, 1) }
        runCurrent()

        h.gate("r1").completeExceptionally(IllegalStateException("boom"))
        runCurrent()

        // Coroutine stack-trace recovery may hand run a copy of the exception, so compare type and message.
        val r1 = h.eventsOf("r1")
        assertEquals(2, r1.size)
        assertEquals(Event.Started, r1[0])
        val failed = r1[1] as Event.Failed
        assertTrue("run's error must be reported", failed.error is IllegalStateException)
        assertEquals("boom", failed.error.message)
        assertEquals(StudioByokTasks.QueueState(running = listOf("r2", "r3", "r4", "r5")), h.queue.snapshot())
        assertEquals(listOf(Event.Queued, Event.Started), h.eventsOf("r5"))
        assertEquals(ids, h.invoked)
        assertEquals(listOf("start:1", "update:2", "update:3", "update:4"), h.foreground.calls)
    }
}
