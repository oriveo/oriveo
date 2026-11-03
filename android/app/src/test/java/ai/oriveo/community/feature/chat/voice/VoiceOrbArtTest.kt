package ai.oriveo.community.feature.chat.voice

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.DefaultLightBrandTuned
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Liquid-aurora orb and aurora haze (orb and aurora spec): pure-function values per mode, plus real rendering under both sdks. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VoiceOrbArtTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val eps = 1e-4f

    @Test
    fun scale_energy_and_phase_speed_per_mode() {
        val e = 0.5f
        val b = 0.8f
        assertEquals(1f + 0.16f * e, orbScale(VoiceOrbMode.User, e, b), eps)
        assertEquals(1f + 0.08f * e, orbScale(VoiceOrbMode.Ai, e, b), eps)
        assertEquals(1f + 0.025f * b, orbScale(VoiceOrbMode.Listen, e, b), eps)
        assertEquals(0.95f, orbScale(VoiceOrbMode.Think, e, b), eps)
        assertEquals(1f, orbScale(VoiceOrbMode.Idle, e, b), eps)
        assertEquals(1f, orbScale(VoiceOrbMode.Muted, e, b), eps)

        assertEquals(0.7f, orbEnergy(VoiceOrbMode.User, 0.7f, b), eps)
        assertEquals(0.63f, orbEnergy(VoiceOrbMode.Ai, 0.7f, b), eps)
        assertEquals(0.45f, orbEnergy(VoiceOrbMode.Think, 0.7f, b), eps)
        assertEquals(0.12f, orbEnergy(VoiceOrbMode.Listen, 0.7f, b), eps)
        assertEquals(0.05f, orbEnergy(VoiceOrbMode.Idle, 0.7f, b), eps)
        assertEquals(0.05f, orbEnergy(VoiceOrbMode.Muted, 0.7f, b), eps)

        assertEquals(0.22f, orbPhaseSpeed(VoiceOrbMode.Listen, e), eps)
        assertEquals(0.45f + 0.9f * e, orbPhaseSpeed(VoiceOrbMode.User, e), eps)
        assertEquals(1.25f, orbPhaseSpeed(VoiceOrbMode.Think, e), eps)
        assertEquals(0.4f + 0.6f * e, orbPhaseSpeed(VoiceOrbMode.Ai, e), eps)
        assertEquals(0.05f, orbPhaseSpeed(VoiceOrbMode.Muted, e), eps)
        assertEquals(0.10f, orbPhaseSpeed(VoiceOrbMode.Idle, e), eps)

        assertEquals(0.5f, orbBreathe(0.0), eps)
        // Envelope: rise with a 40 ms time constant to 63%, fall with a 200 ms time constant.
        assertEquals(1f - 0.36788f, envelopeStep(0f, 1f, 40f), 1e-3f)
        assertEquals(0.36788f, envelopeStep(1f, 0f, 200f), 1e-3f)
    }

    @Test
    fun muted_group_desaturates_and_dims() {
        val muted = orbLook(VoiceOrbMode.Muted, 0.05f, 0.9f, dark = true, reduceMotion = false)
        assertEquals(OrbLook(alpha = 0.55f, saturation = 0.15f, glowAlpha = 0.1f), muted)
        val listen = orbLook(VoiceOrbMode.Listen, 0f, 0f, dark = false, reduceMotion = false)
        assertEquals(1f, listen.alpha, eps)
        assertEquals(1f, listen.saturation, eps)
        assertEquals(0.38f, listen.glowAlpha, eps)
        assertEquals(0.55f + 0.45f * 0.5f, orbLook(VoiceOrbMode.Ai, 0.5f, 0.5f, dark = true, reduceMotion = false).glowAlpha, eps)
    }

    @Test
    fun fog_alpha_follows_level() {
        assertEquals(0.30f, fogAlpha(VoiceOrbMode.User, 0f, dark = false, index = 0), eps)
        assertEquals(0.65f, fogAlpha(VoiceOrbMode.User, 1f, dark = false, index = 0), eps)
        assertEquals(0.45f, fogAlpha(VoiceOrbMode.Ai, 0f, dark = true, index = 1), eps)
        assertEquals(0.75f, fogAlpha(VoiceOrbMode.Ai, 1f, dark = true, index = 1), eps)
        assertEquals(0.32f, fogAlpha(VoiceOrbMode.Listen, 1f, dark = false, index = 0), eps)
        assertEquals(0.55f, fogAlpha(VoiceOrbMode.Listen, 1f, dark = true, index = 0), eps)
        assertEquals(0.18f, fogAlpha(VoiceOrbMode.Idle, 0f, dark = false, index = 2), eps)
        assertEquals(0.35f, fogAlpha(VoiceOrbMode.Idle, 0f, dark = true, index = 2), eps)
        // Canvas blob 3 uses haze2: fixed at light .18 / dark .35, not level-driven.
        assertEquals(0.18f, fogAlpha(VoiceOrbMode.User, 1f, dark = false, index = 2), eps)
        assertEquals(0.35f, fogAlpha(VoiceOrbMode.Ai, 1f, dark = true, index = 2), eps)
        val quiet = fogCircles(VoiceOrbMode.User, 0.1f, dark = false, notice = false)
        val loud = fogCircles(VoiceOrbMode.User, 0.9f, dark = false, notice = false)
        assertEquals(3, loud.size)
        (0..1).forEach { assertTrue("circle $it", loud[it].alpha > quiet[it].alpha) }
        assertEquals(quiet[2].alpha, loud[2].alpha, eps)
        assertEquals(listOf(300.dp, 280.dp, 220.dp), loud.map { it.diameter })
        assertEquals(listOf(70.dp, 70.dp, 60.dp), loud.map { it.blur })
    }

    @Test
    fun orb_geometry_follows_the_200_canvas() {
        // 148 orb box = 200 canvas (includes glow margin); visible orb = 148 x 0.78.
        assertEquals(0.74f, OrbSpace(Size(148f, 148f)).u, eps)
        assertEquals(1.5f, OrbSpace(Size(300f, 300f)).u, eps)
        // When the draw area is larger than the orb box, scale by the orb box and stay centered.
        val padded = OrbSpace(Size(248f, 248f), box = 148f)
        assertEquals(0.74f, padded.u, eps)
        assertEquals(124f, padded.at(100f, 100f).x, eps)
        assertEquals(2f * ORB_CANVAS_RADIUS * 0.74f, 148f * 0.78f, eps)
        // Highlight and bottom reflection are the half-axes of SVG ellipses.
        assertEquals(OrbEllipse(82f, 58f, 52f, 32f), OrbHighlight)
        assertEquals(OrbEllipse(100f, 152f, 56f, 26f), OrbReflection)
    }

    @Test
    fun fog_frame_anchors_to_the_window_bottom() {
        // Canvas fog container bottom -120 relative to the full screen: bottom = panel height + panel bottom to window bottom + 120, height 520.
        val gapped = fogFrame(panelH = 300.dp, bottomGap = 34.dp)
        assertEquals(300.dp + 34.dp + 120.dp, gapped.bottom)
        assertEquals(300.dp + 34.dp + 120.dp - 520.dp, gapped.top)
        // Panel bottom is the window bottom: same as when anchored to the stage bottom.
        val flush = fogFrame(panelH = 300.dp, bottomGap = 0.dp)
        assertEquals(420.dp, flush.bottom)
        assertEquals(-100.dp, flush.top)
    }

    @Test
    fun orb_clips_to_the_r78_body_and_strokes_centered_on_it() {
        // Canvas clipPath r=78: the 148 orb box is clipped to a circle of radius 78u (u = 0.74), not the inscribed 74.
        val outline = OrbBodyShape.createOutline(Size(148f, 148f), LayoutDirection.Ltr, Density(1f))
        val rect = (outline as Outline.Rounded).roundRect
        val r = 78f * 0.74f
        assertEquals(74f - r, rect.left, eps)
        assertEquals(74f - r, rect.top, eps)
        assertEquals(74f + r, rect.right, eps)
        assertEquals(74f + r, rect.bottom, eps)
        assertEquals(r, rect.topLeftCornerRadius.x, eps)
        // When the draw area is larger than the orb box (glow margin), still scale by the orb box short side and center.
        val wide = (OrbBodyShape.createOutline(Size(200f, 148f), LayoutDirection.Ltr, Density(1f)) as Outline.Rounded).roundRect
        assertEquals(100f - r, wide.left, eps)
        // Stroke centerline at r78, width 1.2u.
        assertEquals(OrbRim(radius = r, width = 1.2f * 0.74f), orbRim(0.74f))
    }

    @Test
    fun blur_radius_inverts_hwui_sigma() {
        // hwui: sigma = 0.57735·r + 0.5.
        assertEquals(0f, blurRadiusPx(0.5f), 0f)
        assertEquals(0f, blurRadiusPx(0.2f), 0f)
        assertEquals(0f, blurRadiusPx(0f), 0f)
        assertEquals(10f / 0.57735f, blurRadiusPx(10.5f), 1e-3f)
        val sigma = 70f * 2.75f
        assertEquals(sigma, 0.57735f * blurRadiusPx(sigma) + 0.5f, 1e-3f)
        // Canvas sigma: color blobs 14, glow 22 (200 canvas units).
        assertEquals(14f, ORB_BLOB_SIGMA, 0f)
        assertEquals(22f, ORB_GLOW_SIGMA, 0f)
    }

    @Test
    fun glow_and_fog_layers_leave_three_sigma_of_room() {
        val glowSigma = 22f * 148f / 200f
        assertTrue("glow outset ${orbGlowOutset(148.dp)}", orbGlowOutset(148.dp).value >= 3f * glowSigma - eps)
        listOf(false, true).forEach { notice ->
            fogCircles(VoiceOrbMode.Listen, 0f, dark = false, notice = notice).forEach { c ->
                assertTrue("fog layer $c", fogLayerSize(c).value >= c.diameter.value + 6f * c.blur.value - eps)
            }
        }
        // Container: 40 bleed on each side, height 520, bottom edge extends 120 past the panel.
        assertEquals(40.dp, FogBleedX)
        assertEquals(520.dp, FogHeight)
        assertEquals(120.dp, FogBelow)
    }

    @Test
    fun only_ai_switches_palette_and_think_keeps_user_fog_colors() {
        assertTrue(usesAiPalette(VoiceOrbMode.Ai))
        VoiceOrbMode.entries.filter { it != VoiceOrbMode.Ai }.forEach { assertFalse("$it", usesAiPalette(it)) }
        val user = listOf(Color(0xFF8B5CF6), Color(0xFF4F7BFF), Color(0xFFE04FC0))
        assertEquals(user, fogCircles(VoiceOrbMode.Think, 0.45f, dark = false, notice = false).map { it.color })
        assertEquals(
            listOf(Color(0xFF22D3EE), Color(0xFF4F7BFF), Color(0xFF7C5CFF)),
            fogCircles(VoiceOrbMode.Ai, 0.5f, dark = false, notice = false).map { it.color },
        )
    }

    @Test
    fun palette_switch_interpolates_over_200_ms() {
        val clock = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        val user = fogCircles(VoiceOrbMode.User, 0.5f, dark = false, notice = false, aiMix = 0f).map { it.color }
        val ai = fogCircles(VoiceOrbMode.Ai, 0.5f, dark = false, notice = false, aiMix = 1f).map { it.color }
        assertEquals(DefaultLightBrandTuned.homeViolet, user[0])
        // Switching to AI speaking: the first frame does not jump in color; halfway at 100 ms, settled at 200 ms.
        var now = 0L
        clock.step(now, 0.5f, VoiceOrbMode.Ai, reduceMotion = false)
        assertEquals(0f, clock.aiMix, eps)
        repeat(6) {
            now += 16_666_667L
            clock.step(now, 0.5f, VoiceOrbMode.Ai, reduceMotion = false)
        }
        assertEquals(0.5f, clock.aiMix, 0.01f)
        val mid = fogCircles(VoiceOrbMode.Ai, 0.5f, dark = false, notice = false, aiMix = clock.aiMix).map { it.color }
        assertTrue("mid ${mid[0]}", mid[0] != user[0] && mid[0] != ai[0])
        assertEquals(user[1], mid[1])
        repeat(6) {
            now += 16_666_667L
            clock.step(now, 0.5f, VoiceOrbMode.Ai, reduceMotion = false)
        }
        assertEquals(1f, clock.aiMix, eps)
        assertEquals(ai, fogCircles(VoiceOrbMode.Ai, 0.5f, dark = false, notice = false, aiMix = clock.aiMix).map { it.color })
    }

    @Test
    fun palette_switch_eases_in_and_out_and_cuts_under_reduced_motion() {
        // 200 ms ease-in-out: start and end are slower than linear, midpoint symmetric at half.
        val clock = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        var now = 0L
        clock.step(now, 0.5f, VoiceOrbMode.Ai, reduceMotion = false)
        repeat(3) {
            now += 16_666_667L
            clock.step(now, 0.5f, VoiceOrbMode.Ai, reduceMotion = false)
        }
        val early = clock.aiMix
        assertTrue("Should be slower than linear 0.25 at 50 ms: $early", early > 0f && early < 0.2f)
        repeat(6) {
            now += 16_666_667L
            clock.step(now, 0.5f, VoiceOrbMode.Ai, reduceMotion = false)
        }
        val late = clock.aiMix
        assertTrue("Should be faster than linear 0.75 at 150 ms: $late", late > 0.8f && late < 1f)
        assertEquals(0f, paletteMixEased(0f), 0f)
        assertEquals(0.5f, paletteMixEased(0.5f), 0.01f)
        assertEquals(1f, paletteMixEased(1f), 0f)
        // Reduced motion: the first frame jumps directly to the target color, no interpolation.
        val reduced = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        reduced.step(0L, 0.5f, VoiceOrbMode.Ai, reduceMotion = true)
        assertEquals(1f, reduced.aiMix, 0f)
        reduced.step(16_666_667L, 0.5f, VoiceOrbMode.User, reduceMotion = true)
        assertEquals(0f, reduced.aiMix, 0f)
    }

    @Test
    fun muted_stops_the_frame_loop_once_the_palette_settles() {
        val clock = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        clock.step(0L, 0.8f, VoiceOrbMode.User, reduceMotion = false)
        clock.step(16_666_667L, 0.8f, VoiceOrbMode.User, reduceMotion = false)
        assertTrue(clock.needsFrames(VoiceOrbMode.User))
        assertFalse(clock.needsFrames(VoiceOrbMode.Muted))
        // Muted while AI speaking: the palette first returns to the user color over 200 ms, then the frame loop stops; the static picture keeps the last frame (phase no longer advances, energy takes the muted value .05).
        val fromAi = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.Ai)
        fromAi.step(0L, 0.6f, VoiceOrbMode.Ai, reduceMotion = false)
        fromAi.step(16_666_667L, 0.6f, VoiceOrbMode.Ai, reduceMotion = false)
        val phase = fromAi.phase
        assertTrue(fromAi.needsFrames(VoiceOrbMode.Muted))
        var now = 16_666_667L
        repeat(13) {
            now += 16_666_667L
            fromAi.step(now, 0.6f, VoiceOrbMode.Muted, reduceMotion = false)
        }
        assertEquals(0f, fromAi.aiMix, eps)
        assertFalse(fromAi.needsFrames(VoiceOrbMode.Muted))
        assertEquals(phase, fromAi.phase, eps)
        assertEquals(0.05f, fromAi.energy, eps)
    }

    @Test
    fun fog_steps_at_most_30_fps_and_orb_at_most_60_fps() {
        fun stepTimes(interval: Long, vsyncNanos: Long): List<Long> {
            val clock = AuroraClock(interval, VoiceOrbMode.Listen)
            val stepped = mutableListOf<Long>()
            var now = 0L
            repeat(240) {
                if (clock.step(now, 0.3f, VoiceOrbMode.Listen, reduceMotion = false)) stepped += now
                now += vsyncNanos
            }
            return stepped
        }
        listOf(16_666_667L, 8_333_333L).forEach { vsync ->
            val fog = stepTimes(FOG_FRAME_INTERVAL_NANOS, vsync)
            assertTrue("fog never stepped", fog.size > 10)
            fog.zipWithNext { a, b -> assertTrue("fog gap ${b - a}", b - a >= 33_000_000L) }
            val orb = stepTimes(ORB_FRAME_INTERVAL_NANOS, vsync)
            assertTrue("orb never stepped", orb.size > 10)
            orb.zipWithNext { a, b -> assertTrue("orb gap ${b - a}", b - a >= 16_000_000L) }
        }
    }

    @Test
    fun fog_circles_sit_at_canvas_positions_and_scale_x_with_panel_width() {
        val at390 = fogCircles(VoiceOrbMode.Listen, 0f, dark = false, notice = false, panelWidth = 390.dp)
        assertEquals(listOf(150.dp, 290.dp, 220.dp), at390.map { it.centerX })
        assertEquals(listOf(260.dp, 310.dp, 340.dp), at390.map { it.centerY })
        assertEquals(listOf(1f, -1f, 0f), at390.map { it.drift })
        val at780 = fogCircles(VoiceOrbMode.Listen, 0f, dark = false, notice = false, panelWidth = 780.dp)
        assertEquals(listOf(300.dp, 580.dp, 440.dp), at780.map { it.centerX })
        assertEquals(listOf(260.dp, 310.dp, 340.dp), at780.map { it.centerY })
    }

    @Test
    fun notice_keeps_circle_one_and_turns_circle_two_amber() {
        val fog = fogCircles(VoiceOrbMode.Listen, 0.5f, dark = true, notice = true)
        // When not hearing clearly, blob 3 is not drawn: alpha 0 padding, three-blob structure unchanged so it interpolates blob by blob with normal.
        assertEquals(3, fog.size)
        assertEquals(0.40f, fog[0].alpha, eps)
        assertEquals(Color(0xFFF59E0B), fog[1].color)
        assertEquals(0.20f, fog[1].alpha, eps)
        assertEquals(80.dp, fog[1].blur)
        assertEquals(0f, fog[2].alpha, eps)
    }

    @Test
    fun notice_switch_interpolates_amber_over_200_ms_and_cuts_under_reduced_motion() {
        val plain = fogCircles(VoiceOrbMode.Listen, 0f, dark = false, notice = false)
        val amber = fogCircles(VoiceOrbMode.Listen, 0f, dark = false, notice = true)
        val clock = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.Listen)
        var now = 0L
        clock.step(now, 0f, VoiceOrbMode.Listen, reduceMotion = false, notice = true)
        assertEquals(0f, clock.noticeMix, 0f)
        assertTrue(clock.needsFrames(VoiceOrbMode.Muted, notice = true))
        repeat(6) {
            now += 16_666_667L
            clock.step(now, 0f, VoiceOrbMode.Listen, reduceMotion = false, notice = true)
        }
        assertTrue("Mid-interpolation at 100 ms: ${clock.noticeMix}", clock.noticeMix > 0f && clock.noticeMix < 1f)
        val mid = fogCircles(VoiceOrbMode.Listen, 0f, dark = false, notice = true, noticeMix = clock.noticeMix)
        assertEquals(3, mid.size)
        assertTrue(mid[1].color != plain[1].color && mid[1].color != amber[1].color)
        assertTrue(mid[2].alpha > 0f && mid[2].alpha < plain[2].alpha)
        repeat(7) {
            now += 16_666_667L
            clock.step(now, 0f, VoiceOrbMode.Listen, reduceMotion = false, notice = true)
        }
        assertEquals(1f, clock.noticeMix, 0f)
        assertEquals(amber, fogCircles(VoiceOrbMode.Listen, 0f, dark = false, notice = true, noticeMix = clock.noticeMix))
        val reduced = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.Listen)
        reduced.hold(0f, VoiceOrbMode.Listen, notice = true)
        assertEquals(1f, reduced.noticeMix, 0f)
        reduced.hold(0f, VoiceOrbMode.Listen, notice = false)
        assertEquals(0f, reduced.noticeMix, 0f)
    }

    @Test
    fun reduced_motion_runs_no_frame_loop_and_each_hold_redraws_once() {
        val clock = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        assertFalse(clock.needsFrames(VoiceOrbMode.User, reduceMotion = true))
        assertFalse(clock.needsFrames(VoiceOrbMode.Think, reduceMotion = true))
        val before = clock.frame.longValue
        clock.hold(0.5f, VoiceOrbMode.User, notice = false)
        assertEquals(before + 1, clock.frame.longValue)
        assertEquals(0.5f, clock.level, eps)
        assertEquals(0f, clock.energy, eps)
        assertEquals(0.6f + 0.4f * 0.5f, orbLook(VoiceOrbMode.User, clock.energy, clock.level, dark = false, reduceMotion = true).alpha, eps)
        clock.hold(0.9f, VoiceOrbMode.Ai, notice = false)
        assertEquals(before + 2, clock.frame.longValue)
        assertEquals(1f, clock.aiMix, 0f)
        assertEquals(0.96f, orbLook(VoiceOrbMode.Ai, clock.energy, clock.level, dark = false, reduceMotion = true).alpha, eps)
    }

    @Test
    fun orb_alpha_reads_the_raw_level_not_the_envelope() {
        val clock = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        clock.step(0L, 0f, VoiceOrbMode.User, reduceMotion = false)
        clock.step(16_666_667L, 0.8f, VoiceOrbMode.User, reduceMotion = false)
        assertTrue("Envelope has not caught up yet: ${clock.envelope}", clock.envelope < 0.8f)
        assertEquals(0.8f, clock.level, eps)
        assertEquals(0.92f, orbLook(VoiceOrbMode.User, clock.energy, clock.level, dark = false, reduceMotion = true).alpha, eps)
    }

    /** Advance frame by frame at [hz]: first one frame with dt = 0 to land on the start, then one frame per value in [levels]; returns each frame's (including the start) first-stage a, second-stage b, and energy. */
    private fun driveEnvelope(hz: Int, levels: List<Float>): Triple<List<Float>, List<Float>, List<Float>> {
        // At 120 Hz the frame gap is under the orb's 16 ms frame limit; no limiting here, this measures the filter only.
        val clock = AuroraClock(1L, VoiceOrbMode.User)
        val dt = 1_000_000_000.0 / hz
        clock.step(0L, 0f, VoiceOrbMode.User, reduceMotion = false)
        val a = mutableListOf(clock.envelope)
        val b = mutableListOf(clock.smoothed)
        val e = mutableListOf(clock.energy)
        levels.forEachIndexed { i, g ->
            assertTrue(clock.step(((i + 1) * dt).toLong(), g, VoiceOrbMode.User, reduceMotion = false))
            a += clock.envelope
            b += clock.smoothed
            e += clock.energy
        }
        return Triple(a, b, e)
    }

    private fun maxSecondDiff(xs: List<Float>): Float =
        (1 until xs.size - 1).maxOf { kotlin.math.abs(xs[it + 1] - 2f * xs[it] + xs[it - 1]) }

    @Test
    fun envelopeTwoStageStep() {
        // Constant level 1: start a = b = 0; after first-stage 40 / 200 ms, the second stage (24 ms) follows, and energy uses the second stage.
        val (_, b60, e60) = driveEnvelope(60, List(12) { 1f })
        assertEquals(0.541100f, b60[3], 1e-5f)
        assertEquals(0.847057f, b60[6], 1e-5f)
        assertEquals(0.986347f, b60[12], 1e-5f)
        assertEquals(4, b60.indexOfFirst { it >= 0.632121f })
        assertEquals(b60, e60)
        val (_, b120, _) = driveEnvelope(120, List(24) { 1f })
        assertEquals(0.509031f, b120[6], 1e-5f)
        assertEquals(0.833876f, b120[12], 1e-5f)
        assertEquals(0.985061f, b120[24], 1e-5f)
        assertEquals(8, b120.indexOfFirst { it >= 0.632121f })
    }

    @Test
    fun envelopeStaircaseSmooth() {
        // 15 Hz level steps: 8 frames per level at 120 Hz, 4 frames per level at 60 Hz.
        val stairs = listOf(0.2f, 0.6f, 0.3f, 0.8f, 0.5f, 0.9f, 0.4f, 0.7f, 0.2f, 0f, 0.5f, 1f, 0.6f, 0.1f)
        val (a120, b120, _) = driveEnvelope(120, stairs.flatMap { g -> List(8) { g } })
        assertEquals(0.027111f, maxSecondDiff(b120), 1e-5f)
        assertEquals(0.668129f, b120.last(), 1e-5f)
        assertEquals(0.093291f, maxSecondDiff(a120), 1e-5f)
        val (a60, b60, _) = driveEnvelope(60, stairs.flatMap { g -> List(4) { g } })
        assertEquals(0.083278f, maxSecondDiff(b60), 1e-5f)
        assertEquals(0.658897f, b60.last(), 1e-5f)
        assertEquals(0.167383f, maxSecondDiff(a60), 1e-5f)
    }

    @Test
    fun modeSwitchEasesScale() {
        // User speaking E≈1 (1.16) to thinking, 60 Hz 200 ms ease-in-out, no single-frame jump.
        val frame = 16_666_667L
        val clock = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        var now = 0L
        clock.step(now, 1f, VoiceOrbMode.User, reduceMotion = false)
        repeat(120) {
            now += frame
            clock.step(now, 1f, VoiceOrbMode.User, reduceMotion = false)
        }
        assertEquals(1.16f, clock.scale, 1e-3f)
        assertEquals(1f, clock.energy, 1e-3f)
        val scales = mutableListOf(clock.scale)
        val energies = mutableListOf(clock.energy)
        repeat(13) {
            now += frame
            clock.step(now, 1f, VoiceOrbMode.Think, reduceMotion = false)
            // The target energy for the haze does not go through easing: switching to thinking gives .45 on the same frame.
            assertEquals(0.45f, clock.targetEnergy, 0f)
            scales += clock.scale
            energies += clock.energy
        }
        for (i in 1 until scales.size) {
            assertTrue("Frame $i scale delta ${scales[i] - scales[i - 1]}", scales[i] - scales[i - 1] in -0.04f..0f)
            assertTrue("Frame $i energy delta ${energies[i] - energies[i - 1]}", energies[i] - energies[i - 1] in -0.10f..0f)
        }
        assertTrue("The first frame should not already be settled: ${scales[1]}", scales[1] > 1.1f)
        assertEquals(0.95f, scales.last(), 1e-6f)
        assertEquals(0.45f, energies.last(), 1e-6f)

        // Re-triggering mid-transition (speaking -> thinking -> speaking): the first 6 frames are still transitioning; restarting from the first frame does not jump, and it is back to 1.16 within 200 ms.
        val again = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        var t = 0L
        again.step(t, 1f, VoiceOrbMode.User, reduceMotion = false)
        repeat(120) {
            t += frame
            again.step(t, 1f, VoiceOrbMode.User, reduceMotion = false)
        }
        val path = mutableListOf(again.scale)
        repeat(6) {
            t += frame
            again.step(t, 1f, VoiceOrbMode.Think, reduceMotion = false)
            path += again.scale
            assertTrue("Thinking frame ${it + 1} is still transitioning: ${again.scale}", again.scale > 1.0f)
        }
        repeat(12) {
            t += frame
            again.step(t, 1f, VoiceOrbMode.User, reduceMotion = false)
            path += again.scale
        }
        for (i in 1 until path.size) {
            assertTrue("Frame $i scale delta ${path[i] - path[i - 1]}", kotlin.math.abs(path[i] - path[i - 1]) <= 0.04f)
        }
        assertEquals(1.16f, again.scale, 1e-3f)

        // Reduced motion snaps directly: scale stays 1, E recorded as 0.
        val reduced = AuroraClock(ORB_FRAME_INTERVAL_NANOS, VoiceOrbMode.User)
        reduced.step(0L, 1f, VoiceOrbMode.User, reduceMotion = true)
        reduced.step(frame, 1f, VoiceOrbMode.Think, reduceMotion = true)
        assertEquals(1f, reduced.scale, 0f)
        assertEquals(0f, reduced.energy, 0f)

        // Muted group snaps directly: user speaking 1.16 goes to 1 on the next muted frame; releasing mute also snaps to the new mode target.
        now += frame
        clock.step(now, 1f, VoiceOrbMode.User, reduceMotion = false)
        repeat(30) {
            now += frame
            clock.step(now, 1f, VoiceOrbMode.User, reduceMotion = false)
        }
        now += frame
        clock.step(now, 1f, VoiceOrbMode.Muted, reduceMotion = false)
        assertEquals(1f, clock.scale, 0f)
        assertEquals(0.05f, clock.energy, 0f)
        assertEquals(0.05f, clock.targetEnergy, 0f)
        now += frame
        clock.step(now, 0f, VoiceOrbMode.Think, reduceMotion = false)
        assertEquals(0.95f, clock.scale, 0f)
        assertEquals(0.45f, clock.energy, 0f)
    }

    @Test
    fun reduce_motion_only_changes_alpha() {
        VoiceOrbMode.entries.forEach { mode ->
            assertEquals("$mode scale", 1f, orbScale(mode, 0.8f, 1f, reduceMotion = true), eps)
            assertEquals("$mode phase", 0f, orbPhaseSpeed(mode, 0.8f, reduceMotion = true), eps)
        }
        assertEquals(0.6f, orbLook(VoiceOrbMode.User, 0f, 0f, dark = false, reduceMotion = true).alpha, eps)
        assertEquals(0.6f + 0.4f * 0.5f, orbLook(VoiceOrbMode.User, 0.5f, 0.5f, dark = false, reduceMotion = true).alpha, eps)
        // Under reduced motion E is recorded as 0: the glow stays at the base value and does not change with level.
        assertEquals(0.38f, orbLook(VoiceOrbMode.User, 0.9f, 0.9f, dark = false, reduceMotion = true).glowAlpha, eps)
        assertEquals(0.55f, orbLook(VoiceOrbMode.Ai, 0.9f, 0.9f, dark = true, reduceMotion = true).glowAlpha, eps)
        // Under reduced motion the jitter becomes an alpha flash: dims at the midpoint, restores at the end.
        assertEquals(0.6f, shakeAlpha(0.5f), eps)
        assertEquals(1f, shakeAlpha(1f), eps)
        assertEquals(0f, shakeOffsetDp(1f), eps)
    }

    @Test
    fun stage_clock_override_freezes_time_and_phase_and_draws_the_regular_look() {
        var think: AuroraClock? = null
        var ai: AuroraClock? = null
        var fog: AuroraClock? = null
        val level = MutableStateFlow(0.5f)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            // The sample entry supplies the clock override; even if the caller judges reduced motion from the system setting, the clock still uses the usual look.
            CompositionLocalProvider(LocalVoiceStageClockOverride provides 0L) {
                think = rememberAuroraClock(VoiceOrbMode.Think, level, reduceMotion = true, ORB_FRAME_INTERVAL_NANOS)
                fog = rememberAuroraClock(VoiceOrbMode.Think, level, reduceMotion = true, FOG_FRAME_INTERVAL_NANOS, followsLevel = false)
            }
            CompositionLocalProvider(LocalVoiceStageClockOverride provides 5_000L) {
                ai = rememberAuroraClock(VoiceOrbMode.Ai, level, reduceMotion = false, ORB_FRAME_INTERVAL_NANOS)
            }
        }
        composeRule.waitForIdle()
        val t = checkNotNull(think)
        val frames = t.frame.longValue
        assertEquals(0.0, t.tMs, 0.0)
        assertEquals(0f, t.phase, 0f)
        assertEquals(0.0, checkNotNull(fog).tMs, 0.0)
        // No frame loop: further waiting does not advance it.
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.waitForIdle()
        assertEquals(frames, t.frame.longValue)
        assertEquals(0.0, t.tMs, 0.0)
        // Thinking: scale 0.95 applies (reduced motion treated as off).
        val reduce = stageReduceMotion(0L, systemReduceMotion = true)
        assertFalse(reduce)
        assertEquals(0.95f, orbScale(VoiceOrbMode.Think, t.energy, t.breathe, reduce), eps)
        assertEquals(0.45f, t.energy, eps)
        // Clock at 5 s: tMs is pinned to that value, phase = that time x phase speed, energy = level via the envelope.
        val a = checkNotNull(ai)
        assertEquals(5_000.0, a.tMs, 0.0)
        assertEquals(orbBreathe(5_000.0), a.breathe, eps)
        assertEquals(0.9f * 0.5f, a.energy, eps)
        assertEquals(5f * orbPhaseSpeed(VoiceOrbMode.Ai, a.energy), a.phase, eps)
        assertEquals(1f, a.aiMix, 0f)
        // Orb alpha does not use the reduced-motion formula (.6 + .4 x level = .8); the usual value is 1.
        val look = orbLook(VoiceOrbMode.Ai, a.energy, a.level, dark = false, reduceMotion = reduce)
        assertEquals(1f, look.alpha, 0f)
        assertEquals(0.38f + 0.45f * a.energy, look.glowAlpha, eps)
        // Production (no override) follows the system setting.
        assertTrue(stageReduceMotion(null, systemReduceMotion = true))
        assertFalse(stageReduceMotion(null, systemReduceMotion = false))
        activity.finish()
    }

    @Test
    fun reduced_motion_fog_clock_ignores_level_and_redraws_only_on_mode_or_notice_change() {
        var fog: AuroraClock? = null
        var orb: AuroraClock? = null
        var mode by mutableStateOf(VoiceOrbMode.User)
        var notice by mutableStateOf(false)
        val level = MutableStateFlow(0.2f)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            fog = rememberAuroraClock(mode, level, reduceMotion = true, FOG_FRAME_INTERVAL_NANOS, notice, followsLevel = false)
            orb = rememberAuroraClock(mode, level, reduceMotion = true, ORB_FRAME_INTERVAL_NANOS)
        }
        composeRule.waitForIdle()
        val fogFrames = checkNotNull(fog).frame.longValue
        val orbFrames = checkNotNull(orb).frame.longValue
        // Reduced motion E=0: the fog picture does not change with level and is not redrawn; the orb still redraws with level.
        level.value = 0.7f
        composeRule.waitForIdle()
        level.value = 0.4f
        composeRule.waitForIdle()
        assertEquals(fogFrames, fog!!.frame.longValue)
        assertEquals(orbFrames + 2, orb!!.frame.longValue)
        notice = true
        composeRule.waitForIdle()
        assertEquals(fogFrames + 1, fog!!.frame.longValue)
        assertEquals(1f, fog!!.noticeMix, 0f)
        mode = VoiceOrbMode.Ai
        composeRule.waitForIdle()
        assertEquals(fogFrames + 2, fog!!.frame.longValue)
        assertEquals(1f, fog!!.aiMix, 0f)
        activity.finish()
    }

    @Test
    fun renders_with_render_effect_blur_on_sdk_34() {
        assertEquals(VoiceOrbBlur.RenderEffect, renderBoth())
    }

    @Test
    @Config(sdk = [30])
    fun renders_with_radial_fallback_on_sdk_30() {
        assertEquals(VoiceOrbBlur.RadialFallback, renderBoth())
    }

    /** The orb picks blur by sdk; fog draws a precomputed gradient in both sdks (independent of the orb's blur type). */
    private fun renderBoth(): VoiceOrbBlur {
        var orbBlur: VoiceOrbBlur? = null
        var fogPaint: VoiceFogPaint? = null
        val level = MutableStateFlow(0.6f)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = true) {
                VoiceAuroraFog(
                    mode = VoiceOrbMode.User,
                    level = level,
                    notice = false,
                    modifier = Modifier.fillMaxWidth().height(300.dp),
                    onComposed = { fogPaint = it },
                )
                VoiceAuroraOrb(mode = VoiceOrbMode.User, level = level, nudges = 0, onComposed = { orbBlur = it })
            }
        }
        composeRule.mainClock.advanceTimeBy(500)
        composeRule.waitForIdle()
        activity.finish()
        assertEquals(VoiceFogPaint.DiscGradient, fogPaint)
        return checkNotNull(orbBlur) { "the orb never composed" }
    }

    @Test
    fun fogDiscProfile_matches_disc_convolved_with_gaussian() {
        val cases = listOf(
            Triple(300.0, 70.0, listOf(0.0 to 0.899331, 150.0 to 0.403950, 220.0 to 0.115670, 290.0 to 0.015066)),
            Triple(220.0, 60.0, listOf(0.0 to 0.813730, 110.0 to 0.386054)),
        )
        cases.forEach { (d, sigma, points) ->
            points.forEach { (rho, want) ->
                assertEquals("P($d, $sigma, ρ=$rho)", want, fogDiscProfile(rho, d / 2.0, sigma), 2e-4)
            }
        }
        // 41 evenly spaced stops covering [0, R+4 sigma], last stop 0; linear interpolation vs the analytic profile differs by <= 1e-3.
        listOf(300f to 70f, 280f to 70f, 220f to 60f, 280f to 80f, 280f to 75f).forEach { (d, sigma) ->
            val stops = fogProfile(d, sigma)
            assertEquals(FOG_PROFILE_STOPS, stops.size)
            assertEquals(0f, stops.last(), 0f)
            val extent = d / 2.0 + 4.0 * sigma
            val step = extent / (FOG_PROFILE_STOPS - 1)
            for (k in 0 until 400) {
                val rho = extent * k / 400.0
                val i = (rho / step).toInt().coerceAtMost(FOG_PROFILE_STOPS - 2)
                val f = (rho - i * step) / step
                val interp = stops[i] + (stops[i + 1] - stops[i]) * f
                assertEquals("($d, $sigma) ρ=$rho", fogDiscProfile(rho, d / 2.0, sigma.toDouble()), interp, 1e-3)
            }
        }
        // Cache keyed by sigma rounded to 0.5: the same key returns the same instance.
        assertTrue(fogProfile(280f, 75.1f) === fogProfile(280f, 74.9f))
    }

    @Test
    fun fogGradientMatchesDiscBlur() {
        // A single blob (diameter 300, sigma 70, alpha .4) drawn natively on light / dark backgrounds; expected values are computed independently: a 4x4 subsampled disc coverage grid convolved with a per-pixel Gaussian,
        // without calling the production profile function; compare per pixel over 8 directions against bg x (1-alpha P) + color x alpha P per channel, <= 1.5/255.
        val d = 300f
        val sigma = 70.0
        val alpha = 0.4f
        val color = Color(0xFF8B5CF6)
        val side = (d + 8f * sigma.toFloat()).toInt()
        val c = side / 2
        val r = d / 2.0
        // Disc coverage: only the disc's bounding box [c-R, c+R) is stored.
        val lo = (c - r).toInt()
        val n = (2 * r).toInt()
        val disk = Array(n) { i ->
            DoubleArray(n) { j ->
                var hit = 0
                for (si in 0 until 4) for (sj in 0 until 4) {
                    val px = lo + i + (si + 0.5) / 4.0 - c
                    val py = lo + j + (sj + 0.5) / 4.0 - c
                    if (px * px + py * py <= r * r) hit++
                }
                hit / 16.0
            }
        }
        val gauss = DoubleArray(side + n) { k -> kotlin.math.exp(-(k * k) / (2.0 * sigma * sigma)) / (kotlin.math.sqrt(2.0 * kotlin.math.PI) * sigma) }
        fun coverage(x: Int, y: Int): Double {
            var sum = 0.0
            for (i in 0 until n) {
                val gx = gauss[kotlin.math.abs(x - (lo + i))]
                val row = disk[i]
                var acc = 0.0
                for (j in 0 until n) acc += row[j] * gauss[kotlin.math.abs(y - (lo + j))]
                sum += gx * acc
            }
            return sum
        }
        val directions = listOf(1 to 0, 1 to 1, 0 to 1, -1 to 1, -1 to 0, -1 to -1, 0 to -1, 1 to -1)
        val samples = directions.flatMap { (dx, dy) ->
            generateSequence(0) { it + 1 }
                .map { k -> (c + dx * k) to (c + dy * k) }
                .takeWhile { (x, y) -> x in 0 until side && y in 0 until side }
                .toList()
        }.distinct()
        val expected = samples.map { (x, y) -> (alpha * coverage(x, y)).toFloat() }
        listOf(Color.White, Color.Black, Color(0xFF101014)).forEach { bg ->
            val image = ImageBitmap(side, side)
            val cache = FogBrushCache()
            CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, Canvas(image), Size(side.toFloat(), side.toFloat())) {
                drawRect(bg)
                drawFogDisc(cache, color, alpha, d.dp, sigma.toFloat().dp)
            }
            val pixels = image.toPixelMap()
            var worst = 0f
            var at = 0 to 0
            samples.forEachIndexed { idx, (x, y) ->
                val p = expected[idx]
                val got = pixels[x, y]
                listOf(
                    got.red to bg.red * (1f - p) + color.red * p,
                    got.green to bg.green * (1f - p) + color.green * p,
                    got.blue to bg.blue * (1f - p) + color.blue * p,
                ).forEach { (g, w) ->
                    val e = kotlin.math.abs(g - w)
                    if (e > worst) {
                        worst = e
                        at = x to y
                    }
                }
            }
            assertTrue("bg $bg worst ${worst * 255f}/255 at $at", worst <= 1.5f / 255f + 1e-4f)
        }
    }

    @Test
    fun fogBrushCacheIndexesAlphaBucketsLazily() {
        // Alpha rounded to 1/256 levels: the same level reuses the same brush, returning to an old level does not rebuild; the table is discarded whole when color changes.
        val cache = FogBrushCache()
        val profile = fogProfile(300f, 70f)
        val violet = Color(0xFF8B5CF6)
        val a = cache.brush(violet, 0.5f, profile, 430f)
        assertTrue(a === cache.brush(violet, 0.5f + 0.4f / 256f, profile, 430f))
        val b = cache.brush(violet, 0.5f + 1f / 256f, profile, 430f)
        assertTrue(a !== b)
        assertTrue(a === cache.brush(violet, 0.5f, profile, 430f))
        assertTrue(b === cache.brush(violet, 0.5f + 1f / 256f, profile, 430f))
        val cyan = cache.brush(Color(0xFF22D3EE), 0.5f, profile, 430f)
        assertTrue(cyan !== a)
        assertTrue(a !== cache.brush(violet, 0.5f, profile, 430f))
    }

    @Test
    fun thinking_orb_does_not_recompose_per_frame() {
        var compositions = 0
        composeRule.mainClock.autoAdvance = false
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceAuroraOrb(mode = VoiceOrbMode.Think, level = null, nudges = 0, onComposed = { compositions++ })
            }
        }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitForIdle()
        assertTrue("the orb never composed", compositions >= 1)
        val before = compositions
        // Advance the 1 s frame clock: only the phase redraws, no recomposition.
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.waitForIdle()
        val recomposed = compositions - before
        assertTrue("thinking orb recomposed $recomposed times in 1 s", recomposed <= 2)
        activity.finish()
    }

    @Test
    fun each_nudge_change_shakes_once() {
        var shakes = 0
        var nudges by mutableIntStateOf(0)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceAuroraOrb(mode = VoiceOrbMode.Listen, level = null, nudges = nudges, onShake = { shakes++ })
            }
        }
        composeRule.mainClock.advanceTimeBy(100)
        composeRule.waitForIdle()
        assertEquals("first composition does not shake", 0, shakes)
        nudges = 1
        composeRule.mainClock.advanceTimeBy(300)
        composeRule.waitForIdle()
        assertEquals(1, shakes)
        nudges = 2
        composeRule.mainClock.advanceTimeBy(300)
        composeRule.waitForIdle()
        assertEquals(2, shakes)
        activity.finish()
    }
}
