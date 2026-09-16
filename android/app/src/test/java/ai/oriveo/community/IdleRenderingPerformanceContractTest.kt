package ai.oriveo.community

import ai.oriveo.community.feature.onboarding.OnboardingMath
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
 * ## Mechanism
 *
 * `InfiniteTransition.run()` is wrapped in `if (isRunning || refreshChildNeeded) { LaunchedEffect {
 * while(true) { withInfiniteAnimationFrameNanos { ... } } } }`, and `onFrame` writes back
 * `isRunning = !allFinished`.
 *
 * - **Burning frames requires exactly one thing: registering an animation that never reports
 *   `isFinished`** (`animateFloat` + `infiniteRepeatable`). Whether anything reads `.value`, and
 *   whether the value changes at all, makes no difference to the frame loop.
 * - An empty transition (created but never given an `animateFloat`) walks an empty `_animations` on
 *   its first frame, so `allFinished` -> `isRunning=false` -> the guard turns false, the
 *   `LaunchedEffect` is removed and it **stops for good after one frame**. The predicate is
 *   therefore `infiniteRepeatable`, not `rememberInfiniteTransition` -- the latter on its own is a
 *   tidiness issue, not a performance one.
 * - `initialValue == targetValue` **does not stop it**: `infiniteRepeatable`'s durationNanos is
 *   `Long.MAX_VALUE`, so it is never finished and the frame loop keeps running; the value simply
 *   stops changing, which only avoids recomposition. Stopping it means **not calling**
 *   `animateFloat` at all.
 * - When `durationScale == 0f` (the user turned system animations off), `run()` takes `skipToEnd()`
 *   and parks on `snapshotFlow { coroutineContext.durationScale }.first { it > 0f }`, requesting no
 *   more frames -- which is exactly where the "all infinite animation stopped" column above comes
 *   from. **Corollary: putting an infinite animation behind a `reduceMotion` gate saves no CPU.**
 *   Users who turned animations off were never burning frames; users who did not still are.
 *
 * ## Two tiers
 *
 * 1. **Idle resident screens** ([idlePathSources]): the user opens them and just sits there, and in
 *    the default state (`durationScale == 1`) they are pinned to the refresh rate. So **not a single
 *    infinite animation may be registered**, and a reduceMotion gate does not count -- it cannot help
 *    the overwhelming majority of users. Motion is kept by changing the driver instead: a
 *    low-frequency `delay` tick (the home decorative cursor), or hanging off the page's existing
 *    single time source (the onboarding cost card).
 * 2. **Components allowed to register infinite animation, but which must be switchable off by the
 *    system setting** ([motionGatedSources]): short-lived pulses and the like, where the only lock is
 *    "every `infiniteRepeatable` sits in a reduceMotion short-circuit branch". That is a gate on
 *    **intent and accessibility consistency**, not a CPU gate (see above); do not mistake it for a
 *    performance win.
 *
 * Transient states with a clear lifecycle (streaming generation, thinking, uploading, a refresh
 * spinner) unmount when they finish and are out of scope for both tiers.
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
        // Onboarding is another "open it and sit there" screen: the motion is kept, but it is now
        // driven by the stage's single time source rather than a registered infinite animation.
        "feature/onboarding/OnboardingOrbitStage.kt",
    )

    /**
     * Components that keep infinite motion but must let the system "disable animations" setting
     * actually take effect.
     *
     * `OriveoStatusDot` is the **living example of the correct shape** (`if (pulsing &&
     * !reduceMotion)` conditional creation). Keeping it in the list both pins it against being
     * broken and proves the detector does not flag that shape.
     */
    private val motionGatedSources = listOf(
        "ui/component/OriveoStatusDot.kt",
        "feature/settings/MemoryScreen.kt",
    )

    @Test
    fun `idle path composables declare no infinite animation driver`() {
        val offenders = idlePathSources.filter { path ->
            codeWithoutComments(path).contains(INFINITE_SPEC)
        }

        assertTrue(
            "Idle-state resident components must not register infinite animation (it pins the whole screen to the display refresh rate; measured at ~80-98% single-core CPU). " +
                "Offending files: $offenders -- use a finite entrance/state-transition animation, or a low-frequency state toggle instead. " +
                "Note: putting it behind a reduceMotion gate does not count as fixed; users who did not turn system animations off still burn frames.",
            offenders.isEmpty(),
        )
    }

    @Test
    fun `motion gated composables short circuit every infinite animation on reduce motion`() {
        val offenders = motionGatedSources.filter { path ->
            unguardedInfiniteAnimations(path, structuralCode(source(path))) > 0
        }

        assertTrue(
            "These components keep infinite motion, but every infiniteRepeatable must sit in a reduceMotion short-circuit branch " +
                "(`if (... && !reduceMotion) { ... }` or `if (reduceMotion) { ... } else { ... }`), " +
                "otherwise the system \"disable animations\" setting has no effect on them. Offending files: $offenders",
            offenders.isEmpty(),
        )
    }

    /**
     * Self-check for the detector, so the test above cannot quietly become a no-op.
     *
     * It pins two things in particular: (1) the mere presence of the word reduceMotion in a file is
     * not a pass; (2) `if (reduceMotion) { animation }`, which hangs the animation off the "animations
     * are off" branch, must be caught.
     */
    @Test
    fun `reduce motion guard detector accepts both correct shapes and rejects the rest`() {
        val negatedGuard = """
            fun sample(pulsing: Boolean, reduceMotion: Boolean) {
                if (pulsing && !reduceMotion) {
                    val t = rememberInfiniteTransition(label = "x")
                    t.animateFloat(0f, 1f, infiniteRepeatable(tween(700)))
                }
            }
        """.trimIndent()
        val elseGuard = """
            fun sample(reduceMotion: Boolean) {
                val scale = if (reduceMotion) {
                    1f
                } else {
                    rememberInfiniteTransition(label = "x")
                        .animateFloat(0f, 1f, infiniteRepeatable(tween(700))).value
                }
            }
        """.trimIndent()
        val ungated = """
            fun sample() {
                val t = rememberInfiniteTransition(label = "x")
                t.animateFloat(0f, 1f, infiniteRepeatable(tween(700)))
            }
        """.trimIndent()
        val insideReduceMotionBranch = """
            fun sample(reduceMotion: Boolean) {
                if (reduceMotion) {
                    rememberInfiniteTransition(label = "x")
                        .animateFloat(0f, 1f, infiniteRepeatable(tween(700)))
                }
            }
        """.trimIndent()
        val wordPresentButNotGuarding = """
            fun sample(context: Context) {
                val reduceMotion = isReduceMotionEnabled(context)
                val fade = if (reduceMotion) 0 else 360
                rememberInfiniteTransition(label = "x")
                    .animateFloat(0f, 1f, infiniteRepeatable(tween(700)))
            }
        """.trimIndent()
        // infiniteRepeatable mentioned in a comment or a string is not a violation (a fixed-up file
        // usually keeps an explanatory comment)
        val onlyMentionedInProse = """
            fun sample() {
                // there used to be an infiniteRepeatable here; it was removed because it burned frames
                val label = "infiniteRepeatable"
            }
        """.trimIndent()

        assertEquals(0, unguardedInfiniteAnimations("negatedGuard", structuralCode(negatedGuard)))
        assertEquals(0, unguardedInfiniteAnimations("elseGuard", structuralCode(elseGuard)))
        assertEquals(1, unguardedInfiniteAnimations("ungated", structuralCode(ungated)))
        assertEquals(
            1,
            unguardedInfiniteAnimations("insideReduceMotionBranch", structuralCode(insideReduceMotionBranch)),
        )
        assertEquals(
            1,
            unguardedInfiniteAnimations("wordPresentButNotGuarding", structuralCode(wordPresentButNotGuarding)),
        )
        assertEquals(0, unguardedInfiniteAnimations("onlyMentionedInProse", structuralCode(onlyMentionedInProse)))
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

    @Test
    fun `onboarding cost card floats on the single stage clock`() {
        val code = codeWithoutComments("feature/onboarding/OnboardingOrbitStage.kt")

        assertTrue("both cost card axes must be driven by the stage's single time source", code.contains("OnboardingMath.pingPong(time,"))
        assertEquals("the two axes (6.0s / 7.4s) must not be collapsed into one", 2, code.split("OnboardingMath.pingPong(time,").size - 1)
        assertTrue("the period constants must be kept", code.contains("COST_CARD_LIFT_PERIOD_SECONDS = 6f"))
        assertTrue("the period constants must be kept", code.contains("COST_CARD_DRIFT_PERIOD_SECONDS = 7.4f"))
        assertTrue(
            "the stage clock must still pause on reduceMotion / inactivity; it is also what holds the cost card still",
            code.contains("OnboardingMotionPolicy.isOrbitClockPaused(reduceMotion, isAnimating)"),
        )
    }

    /**
     * `pingPong` drives the cost card's float, so it has to stay pointwise equivalent to the
     * `infiniteRepeatable(tween(period, LinearEasing), RepeatMode.Reverse)` it replaced: start at 0,
     * rise linearly to 1 over `period` seconds, fall back over the same span, and repeat forever.
     */
    @Test
    fun `ping pong matches the reverse linear tween it replaced`() {
        val period = 6f
        assertEquals(0f, OnboardingMath.pingPong(0f, period), 1e-4f)
        assertEquals(0.5f, OnboardingMath.pingPong(period / 2f, period), 1e-4f)
        assertEquals(1f, OnboardingMath.pingPong(period, period), 1e-4f)
        assertEquals(0.5f, OnboardingMath.pingPong(period * 1.5f, period), 1e-4f)
        assertEquals(0f, OnboardingMath.pingPong(period * 2f, period), 1e-4f)
        // the second round trip lands exactly on the first
        assertEquals(0.5f, OnboardingMath.pingPong(period * 2.5f, period), 1e-4f)
        assertEquals(1f, OnboardingMath.pingPong(period * 3f, period), 1e-4f)
        // the periods are not integer multiples of one another: at the same instant the two axes
        // differ, which is what keeps the combined path from looking like it loops
        assertTrue(kotlin.math.abs(OnboardingMath.pingPong(3f, 6f) - OnboardingMath.pingPong(3f, 7.4f)) > 0.05f)
        // a degenerate period must not blow up
        assertEquals(0f, OnboardingMath.pingPong(3f, 0f), 1e-4f)
        // when the stage clock is paused `time` is 0, and both axes must return to the resting value
        assertEquals(0f, OnboardingMath.pingPong(0f, 6f), 1e-4f)
        assertEquals(0f, OnboardingMath.pingPong(0f, 7.4f), 1e-4f)
    }

    // ── helpers ──

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

    /**
     * Source with comments, strings and string templates stripped, leaving only braces that really
     * take part in the syntax.
     *
     * Without this, quotes and braces inside string templates throw the brace matching off -- and
     * UI files of this size (`MemoryScreen.kt` runs to well over a thousand lines) are full of them.
     */
    private fun structuralCode(text: String): String {
        val out = StringBuilder(text.length)
        // Context stack: 'c' code / 's' plain string / 'r' raw (triple-quoted) string.
        // A template interpolation pushes another 'c' inside the string; the brace depth recorded on
        // push is what identifies its closing brace.
        val contexts = mutableListOf('c')
        val entryDepths = mutableListOf(0)
        var depth = 0
        var i = 0
        while (i < text.length) {
            val context = contexts[contexts.size - 1]
            val atRoot = contexts.size == 1
            when (context) {
                'c' -> when {
                    text.startsWith("/*", i) -> {
                        val end = text.indexOf("*/", i + 2)
                        i = if (end < 0) text.length else end + 2
                        if (atRoot) out.append(' ')
                    }
                    text.startsWith("//", i) -> {
                        val end = text.indexOf('\n', i)
                        i = if (end < 0) text.length else end
                        if (atRoot) out.append(' ')
                    }
                    text.startsWith("\"\"\"", i) -> {
                        if (atRoot) out.append(' ')
                        i += 3
                        contexts.add('r')
                        entryDepths.add(depth)
                    }
                    text[i] == '"' -> {
                        if (atRoot) out.append(' ')
                        i++
                        contexts.add('s')
                        entryDepths.add(depth)
                    }
                    text[i] == '\'' -> {
                        i++
                        while (i < text.length && text[i] != '\'') {
                            if (text[i] == '\\') i++
                            i++
                        }
                        i++
                        if (atRoot) out.append(' ')
                    }
                    text[i] == '{' -> {
                        depth++
                        if (atRoot) out.append('{')
                        i++
                    }
                    text[i] == '}' -> {
                        if (!atRoot && depth == entryDepths[entryDepths.size - 1]) {
                            // end of a template interpolation, back into the string
                            contexts.removeAt(contexts.size - 1)
                            entryDepths.removeAt(entryDepths.size - 1)
                        } else {
                            depth--
                            if (atRoot) out.append('}')
                        }
                        i++
                    }
                    else -> {
                        if (atRoot) out.append(text[i])
                        i++
                    }
                }
                's' -> when {
                    text[i] == '\\' -> i += 2
                    text.startsWith("\${", i) -> {
                        i += 2
                        contexts.add('c')
                        entryDepths.add(depth)
                    }
                    text[i] == '"' -> {
                        contexts.removeAt(contexts.size - 1)
                        entryDepths.removeAt(entryDepths.size - 1)
                        i++
                    }
                    else -> i++
                }
                else -> when {
                    text.startsWith("\"\"\"", i) -> {
                        contexts.removeAt(contexts.size - 1)
                        entryDepths.removeAt(entryDepths.size - 1)
                        i += 3
                    }
                    text.startsWith("\${", i) -> {
                        i += 2
                        contexts.add('c')
                        entryDepths.add(depth)
                    }
                    else -> i++
                }
            }
        }
        return out.toString()
    }

    /**
     * Counts `infiniteRepeatable` calls that do **not** sit in a reduceMotion short-circuit branch.
     *
     * Two shapes are accepted: `if (... !reduceMotion ...) { animation }` and `if (reduceMotion) {
     * static } else { animation }`. Conversely `if (reduceMotion) { animation }` is a violation --
     * the predicate looks at **which branch the call belongs to**, not at whether the file mentions
     * the word anywhere.
     */
    private fun unguardedInfiniteAnimations(label: String, code: String): Int {
        val allowed = mutableListOf<Boolean>()
        val ifConditions = mutableListOf<String?>()
        var pendingElseCondition: String? = null
        var unguarded = 0
        var i = 0
        while (i < code.length) {
            when {
                code.startsWith(INFINITE_SPEC_CALL, i) -> {
                    if (allowed.none { it }) unguarded++
                    i += INFINITE_SPEC_CALL.length
                }
                code[i] == '{' -> {
                    val condition = ifConditionEndingAt(code, i)
                    allowed.add(
                        when {
                            condition != null -> mentionsNegatedReduceMotion(condition)
                            isElseBlockStart(code, i) ->
                                pendingElseCondition?.let { mentionsPlainReduceMotion(it) } == true
                            else -> false
                        },
                    )
                    ifConditions.add(condition)
                    pendingElseCondition = null
                    i++
                }
                code[i] == '}' -> {
                    check(allowed.isNotEmpty()) { "$label: unbalanced braces, structural scan failed" }
                    allowed.removeAt(allowed.size - 1)
                    pendingElseCondition = ifConditions.removeAt(ifConditions.size - 1)
                    i++
                }
                else -> i++
            }
        }
        check(allowed.isEmpty()) { "$label: unclosed braces (${allowed.size} left), structural scan failed" }
        return unguarded
    }

    /** The `if (...)` condition immediately preceding `{`; null when it is not an if block (`when (...) {` and `someCall(...) {` are excluded here). */
    private fun ifConditionEndingAt(code: String, braceIndex: Int): String? {
        var i = braceIndex - 1
        while (i >= 0 && code[i].isWhitespace()) i--
        if (i < 0 || code[i] != ')') return null
        val closing = i
        var parens = 0
        while (i >= 0) {
            if (code[i] == ')') parens++
            if (code[i] == '(') {
                parens--
                if (parens == 0) break
            }
            i--
        }
        if (i < 0) return null
        val opening = i
        var j = opening - 1
        while (j >= 0 && code[j].isWhitespace()) j--
        if (j < 1 || code[j] != 'f' || code[j - 1] != 'i') return null
        val before = if (j - 2 >= 0) code[j - 2] else ' '
        if (before.isLetterOrDigit() || before == '_') return null
        return code.substring(opening + 1, closing)
    }

    private fun isElseBlockStart(code: String, braceIndex: Int): Boolean {
        var i = braceIndex - 1
        while (i >= 0 && code[i].isWhitespace()) i--
        if (i < 3 || code.substring(i - 3, i + 1) != "else") return false
        val before = if (i - 4 >= 0) code[i - 4] else ' '
        return !(before.isLetterOrDigit() || before == '_')
    }

    private fun mentionsNegatedReduceMotion(condition: String): Boolean =
        REDUCE_MOTION_MENTION.findAll(condition).any { it.groupValues[1].isNotEmpty() }

    private fun mentionsPlainReduceMotion(condition: String): Boolean =
        REDUCE_MOTION_MENTION.findAll(condition).any { it.groupValues[1].isEmpty() }

    private companion object {
        /** Predicate anchor: registering an animation that never finishes always means writing this spec. */
        const val INFINITE_SPEC = "infiniteRepeatable"

        /** Branch ownership only counts **call sites**; without the opening paren the import line at the top of the file would read as a violation. */
        const val INFINITE_SPEC_CALL = "infiniteRepeatable("

        /** Capture group 1 non-empty = the mention is negated with `!`. */
        val REDUCE_MOTION_MENTION = Regex("""(!\s*)?[A-Za-z0-9_.]*[Rr]educeMotion""")
    }
}
