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
}
