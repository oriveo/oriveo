package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.model.StreamActivity
import ai.oriveo.community.feature.chat.components.STREAM_QUIET_THRESHOLD_MS
import ai.oriveo.community.feature.chat.components.StreamActivityLabel
import ai.oriveo.community.feature.chat.components.StreamActivityPresentation
import ai.oriveo.community.feature.chat.components.StreamQuietState
import ai.oriveo.community.feature.chat.components.label
import ai.oriveo.community.feature.chat.components.resolveStreamActivityPresentation
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression lock for the waiting-feedback decision and the pause timer.
 *
 * A unit test cannot render Compose, so the decision is a pure function and the timer is a state
 * machine that does not depend on composition; the composable only consumes their results. The
 * wiring in between is held by structure guards.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class StreamActivityPresentationTest {

    // The five rows of the decision table, one test each.

    @Test
    fun `row 1 - not generating shows nothing even with a stale activity and a quiet screen`() {
        assertEquals(
            StreamActivityPresentation.Hidden,
            resolveStreamActivityPresentation(
                isGenerating = false,
                hasBodyText = true,
                typingIndicatorVisible = false,
                activity = StreamActivity.WebSearch,
                quiet = true,
            ),
        )
    }

    @Test
    fun `row 2 - activity with the dots indicator on screen relabels the dots and adds no status line`() {
        assertEquals(
            StreamActivityPresentation.IndicatorLabel(StreamActivityLabel.WebSearch),
            resolveStreamActivityPresentation(
                isGenerating = true,
                hasBodyText = false,
                typingIndicatorVisible = true,
                activity = StreamActivity.WebSearch,
                quiet = true,
            ),
        )
    }

    @Test
    fun `row 3 - activity without the dots indicator goes to the status line`() {
        // Body text is present.
        assertEquals(
            StreamActivityPresentation.StatusLine(StreamActivityLabel.WebSearch),
            resolveStreamActivityPresentation(
                isGenerating = true,
                hasBodyText = true,
                typingIndicatorVisible = false,
                activity = StreamActivity.WebSearch,
                quiet = false,
            ),
        )
        // No body text, and the reasoning block has replaced the dots: the activity label
        // still needs somewhere to go.
        assertEquals(
            StreamActivityPresentation.StatusLine(StreamActivityLabel.WebSearch),
            resolveStreamActivityPresentation(
                isGenerating = true,
                hasBodyText = false,
                typingIndicatorVisible = false,
                activity = StreamActivity.WebSearch,
                quiet = false,
            ),
        )
    }

    @Test
    fun `row 4 - quiet screen with body text shows the neutral status line`() {
        assertEquals(
            StreamActivityPresentation.StatusLine(StreamActivityLabel.Generating),
            resolveStreamActivityPresentation(
                isGenerating = true,
                hasBodyText = true,
                typingIndicatorVisible = false,
                activity = null,
                quiet = true,
            ),
        )
    }

    @Test
    fun `row 5 - everything else stays hidden`() {
        // Body text is still arriving.
        assertEquals(
            StreamActivityPresentation.Hidden,
            resolveStreamActivityPresentation(
                isGenerating = true,
                hasBodyText = true,
                typingIndicatorVisible = false,
                activity = null,
                quiet = false,
            ),
        )
        // A pause with no body text: the dots are moving, so no status line.
        assertEquals(
            StreamActivityPresentation.Hidden,
            resolveStreamActivityPresentation(
                isGenerating = true,
                hasBodyText = false,
                typingIndicatorVisible = true,
                activity = null,
                quiet = true,
            ),
        )
        // A pause with no body text: the reasoning block is moving, so none here either.
        assertEquals(
            StreamActivityPresentation.Hidden,
            resolveStreamActivityPresentation(
                isGenerating = true,
                hasBodyText = false,
                typingIndicatorVisible = false,
                activity = null,
                quiet = true,
            ),
        )
    }

    @Test
    fun `at most one waiting label is on screen for every reachable input combination`() {
        val booleans = listOf(false, true)
        for (isGenerating in booleans) for (hasBodyText in booleans) for (dots in booleans)
            for (activity in listOf(null, StreamActivity.WebSearch)) for (quiet in booleans) {
                // The dots only show when the body is empty, so both being true is unreachable.
                if (dots && hasBodyText) continue
                val result = resolveStreamActivityPresentation(isGenerating, hasBodyText, dots, activity, quiet)
                if (result is StreamActivityPresentation.StatusLine) {
                    assertFalse("no status line may be stacked while the dots indicator is on screen", dots)
                }
                if (result is StreamActivityPresentation.IndicatorLabel) {
                    assertTrue("the label override only happens while the dots indicator is on screen", dots)
                }
            }
    }

    @Test
    fun `labels map to the neutral generating key and the web search key`() {
        assertEquals(R.string.generating, StreamActivityLabel.Generating.stringRes)
        assertEquals(R.string.stream_activity_web_search, StreamActivityLabel.WebSearch.stringRes)
        assertEquals(StreamActivityLabel.WebSearch, StreamActivity.WebSearch.label())
    }

    // The pause timer.

    @Test
    fun `quiet turns on only after the threshold passes with no visible change`() = runTest {
        val state = StreamQuietState()
        val job = launch { state.run() }
        runCurrent()
        assertFalse("observation has only just started, so nothing can count as a pause yet", state.quiet)

        advanceTimeBy(STREAM_QUIET_THRESHOLD_MS - 1)
        runCurrent()
        assertFalse(state.quiet)

        advanceTimeBy(1)
        runCurrent()
        assertTrue(state.quiet)

        job.cancelAndJoin()
    }

    @Test
    fun `a visible change restarts the countdown from that change and drops quiet at once`() = runTest {
        val state = StreamQuietState()
        val job = launch { state.run() }
        runCurrent()

        // New text at 1.4s: the countdown restarts from this change, not from the beginning.
        advanceTimeBy(1_400)
        state.noteVisibleChange()
        runCurrent()
        advanceTimeBy(1_400)
        runCurrent()
        assertFalse("only 1.4s have passed since the last visible change", state.quiet)
        advanceTimeBy(100)
        runCurrent()
        assertTrue(state.quiet)

        // Text resumes after a pause: quiet drops at once.
        state.noteVisibleChange()
        runCurrent()
        assertFalse(state.quiet)

        job.cancelAndJoin()
    }

    @Test
    fun `leaving the live stream resets quiet`() = runTest {
        val state = StreamQuietState()
        val job = launch { state.run() }
        advanceTimeBy(STREAM_QUIET_THRESHOLD_MS)
        runCurrent()
        assertTrue(state.quiet)

        job.cancelAndJoin()
        assertFalse("the quiet state must not carry over once the stream has ended", state.quiet)
    }

    @Test
    fun `quiet threshold is one and a half seconds`() {
        assertEquals(1_500L, STREAM_QUIET_THRESHOLD_MS)
    }

    // Structure guards: the wiring a unit test cannot reach.

    @Test
    fun `message bubble consumes the pure decision and feeds quiet from visible content only`() {
        val bubble = source("feature/chat/components/MessageBubble.kt")

        assertTrue("the presentation decision must go through the single pure function", bubble.contains("resolveStreamActivityPresentation("))
        assertTrue(
            "the body pause timer must follow the reveal's visible progress, not the incoming text: until the reveal catches up, text is still appearing on screen",
            bubble.contains("onVisibleTextAdvanced = onVisibleBodyAdvanced"),
        )
        assertTrue(
            "reasoning counts only when its text changes, and setting or clearing the activity resets once; the empty-heartbeat signal streamingReasoningActive must not be a timer key",
            bubble.contains(
                "LaunchedEffect(streamQuiet, waitingOnLiveStream, displayReasoningText, streamingActivity)",
            ),
        )
        assertTrue(
            "the waiting label only applies to the message with a live stream attached",
            bubble.contains("val waitingOnLiveStream = isStreaming && isLiveStream"),
        )

        // Position: the status line comes after the body and before the tool card and the citations block.
        val lineAt = bubble.indexOf("StreamActivityLine(text = ")
        assertTrue(lineAt > bubble.indexOf("MarkdownMessageView("))
        listOf("UnhandledToolCallsCard(message.unhandledToolCalls)", "CitationsBlock(citations")
            .forEach { later ->
                assertTrue("the status line must sit above $later", lineAt < bubble.indexOf(later, lineAt))
            }
    }

    @Test
    fun `only the streaming cell collects the activity flow`() {
        val list = source("feature/chat/ChatMessagesList.kt")
        val collectAt = list.indexOf("streamingActivity.collectAsStateWithLifecycle()")
        assertTrue(collectAt > 0)
        val guard = list.lastIndexOf("if (isStreaming) {", collectAt)
        assertTrue(
            "the activity flow may only be collected inside the isStreaming branch of the streaming cell; otherwise one update recomposes every visible cell",
            guard > 0 && collectAt - guard < 80,
        )
    }

    @Test
    fun `status line keeps the visual contract`() {
        val line = source("feature/chat/components/StreamActivityLine.kt")

        assertTrue(line.contains("OriveoTheme.typography.footnote"))
        assertTrue(line.contains("liveRegion = LiveRegionMode.Polite"))
        assertTrue(line.contains("private const val SHIMMER_PERIOD_MS = 1800"))
        assertTrue(line.contains("private const val SHIMMER_BAND_FRACTION = 0.3f"))
        assertTrue(line.contains("private const val APPEAR_FADE_MS = 200"))
        assertTrue(line.contains("maxLines = 1"))
        assertTrue("reduced motion: static textSecondary", line.contains("if (reduceMotion) colors.textSecondary else colors.textTertiary"))
        assertTrue("the sweep direction is mirrored in RTL", line.contains("LocalLayoutDirection.current == LayoutDirection.Rtl"))
        assertFalse(
            "a ShaderBrush span crashes with a derived state reading itself",
            line.lineSequence().filterNot { it.trim().startsWith("*") || it.trim().startsWith("//") }
                .any { it.contains("ShaderBrush") },
        )
        // The sweep is the only infinite animation and must sit entirely in the else branch of reduceMotion.
        val infiniteAt = line.indexOf("infiniteRepeatable(")
        val guardAt = line.lastIndexOf("val sweep = if (reduceMotion) {", infiniteAt)
        assertTrue(guardAt in 1 until infiniteAt)
        assertEquals("only one infinite animation is allowed", infiniteAt, line.lastIndexOf("infiniteRepeatable("))
    }

    @Test
    fun `web search label exists in all sixteen locales without a trailing ellipsis`() {
        val resDir = File("src/main/res")
        val values = resDir.listFiles { file -> file.isDirectory && File(file, "strings.xml").exists() }
            .orEmpty()
            .associate { dir ->
                dir.name to Regex("""<string name="stream_activity_web_search">(.*?)</string>""")
                    .find(File(dir, "strings.xml").readText())?.groupValues?.get(1)
            }

        assertEquals("sixteen locale values directories", 16, values.size)
        values.forEach { (dir, value) ->
            assertFalse("$dir is missing stream_activity_web_search", value.isNullOrBlank())
            assertFalse("the label in $dir must not end with an ellipsis: $value", value!!.endsWith("…") || value.endsWith("..."))
        }
        // No locale simply repeats the English string.
        assertEquals(1, values.values.count { it == "Searching the web" })
    }

    private fun source(path: String): String =
        File("src/main/java/ai/oriveo/community/$path").readText()
}
