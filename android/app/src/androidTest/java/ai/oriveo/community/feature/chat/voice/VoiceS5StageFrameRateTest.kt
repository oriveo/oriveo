package ai.oriveo.community.feature.chat.voice

import android.app.KeyguardManager
import android.os.Build
import android.os.PowerManager
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.FrameMetrics
import android.view.ViewTreeObserver
import android.view.Window
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.MainActivity
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import java.util.Collections
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.sin
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * S5 stage frame rate probe on a real device.
 *
 * stageSpeakingFrameRate: the production voice stage ([VoiceConversationBar]) in the speaking status, hosted in the
 * app's activity with reduce motion off, is fed a 0..1 sine level for [MEASURE_MS]. A FrameMetrics listener records
 * every frame, and a draw listener on the decor view timestamps every draw as a second source (FrameMetrics can stay
 * silent on some windows); the probe reports the mean frame interval (vsync to vsync), the p95 frame duration and the share of
 * frames over the display's frame budget. Recorded only, no gate.
 *
 * Writes getExternalFilesDir("s5-results")/stage.json and logs a summary line under tag VoiceS5.
 */
@RunWith(AndroidJUnit4::class)
class VoiceS5StageFrameRateTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    private data class Frame(val vsyncNs: Long, val totalNs: Long)

    @Test
    fun stageSpeakingFrameRate() {
        // Reduce motion off: the orb only animates with a non-zero animator scale (read once per process).
        val scaleBefore = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        if (scaleBefore == 0f) shell("settings put global animator_duration_scale 1")
        val level = MutableStateFlow(0f)
        val frames = Collections.synchronizedList(mutableListOf<Frame>())
        val draws = Collections.synchronizedList(mutableListOf<Long>())
        val drawListener = ViewTreeObserver.OnDrawListener { draws += System.nanoTime() }
        val metricsThread = HandlerThread("s5-frame-metrics").also { it.start() }
        val listener = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
            frames += Frame(
                vsyncNs = metrics.getMetric(FrameMetrics.VSYNC_TIMESTAMP),
                totalNs = metrics.getMetric(FrameMetrics.TOTAL_DURATION),
            )
        }
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            var refreshHz = 60f
            var accelerated = false
            scenario.onActivity { activity ->
                // A locked or dark screen never draws: show over the keyguard, turn the screen on and keep it on.
                activity.setShowWhenLocked(true)
                activity.setTurnScreenOn(true)
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                activity.getSystemService(KeyguardManager::class.java)?.requestDismissKeyguard(activity, null)
                @Suppress("DEPRECATION")
                refreshHz = activity.display?.refreshRate ?: activity.windowManager.defaultDisplay.refreshRate
                activity.setContent {
                    OriveoTheme {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
                            VoiceConversationBar(
                                status = ConversationStatusKey.SPEAKING,
                                level = level,
                                page = VoiceConversationPage.Chat,
                                onEnd = {},
                                onTapOrb = {},
                                onToggleMute = {},
                            )
                        }
                    }
                }
            }
            // Let the stage settle (first composition, fonts, shaders) before measuring.
            feedSine(level, WARMUP_MS)
            var focused = false
            var interactive = false
            var keyguardLocked = false
            scenario.onActivity {
                accelerated = it.window.decorView.isHardwareAccelerated
                focused = it.hasWindowFocus()
                interactive = it.getSystemService(PowerManager::class.java)?.isInteractive == true
                keyguardLocked = it.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
                it.window.addOnFrameMetricsAvailableListener(listener, Handler(metricsThread.looper))
                it.window.decorView.viewTreeObserver.addOnDrawListener(drawListener)
            }
            feedSine(level, MEASURE_MS)
            scenario.onActivity {
                it.window.removeOnFrameMetricsAvailableListener(listener)
                it.window.decorView.viewTreeObserver.removeOnDrawListener(drawListener)
            }
            instrumentation.waitForIdleSync()
            // FrameMetrics is delivered asynchronously: give the last frames a moment to land.
            SystemClock.sleep(METRICS_FLUSH_MS)

            val sample = synchronized(frames) { frames.toList() }
            val budgetNs = (1_000_000_000.0 / refreshHz).toLong()
            val drawTimes = synchronized(draws) { draws.toList() }
            // Interval source: FrameMetrics vsync stamps when delivered, else the decor view's draw stamps.
            val intervalSource = if (sample.size > 1) "frameMetrics" else "onDraw"
            val stamps = if (sample.size > 1) sample.map { it.vsyncNs } else drawTimes
            val intervals = stamps.zipWithNext { a, b -> b - a }.filter { it > 0 }
            val meanIntervalMs = intervals.takeIf { it.isNotEmpty() }?.average()?.div(1_000_000.0)
            val durations = sample.map { it.totalNs }.sorted()
            val p95Ms = durations.takeIf { it.isNotEmpty() }
                ?.let { it[(ceil(it.size * 0.95).toInt() - 1).coerceIn(0, it.lastIndex)] / 1_000_000.0 }
            val jankFrames = sample.count { it.totalNs > budgetNs }
            val droppedRatio = if (sample.isEmpty()) null else jankFrames.toDouble() / sample.size
            // Vsyncs skipped between frames (interval longer than 1.5 budgets) over the whole window.
            val skippedVsyncs = intervals.sumOf { ((it + budgetNs / 2) / budgetNs - 1).coerceAtLeast(0) }
            val fps = meanIntervalMs?.let { 1000.0 / it }
            val summary = JSONObject()
                .put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
                .put("sdk", Build.VERSION.SDK_INT)
                .put("refreshHz", refreshHz.toDouble())
                .put("frameBudgetMs", budgetNs / 1_000_000.0)
                .put("animatorScaleBefore", scaleBefore.toDouble())
                .put("measureMs", MEASURE_MS)
                .put("levelPeriodMs", LEVEL_PERIOD_MS)
                .put("frames", sample.size)
                .put("draws", drawTimes.size)
                .put("intervalSource", intervalSource)
                .put("hardwareAccelerated", accelerated)
                .put("windowFocused", focused)
                .put("interactive", interactive)
                .put("keyguardLocked", keyguardLocked)
                .put("meanFrameIntervalMs", meanIntervalMs ?: JSONObject.NULL)
                .put("fps", fps ?: JSONObject.NULL)
                .put("p95FrameDurationMs", p95Ms ?: JSONObject.NULL)
                .put("framesOverBudget", jankFrames)
                .put("droppedRatio", droppedRatio ?: JSONObject.NULL)
                .put("skippedVsyncs", skippedVsyncs)
            val out = File(context.getExternalFilesDir("s5-results"), "stage.json")
            val json = runCatching { JSONObject(out.readText()) }.getOrElse { JSONObject() }
            json.put("stageSpeakingFrameRate", summary)
            out.writeText(json.toString(2))
            Log.i(
                TAG,
                "VOICE-S5 stage speaking frames=${sample.size} draws=${drawTimes.size} source=$intervalSource " +
                    "refreshHz=$refreshHz accelerated=$accelerated focused=$focused interactive=$interactive " +
                    "keyguardLocked=$keyguardLocked " +
                    "meanIntervalMs=${meanIntervalMs?.let { "%.2f".format(it) } ?: "n/a"} " +
                    "fps=${fps?.let { "%.1f".format(it) } ?: "n/a"} " +
                    "p95Ms=${p95Ms?.let { "%.2f".format(it) } ?: "n/a"} " +
                    "overBudget=$jankFrames droppedRatio=${droppedRatio?.let { "%.4f".format(it) } ?: "n/a"} " +
                    "skippedVsyncs=$skippedVsyncs animatorScaleBefore=$scaleBefore",
            )
            // Not a performance gate: an empty sample only means the measurement itself did not happen.
            assertTrue("no frames measured (frames=${sample.size} draws=${drawTimes.size}): measurement invalid", stamps.size > 1)
        } finally {
            scenario.close()
            metricsThread.quitSafely()
            if (scaleBefore == 0f) shell("settings put global animator_duration_scale 0")
        }
    }

    /** Pushes a 0..1 sine level at about 60 Hz for [durationMs] from the instrumentation thread. */
    private fun feedSine(level: MutableStateFlow<Float>, durationMs: Long) {
        val start = SystemClock.uptimeMillis()
        while (true) {
            val elapsed = SystemClock.uptimeMillis() - start
            if (elapsed >= durationMs) break
            level.value = (0.5 + 0.5 * sin(2 * PI * elapsed / LEVEL_PERIOD_MS)).toFloat()
            SystemClock.sleep(LEVEL_TICK_MS)
        }
    }

    private fun shell(command: String) {
        instrumentation.uiAutomation.executeShellCommand(command).close()
    }

    private companion object {
        const val TAG = "VoiceS5"
        const val WARMUP_MS = 2_000L
        const val MEASURE_MS = 10_000L
        const val LEVEL_PERIOD_MS = 1_000.0
        const val LEVEL_TICK_MS = 16L
        const val METRICS_FLUSH_MS = 500L
    }
}
