package ai.oriveo.community.feature.chat.voice

import androidx.activity.ComponentActivity
import android.app.KeyguardManager
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.PixelCopy
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.MainActivity
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.sin
import kotlin.math.sqrt
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * V1 card aB: on the RenderEffect path, measure the actual Gaussian sigma and alpha of the production fog and glow and compare them
 * with the canvas (CSS blur(Npx) means sigma=N, opacity applied to the whole blurred blob, sRGB source-over).
 * Sigma and alpha each differ by at most 3%, and light and dark reach the same conclusion.
 *
 * (1) softBlur acts on a white half-plane (black background); the vertical 16-84% transition width = 2 sigma.
 * (2) The production [VoiceAuroraFog] (Idle, clock frozen at t=0 so there is no horizontal drift) is laid over pure light and dark backgrounds.
 *    Fits the alpha and sigma multipliers against the analytic per-blob source-over model of "disk convolved with Gaussian sigma x alpha", and reports the residual at 1x1.
 * (3) The production [VoiceAuroraOrb] glow is handled the same way (sampled in the ring outside the orb, the union of the three circles modeled by numeric convolution).
 *
 * Writes getExternalFilesDir("v1-results")/blur.json, logcat TAG VoiceV1.
 */
@RunWith(AndroidJUnit4::class)
class VoiceOrbBlurProbeTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test
    fun halfPlaneSigma() {
        val density = context.resources.displayMetrics.density
        val blobUnit = VoiceAuroraOrbSize / ORB_CANVAS
        val cases = listOf(
            "orbBlob14" to blobUnit * ORB_BLOB_SIGMA,
            "orbGlow22" to blobUnit * ORB_GLOW_SIGMA,
            "fog60" to 60.dp,
            "fog70" to 70.dp,
            "fog80" to 80.dp,
        )
        val results = JSONArray()
        val failures = mutableListOf<String>()
        cases.forEach { (name, sigma) ->
            val sigmaPx = sigma.value * density
            val extraDp = (8f * sigmaPx / density).dp
            val shot = capture { activity ->
                activity.setContent {
                    val d = LocalDensity.current
                    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                        // Expand 4 sigma on each side: only the midline edge remains, so the column profile is unaffected by the left and right bounds.
                        val w = with(d) { activity.window.decorView.width.toDp() } + extraDp
                        val h = with(d) { activity.window.decorView.height.toDp() }
                        Canvas(Modifier.requiredSize(w, h).softBlur(VoiceOrbBlur.RenderEffect, sigma, d)) {
                            drawRect(Color.White, size = Size(size.width, size.height / 2f))
                        }
                    }
                }
            }
            val x = shot.bitmap.width / 2
            val column = DoubleArray(shot.bitmap.height) { y -> channels(shot.bitmap.getPixel(x, y)).average() / 255.0 }
            val y84 = crossing(column, 0.84)
            val y16 = crossing(column, 0.16)
            val measured = if (y84 != null && y16 != null) (y16 - y84) / 2.0 else null
            val ratio = measured?.div(sigmaPx)
            results.put(
                JSONObject()
                    .put("case", name)
                    .put("sigmaDp", sigma.value.toDouble())
                    .put("expectedSigmaPx", sigmaPx.toDouble())
                    .put("radiusPx", blurRadiusPx(sigmaPx).toDouble())
                    .put("y84", y84 ?: JSONObject.NULL)
                    .put("y16", y16 ?: JSONObject.NULL)
                    .put("measuredSigmaPx", measured ?: JSONObject.NULL)
                    .put("ratio", ratio ?: JSONObject.NULL),
            )
            Log.i(TAG, "VOICE-V1 halfPlane $name expectedPx=${f(sigmaPx)} measuredPx=${measured?.let { f(it) }} ratio=${ratio?.let { f(it) }}")
            if (ratio == null || abs(ratio - 1.0) > TOLERANCE) failures += "$name ratio=$ratio"
        }
        write("halfPlane", JSONObject().put("device", device()).put("density", density.toDouble()).put("cases", results))
        assertTrue("half-plane σ off by > 3%: $failures", failures.isEmpty())
    }

    @Test
    fun fogAlphaAndSigma() {
        val out = JSONObject().put("device", device())
        val failures = mutableListOf<String>()
        listOf(false, true).forEach { dark ->
            val bg = if (dark) Color.Black else Color.White
            var panelX = 0f
            var panelY = 0f
            var panelW = 0
            var panelH = 0
            val shot = capture { activity ->
                activity.setContent {
                    OriveoTheme(darkTheme = dark) {
                        CompositionLocalProvider(LocalVoiceStageClockOverride provides 0L) {
                            Box(Modifier.fillMaxSize().background(bg)) {
                                Box(
                                    Modifier.align(Alignment.TopStart).fillMaxWidth().height(PANEL_HEIGHT)
                                        .onGloballyPositioned {
                                            val p = it.positionInWindow()
                                            panelX = p.x
                                            panelY = p.y
                                            panelW = it.size.width
                                            panelH = it.size.height
                                        },
                                ) {
                                    VoiceAuroraFog(mode = VoiceOrbMode.Idle, level = null, notice = false, modifier = Modifier.fillMaxSize())
                                }
                            }
                        }
                    }
                }
            }
            val d = Density(context.resources.displayMetrics.density)
            val model = buildFog(d, dark, panelX, panelY, panelW, panelH, bg, shot.bitmap)
            val fit = model.fit()
            out.put(if (dark) "dark" else "light", fit.json)
            Log.i(TAG, "VOICE-V1 fog dark=$dark ${fit.line}")
            if (!fit.within()) failures += "fog dark=$dark ${fit.line}"
        }
        write("fog", out)
        assertTrue("fog σ / α off by > 3%: $failures", failures.isEmpty())
    }

    @Test
    fun glowAlphaAndSigma() {
        val out = JSONObject().put("device", device())
        val failures = mutableListOf<String>()
        listOf(false, true).forEach { dark ->
            val bg = if (dark) Color.Black else Color.White
            var orbX = 0f
            var orbY = 0f
            var orbW = 0
            val shot = capture { activity ->
                activity.setContent {
                    OriveoTheme(darkTheme = dark) {
                        CompositionLocalProvider(LocalVoiceStageClockOverride provides 0L) {
                            Box(Modifier.fillMaxSize().background(bg), contentAlignment = Alignment.Center) {
                                VoiceAuroraOrb(
                                    mode = VoiceOrbMode.Idle,
                                    level = null,
                                    nudges = 0,
                                    modifier = Modifier.onGloballyPositioned {
                                        val p = it.positionInWindow()
                                        orbX = p.x
                                        orbY = p.y
                                        orbW = it.size.width
                                    },
                                )
                            }
                        }
                    }
                }
            }
            val d = Density(context.resources.displayMetrics.density)
            val model = buildGlow(d, dark, orbX, orbY, orbW, bg, shot.bitmap)
            val fit = model.fit()
            out.put(if (dark) "dark" else "light", fit.json)
            Log.i(TAG, "VOICE-V1 glow dark=$dark ${fit.line}")
            if (!fit.within()) failures += "glow dark=$dark ${fit.line}"
        }
        write("glow", out)
        assertTrue("glow σ / α off by > 3%: $failures", failures.isEmpty())
    }

    // ── Fit results ──

    private class Fit(val alphaScale: Double, val sigmaScale: Double, val rmsFit: Double, val rmsUnit: Double, val samples: Int) {
        fun within() = abs(alphaScale - 1.0) <= TOLERANCE && abs(sigmaScale - 1.0) <= TOLERANCE
        val line get() = "alpha×${f(alphaScale)} sigma×${f(sigmaScale)} rmsFit=${f(rmsFit)} rms1x1=${f(rmsUnit)} samples=$samples"
        val json: JSONObject get() = JSONObject()
            .put("alphaScale", alphaScale)
            .put("sigmaScale", sigmaScale)
            .put("rmsFit255", rmsFit)
            .put("rmsAtUnit255", rmsUnit)
            .put("samples", samples)
    }

    /** Scans sigma multipliers coarse (0.05) then fine (0.01); [sse] returns (best alpha multiplier, SSE) for a given sigma multiplier. */
    private fun fitScales(samples: Int, unitSse: Double, sse: (Double) -> Pair<Double, Double>): Fit {
        fun scan(from: Double, to: Double, step: Double): Triple<Double, Double, Double> {
            var best = Triple(1.0, 1.0, Double.MAX_VALUE)
            var s = from
            while (s <= to + 1e-9) {
                val (a, e) = sse(s)
                if (e < best.third) best = Triple(s, a, e)
                s += step
            }
            return best
        }
        val coarse = scan(0.70, 1.60, 0.05)
        val fine = scan(coarse.first - 0.05, coarse.first + 0.05, 0.01)
        val n = samples * 3.0
        return Fit(fine.second, fine.first, sqrt(fine.third / n), sqrt(unitSse / n), samples)
    }

    // ── Fog: per-blob radial analytic profile ──

    private class FogCircleSpec(val cx: Double, val cy: Double, val radius: Double, val sigma: Double, val alpha: Double, val rgb: DoubleArray)

    private inner class FogModel(
        val circles: List<FogCircleSpec>,
        val bg: DoubleArray,
        val px: IntArray,
        val py: IntArray,
        val observed: Array<DoubleArray>,
    ) {
        /** Distance from each sample point to each circle center. */
        private val dist = Array(circles.size) { i -> DoubleArray(px.size) { j -> hypot(px[j] + 0.5 - circles[i].cx, py[j] + 0.5 - circles[i].cy) } }

        private fun coverage(sigmaScale: Double): Array<DoubleArray> = Array(circles.size) { i ->
            val c = circles[i]
            val table = diskGaussTable(c.radius, c.sigma * sigmaScale, dist[i].max() + 2.0)
            DoubleArray(px.size) { j -> lookup(table, dist[i][j]) }
        }

        private fun sse(cov: Array<DoubleArray>, alphaScale: Double): Double {
            var sum = 0.0
            for (j in px.indices) {
                var r = bg[0]
                var g = bg[1]
                var b = bg[2]
                for (i in circles.indices) {
                    val a = (circles[i].alpha * alphaScale * cov[i][j]).coerceIn(0.0, 1.0)
                    r = r * (1 - a) + circles[i].rgb[0] * a
                    g = g * (1 - a) + circles[i].rgb[1] * a
                    b = b * (1 - a) + circles[i].rgb[2] * a
                }
                val o = observed[j]
                sum += (r - o[0]) * (r - o[0]) + (g - o[1]) * (g - o[1]) + (b - o[2]) * (b - o[2])
            }
            return sum
        }

        fun fit(): Fit {
            val unit = sse(coverage(1.0), 1.0)
            return fitScales(px.size, unit) { s ->
                val cov = coverage(s)
                golden(0.6, 1.8) { a -> sse(cov, a) }
            }
        }
    }

    private fun buildFog(
        d: Density,
        dark: Boolean,
        panelX: Float,
        panelY: Float,
        panelW: Int,
        panelH: Int,
        bg: Color,
        bitmap: Bitmap,
    ): FogModel = with(d) {
        // Replicates the rounding of fogFrame / fogLayer: container left = panel left - bleed; top = panel top + round(bottom) - height.
        val bleed = FogBleedX.roundToPx()
        val height = FogHeight.roundToPx()
        val span = fogFrame(panelH.toDp(), 0.dp)
        val left = panelX - bleed
        val top = panelY + span.bottom.roundToPx() - height
        val panelWidth = panelW.toDp()
        val energy = orbEnergy(VoiceOrbMode.Idle, 0f, orbBreathe(0.0))
        val specs = fogCircles(VoiceOrbMode.Idle, energy, dark, notice = false, panelWidth = panelWidth)
        val circles = specs.map { c ->
            val side = fogLayerSize(c).roundToPx()
            val placeX = (FogBleedX + c.centerX).roundToPx() - side / 2
            val placeY = c.centerY.roundToPx() - side / 2
            FogCircleSpec(
                cx = (left + placeX + side / 2.0),
                cy = (top + placeY + side / 2.0),
                radius = c.diameter.toPx() / 2.0,
                sigma = c.blur.toPx().toDouble(),
                alpha = c.alpha.toDouble(),
                rgb = rgb(c.color),
            )
        }
        // Sampling: one point every 6 px within the window and the fog container.
        val x0 = left.toInt().coerceAtLeast(0)
        val x1 = (left + panelW + 2 * bleed).toInt().coerceAtMost(bitmap.width)
        val y0 = top.toInt().coerceAtLeast(0)
        val y1 = (top + height).toInt().coerceAtMost(bitmap.height)
        val xs = mutableListOf<Int>()
        val ys = mutableListOf<Int>()
        for (y in y0 until y1 step 6) for (x in x0 until x1 step 6) { xs += x; ys += y }
        val observed = Array(xs.size) { channels(bitmap.getPixel(xs[it], ys[it])) }
        FogModel(circles, rgb(bg), xs.toIntArray(), ys.toIntArray(), observed)
    }

    // ── Glow: union of three circles (later ones drawn on top) x numeric Gaussian convolution ──

    private inner class GlowModel(
        val centers: List<Pair<Double, Double>>,
        val radius: Double,
        val sigma: Double,
        val colors: List<DoubleArray>,
        val alpha: Double,
        val originX: Double,
        val originY: Double,
        val cells: Int,
        val bg: DoubleArray,
        val px: IntArray,
        val py: IntArray,
        val observed: Array<DoubleArray>,
    ) {
        /** Unblurred premultiplied RGBA grid ([CELL] px per cell, 4x4 supersampling). */
        private val source: Array<DoubleArray> = Array(4) { DoubleArray(cells * cells) }.also { src ->
            for (gy in 0 until cells) for (gx in 0 until cells) {
                var r = 0.0
                var g = 0.0
                var b = 0.0
                var a = 0.0
                for (sy in 0 until 4) for (sx in 0 until 4) {
                    val x = originX + (gx + (sx + 0.5) / 4) * CELL
                    val y = originY + (gy + (sy + 0.5) / 4) * CELL
                    val top = centers.indices.lastOrNull { hypot(x - centers[it].first, y - centers[it].second) <= radius }
                    if (top != null) {
                        r += colors[top][0]
                        g += colors[top][1]
                        b += colors[top][2]
                        a += 1.0
                    }
                }
                val k = gy * cells + gx
                src[0][k] = r / 16
                src[1][k] = g / 16
                src[2][k] = b / 16
                src[3][k] = a / 16
            }
        }

        /** Three channels at the sample points of (premultiplied color - background x coverage), i.e. out - bg = alpha * m. */
        private fun modelTerms(sigmaScale: Double): Array<DoubleArray> {
            val blurred = source.map { gaussBlur(it, cells, sigma * sigmaScale / CELL) }
            return Array(px.size) { j ->
                val gx = (px[j] + 0.5 - originX) / CELL - 0.5
                val gy = (py[j] + 0.5 - originY) / CELL - 0.5
                val cov = bilinear(blurred[3], cells, gx, gy)
                DoubleArray(3) { c -> bilinear(blurred[c], cells, gx, gy) - bg[c] * cov }
            }
        }

        /** Closed-form least squares for alpha: out - bg = g * m. */
        private fun solve(m: Array<DoubleArray>, fixed: Double?): Pair<Double, Double> {
            var ym = 0.0
            var mm = 0.0
            for (j in px.indices) for (c in 0 until 3) {
                val y = observed[j][c] - bg[c]
                ym += y * m[j][c]
                mm += m[j][c] * m[j][c]
            }
            val g = fixed ?: (ym / mm)
            var sum = 0.0
            for (j in px.indices) for (c in 0 until 3) {
                val e = observed[j][c] - bg[c] - g * m[j][c]
                sum += e * e
            }
            return g / alpha to sum
        }

        fun fit(): Fit {
            val unit = solve(modelTerms(1.0), alpha).second
            return fitScales(px.size, unit) { s -> solve(modelTerms(s), null) }
        }
    }

    private fun buildGlow(
        d: Density,
        dark: Boolean,
        orbX: Float,
        orbY: Float,
        orbW: Int,
        bg: Color,
        bitmap: Bitmap,
    ): GlowModel = with(d) {
        val mode = VoiceOrbMode.Idle
        val breathe = orbBreathe(0.0)
        val e = orbEnergy(mode, 0f, breathe)
        val phase = 0f
        val scale = orbScale(mode, e, breathe).toDouble()
        val look = orbLook(mode, e, 0f, dark, reduceMotion = false)
        // Replicates the VoiceAuroraOrb glow canvas: box outset = round(3 sigma), u = (canvas side - 2 x outset) / 200, centers at the orb box center; the whole orb then scales about the center by scale.
        val outset = orbGlowOutset(VoiceAuroraOrbSize)
        val canvasSide = orbW + 2 * outset.roundToPx()
        val box = canvasSide - 2f * outset.toPx()
        val u = box / ORB_CANVAS
        val cx = orbX + orbW / 2.0
        val cy = orbY + orbW / 2.0
        val centers = (0 until 3).map { i ->
            val a = 0.7f * phase + 2.1f * i
            (cx + scale * 18.0 * cos(a) * u) to (cy + scale * (8.0 + 14.0 * sin(a)) * u)
        }
        val radius = scale * (58.0 + 16.0 * e) * u
        val sigma = scale * (VoiceAuroraOrbSize / ORB_CANVAS * ORB_GLOW_SIGMA).toPx()
        val half = scale * canvasSide / 2.0
        val cells = ceil(2 * half / CELL).toInt()
        val originX = cx - cells * CELL / 2.0
        val originY = cy - cells * CELL / 2.0
        // Sampling: the ring outside the orb, r in [80u, 125u] (avoids the r78 stroke and the layer edge), one point every 2 px.
        val rIn = scale * 80.0 * u + 2.0
        val rOut = scale * 125.0 * u
        val xs = mutableListOf<Int>()
        val ys = mutableListOf<Int>()
        val x0 = floor(cx - rOut).toInt().coerceAtLeast(0)
        val x1 = ceil(cx + rOut).toInt().coerceAtMost(bitmap.width - 1)
        val y0 = floor(cy - rOut).toInt().coerceAtLeast(0)
        val y1 = ceil(cy + rOut).toInt().coerceAtMost(bitmap.height - 1)
        for (y in y0..y1 step 2) for (x in x0..x1 step 2) {
            val r = hypot(x + 0.5 - cx, y + 0.5 - cy)
            if (r in rIn..rOut) { xs += x; ys += y }
        }
        val observed = Array(xs.size) { channels(bitmap.getPixel(xs[it], ys[it])) }
        GlowModel(
            centers, radius, sigma.toDouble(), GLOW_COLORS.map(::rgb), look.glowAlpha.toDouble(),
            originX, originY, cells, rgb(bg), xs.toIntArray(), ys.toIntArray(), observed,
        )
    }

    // ── On-device sampling ──

    private class Shot(val bitmap: Bitmap)

    /** Launches MainActivity, swaps in the content, and after the frame settles, PixelCopies the whole window (including RenderEffect). */
    private fun capture(content: (ComponentActivity) -> Unit): Shot {
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val thread = HandlerThread("v1-pixel-copy").also { it.start() }
        try {
            scenario.onActivity { activity ->
                activity.setShowWhenLocked(true)
                activity.setTurnScreenOn(true)
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                activity.getSystemService(KeyguardManager::class.java)?.requestDismissKeyguard(activity, null)
                content(activity)
            }
            instrumentation.waitForIdleSync()
            SystemClock.sleep(SETTLE_MS)
            instrumentation.waitForIdleSync()
            var bitmap: Bitmap? = null
            var result = -1
            val latch = CountDownLatch(1)
            scenario.onActivity { activity ->
                val decor = activity.window.decorView
                val b = Bitmap.createBitmap(decor.width, decor.height, Bitmap.Config.ARGB_8888)
                PixelCopy.request(activity.window, b, { r -> result = r; bitmap = b; latch.countDown() }, Handler(thread.looper))
            }
            assertTrue("PixelCopy timed out", latch.await(10, TimeUnit.SECONDS))
            assertTrue("PixelCopy failed: $result", result == PixelCopy.SUCCESS)
            return Shot(bitmap!!)
        } finally {
            scenario.close()
            thread.quitSafely()
        }
    }

    private fun write(key: String, value: JSONObject) {
        val out = File(context.getExternalFilesDir("v1-results"), "blur.json")
        val json = runCatching { JSONObject(out.readText()) }.getOrElse { JSONObject() }
        json.put(key, value)
        out.writeText(json.toString(2))
    }

    private fun device() = "${Build.MANUFACTURER} ${Build.MODEL} sdk${Build.VERSION.SDK_INT}"

    private companion object {
        const val TAG = "VoiceV1"
        const val TOLERANCE = 0.03
        const val SETTLE_MS = 1_200L
        const val CELL = 4.0
        val PANEL_HEIGHT: Dp = 400.dp

        /** Glow circles = the first three colors of the user palette blobs (VoiceOrbArt UserPalette). */
        val GLOW_COLORS = listOf(Color(0xFF38D6E8), Color(0xFFE04FC0), Color(0xFF4F7BFF))

        fun f(v: Double) = "%.4f".format(v)
        fun f(v: Float) = "%.3f".format(v)

        fun channels(argb: Int) = doubleArrayOf(((argb shr 16) and 0xFF).toDouble(), ((argb shr 8) and 0xFF).toDouble(), (argb and 0xFF).toDouble())

        fun rgb(c: Color) = doubleArrayOf(c.red * 255.0, c.green * 255.0, c.blue * 255.0)

        /** Sub-pixel position where a monotone profile (high to low) first crosses [level]. */
        fun crossing(v: DoubleArray, level: Double): Double? {
            for (i in 0 until v.size - 1) {
                if (v[i] >= level && v[i + 1] < level) return i + (v[i] - level) / (v[i] - v[i + 1])
            }
            return null
        }

        /** Golden-section search for the minimum of [f] on [lo, hi]: returns (argument, value). */
        fun golden(lo: Double, hi: Double, f: (Double) -> Double): Pair<Double, Double> {
            val k = (sqrt(5.0) - 1) / 2
            var a = lo
            var b = hi
            var c = b - k * (b - a)
            var d = a + k * (b - a)
            var fc = f(c)
            var fd = f(d)
            repeat(40) {
                if (fc < fd) { b = d; d = c; fd = fc; c = b - k * (b - a); fc = f(c) } else { a = c; c = d; fc = fd; d = a + k * (b - a); fd = f(d) }
            }
            val x = (a + b) / 2
            return x to f(x)
        }

        /** Exponentially scaled I0: e^{-x} * I0(x) (Abramowitz-Stegun 9.8.1 / 9.8.2). */
        fun i0e(x: Double): Double {
            if (x < 3.75) {
                val t = (x / 3.75) * (x / 3.75)
                val i0 = 1 + t * (3.5156229 + t * (3.0899424 + t * (1.2067492 + t * (0.2659732 + t * (0.0360768 + t * 0.0045813)))))
                return i0 * exp(-x)
            }
            val t = 3.75 / x
            val p = 0.39894228 + t * (0.01328592 + t * (0.00225319 + t * (-0.00157565 + t * (0.00916281 +
                t * (-0.02057706 + t * (0.02635537 + t * (-0.01647633 + t * 0.00392377)))))))
            return p / sqrt(x)
        }

        /** Radial profile P(r) of a disk of radius R convolved with a 2D Gaussian of sigma; one cell per 1 px of r. */
        fun diskGaussTable(radius: Double, sigma: Double, rMax: Double): DoubleArray {
            val n = 240
            val h = radius / n
            val s2 = sigma * sigma
            return DoubleArray(ceil(rMax).toInt() + 2) { ri ->
                val r = ri.toDouble()
                var sum = 0.0
                for (k in 0..n) {
                    val rho = k * h
                    val v = rho / s2 * exp(-(r - rho) * (r - rho) / (2 * s2)) * i0e(r * rho / s2)
                    sum += v * if (k == 0 || k == n) 1.0 else if (k % 2 == 1) 4.0 else 2.0
                }
                sum * h / 3
            }
        }

        fun lookup(table: DoubleArray, r: Double): Double {
            val i = r.toInt().coerceIn(0, table.size - 2)
            val t = r - i
            return table[i] * (1 - t) + table[i + 1] * t
        }

        /** Separable Gaussian blur of a square grid; outside the grid is treated as transparent (decal). */
        fun gaussBlur(src: DoubleArray, n: Int, sigmaCells: Double): DoubleArray {
            val rad = ceil(4 * sigmaCells).toInt()
            val w = DoubleArray(2 * rad + 1) { exp(-((it - rad) * (it - rad)) / (2 * sigmaCells * sigmaCells)) }
            val sum = w.sum()
            for (i in w.indices) w[i] /= sum
            val tmp = DoubleArray(n * n)
            for (y in 0 until n) for (x in 0 until n) {
                var acc = 0.0
                for (k in -rad..rad) { val xx = x + k; if (xx in 0 until n) acc += w[k + rad] * src[y * n + xx] }
                tmp[y * n + x] = acc
            }
            val out = DoubleArray(n * n)
            for (y in 0 until n) for (x in 0 until n) {
                var acc = 0.0
                for (k in -rad..rad) { val yy = y + k; if (yy in 0 until n) acc += w[k + rad] * tmp[yy * n + x] }
                out[y * n + x] = acc
            }
            return out
        }

        fun bilinear(g: DoubleArray, n: Int, x: Double, y: Double): Double {
            val x0 = floor(x).toInt()
            val y0 = floor(y).toInt()
            val tx = x - x0
            val ty = y - y0
            fun at(i: Int, j: Int) = if (i in 0 until n && j in 0 until n) g[j * n + i] else 0.0
            return at(x0, y0) * (1 - tx) * (1 - ty) + at(x0 + 1, y0) * tx * (1 - ty) +
                at(x0, y0 + 1) * (1 - tx) * ty + at(x0 + 1, y0 + 1) * tx * ty
        }
    }
}
