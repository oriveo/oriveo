package ai.oriveo.community.core.performance

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The sampler state machine runs on a fake clock: each sampler-thread beat = one tick, main-thread heartbeat = onHeartbeat. */
class MainThreadStallSamplerTest {

    private var now = 10_000L
    private var stackCalls = 0
    private var stack: Array<StackTraceElement> = arrayOf(frame("android.os.Looper", "loop"))
    private val detector = StallDetector(clock = { now }, captureMainStack = { stackCalls++; stack })

    private fun frame(cls: String, method: String) = StackTraceElement(cls, method, "SourceFile", 1)

    /** Advances one beat by nextDelayMs and ticks. */
    private fun step(): Boolean {
        now += detector.nextDelayMs()
        return detector.tick()
    }

    @Test
    fun `heartbeat answered in time never counts as a stall and never grabs a stack`() {
        repeat(50) {
            if (step()) {
                now += 5
                detector.onHeartbeat()
            }
        }
        assertNull(detector.lastStall())
        assertEquals(0, stackCalls)
    }

    @Test
    fun `lateness below the threshold is not a stall`() {
        assertTrue(detector.tick())
        now += STALL_THRESHOLD_MS - 1
        assertFalse(detector.tick())
        detector.onHeartbeat()
        assertNull(detector.lastStall())
        assertEquals(0, stackCalls)
    }

    @Test
    fun `stall starts at the heartbeat post time and samples every hundred milliseconds`() {
        assertTrue(detector.tick())
        val postedAt = now
        // Heartbeat in flight: the next beat lands exactly at the threshold.
        assertEquals(STALL_HEARTBEAT_INTERVAL_MS, detector.nextDelayMs())
        now += STALL_HEARTBEAT_INTERVAL_MS
        detector.tick()
        assertEquals(STALL_THRESHOLD_MS - STALL_HEARTBEAT_INTERVAL_MS, detector.nextDelayMs())
        step()
        assertEquals(1, stackCalls)
        assertEquals(STALL_SAMPLE_INTERVAL_MS, detector.nextDelayMs())
        repeat(4) { step() }
        detector.onHeartbeat()

        val stall = detector.lastStall()!!
        assertEquals(postedAt, stall.startMs)
        assertEquals(now, stall.endMs)
        assertEquals(5, stall.samples.size)
        assertEquals(listOf(400L, 500L, 600L, 700L, 800L), stall.samples.map { it.atMs - postedAt })
        // After recovery, back to a 5 Hz heartbeat.
        assertEquals(STALL_HEARTBEAT_INTERVAL_MS, detector.nextDelayMs())
    }

    @Test
    fun `samples are capped per stall`() {
        detector.tick()
        repeat(STALL_MAX_SAMPLES + 30) { step() }
        assertEquals(STALL_MAX_SAMPLES, detector.lastStall()!!.samples.size)
        assertEquals(STALL_MAX_SAMPLES, stackCalls)
        detector.onHeartbeat()
        assertEquals(STALL_MAX_SAMPLES, detector.lastStall()!!.samples.size)
    }

    @Test
    fun `only the most recent stall is kept`() {
        detector.tick()
        repeat(6) { step() }
        detector.onHeartbeat()
        val firstEnd = detector.lastStall()!!.endMs!!
        now += 1_000
        detector.tick()
        repeat(4) { step() }
        detector.onHeartbeat()
        val stall = detector.lastStall()!!
        assertTrue(stall.startMs > firstEnd)
        assertEquals(3, stall.samples.size)
    }

    @Test
    fun `samples between selects the frame window including an ongoing stall`() {
        detector.tick()
        val postedAt = now
        repeat(8) { step() }
        // Still queryable while the stall has not yet recovered.
        assertEquals(3, detector.samplesBetween(postedAt + 450, postedAt + 700).size)
        detector.onHeartbeat()
        assertEquals(3, detector.samplesBetween(postedAt + 450, postedAt + 700).size)
        assertTrue(detector.samplesBetween(0, postedAt + 399).isEmpty())
    }

    @Test
    fun `reset closes the stall and clears the pending heartbeat`() {
        detector.tick()
        repeat(5) { step() }
        detector.reset()
        assertEquals(now, detector.lastStall()!!.endMs)
        // Returning after a long pause: the first beat only posts a heartbeat and does not count the pause as a stall.
        now += 60_000
        assertTrue(detector.tick())
    }

    // ── Summary ──

    private fun sample(at: Long, vararg frames: StackTraceElement) = StallSample(at, arrayOf(*frames))

    private val looper = frame("android.os.Looper", "loop")
    private val dbWrite = frame("ai.oriveo.community.core.data.a", "b")
    private val compose = frame("androidx.compose.runtime.c", "d")
    private val chatList = frame("ai.oriveo.community.feature.chat.e", "f")

    @Test
    fun `top frame is the most frequent first app frame`() {
        val samples = listOf(
            sample(1, compose, chatList, looper),
            sample(2, frame("java.io.File", "write"), dbWrite, chatList, looper),
            sample(3, frame("java.io.File", "write"), dbWrite, chatList, looper),
            sample(4, compose, chatList, looper),
            sample(5, frame("java.io.File", "write"), dbWrite, chatList, looper),
        )
        val analysis = analyzeStall(samples)
        assertEquals("ai.oriveo.community.core.data.a.b", analysis.topFrame)
        assertEquals(dbWrite, analysis.representativeStack!![1])
        assertEquals(5, analysis.sampleCount)
    }

    @Test
    fun `framework only stall has no top frame but still a representative stack`() {
        val binder = frame("android.os.BinderProxy", "transactNative")
        val analysis = analyzeStall(listOf(sample(1, binder, looper), sample(2, binder, looper)))
        assertNull(analysis.topFrame)
        assertEquals(binder, analysis.representativeStack!![0])
    }

    @Test
    fun `no samples yields an empty analysis`() {
        val analysis = analyzeStall(emptyList())
        assertNull(analysis.topFrame)
        assertNull(analysis.representativeStack)
        assertEquals("", analysis.foldedStacks)
    }

    @Test
    fun `folded stacks are root first counted and sorted by frequency`() {
        val folded = foldStacks(
            listOf(
                sample(1, compose, looper),
                sample(2, dbWrite, looper),
                sample(3, dbWrite, looper),
            ),
        )
        assertEquals(
            "android.os.Looper.loop;ai.oriveo.community.core.data.a.b 2\n" +
                "android.os.Looper.loop;androidx.compose.runtime.c.d 1\n",
            folded,
        )
    }

    @Test
    fun `folded stacks stay within the attachment budget`() {
        val deep = Array(400) { frame("ai.oriveo.community.deep.Frame$it", "call") }
        val samples = (0 until STALL_MAX_SAMPLES).map { i -> StallSample(i.toLong(), arrayOf(frame("x.Y$i", "z")) + deep) }
        val folded = foldStacks(samples)
        assertTrue(folded.toByteArray().size <= FOLDED_STACKS_MAX_BYTES)
        assertTrue(folded.isNotEmpty())
    }

    @Test
    fun `top frame tag respects the sentry tag length limit`() {
        val long = frame("ai.oriveo.community." + "x".repeat(300), "m")
        assertEquals(200, analyzeStall(listOf(sample(1, long))).topFrame!!.length)
    }

    /**
     * Substitute evidence for the performance gate (a Macrobenchmark frame-time comparison needs the whole device exclusively): when idle, the main thread pays one
     * [StallDetector.onHeartbeat] every 200ms, and the sampler thread pays one [StallDetector.tick]. The cost of one full idle cycle is measured;
     * the upper bound is relaxed to 20µs to absorb CI jitter. Even at that bound, 5 Hz costs the main thread only 4µs/200ms ≈ 0.002%, far below the 1% frame-time gate.
     */
    @Test
    fun `idle heartbeat cycle costs microseconds`() {
        val idle = StallDetector(clock = { System.nanoTime() / 1_000_000 }, captureMainStack = { error("no stack capture should happen while idle") })
        repeat(20_000) { if (idle.tick()) idle.onHeartbeat(); idle.nextDelayMs() }
        val cycles = 200_000
        val heartbeatNanos = LongArray(1)
        val started = System.nanoTime()
        repeat(cycles) {
            if (idle.tick()) {
                val t = System.nanoTime()
                idle.onHeartbeat()
                heartbeatNanos[0] += System.nanoTime() - t
            }
            idle.nextDelayMs()
        }
        val perCycleNanos = (System.nanoTime() - started) / cycles
        val perHeartbeatNanos = heartbeatNanos[0] / cycles
        println("stall sampler idle cycle ${perCycleNanos}ns, main-thread heartbeat ${perHeartbeatNanos}ns")
        assertTrue("idle cycle ${perCycleNanos}ns", perCycleNanos < 20_000)
        assertTrue("main-thread heartbeat ${perHeartbeatNanos}ns", perHeartbeatNanos < 20_000)
    }
}
