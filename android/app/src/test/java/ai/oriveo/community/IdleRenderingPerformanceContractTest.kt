package ai.oriveo.community

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Idle-state rendering performance contract -- mirrors the iOS `ChatAuroraPerformanceRegressionTests`.
 *
 * Real-device profiling (120Hz tablet, debug build, with `animator_duration_scale` as the only
 * variable) showed:
 *
 * | Scenario | Infinite animation running | All infinite animation stopped |
 * |---|---|---|
 * | Empty chat screen, idle, unfocused | 79.7% CPU / 4864 frames in 20s | 0.2% CPU / 0 frames |
 * | Empty chat screen, idle, focused | 97.6% CPU | 4.7% CPU (system text cursor only) |
 * | Home screen, idle | 85.7% CPU / 4532 frames in 20s | 0.1% CPU / 0 frames |
 *
 * The root cause is that Compose's `InfiniteTransition.run()` is internally
 * `while(true) { withInfiniteAnimationFrameNanos { ... } }`, which **wakes the main thread every
 * frame even if nothing reads its value** (animation-core 1.9.2). This test locks down one rule:
 *
 * > Screens the user "opens and just sits on" (empty chat screen, composer, home hero) must
 * > **never** be driven by an infinite animation.
 *
 * Infinite animation is allowed only for transient states with a clear lifecycle -- streaming
 * generation, thinking, uploading -- which unmount when they finish and are out of scope here.
 */
class IdleRenderingPerformanceContractTest {

    /** Idle-state resident components: an infinite animation driver in these files pins the whole screen to the display refresh rate. */
    private val idlePathSources = listOf(
        "feature/chat/components/ChatAuroraBackground.kt",
        "feature/chat/components/EmptyChatState.kt",
        "feature/chat/composer/ComposerAnimatedBorder.kt",
        "feature/chat/composer/EnhancedComposer.kt",
        "feature/chat/composer/ComposerControlChip.kt",
        "feature/chat/ChatScreenContent.kt",
        "feature/home/AuroraTheme.kt",
        "feature/home/homescreen/NewChatBar.kt",
    )

    @Test
    fun `idle path composables declare no infinite animation driver`() {
        val offenders = idlePathSources.filter { path ->
            val code = codeWithoutComments(path)
            code.contains("rememberInfiniteTransition") || code.contains("infiniteRepeatable")
        }

        assertTrue(
            "Idle-state resident components must not use infinite animation (it pins the whole screen to the display refresh rate; measured at ~80-98% single-core CPU). " +
                "Offending files: $offenders -- use a finite entrance/state-transition animation, or a low-frequency state toggle instead.",
            offenders.isEmpty(),
        )
    }

    @Test
    fun `chat aurora keeps static visuals with finite entrance only`() {
        val source = source("feature/chat/components/ChatAuroraBackground.kt")

        // Visuals must be fully preserved: offscreen compositing isolation + dot-grid caching + three glow layers
        assertTrue("Aurora must keep Offscreen isolation, otherwise the dark BlendMode.Screen pollutes layers beneath it", source.contains("CompositingStrategy.Offscreen"))
        assertTrue("Dot grid must still be cached once per size/theme", source.contains("drawWithCache"))
        assertEquals("Three glow layers (main + secondary + top subtle glow) must not be reduced", 3, source.split("Brush.radialGradient(").size - 1)
        // Entrance is a finite animation that settles once it finishes
        assertTrue("Entrance settle should be a one-shot tween", source.contains("label = \"auroraSettle\""))
        assertTrue("Entrance fade-in must be preserved", source.contains("label = \"auroraAlpha\""))
    }

    @Test
    fun `empty state logo settles instead of breathing`() {
        val source = source("feature/chat/components/EmptyChatState.kt")

        assertTrue("Soft-glow circle should settle once to 1.06 (matching iOS scaleEffect(... ? 1.06 : 0.92))", source.contains("1.06f"))
        assertFalse("There should no longer be a permanently breathing scale upper bound of 1.14", source.contains("1.14f"))
    }

    @Test
    fun `focused composer border is static and cached`() {
        val source = source("feature/chat/composer/ComposerAnimatedBorder.kt")

        assertTrue("Colorful sweep border visual must be preserved", source.contains("Brush.sweepGradient"))
        assertTrue("Phase should be a static constant matching iOS's 24 degrees", source.contains("STATIC_PHASE"))
        assertTrue("Color stops + brush must be cached by size, not rebuilt as 19 Pairs every frame", source.contains("drawWithCache"))
        assertTrue("The six-color ring visual must not be reduced", source.contains("AI_BORDER_COLORS"))
    }

    @Test
    fun `home hero aurora ring stays static and cached`() {
        val source = source("feature/home/AuroraTheme.kt")

        assertTrue("Hero aurora color ring visual must be preserved", source.contains("auroraGlowColors"))
        assertTrue("Ring and face must be cached per size (drawWithCache), not rebuilt every frame", source.contains("drawWithCache"))
        assertTrue("Focus runs a single finite 0.4s transition", source.contains("tween(durationMillis = 400, easing = EaseInOut)"))
        assertTrue("Outer 4dp blurred glow must not be dropped", source.contains("strokeWidth = 4.dp.toPx()"))
        assertTrue("Inner 2dp sharp color ring must not be dropped", source.contains("style = Stroke(width = 2.dp.toPx())"))
    }

    @Test
    fun `home decorative cursor blinks by low frequency toggle`() {
        val source = source("feature/home/homescreen/NewChatBar.kt")

        assertTrue("Decorative cursor should still blink (hard toggle, visually matching a real text cursor)", source.contains("CURSOR_BLINK_INTERVAL_MS"))
        assertTrue("Should toggle at low frequency via delay rather than frame-by-frame tweening", codeWithoutComments("feature/home/homescreen/NewChatBar.kt").contains("delay(CURSOR_BLINK_INTERVAL_MS)"))
    }

    private fun source(relativePath: String): String =
        File("src/main/java/ai/oriveo/community/$relativePath").readText()

    /**
     * Source code with comments stripped.
     *
     * Needed because some of these files carry an explanatory comment noting that an infinite
     * transition used to live there and was removed; scanning the raw source would flag that
     * comment itself as a violation.
     */
    private fun codeWithoutComments(relativePath: String): String =
        source(relativePath)
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lineSequence()
            .joinToString("\n") { it.substringBefore("//") }
}
