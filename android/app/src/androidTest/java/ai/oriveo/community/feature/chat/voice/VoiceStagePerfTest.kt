package ai.oriveo.community.feature.chat.voice

import android.app.KeyguardManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.FrameMetrics
import android.view.Window
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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
import kotlin.math.ceil
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Stage perf probe for the voice live STT system.
 *
 * sixStatesThirtySeconds: the production voice stage ([VoiceConversationBar]) on the chat page, hosted in the app's
 * activity with reduce motion off, is held in each of six states (listening, user speaking, thinking, AI speaking,
 * say again, muted) for [STATE_MS]. While the user or the AI speaks, the level cycles through the contract's staircase
 * at 15 Hz; other states get level 0. A FrameMetrics listener records every frame; frames are assigned to a state by
 * their vsync stamp falling inside that state's measuring window (after a settle period that skips the mode switch).
 *
 * Per state: frames, fps, total / GPU frame time p50 / p95 / max, UI thread ms per frame (input + animation + layout
 * + draw), frames over budget (total > deadline; deadline = FrameMetrics.DEADLINE on API 31+, else one refresh
 * interval). Each state must keep frames over budget at or under 1%.
 *
 * Writes getExternalFilesDir("v2-results")/stage-perf.json and logs one line per state under tag VoiceLive.
 */
@RunWith(AndroidJUnit4::class)
class VoiceStagePerfTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    private data class Frame(val vsyncNs: Long, val totalNs: Long, val gpuNs: Long, val uiNs: Long, val deadlineNs: Long?)

    private data class StageState(
        val name: String,
        val status: ConversationStatusKey,
        val userSpeaking: Boolean,
        val staircase: Boolean,
    )

    private val states = listOf(
        StageState("listening", ConversationStatusKey.LISTENING, userSpeaking = false, staircase = false),
        StageState("userSpeaking", ConversationStatusKey.LISTENING, userSpeaking = true, staircase = true),
        StageState("thinking", ConversationStatusKey.THINKING, userSpeaking = false, staircase = false),
        StageState("aiSpeaking", ConversationStatusKey.SPEAKING, userSpeaking = false, staircase = true),
        StageState("sayAgain", ConversationStatusKey.SAY_AGAIN, userSpeaking = false, staircase = false),
        StageState("muted", ConversationStatusKey.MUTED, userSpeaking = false, staircase = false),
    )

    @Test
    fun sixStatesThirtySeconds() {
        // Reduce motion off: the orb only animates with a non-zero animator scale (read once per process).
        val scaleBefore = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        if (scaleBefore == 0f) shell("settings put global animator_duration_scale 1")
        val level = MutableStateFlow(0f)
        var status by mutableStateOf(states.first().status)
        var userSpeaking by mutableStateOf(states.first().userSpeaking)
        val frames = Collections.synchronizedList(mutableListOf<Frame>())
        val metricsThread = HandlerThread("v2-frame-metrics").also { it.start() }
        val listener = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
            val ui = metrics.getMetric(FrameMetrics.INPUT_HANDLING_DURATION) +
                metrics.getMetric(FrameMetrics.ANIMATION_DURATION) +
                metrics.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION) +
                metrics.getMetric(FrameMetrics.DRAW_DURATION)
            frames += Frame(
                vsyncNs = metrics.getMetric(FrameMetrics.VSYNC_TIMESTAMP),
                totalNs = metrics.getMetric(FrameMetrics.TOTAL_DURATION),
                gpuNs = metrics.getMetric(FrameMetrics.GPU_DURATION),
                uiNs = ui,
                deadlineNs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    metrics.getMetric(FrameMetrics.DEADLINE)
                } else {
                    null
                },
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
                                status = status,
                                level = level,
                                page = VoiceConversationPage.Chat,
                                onEnd = {},
                                onTapOrb = {},
                                onToggleMute = {},
                                userSpeaking = userSpeaking,
                            )
                        }
                    }
                }
            }
            // Let the stage settle (first composition, fonts, shaders) before measuring.
            SystemClock.sleep(WARMUP_MS)
            scenario.onActivity {
                accelerated = it.window.decorView.isHardwareAccelerated
                it.window.addOnFrameMetricsAvailableListener(listener, Handler(metricsThread.looper))
            }
            val windows = mutableListOf<Pair<Long, Long>>()
            for (state in states) {
                scenario.onActivity {
                    status = state.status
                    userSpeaking = state.userSpeaking
                }
                feed(level, state.staircase, SETTLE_MS)
                val startNs = System.nanoTime()
                feed(level, state.staircase, STATE_MS)
                windows += startNs to System.nanoTime()
            }
            scenario.onActivity { it.window.removeOnFrameMetricsAvailableListener(listener) }
            instrumentation.waitForIdleSync()
            // FrameMetrics is delivered asynchronously: give the last frames a moment to land.
            SystemClock.sleep(METRICS_FLUSH_MS)

            val sample = synchronized(frames) { frames.toList() }
            val intervalNs = (1_000_000_000.0 / refreshHz).toLong()
            // Virtual devices (emulator Build.HARDWARE measured as ranchu, older images goldfish) use SwiftShader software rasterization for GLES:
            // frame time does not represent a real GPU and is not comparable, so the <= 1% gate is not judged here; this only asserts that dynamic states draw frames. The gate is left to real devices (see the real-device checklist).
            val virtualDevice = Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish"
            val results = JSONArray()
            val failures = mutableListOf<String>()
            states.forEachIndexed { index, state ->
                val (startNs, endNs) = windows[index]
                val inState = sample.filter { it.vsyncNs in startNs until endNs }.sortedBy { it.vsyncNs }
                val intervals = inState.map { it.vsyncNs }.zipWithNext { a, b -> b - a }.filter { it > 0 }
                val fps = intervals.takeIf { it.isNotEmpty() }?.average()?.let { 1_000_000_000.0 / it }
                val total = inState.map { it.totalNs }.sorted()
                val gpu = inState.map { it.gpuNs }.sorted()
                val uiMeanMs = inState.takeIf { it.isNotEmpty() }?.map { it.uiNs }?.average()?.div(1_000_000.0)
                val uiP95Ms = percentileMs(inState.map { it.uiNs }.sorted(), 0.95)
                val overBudget = inState.count { it.totalNs > (it.deadlineNs ?: intervalNs) }
                // Muted stops the frame loop by design: no frames there means a static stage, zero frames over budget.
                val static = state.status == ConversationStatusKey.MUTED && inState.isEmpty()
                val overRatio = when {
                    static -> 0.0
                    inState.isEmpty() -> null
                    else -> overBudget.toDouble() / inState.size
                }
                results.put(
                    JSONObject()
                        .put("state", state.name)
                        .put("status", state.status.rawValue)
                        .put("userSpeaking", state.userSpeaking)
                        .put("staircase15Hz", state.staircase)
                        .put("measureMs", STATE_MS)
                        .put("frames", inState.size)
                        .put("static", static)
                        .put("fps", fps ?: JSONObject.NULL)
                        .put("totalP50Ms", percentileMs(total, 0.50) ?: JSONObject.NULL)
                        .put("totalP95Ms", percentileMs(total, 0.95) ?: JSONObject.NULL)
                        .put("totalMaxMs", total.lastOrNull()?.div(1_000_000.0) ?: JSONObject.NULL)
                        .put("gpuP50Ms", percentileMs(gpu, 0.50) ?: JSONObject.NULL)
                        .put("gpuP95Ms", percentileMs(gpu, 0.95) ?: JSONObject.NULL)
                        .put("gpuMaxMs", gpu.lastOrNull()?.div(1_000_000.0) ?: JSONObject.NULL)
                        .put("uiThreadMeanMs", uiMeanMs ?: JSONObject.NULL)
                        .put("uiThreadP95Ms", uiP95Ms ?: JSONObject.NULL)
                        .put("framesOverBudget", overBudget)
                        .put("overBudgetRatio", overRatio ?: JSONObject.NULL),
                )
                Log.i(
                    TAG,
                    "VOICE-LIVE V2 stage-perf state=${state.name} frames=${inState.size} " +
                        "fps=${fmt(fps, "%.1f")} " +
                        "totalP50=${fmt(percentileMs(total, 0.50))} totalP95=${fmt(percentileMs(total, 0.95))} " +
                        "totalMax=${fmt(total.lastOrNull()?.div(1_000_000.0))} " +
                        "gpuP50=${fmt(percentileMs(gpu, 0.50))} gpuP95=${fmt(percentileMs(gpu, 0.95))} " +
                        "gpuMax=${fmt(gpu.lastOrNull()?.div(1_000_000.0))} " +
                        "uiMean=${fmt(uiMeanMs)} uiP95=${fmt(uiP95Ms)} " +
                        "overBudget=$overBudget ratio=${fmt(overRatio, "%.4f")} static=$static",
                )
                // A static muted stage passes; muted frames, when any, are judged by the budget like every other state.
                if (inState.size < 2 && state.status != ConversationStatusKey.MUTED) {
                    failures += "${state.name}: no frames measured (frames=${inState.size})"
                } else if (!virtualDevice && overRatio != null && overRatio > MAX_OVER_BUDGET_RATIO) {
                    failures += "${state.name}: over budget ${"%.4f".format(overRatio)} > $MAX_OVER_BUDGET_RATIO"
                }
            }
            val summary = JSONObject()
                .put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
                .put("sdk", Build.VERSION.SDK_INT)
                .put("hardware", Build.HARDWARE)
                .put("virtualDevice", virtualDevice)
                .put("refreshHz", refreshHz.toDouble())
                .put("refreshIntervalMs", intervalNs / 1_000_000.0)
                .put("deadlineSource", if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) "frameMetrics" else "refreshInterval")
                .put("hardwareAccelerated", accelerated)
                .put("animatorScaleBefore", scaleBefore.toDouble())
                .put("settleMs", SETTLE_MS)
                .put("states", results)
            val out = File(context.getExternalFilesDir("v2-results"), "stage-perf.json")
            val json = runCatching { JSONObject(out.readText()) }.getOrElse { JSONObject() }
            json.put("sixStatesThirtySeconds", summary)
            out.writeText(json.toString(2))
            Log.i(TAG, "VOICE-LIVE V2 stage-perf refreshHz=$refreshHz sdk=${Build.VERSION.SDK_INT} accelerated=$accelerated virtualDevice=$virtualDevice")
            assertTrue(failures.joinToString("; "), failures.isEmpty())
        } finally {
            scenario.close()
            metricsThread.quitSafely()
            if (scaleBefore == 0f) shell("settings put global animator_duration_scale 0")
        }
    }

    /** Holds [level] for [durationMs]: the contract staircase at 15 Hz when [staircase], else 0. */
    private fun feed(level: MutableStateFlow<Float>, staircase: Boolean, durationMs: Long) {
        val start = SystemClock.uptimeMillis()
        while (true) {
            val elapsed = SystemClock.uptimeMillis() - start
            if (elapsed >= durationMs) break
            level.value = if (staircase) STAIRCASE[((elapsed * STAIRCASE_HZ / 1_000L) % STAIRCASE.size).toInt()] else 0f
            SystemClock.sleep(TICK_MS)
        }
    }

    private fun percentileMs(sorted: List<Long>, p: Double): Double? =
        sorted.takeIf { it.isNotEmpty() }
            ?.let { it[(ceil(it.size * p).toInt() - 1).coerceIn(0, it.lastIndex)] / 1_000_000.0 }

    private fun fmt(value: Double?, pattern: String = "%.2f"): String = value?.let { pattern.format(it) } ?: "n/a"

    private fun shell(command: String) {
        instrumentation.uiAutomation.executeShellCommand(command).close()
    }

    private companion object {
        const val TAG = "VoiceLive"
        const val WARMUP_MS = 2_000L
        const val SETTLE_MS = 1_000L
        const val STATE_MS = 30_000L
        const val STAIRCASE_HZ = 15L
        const val TICK_MS = 8L
        const val METRICS_FLUSH_MS = 500L
        const val MAX_OVER_BUDGET_RATIO = 0.01

        // Contract item 3 staircase.
        val STAIRCASE = floatArrayOf(0.2f, 0.6f, 0.3f, 0.8f, 0.5f, 0.9f, 0.4f, 0.7f, 0.2f, 0f, 0.5f, 1f, 0.6f, 0.1f)
    }
}
