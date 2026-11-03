package ai.oriveo.community.core.performance

import ai.oriveo.community.core.observability.RecordingObservabilitySink
import ai.oriveo.community.core.performance.SyncCycleMonitor.Trigger
import org.junit.Assert.assertEquals
import org.junit.Test

class SyncCycleMonitorTest {

    private class ManualScheduler : ChatPerformanceMonitor.DeadlineScheduler {
        val pending = mutableListOf<Pair<() -> Unit, BooleanArray>>()
        override fun schedule(delayMs: Long, action: () -> Unit): () -> Unit {
            val cancelled = booleanArrayOf(false)
            pending += action to cancelled
            return { cancelled[0] = true }
        }
        fun fireAll() = pending.filter { !it.second[0] }.forEach { it.second[0] = true; it.first() }
    }

    private val sink = RecordingObservabilitySink()
    private val scheduler = ManualScheduler()
    private val monitor = SyncCycleMonitor(sink = { sink }, scheduler = scheduler)

    @Test
    fun `finished cycle reports ok with trigger and document counts`() {
        val token = monitor.begin(Trigger.Launch)
        monitor.recordRead(120)
        monitor.recordRead(3)
        monitor.recordWritten(40)
        monitor.finish(token)
        val trace = sink.last(SyncCycleMonitor.SYNC_CYCLE)
        assertEquals("ok", trace.outcome)
        assertEquals("launch", trace.tags[SyncCycleMonitor.TAG_TRIGGER])
        assertEquals(123.0 to "none", trace.measurements[SyncCycleMonitor.MEASUREMENT_DOCS_READ])
        assertEquals(40.0 to "none", trace.measurements[SyncCycleMonitor.MEASUREMENT_DOCS_WRITTEN])
        // A timeout firing after finish must not overwrite the recorded result.
        scheduler.fireAll()
        assertEquals(1, trace.closeCount)
    }

    @Test
    fun `failure is reported as internal error`() {
        val token = monitor.begin(Trigger.Manual)
        monitor.fail(token)
        assertEquals("internal_error", sink.last(SyncCycleMonitor.SYNC_CYCLE).outcome)
        assertEquals("manual", sink.last(SyncCycleMonitor.SYNC_CYCLE).tags[SyncCycleMonitor.TAG_TRIGGER])
    }

    @Test
    fun `deadline closes the cycle as deadline exceeded`() {
        monitor.begin(Trigger.Launch)
        scheduler.fireAll()
        assertEquals("deadline_exceeded", sink.last(SyncCycleMonitor.SYNC_CYCLE).outcome)
    }

    @Test
    fun `superseded cycle is discarded and stale token cannot close the new one`() {
        val first = monitor.begin(Trigger.Launch)
        val second = monitor.begin(Trigger.Manual)
        assertEquals("discarded", sink.traces[0].outcome)
        monitor.finish(first)
        assertEquals(null, sink.traces[1].outcome)
        monitor.finish(second)
        assertEquals("ok", sink.traces[1].outcome)
    }

    @Test
    fun `discard and background discard never report`() {
        val token = monitor.begin(Trigger.Launch)
        monitor.discard(token)
        assertEquals("discarded", sink.traces[0].outcome)
        monitor.begin(Trigger.Launch)
        monitor.discardAll()
        assertEquals("discarded", sink.traces[1].outcome)
    }

    @Test
    fun `reads and writes outside a cycle are not counted`() {
        monitor.recordRead(50)
        monitor.recordWritten(50)
        val token = monitor.begin(Trigger.Launch)
        monitor.recordRead(1)
        monitor.finish(token)
        monitor.recordWritten(7)
        val trace = sink.last(SyncCycleMonitor.SYNC_CYCLE)
        assertEquals(1.0 to "none", trace.measurements[SyncCycleMonitor.MEASUREMENT_DOCS_READ])
        assertEquals(0.0 to "none", trace.measurements[SyncCycleMonitor.MEASUREMENT_DOCS_WRITTEN])
    }
}
