package ai.oriveo.community.core.performance

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppJankStatsTest {

    @Test
    fun `capture is allowed for actionable severe jank after startup grace`() {
        assertTrue(
            shouldCaptureSevereJankEvent(
                frameDurationMs = 820.0,
                routeState = "chat",
                nowElapsedMs = 20_000L,
                trackingStartedAtMs = 0L,
                lastCapturedAtMs = 0L,
            ),
        )
    }

    @Test
    fun `capture is suppressed during startup grace`() {
        assertFalse(
            shouldCaptureSevereJankEvent(
                frameDurationMs = 820.0,
                routeState = "home",
                nowElapsedMs = 3_000L,
                trackingStartedAtMs = 0L,
                lastCapturedAtMs = 0L,
            ),
        )
    }

    @Test
    fun `capture is suppressed when route is still unknown`() {
        assertFalse(
            shouldCaptureSevereJankEvent(
                frameDurationMs = 820.0,
                routeState = "unknown",
                nowElapsedMs = 20_000L,
                trackingStartedAtMs = 0L,
                lastCapturedAtMs = 0L,
            ),
        )
    }

    @Test
    fun `capture is suppressed while throttle window is active`() {
        assertFalse(
            shouldCaptureSevereJankEvent(
                frameDurationMs = 820.0,
                routeState = "chat",
                nowElapsedMs = 20_000L,
                trackingStartedAtMs = 0L,
                lastCapturedAtMs = 10_000L,
            ),
        )
    }

    @Test
    fun `capture is suppressed for non severe jank`() {
        assertFalse(
            shouldCaptureSevereJankEvent(
                frameDurationMs = 320.0,
                routeState = "chat",
                nowElapsedMs = 20_000L,
                trackingStartedAtMs = 0L,
                lastCapturedAtMs = 0L,
            ),
        )
    }

    @Test
    fun `emulator environment detected for test-keys build`() {
        assertTrue(
            isEmulatorEnvironment(
                buildTags = "test-keys",
                supportedAbis = arrayOf("arm64-v8a", "armeabi-v7a", "armeabi"),
            ),
        )
    }

    @Test
    fun `emulator environment detected when x86 abi is supported`() {
        assertTrue(
            isEmulatorEnvironment(
                buildTags = "release-keys",
                supportedAbis = arrayOf("x86_64", "arm64-v8a", "x86", "armeabi-v7a", "armeabi"),
            ),
        )
    }

    @Test
    fun `real device with release-keys and arm abis is not emulator`() {
        assertFalse(
            isEmulatorEnvironment(
                buildTags = "release-keys",
                supportedAbis = arrayOf("arm64-v8a", "armeabi-v7a", "armeabi"),
            ),
        )
    }

    @Test
    fun `emulator detection tolerates missing build info`() {
        assertFalse(
            isEmulatorEnvironment(
                buildTags = null,
                supportedAbis = null,
            ),
        )
    }

    // ── Frozen-frame stall attribution ──

    private fun el(cls: String, method: String) = StackTraceElement(cls, method, "SourceFile", 1)

    private val stalledStack = arrayOf(
        el("java.io.FileOutputStream", "write"),
        el("ai.oriveo.community.core.data.a", "b"),
        el("android.os.Looper", "loop"),
    )

    @Test
    fun `ui thread freeze with samples groups by the server resolved top app frame`() {
        val stall = analyzeStall(listOf(StallSample(1, stalledStack), StallSample(2, stalledStack)))
        val issue = buildJankIssue(JANK_KIND_FREEZE, "chat", 2_400.0, "idle", STALL_SIDE_UI_THREAD, stall, null)
        assertEquals("Frozen frame", issue.title)
        // route is not part of the fingerprint: the same stall merges across pages.
        assertEquals(listOf(JANK_MODULE, JANK_KIND_FREEZE, "{{ stack.module }}", "{{ stack.function }}"), issue.fingerprint)
        assertEquals("ai.oriveo.community.core.data.a.b", issue.tags["stall.top_frame"])
        assertEquals("chat", issue.tags["route"])
        assertEquals(STALL_SIDE_UI_THREAD, issue.tags["stall.side"])
        assertEquals("performance", issue.tags["module"])
        assertTrue(stalledStack.contentEquals(issue.mainThreadStack))
        assertEquals(2, issue.context["stall_sample_count"])
        assertTrue(issue.foldedStacks!!.endsWith(" 2\n"))
    }

    @Test
    fun `ui thread freeze without samples gets its own group and no stack`() {
        val issue = buildJankIssue(JANK_KIND_SUSTAINED, "home", 900.0, "streaming", STALL_SIDE_UI_THREAD, analyzeStall(emptyList()), null)
        assertEquals("Sustained severe jank", issue.title)
        assertEquals(listOf(JANK_MODULE, JANK_KIND_SUSTAINED, STALL_SIDE_UI_THREAD, "no_samples"), issue.fingerprint)
        assertNull(issue.mainThreadStack)
        assertNull(issue.foldedStacks)
        assertFalse("stall.top_frame" in issue.tags)
    }

    @Test
    fun `render thread freeze carries frame metrics segments and no main thread samples`() {
        val log = RenderStallLog()
        val segments = RenderSegments(syncMs = 12.0, commandIssueMs = 3.0, swapBuffersMs = 2_950.0, gpuMs = 4.0)
        log.record(intendedVsyncNanos = 100_000 * ms, renderSideNanos = 2_990 * ms, segments = segments)
        val found = renderStallSegments(frameStartNanos = 100_033 * ms, frameDurationNanos = 3_016 * ms, log = log)
        assertEquals(segments, found)

        val issue = buildJankIssue(JANK_KIND_FREEZE, "chat", 3_016.0, "idle", STALL_SIDE_RENDER_THREAD, null, found)
        assertEquals(listOf(JANK_MODULE, JANK_KIND_FREEZE, STALL_SIDE_RENDER_THREAD), issue.fingerprint)
        assertEquals(2_950.0, issue.context["swap_buffers_ms"])
        assertEquals(4.0, issue.context["gpu_ms"])
        assertNull(issue.mainThreadStack)
        assertFalse("stall.top_frame" in issue.tags)
    }

    @Test
    fun `segments older than the lookback window are not attributed`() {
        val log = RenderStallLog()
        log.record(intendedVsyncNanos = 50_000 * ms, renderSideNanos = 3_000 * ms, segments = RenderSegments(1.0, 1.0, 1.0, null))
        assertNull(renderStallSegments(frameStartNanos = 100_033 * ms, frameDurationNanos = 3_016 * ms, log = log))
    }

    @Test
    fun `jank issue titles are registered in the fixture`() {
        val registered = ai.oriveo.community.core.observability.ObservabilityFixture.json["diagnostics"]!!
            .let { it as kotlinx.serialization.json.JsonObject }["issue"]!!
            .let { it as kotlinx.serialization.json.JsonArray }
            .map { (it as kotlinx.serialization.json.JsonObject)["name"].toString().trim('"') }
        listOf(JANK_KIND_FREEZE, JANK_KIND_SUSTAINED).forEach { assertTrue(jankMessage(it) in registered) }
    }

    // ── Frozen-frame stall attribution ──

    private fun el(cls: String, method: String) = StackTraceElement(cls, method, "SourceFile", 1)

    private val stalledStack = arrayOf(
        el("java.io.FileOutputStream", "write"),
        el("ai.oriveo.community.core.data.a", "b"),
        el("android.os.Looper", "loop"),
    )

    @Test
    fun `ui thread freeze with samples groups by the server resolved top app frame`() {
        val stall = analyzeStall(listOf(StallSample(1, stalledStack), StallSample(2, stalledStack)))
        val issue = buildJankIssue(JANK_KIND_FREEZE, "chat", 2_400.0, "idle", STALL_SIDE_UI_THREAD, stall, null)
        assertEquals("Frozen frame", issue.title)
        // route is not part of the fingerprint: the same stall merges across pages.
        assertEquals(listOf(JANK_MODULE, JANK_KIND_FREEZE, "{{ stack.module }}", "{{ stack.function }}"), issue.fingerprint)
        assertEquals("ai.oriveo.community.core.data.a.b", issue.tags["stall.top_frame"])
        assertEquals("chat", issue.tags["route"])
        assertEquals(STALL_SIDE_UI_THREAD, issue.tags["stall.side"])
        assertEquals("performance", issue.tags["module"])
        assertTrue(stalledStack.contentEquals(issue.mainThreadStack))
        assertEquals(2, issue.context["stall_sample_count"])
        assertTrue(issue.foldedStacks!!.endsWith(" 2\n"))
    }

    @Test
    fun `ui thread freeze without samples gets its own group and no stack`() {
        val issue = buildJankIssue(JANK_KIND_SUSTAINED, "home", 900.0, "streaming", STALL_SIDE_UI_THREAD, analyzeStall(emptyList()), null)
        assertEquals("Sustained severe jank", issue.title)
        assertEquals(listOf(JANK_MODULE, JANK_KIND_SUSTAINED, STALL_SIDE_UI_THREAD, "no_samples"), issue.fingerprint)
        assertNull(issue.mainThreadStack)
        assertNull(issue.foldedStacks)
        assertFalse("stall.top_frame" in issue.tags)
    }

    @Test
    fun `render thread freeze carries frame metrics segments and no main thread samples`() {
        val log = RenderStallLog()
        val segments = RenderSegments(syncMs = 12.0, commandIssueMs = 3.0, swapBuffersMs = 2_950.0, gpuMs = 4.0)
        log.record(intendedVsyncNanos = 100_000 * ms, renderSideNanos = 2_990 * ms, segments = segments)
        val found = renderStallSegments(frameStartNanos = 100_033 * ms, frameDurationNanos = 3_016 * ms, log = log)
        assertEquals(segments, found)

        val issue = buildJankIssue(JANK_KIND_FREEZE, "chat", 3_016.0, "idle", STALL_SIDE_RENDER_THREAD, null, found)
        assertEquals(listOf(JANK_MODULE, JANK_KIND_FREEZE, STALL_SIDE_RENDER_THREAD), issue.fingerprint)
        assertEquals(2_950.0, issue.context["swap_buffers_ms"])
        assertEquals(4.0, issue.context["gpu_ms"])
        assertNull(issue.mainThreadStack)
        assertFalse("stall.top_frame" in issue.tags)
    }

    @Test
    fun `segments older than the lookback window are not attributed`() {
        val log = RenderStallLog()
        log.record(intendedVsyncNanos = 50_000 * ms, renderSideNanos = 3_000 * ms, segments = RenderSegments(1.0, 1.0, 1.0, null))
        assertNull(renderStallSegments(frameStartNanos = 100_033 * ms, frameDurationNanos = 3_016 * ms, log = log))
    }

    @Test
    fun `jank issue titles are registered in the fixture`() {
        val registered = ai.oriveo.community.core.observability.ObservabilityFixture.json["diagnostics"]!!
            .let { it as kotlinx.serialization.json.JsonObject }["issue"]!!
            .let { it as kotlinx.serialization.json.JsonArray }
            .map { (it as kotlinx.serialization.json.JsonObject)["name"].toString().trim('"') }
        listOf(JANK_KIND_FREEZE, JANK_KIND_SUSTAINED).forEach { assertTrue(jankMessage(it) in registered) }
    }
}
