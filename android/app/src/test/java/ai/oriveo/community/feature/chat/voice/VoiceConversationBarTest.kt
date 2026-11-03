package ai.oriveo.community.feature.chat.voice

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.recognitionLanguageRows
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.realtime.RealtimeConversationInput
import ai.oriveo.community.core.voice.realtime.RealtimeConversationLogic
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.core.voice.realtime.RealtimeSessionEvent
import ai.oriveo.community.core.voice.realtime.StageLine
import ai.oriveo.community.core.voice.realtime.captionText
import ai.oriveo.community.core.voice.realtime.stageLine
import ai.oriveo.community.testing.TestSharedPreferences
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.time.Duration.Companion.seconds

/**
 * The rendered voice bar: status words fit in two lines in all 16 locales for the statuses each page can reach
 * (home: listening / thinking / muted / error; chat: all seven), and only the status word is spoken.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@OptIn(ExperimentalCoroutinesApi::class)
class VoiceConversationBarTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val qualifiers = listOf(
        "en", "zh-rCN", "zh-rTW", "ja", "ko", "de", "fr", "es", "pt-rBR", "ru", "tr", "in", "vi", "th", "hi", "ar",
    )

    @Test
    fun `home reaches only listening thinking muted and error, chat reaches all seven`() {
        // shared/voice-contracts/voice-conversation.v1.json pageReachableStatusKeys: shared across platforms.
        val reachable = Json.parseToJsonElement(workspaceFile("shared/voice-contracts/voice-conversation.v1.json").readText())
            .jsonObject["pageReachableStatusKeys"]!!.jsonObject
        fun keys(page: String): Set<ConversationStatusKey> = reachable[page]!!.jsonArray.map { raw ->
            ConversationStatusKey.entries.single { it.rawValue == raw.jsonPrimitive.content }
        }.toSet()
        assertEquals(keys("home"), VoiceConversationBarStatus.reachable(VoiceConversationPage.Home))
        assertEquals(keys("chat"), VoiceConversationBarStatus.reachable(VoiceConversationPage.Chat))
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }

    @Test
    fun `at 200 percent text status words fit in three lines without ellipsis for every reachable status in every locale`() {
        // 360x640 dp phone, system 200% font scale: the stage on the home and chat pages fills the screen width (36 dp margin on each side of the text); status words 17 sp, the two didn't-catch-that states 20 sp.
        val widths = mapOf(VoiceConversationPage.Home to 360.dp, VoiceConversationPage.Chat to 360.dp)
        val truncated = mutableListOf<String>()
        for (qualifier in qualifiers) {
            RuntimeEnvironment.setQualifiers("+$qualifier-w360dp-h640dp")
            for ((page, width) in widths) {
                var status by mutableStateOf(ConversationStatusKey.LISTENING)
                var layout: TextLayoutResult? = null
                val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
                activity.setContent {
                    OriveoTheme(darkTheme = false) {
                        val density = LocalDensity.current
                        CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                            Box(Modifier.width(width)) {
                                VoiceConversationBar(
                                    status = status,
                                    level = null,
                                    page = page,
                                    onEnd = {},
                                    onTapOrb = {},
                                    onToggleMute = {},
                                    onStatusLayout = { layout = it },
                                )
                            }
                        }
                    }
                }
                for (key in VoiceConversationBarStatus.reachable(page)) {
                    status = key
                    composeRule.waitForIdle()
                    val result = requireNotNull(layout)
                    val last = result.lineCount - 1
                    if (result.lineCount > 3 || result.isLineEllipsized(last) || result.hasVisualOverflow) {
                        truncated += "$qualifier/$page/${key.rawValue}: ${result.layoutInput.text}"
                    }
                }
                activity.finish()
            }
        }
        assertTrue("truncated status words: $truncated", truncated.isEmpty())
    }

    @Test
    fun `mute button reads differently in its two states and the end button always has a description`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        var status by mutableStateOf(ConversationStatusKey.LISTENING)
        val activity = stage(status = { status })
        fun described(tag: String) = composeRule.onNodeWithTag(tag).fetchSemanticsNode()
            .config[SemanticsProperties.ContentDescription]
        val unmuted = described("voice_conversation_mute_button")
        val endLive = described("voice_conversation_end_button")
        status = ConversationStatusKey.MUTED
        composeRule.waitForIdle()
        val muted = described("voice_conversation_mute_button")
        val endMuted = described("voice_conversation_end_button")
        // Unmuted reads "Mute", muted reads "Unmute": both descriptions come from the production string resources and differ from each other
        assertEquals(listOf(activity.getString(R.string.voice_conversation_mute_a11y)), unmuted)
        assertEquals(listOf(activity.getString(R.string.voice_conversation_unmute_a11y)), muted)
        assertTrue("mute descriptions must differ：$unmuted / $muted", unmuted != muted)
        // Both end-button states have a non-empty description
        val end = listOf(activity.getString(R.string.voice_conversation_end_a11y))
        assertTrue("end button description is blank", end.single().isNotBlank())
        assertEquals(end, endLive)
        assertEquals(end, endMuted)
        activity.finish()
    }

    @Test
    fun `the bar exposes the status word, three buttons and no live region`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceConversationBar(
                    status = ConversationStatusKey.LISTENING,
                    level = null,
                    page = VoiceConversationPage.Chat,
                    onEnd = {},
                    onTapOrb = {},
                    onToggleMute = {},
                )
            }
        }
        composeRule.waitForIdle()
        val orb = composeRule.onNodeWithTag("voice_conversation_orb_button").fetchSemanticsNode()
        assertEquals(listOf(activity.getString(R.string.voice_conversation_status_listening)), orb.config[SemanticsProperties.ContentDescription])
        // The status word is read once, on the orb node only: the visible status word itself is hidden from screen readers
        val spoken = spokenNodes(activity.getString(R.string.voice_conversation_status_listening))
        assertEquals(listOf("voice_conversation_orb_button"), spoken.map { it.config.getOrNull(SemanticsProperties.TestTag) })
        composeRule.onNodeWithTag("voice_conversation_end_button").fetchSemanticsNode()
        composeRule.onNodeWithTag("voice_conversation_mute_button").fetchSemanticsNode()
        val live = composeRule.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion), useUnmergedTree = true)
            .fetchSemanticsNodes()
        assertTrue("no live region in the bar: the host announces once", live.isEmpty())
        assertEquals(null, orb.config.getOrNull(SemanticsProperties.LiveRegion))
    }

    @Test
    fun `caption status reads the live caption on the orb and falls back to the listening word when empty`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        var caption by mutableStateOf("\u4f60\u597d\u4e16\u754c")
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceConversationBar(
                    status = ConversationStatusKey.CAPTION,
                    level = null,
                    page = VoiceConversationPage.Home,
                    onEnd = {},
                    onTapOrb = {},
                    onToggleMute = {},
                    caption = caption,
                )
            }
        }
        composeRule.waitForIdle()
        fun shown() = composeRule.onNodeWithTag("voice_conversation_orb_button").fetchSemanticsNode()
            .config[SemanticsProperties.ContentDescription]
        val listening = activity.getString(R.string.voice_conversation_status_listening)
        // Same as iOS status(key, caption:): when the caption is non-empty, the orb's screen-reader description is the caption and follows its updates
        assertEquals(listOf("\u4f60\u597d\u4e16\u754c"), shown())
        caption = "\u4f60\u597d\u4e16\u754c\u518d\u89c1"
        composeRule.waitForIdle()
        assertEquals(listOf("\u4f60\u597d\u4e16\u754c\u518d\u89c1"), shown())
        // In the semantics tree "Listening" appears 0 times, and the caption text appears exactly once, on the orb node
        assertEquals(0, spokenNodes(listening).size)
        val captionNodes = spokenNodes("\u4f60\u597d\u4e16\u754c\u518d\u89c1")
        assertEquals(1, captionNodes.size)
        assertEquals("voice_conversation_orb_button", captionNodes.single().config.getOrNull(SemanticsProperties.TestTag))
        // Empty caption: falls back to "Listening"
        caption = ""
        composeRule.waitForIdle()
        assertEquals(listOf(listening), shown())
        assertEquals(null, VoiceConversationBarStatus.captionText(ConversationStatusKey.CAPTION, ""))
        // The caption replaces the status word only in the caption state
        assertEquals(null, VoiceConversationBarStatus.captionText(ConversationStatusKey.LISTENING, "\u4f60\u597d"))
        activity.finish()
    }

    /** Unmerged semantics nodes whose text or content description is exactly [value]. */
    @Test
    fun realtime_caption_shows_under_any_status() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        var caption by mutableStateOf("one two")
        var status by mutableStateOf(ConversationStatusKey.SPEAKING)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceConversationBar(
                    status = status,
                    level = null,
                    page = VoiceConversationPage.Chat,
                    onEnd = {},
                    onTapOrb = {},
                    onToggleMute = {},
                    caption = caption,
                    realtimeCaption = true,
                )
            }
        }
        composeRule.waitForIdle()
        fun shown() = composeRule.onNodeWithTag("voice_conversation_orb_button").fetchSemanticsNode()
            .config[SemanticsProperties.ContentDescription]
        val speaking = activity.getString(R.string.voice_conversation_status_speaking)
        val listening = activity.getString(R.string.voice_conversation_status_listening)
        // On the realtime stage the caption is the stageLine text: revealed AI text (assistant line) replaces "Speaking"
        assertEquals(listOf("one two"), shown())
        assertEquals(0, spokenNodes(speaking).size)
        // user line: your words replace "Listening"
        status = ConversationStatusKey.LISTENING
        caption = "wait"
        composeRule.waitForIdle()
        assertEquals(listOf("wait"), shown())
        // status line (empty caption): only the status word is shown, no placeholder
        caption = ""
        composeRule.waitForIdle()
        assertEquals(listOf(listening), shown())
        assertEquals("\u4f60\u597d", VoiceConversationBarStatus.captionText(ConversationStatusKey.SPEAKING, "\u4f60\u597d", realtime = true))
        assertEquals(null, VoiceConversationBarStatus.captionText(ConversationStatusKey.SPEAKING, " ", realtime = true))
        // Cascade unchanged: replaces only in the caption state
        assertEquals(null, VoiceConversationBarStatus.captionText(ConversationStatusKey.SPEAKING, "\u4f60\u597d"))
        activity.finish()
    }

    /** Feeds the production reducer and returns the stage line plus the status key the realtime bar would get. */
    private fun realtimeStage(vararg inputs: RealtimeConversationInput): Pair<StageLine?, ConversationStatusKey> {
        var state = RealtimeConversationLogic.initialState()
        for (input in inputs) state = RealtimeConversationLogic.reduce(state, input).state
        return stageLine(state) to requireNotNull(RealtimeConversationLogic.statusKey(state))
    }

    /** Composes the realtime bar with the controller's caption for [line] and returns the orb's description. */
    private fun realtimeShown(line: StageLine?, status: ConversationStatusKey): List<String>? {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceConversationBar(
                    status = status,
                    level = null,
                    page = VoiceConversationPage.Chat,
                    onEnd = {},
                    onTapOrb = {},
                    onToggleMute = {},
                    caption = line?.captionText.orEmpty(),
                    realtimeCaption = true,
                )
            }
        }
        composeRule.waitForIdle()
        val shown = composeRule.onNodeWithTag("voice_conversation_orb_button").fetchSemanticsNode()
            .config[SemanticsProperties.ContentDescription]
        activity.finish()
        return shown
    }

    private fun session(event: RealtimeSessionEvent) = RealtimeConversationInput.Session(event)

    /** 1 s of 24 kHz PCM16 downlink (silence is enough: reveal follows played ms, not level). */
    private val oneSecondAudio = java.util.Base64.getEncoder().encodeToString(ByteArray(48_000))

    @Test
    fun `stage line user caption wins`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        val (line, status) = realtimeStage(
            session(RealtimeSessionEvent.Ready),
            session(RealtimeSessionEvent.UserSpeechStarted("u1")),
            session(RealtimeSessionEvent.UserTranscript("u1", "wait", false)),
            session(RealtimeSessionEvent.AssistantAudio("a1", 0, oneSecondAudio, 24_000)),
            session(RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false)),
            RealtimeConversationInput.PlaybackProgress("a1", 500),
        )
        // AI is speaking with revealed text, but your words are not final: the stage line is your words
        assertEquals(ConversationStatusKey.SPEAKING, status)
        assertEquals(StageLine.User("wait"), line)
        assertEquals(listOf("wait"), realtimeShown(line, status))
    }

    @Test
    fun `stage line status when nothing revealed`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        val (line, status) = realtimeStage(
            session(RealtimeSessionEvent.Ready),
            session(RealtimeSessionEvent.AssistantAudio("a1", 0, oneSecondAudio, 24_000)),
            session(RealtimeSessionEvent.AssistantTranscript("a1", "one two three four", false)),
        )
        // AI is speaking but nothing has played yet: no placeholder, show the status word
        assertEquals(ConversationStatusKey.SPEAKING, status)
        assertEquals(StageLine.Status(ConversationStatusKey.SPEAKING), line)
        val speaking = RuntimeEnvironment.getApplication().getString(R.string.voice_conversation_status_speaking)
        assertEquals(listOf(speaking), realtimeShown(line, status))
    }

    private fun spokenNodes(value: String) = composeRule.onAllNodes(
        SemanticsMatcher("text or description is $value") { node ->
            val texts = node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text }
            val descriptions = node.config.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
            value in texts || value in descriptions
        },
        useUnmergedTree = true,
    ).fetchSemanticsNodes()

    @Test
    fun `a wrapped chip is narrower than the stage, centered on it, and centers each line`() {
        RuntimeEnvironment.setQualifiers("+en-w360dp-h640dp")
        val longest = recognitionLanguageRows(null).mapNotNull { (it.label as? ai.oriveo.community.core.app.UiText.Dynamic)?.value }
            .maxBy { it.length }
        var chipText: TextLayoutResult? = null
        val activity = stage(
            status = { ConversationStatusKey.CHECK_LANGUAGE },
            languageName = longest,
            fontScale = 2f,
            onChipLayout = { chipText = it },
        )
        val d = stageDensity
        val text = requireNotNull(chipText)
        assertTrue("chip wraps: ${text.lineCount}", text.lineCount > 1)
        val host = composeRule.onNodeWithTag(STAGE_HOST).fetchSemanticsNode().boundsInRoot
        val chip = composeRule.onNodeWithTag("voice_conversation_language_chip").fetchSemanticsNode().boundsInRoot
        // Width follows content: with multiple lines it shrinks to the widest line instead of filling the stage; the block is centered horizontally on the stage
        assertTrue("chip ${chip.width} < stage ${host.width}", chip.width < host.width - 1f * d)
        assertEquals("chip centered", host.center.x, chip.center.x, 1f * d)
        // Each line is centered: equal left and right margins per line
        for (line in 0 until text.lineCount) {
            val left = text.getLineLeft(line)
            val right = text.size.width - text.getLineRight(line)
            assertEquals("line $line centered", left, right, 1f * d)
        }
        activity.setContent {}
        composeRule.waitForIdle()
        activity.finish()
    }

    // Old behavior: in the THINKING state composition read driftA / driftB .value, so every animation frame recomposed the orb once (about 60 times per second).
    @Test
    fun thinking_orb_does_not_recompose_per_frame() {
        var compositions = 0
        composeRule.mainClock.autoAdvance = false
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceAuroraOrb(
                    mode = VoiceOrbMode.Think,
                    level = null,
                    nudges = 0,
                    onComposed = { compositions++ },
                )
            }
        }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitForIdle()
        assertTrue("the orb never composed", compositions >= 1)
        val before = compositions
        // Advance the animation clock by 1 s: drift only redraws, it does not recompose.
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.waitForIdle()
        val recomposed = compositions - before
        assertTrue("thinking orb recomposed $recomposed times in 1 s", recomposed <= 2)
        activity.finish()
    }

    /** LocalDensity inside OriveoTheme while the last [stage] was composed (dp → px). */
    private var stageDensity = 1f

    private fun stage(
        status: () -> ConversationStatusKey,
        caption: () -> String? = { null },
        nudges: () -> Int = { 0 },
        languageName: String? = null,
        onOpenLanguage: () -> Unit = {},
        onShake: () -> Unit = {},
        onLayout: (TextLayoutResult) -> Unit = {},
        onTheme: (androidx.compose.ui.graphics.Color) -> Unit = {},
        fontScale: Float = 1f,
        onChipLayout: ((TextLayoutResult) -> Unit)? = null,
        switchingTo: () -> String? = { null },
    ): ComponentActivity {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                onTheme(OriveoTheme.colors.textPrimary)
                val density = LocalDensity.current
                stageDensity = density.density
                CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                Box(Modifier.width(360.dp).testTag(STAGE_HOST)) {
                    VoiceConversationBar(
                        status = status(),
                        level = null,
                        page = VoiceConversationPage.Chat,
                        onEnd = {},
                        onTapOrb = {},
                        onToggleMute = {},
                        caption = caption(),
                        onStatusLayout = onLayout,
                        nudges = nudges(),
                        languageName = languageName,
                        onOpenLanguage = onOpenLanguage,
                        onOrbShake = onShake,
                        onLanguageChipLayout = onChipLayout,
                        switchingTo = switchingTo(),
                    )
                }
                }
            }
        }
        composeRule.waitForIdle()
        return activity
    }

    @Test
    fun `nudges change triggers one shake`() {
        var nudges by mutableStateOf(0)
        var caption by mutableStateOf("\u4f60\u597d")
        var shakes = 0
        val activity = stage(
            status = { ConversationStatusKey.CAPTION },
            caption = { caption },
            nudges = { nudges },
            onShake = { shakes++ },
        )
        assertEquals("first frame does not shake", 0, shakes)
        nudges = 1
        composeRule.waitForIdle()
        assertEquals(1, shakes)
        // Recompositions with an unchanged count no longer shake
        caption = "\u4f60\u597d\u4e16\u754c"
        composeRule.waitForIdle()
        assertEquals(1, shakes)
        nudges = 2
        composeRule.waitForIdle()
        assertEquals(2, shakes)
        activity.finish()
    }

    @Test
    fun `CHECK_LANGUAGE shows chip, tap opens language picker`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        val settings = languageSettings()
        settings.setRecognitionLanguage(LanguageOption.Japanese.localeTag)
        val status = mutableStateOf<ConversationStatusKey?>(ConversationStatusKey.SAY_AGAIN)
        val paused = mutableListOf<Boolean>()
        val shown = mutableStateOf(true)
        val (activity, handle) = switcher(status, shown, settings, VoiceCapturePause { paused += it })
        val chips = composeRule.onAllNodes(SemanticsMatcher.expectValue(SemanticsProperties.TestTag, "voice_conversation_language_chip"))
        assertTrue("the capsule appears only in the recognition-language prompt state", chips.fetchSemanticsNodes().isEmpty())
        status.value = ConversationStatusKey.CHECK_LANGUAGE
        composeRule.waitForIdle()
        // The language name in the capsule matches the form row (same recognitionLanguageRows label)
        val name = LanguageOption.Japanese.displayName
        val chip = composeRule.onNodeWithTag("voice_conversation_language_chip")
        assertEquals(
            listOf(activity.getString(R.string.voice_conversation_language_chip, name)),
            chip.fetchSemanticsNode().config[SemanticsProperties.ContentDescription],
        )
        val title = activity.getString(R.string.voice_recognition_language)
        composeRule.onNodeWithText(title).assertDoesNotExist()
        chip.performClick()
        composeRule.waitForIdle()
        assertTrue(handle.languagePickerOpen)
        assertEquals(listOf(true), paused)
        composeRule.onNodeWithText(title).assertExists()
        composeRule.onNodeWithText(name).assertExists()
        activity.finish()
    }

    @Test
    fun `chip label glues the colon to the word before it`() {
        assertEquals("Erkennungssprache\u2060: Englisch", languageChipNoBreakColon("Erkennungssprache: Englisch"))
        assertEquals("Langue de reconnaissance\u00A0: Anglais", languageChipNoBreakColon("Langue de reconnaissance : Anglais"))
        assertEquals("\u8a8d\u8b58する\u8a00\u8a9e\u2060：\u82f1\u8a9e", languageChipNoBreakColon("\u8a8d\u8b58する\u8a00\u8a9e：\u82f1\u8a9e"))
        assertEquals("\u8bc6\u522b\u8bed\u8a00 \u82f1\u8bed", languageChipNoBreakColon("\u8bc6\u522b\u8bed\u8a00 \u82f1\u8bed"))
    }

    @Test
    fun `at 200 percent text the check-language word and the longest chip fit without ellipsis or overlap in every locale`() {
        // Two language names: the longest one in the production language rows (a UiText.Dynamic name), and the system name for the stored value en-US (e.g. the German "Englisch (Vereinigte Staaten)");
        // system 200% font scale, 16 interface languages.
        val longest = recognitionLanguageRows(null).mapNotNull { (it.label as? ai.oriveo.community.core.app.UiText.Dynamic)?.value }
            .maxBy { it.length }
        val problems = mutableListOf<String>()
        for (qualifier in qualifiers) for (nameKind in listOf("longest", "en-US")) {
            // 360x640 dp: a common minimum phone screen (Robolectric's default 470 dp screen height cannot fit the stage at 200% font scale)
            RuntimeEnvironment.setQualifiers("+$qualifier-w360dp-h640dp")
            val uiLocale = RuntimeEnvironment.getApplication().resources.configuration.locales[0]
            val name = if (nameKind == "longest") longest else recognitionLanguageDisplayName("en-US", uiLocale)
            var word: TextLayoutResult? = null
            var chipText: TextLayoutResult? = null
            val activity = stage(
                status = { ConversationStatusKey.CHECK_LANGUAGE },
                languageName = name,
                fontScale = 2f,
                onLayout = { word = it },
                onChipLayout = { chipText = it },
            )
            val w = requireNotNull(word)
            val c = requireNotNull(chipText)
            val t = c.layoutInput.text.text
            val lines = (0 until c.lineCount).map { t.substring(c.getLineStart(it), c.getLineEnd(it)) }
            // No characters dropped: the last line ends at the end of the whole string; colons (including full-width ones) never start a line
            val lost = c.getLineEnd(c.lineCount - 1) != t.length
            val colonLead = lines.drop(1).any { it.trimStart().firstOrNull() in setOf(':', '：') }
            if (c.layoutInput.maxLines != 3 || c.layoutInput.overflow == TextOverflow.Ellipsis || c.lineCount > 3 || c.hasVisualOverflow ||
                lost || colonLead
            ) {
                problems += "$qualifier/$nameKind chip: lines=$lines lost=$lost colonLead=$colonLead" +
                    " maxW=${c.layoutInput.constraints.maxWidth} ow=${c.didOverflowWidth} oh=${c.didOverflowHeight} size=${c.size} mpw=${c.multiParagraph.width} mph=${c.multiParagraph.height}"
            }
            if (w.layoutInput.overflow == TextOverflow.Ellipsis || w.lineCount > 3 || w.hasVisualOverflow) {
                problems += "$qualifier/$nameKind word: ${w.layoutInput.text} lines=${w.lineCount}"
            }
            val host = composeRule.onNodeWithTag(STAGE_HOST).getBoundsInRoot()
            val chip = composeRule.onNodeWithTag("voice_conversation_language_chip").getBoundsInRoot()
            val orb = composeRule.onNodeWithTag("voice_conversation_orb_button").getBoundsInRoot()
            if (problems.isNotEmpty() && problems.last().startsWith("$qualifier/$nameKind")) problems += "host=${host.right - host.left} chip=${chip.right - chip.left} d=$stageDensity"
            if (chip.height < 36.dp) problems += "$qualifier chip height ${chip.height}"
            if (host.height < 366.dp) problems += "$qualifier stage height ${host.height}"
            if (!near(orb.height, VoiceAuroraOrbSize)) problems += "$qualifier orb ${orb.height}"
            for (tag in listOf("voice_conversation_mute_button", "voice_conversation_end_button")) {
                val button = composeRule.onNodeWithTag(tag).getBoundsInRoot()
                if (chip.bottom > button.top) problems += "$qualifier chip ${chip.bottom} over $tag ${button.top}"
                if (!near(button.height, 64.dp)) problems += "$qualifier $tag size ${button.height}"
                if (!near(host.bottom - button.bottom, 20.dp)) problems += "$qualifier $tag bottom ${host.bottom - button.bottom}"
            }
            // Clear the content before ending, so the next language leaves only one stage node
            activity.setContent {}
            composeRule.waitForIdle()
            activity.finish()
        }
        assertTrue("200% font scale: $problems", problems.isEmpty())
    }

    @Test
    fun `words, chip and the two buttons are 12 apart and the globe scales with the text`() {
        RuntimeEnvironment.setQualifiers("+en-w360dp-h640dp")
        for (scale in listOf(1f, 2f)) {
            var word: TextLayoutResult? = null
            var chipText: TextLayoutResult? = null
            val activity = stage(
                status = { ConversationStatusKey.CHECK_LANGUAGE },
                languageName = "English",
                fontScale = scale,
                onLayout = { word = it },
                onChipLayout = { chipText = it },
            )
            val d = stageDensity
            val host = composeRule.onNodeWithTag(STAGE_HOST).fetchSemanticsNode().boundsInRoot
            val chip = composeRule.onNodeWithTag("voice_conversation_language_chip").fetchSemanticsNode().boundsInRoot
            val mute = composeRule.onNodeWithTag("voice_conversation_mute_button").fetchSemanticsNode().boundsInRoot
            // Text column top = orb top 18 + orb 148 + 30; text bottom to capsule 12
            val wordBottom = host.top + (18f + 148f + 30f) * d + requireNotNull(word).size.height
            assertEquals("scale $scale word→chip", 12f * d, chip.top - wordBottom, 1f * d)
            // Inside the capsule: left inset 12 + globe + 7 + text + right inset 14; globe 15 dp x fontScale
            val globe = chip.width - requireNotNull(chipText).size.width - (12f + 7f + 14f) * d
            assertEquals("scale $scale globe", 15f * scale * d, globe, 1f * d)
            if (scale == 2f) {
                // At 200% the stage grows taller, and the text column is exactly 12 from the two buttons
                assertTrue("stage ${host.height}", host.height > 366f * d)
                assertEquals("chip→buttons", 12f * d, mute.top - chip.bottom, 1f * d)
            }
            activity.setContent {}
            composeRule.waitForIdle()
            activity.finish()
        }
    }

    @Test
    fun `the fog runs past a 16 dp parent inset without a vertical edge`() {
        // Parent layout has 16 dp side insets: the fog is still drawn beyond the stage edges, and pixels on both sides of the stage's left edge stay continuous along each row (no vertical hard edge)
        RuntimeEnvironment.setQualifiers("+en-w392dp-h640dp")
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        var d = 1f
        var page = androidx.compose.ui.graphics.Color.Unspecified
        activity.setContent {
            OriveoTheme(darkTheme = true) {
                d = LocalDensity.current.density
                page = OriveoTheme.colors.background
                Box(Modifier.width(392.dp).background(OriveoTheme.colors.background).testTag(STAGE_HOST)) {
                    Box(Modifier.padding(horizontal = 16.dp)) {
                        VoiceConversationBar(
                            status = ConversationStatusKey.LISTENING,
                            level = null,
                            page = VoiceConversationPage.Chat,
                            onEnd = {},
                            onTapOrb = {},
                            onToggleMute = {},
                        )
                    }
                }
            }
        }
        composeRule.waitForIdle()
        val image = composeRule.onNodeWithTag(STAGE_HOST).captureToImage().toPixelMap()
        val steps = mutableListOf<String>()
        var fogged = 0
        // Circle 1 center is inside the stage at y≈226 dp; compare pixels 1 dp inside and outside the stage's left edge (x=16 dp) across several rows
        for (yDp in listOf(200, 226, 260, 300)) {
            val y = (yDp * d).toInt().coerceAtMost(image.height - 1)
            val outside = image[(15f * d).toInt(), y]
            val inside = image[(17f * d).toInt(), y]
            val delta = maxOf(
                kotlin.math.abs(outside.red - inside.red),
                kotlin.math.abs(outside.green - inside.green),
                kotlin.math.abs(outside.blue - inside.blue),
            ) * 255f
            if (delta > 2f) steps += "y=$yDp outside=$outside inside=$inside"
            // The fog is really drawn: 1 dp outside the stage is no longer the page background color
            val tint = maxOf(
                kotlin.math.abs(outside.red - page.red),
                kotlin.math.abs(outside.green - page.green),
                kotlin.math.abs(outside.blue - page.blue),
            ) * 255f
            if (tint > 2f) fogged++
        }
        assertTrue("no fog outside the stage side", fogged > 0)
        assertTrue("fog edge at the stage side: $steps", steps.isEmpty())
        activity.finish()
    }

    @Test
    fun `the fog bottom runs to the window bottom plus 120 when the stage sits above it`() {
        // Stage bottom is 24 dp above the window bottom (e.g. a navigation bar): the fog container bottom = window bottom + 120, not stage bottom + 120
        RuntimeEnvironment.setQualifiers("+en-w392dp-h640dp")
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        var d = 1f
        var view: android.view.View? = null
        activity.setContent {
            OriveoTheme(darkTheme = true) {
                d = LocalDensity.current.density
                view = LocalView.current
                Box(Modifier.fillMaxSize()) {
                    Box(Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp)) {
                        VoiceConversationBar(
                            status = ConversationStatusKey.LISTENING,
                            level = null,
                            page = VoiceConversationPage.Chat,
                            onEnd = {},
                            onTapOrb = {},
                            onToggleMute = {},
                        )
                    }
                }
            }
        }
        composeRule.waitForIdle()
        val host = checkNotNull(view)
        val location = IntArray(2).also { host.getLocationInWindow(it) }
        val fog = composeRule.onNodeWithTag(VOICE_FOG_TAG, useUnmergedTree = true).getUnclippedBoundsInRoot()
        val fogBottomInWindowPx = location[1] + fog.bottom.value * d
        val expectedPx = host.rootView.height + 120f * d
        assertEquals(expectedPx, fogBottomInWindowPx, 1.5f * d)
        assertEquals(520f, (fog.bottom - fog.top).value, 1f)
        activity.finish()
    }

    @Test
    fun `the chip names automatic like the sheet row when nothing is saved`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        val status = mutableStateOf<ConversationStatusKey?>(ConversationStatusKey.CHECK_LANGUAGE)
        val (activity, _) = switcher(status, mutableStateOf(true), languageSettings(), VoiceCapturePause {})
        assertEquals(
            listOf(activity.getString(R.string.voice_conversation_language_chip, activity.getString(R.string.voice_language_automatic))),
            composeRule.onNodeWithTag("voice_conversation_language_chip").fetchSemanticsNode().config[SemanticsProperties.ContentDescription],
        )
        activity.finish()
    }

    @Test
    fun `ending the conversation or leaving the page closes the language picker and resumes capture`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        val status = mutableStateOf<ConversationStatusKey?>(ConversationStatusKey.CHECK_LANGUAGE)
        val paused = mutableListOf<Boolean>()
        val shown = mutableStateOf(true)
        val (activity, handle) = switcher(status, shown, languageSettings(), VoiceCapturePause { paused += it })
        val title = activity.getString(R.string.voice_recognition_language)
        composeRule.onNodeWithTag("voice_conversation_language_chip").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(title).assertExists()
        // Session ends: the form closes automatically (language unchanged) and listening resumes
        status.value = null
        composeRule.waitForIdle()
        assertFalse(handle.languagePickerOpen)
        assertEquals(listOf(true, false), paused)
        composeRule.onNodeWithText(title).assertDoesNotExist()
        // Stage leaves composition (page change): likewise close the form and resume listening
        status.value = ConversationStatusKey.CHECK_LANGUAGE
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("voice_conversation_language_chip").performClick()
        composeRule.waitForIdle()
        assertTrue(handle.languagePickerOpen)
        shown.value = false
        composeRule.waitForIdle()
        assertFalse(handle.languagePickerOpen)
        assertEquals(listOf(true, false, true, false), paused)
        activity.finish()
    }

    @Test
    fun `a mixed Chinese and English caption keeps its last 8 scalars in the body color, column inset 36 dp`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        val mixed = "\u6211\u60f3 test \u4e00\u4e0b"
        var layout: TextLayoutResult? = null
        var primary = androidx.compose.ui.graphics.Color.Unspecified
        val activity = stage(
            status = { ConversationStatusKey.CAPTION },
            caption = { mixed },
            onLayout = { layout = it },
            onTheme = { primary = it },
        )
        val shown = requireNotNull(layout).layoutInput.text
        assertEquals(mixed, shown.text)
        val tail = shown.spanStyles.last()
        assertEquals(" test \u4e00\u4e0b", shown.text.substring(tail.start, tail.end))
        assertEquals(primary, tail.item.color)
        assertEquals(CaptionHighlight(dim = "\u6211\u60f3", bright = " test \u4e00\u4e0b"), captionHighlight(mixed))
        // Caption column has 36 dp on each side (the bottom button row is 44 dp); measurement and display use the same letter spacing of -0.3 sp.
        val result = requireNotNull(layout)
        val stageWidth = activity.findViewById<android.view.View>(android.R.id.content).width
        with(result.layoutInput.density) {
            val column = minOf(360.dp.roundToPx(), stageWidth) - 36.dp.roundToPx() * 2
            assertEquals(column, result.layoutInput.constraints.maxWidth)
        }
        assertEquals((-0.3).sp, result.layoutInput.style.letterSpacing)
        activity.finish()
    }

    @Test
    fun `a caption longer than two lines is cut from the head and its tail is in the body color`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        val long = "\u4eca\u5929\u4e0b\u5348\u6211\u60f3\u53bb\u516c\u56ed\u6563\u6b65\u7136\u540e\u987a\u8def\u4e70\u4e00\u4e9b\u6c34\u679c\u56de\u5bb6\u518d\u7ed9\u5988\u5988\u6253\u4e2a\u7535\u8bdd\u95ee\u95ee\u5979\u5468\u672b\u6709\u6ca1\u6709\u7a7a\u4e00\u8d77\u5403\u996d\u987a\u4fbf\u804a\u804a\u4e0b\u4e2a\u6708\u65c5\u884c\u7684\u5b89\u6392\u548c\u9884\u7b97"
        var layout: TextLayoutResult? = null
        var primary = androidx.compose.ui.graphics.Color.Unspecified
        val activity = stage(
            status = { ConversationStatusKey.CAPTION },
            caption = { long },
            onLayout = { layout = it },
            onTheme = { primary = it },
        )
        val result = requireNotNull(layout)
        val shown = result.layoutInput.text
        assertTrue("truncated from the head: $shown", shown.text.startsWith("…"))
        assertTrue("keeps the end: $shown", long.endsWith(shown.text.removePrefix("…")))
        assertTrue(result.lineCount <= 2)
        assertFalse(result.hasVisualOverflow)
        val tail = shown.spanStyles.last()
        assertEquals(shown.length, tail.end)
        assertEquals(shown.length - 8, tail.start)
        assertEquals(primary, tail.item.color)
        val lead = shown.spanStyles.first()
        assertEquals(0, lead.start)
        assertEquals(androidx.compose.ui.graphics.Color(0xFF52525B), lead.item.color)
        assertEquals(androidx.compose.ui.graphics.Color(0xFFB3B3BA), VoiceStageColors.captionLead(dark = true))
        // The status word keeps the old color: still >= 4.5:1 over the aurora fog (revised)
        assertEquals(VoiceStageColors.captionLead(dark = false), VoiceStageColors.statusWord(dark = false))
        assertEquals(VoiceStageColors.captionLead(dark = true), VoiceStageColors.statusWord(dark = true))
        // For space-delimited languages take the last 3 words
        assertEquals(CaptionHighlight(dim = "…a b ", bright = "c d e"), captionHighlight("…a b c d e"))
        activity.finish()
    }

    @Test
    fun `head ellipsis cuts on grapheme cluster boundaries`() {
        val family = "\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67"
        val text = family + family + "abc"
        // Code-point slicing leaves a half grapheme cluster, e.g. "…\u200D👧abc" ; grapheme-cluster slicing can only drop whole clusters.
        assertEquals("…abc", headTrimmed(text) { it.length <= 7 })
        assertEquals("…" + family + "abc", headTrimmed(text) { it.length <= 12 })
        assertEquals(text, headTrimmed(text) { true })
        // If not even one cluster fits, keep the last cluster
        assertEquals("…" + family, headTrimmed(family + family) { false })
    }

    @Test
    fun `say again is shown in amber at 20 sp`() {
        RuntimeEnvironment.setQualifiers("+zh-rCN")
        var layout: TextLayoutResult? = null
        val activity = stage(status = { ConversationStatusKey.SAY_AGAIN }, onLayout = { layout = it })
        val style = requireNotNull(layout).layoutInput.style
        assertEquals(activity.getString(R.string.voice_conversation_status_say_again), layout!!.layoutInput.text.text)
        assertEquals(androidx.compose.ui.graphics.Color(0xFFB45309), style.color)
        assertEquals(20f, style.fontSize.value, 0.001f)
        activity.finish()
    }

    @Test
    fun `status maps to the orb mode`() {
        val expected = mapOf(
            ConversationStatusKey.LISTENING to VoiceOrbMode.Listen,
            ConversationStatusKey.CAPTION to VoiceOrbMode.User,
            ConversationStatusKey.THINKING to VoiceOrbMode.Think,
            ConversationStatusKey.SPEAKING to VoiceOrbMode.Ai,
            ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT to VoiceOrbMode.Ai,
            ConversationStatusKey.MUTED to VoiceOrbMode.Muted,
            ConversationStatusKey.AWAITING_APPROVAL to VoiceOrbMode.Muted,
            ConversationStatusKey.ERROR to VoiceOrbMode.Muted,
            ConversationStatusKey.SAY_AGAIN to VoiceOrbMode.Listen,
            ConversationStatusKey.CHECK_LANGUAGE to VoiceOrbMode.Listen,
        )
        assertEquals(ConversationStatusKey.entries.toSet(), expected.keys)
        for ((status, mode) in expected) assertEquals(status.rawValue, mode, voiceOrbMode(status, userSpeaking = false))
        // The user speaks with no caption: the orb also enters the you-are-speaking state
        assertEquals(VoiceOrbMode.User, voiceOrbMode(ConversationStatusKey.LISTENING, userSpeaking = true))
        assertEquals(VoiceOrbMode.Think, voiceOrbMode(ConversationStatusKey.THINKING, userSpeaking = true))
        assertTrue(voiceStageNotice(ConversationStatusKey.SAY_AGAIN) && voiceStageNotice(ConversationStatusKey.CHECK_LANGUAGE))
        assertFalse(voiceStageNotice(ConversationStatusKey.CAPTION))
    }

    @Test
    fun `status word is announced once per change and capture pauses for the estimated reading time`() = runTest(timeout = 10.seconds) {
        val spoken = mutableListOf<String>()
        val speaking = mutableListOf<Boolean>()
        val announcer = StatusAnnouncer(backgroundScope, screenReaderOn = { true }, speak = { spoken += it }, onSpeaking = { speaking += it })
        announcer.announce("\u5728\u542c")
        announcer.announce("\u5728\u542c")
        assertEquals(listOf("\u5728\u542c"), spoken)
        assertEquals(listOf(true), speaking)
        advanceTimeBy(StatusAnnouncer.estimateMillis("\u5728\u542c") - 1)
        runCurrent()
        assertEquals(listOf(true), speaking)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(listOf(true, false), speaking)
        assertEquals(660L, StatusAnnouncer.estimateMillis("\u5728\u542c"))

        announcer.announce("\u5728\u60f3")
        announcer.announce("\u5728\u8bf4")
        assertEquals(listOf("\u5728\u542c", "\u5728\u60f3", "\u5728\u8bf4"), spoken)
        announcer.reset()
        assertEquals(false, speaking.last())
    }

    @Test
    fun `without a screen reader nothing is announced and capture is never paused`() = runTest(timeout = 10.seconds) {
        val spoken = mutableListOf<String>()
        val speaking = mutableListOf<Boolean>()
        val announcer = StatusAnnouncer(backgroundScope, screenReaderOn = { false }, speak = { spoken += it }, onSpeaking = { speaking += it })
        announcer.announce("Listening")
        announcer.reset()
        assertTrue(spoken.isEmpty())
        assertFalse(speaking.any { it })
    }

    private fun languageSettings(): VoiceEngineSettings {
        val prefs = TestSharedPreferences()
        return VoiceEngineSettings { prefs }
    }

    /** Renders the stage through VoiceConversationSwitcher (the same path as the page); when [shown] is false the whole switcher leaves composition. */
    private fun switcher(
        status: MutableState<ConversationStatusKey?>,
        shown: MutableState<Boolean>,
        settings: VoiceEngineSettings,
        pause: VoiceCapturePause,
        switchingTo: State<String?> = mutableStateOf(null),
        onSwitchNoticeShown: (String) -> Unit = {},
        onStatusLayout: ((TextLayoutResult) -> Unit)? = null,
    ): Pair<ComponentActivity, VoiceConversationHandle> {
        val handle = VoiceConversationHandle(
            page = VoiceConversationPage.Chat,
            statusState = status,
            level = null,
            onEnd = {},
            onTapOrb = {},
            onToggleMute = {},
            captionState = mutableStateOf(""),
            nudgesState = mutableStateOf(0),
            capturePause = pause,
            switchingToState = switchingTo,
            onSwitchNoticeShown = onSwitchNoticeShown,
        )
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                if (shown.value) {
                    VoiceConversationSwitcher(handle = handle, languageSettings = settings, onStatusLayout = onStatusLayout) {}
                }
            }
        }
        composeRule.waitForIdle()
        return activity to handle
    }

    private fun pickerHandle(pause: VoiceCapturePause, onChanged: () -> Unit) = VoiceConversationHandle(
        page = VoiceConversationPage.Chat,
        statusState = mutableStateOf(ConversationStatusKey.LISTENING),
        level = null,
        onEnd = {},
        onTapOrb = {},
        onToggleMute = {},
        captionState = mutableStateOf(""),
        nudgesState = mutableStateOf(0),
        capturePause = pause,
        onLanguageChanged = onChanged,
    )

    @Test
    fun `the language picker pauses capture while open and resumes on close, telling a change only when made`() {
        val paused = mutableListOf<Boolean>()
        var changes = 0
        val handle = pickerHandle(VoiceCapturePause { paused += it }) { changes++ }
        handle.openLanguagePicker()
        assertTrue(handle.languagePickerOpen)
        assertEquals(listOf(true), paused)
        handle.openLanguagePicker()
        assertEquals(listOf(true), paused)
        handle.closeLanguagePicker(changed = false)
        assertFalse(handle.languagePickerOpen)
        assertEquals(listOf(true, false), paused)
        assertEquals(0, changes)

        handle.openLanguagePicker()
        handle.closeLanguagePicker(changed = true)
        assertEquals(listOf(true, false, true, false), paused)
        assertEquals(1, changes)
        handle.closeLanguagePicker(changed = true)
        assertEquals(1, changes)
    }

    @Test
    fun `picker and screen reader pauses stack, capture resumes only when both are done`() {
        val paused = mutableListOf<Boolean>()
        val pause = VoiceCapturePause { paused += it }
        val handle = pickerHandle(pause) {}
        pause.screenReader(true)
        handle.openLanguagePicker()
        pause.screenReader(false)
        assertEquals(listOf(true), paused)
        handle.closeLanguagePicker(changed = false)
        assertEquals(listOf(true, false), paused)

        handle.openLanguagePicker()
        pause.screenReader(true)
        handle.closeLanguagePicker(changed = true)
        assertEquals(listOf(true, false, true), paused)
        pause.screenReader(false)
        assertEquals(listOf(true, false, true, false), paused)
    }

    // E-690: when the engine is switched, the old session ends first (status null) while the new one is still opening, and the stage does not leave; the status line reports "Switched to <model>".
    @Test
    fun switching_notice_overrides_status_line() {
        RuntimeEnvironment.setQualifiers("+en")
        val app = RuntimeEnvironment.getApplication()
        val listening = app.getString(R.string.voice_conversation_status_listening)
        val notice = app.getString(R.string.voice_realtime_switched_to, "GPT Realtime")
        composeRule.mainClock.autoAdvance = false

        var switching by mutableStateOf<String?>(null)
        var layout: TextLayoutResult? = null
        val bar = stage(status = { ConversationStatusKey.LISTENING }, onLayout = { layout = it }, switchingTo = { switching })
        composeRule.mainClock.advanceTimeBy(500)
        composeRule.waitForIdle()
        assertEquals(listening, layout?.layoutInput?.text?.text)
        switching = "GPT Realtime"
        composeRule.mainClock.advanceTimeBy(500)
        composeRule.waitForIdle()
        assertEquals(notice, layout?.layoutInput?.text?.text)
        bar.finish()
    }

    // E-690: through the switcher, when status is null but switchingTo is set the stage stays (the orb still reports the previous status word); it leaves only when both are empty.
    @Test
    fun switching_keeps_stage_while_switching_to_set() {
        RuntimeEnvironment.setQualifiers("+en")
        val listening = RuntimeEnvironment.getApplication().getString(R.string.voice_conversation_status_listening)
        val status = mutableStateOf<ConversationStatusKey?>(ConversationStatusKey.LISTENING)
        val switchingState = mutableStateOf<String?>(null)
        val (activity, _) = switcher(status, mutableStateOf(true), languageSettings(), VoiceCapturePause {}, switchingState)
        assertTrue(spokenNodes(listening).isNotEmpty())
        switchingState.value = "GPT Realtime"
        status.value = null
        composeRule.waitForIdle()
        assertTrue("stage left while switching engines", spokenNodes(listening).isNotEmpty())
        switchingState.value = null
        runCatching { composeRule.waitUntil(timeoutMillis = 5_000) { spokenNodes(listening).isEmpty() } }
        // On timeout, put the semantics nodes reporting "Listening" into the failure message, to show which one never left.
        val left = spokenNodes(listening)
        assertTrue("stage stayed after the conversation ended: ${left.map { "${it.id}:${it.config}" }}", left.isEmpty())
        activity.finish()
    }

    /** Fake engine for the old session: after end, active becomes false and the stage status is cleared with it (same host statusState). */
    private class EndingEngine(private val status: MutableState<ConversationStatusKey?>) : VoiceConversationEngine {
        override val statusKey = MutableStateFlow<ConversationStatusKey?>(ConversationStatusKey.LISTENING)
        override val level = MutableStateFlow(0f)
        override val active = MutableStateFlow(true)
        override val events = MutableSharedFlow<VoiceConversationEvent>()
        override fun start(chat: VoiceConversationChatPort) = Unit
        override fun tapOrb() = Unit
        override fun toggleMute() = Unit
        override fun screenReaderSpeaking(speaking: Boolean) = Unit
        override fun end(reason: EndReason) {
            statusKey.value = null
            active.value = false
            status.value = null
        }
    }

    // E-690: on a device the host sets switchingTo -> old engine ends -> re-entering opens a new session -> finally clears switchingTo; this can all finish within two frames;
    // the hint must still appear on the status line (about 1.6 s), then return to the new session's status word.
    @Test
    fun switch_notice_survives_engine_reentry() {
        RuntimeEnvironment.setQualifiers("+en")
        val app = RuntimeEnvironment.getApplication()
        val listening = app.getString(R.string.voice_conversation_status_listening)
        val notice = app.getString(R.string.voice_realtime_switched_to, "gemini-3.8-live")
        val status = mutableStateOf<ConversationStatusKey?>(ConversationStatusKey.LISTENING)
        // Same host-side holder of the hint name: after the entry ends it is cleared only once the stage has composed.
        val switching = VoiceSwitchingTo()
        var layout: TextLayoutResult? = null
        // Diagnostics: the text sequence of the status line for each layout, and the model sequence the stage reports for "hint composed".
        val texts = mutableListOf<String>()
        val shownCalls = mutableListOf<String>()
        val (activity, _) = switcher(
            status, mutableStateOf(true), languageSettings(), VoiceCapturePause {}, switching.state,
            { shownCalls += it; switching.shown(it) },
        ) { layout = it; texts += it.layoutInput.text.text }
        composeRule.mainClock.autoAdvance = false
        val old = EndingEngine(status)
        val openAi = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-realtime").voiceEngineKey()
        val gemini = VoiceEngineSelection.Cloud(ProviderKind.Gemini, "conn-gemini", "gemini-3.8-live").voiceEngineKey()
        val switched = runBlocking {
            // Same host LaunchedEffect(engineKey): while capturing, set the hint name first, then end the old session and re-enter.
            switching.begin("gemini-3.8-live")
            switchVoiceEngine(old, openAi, gemini) {
                // Same host entry: the new session opens (status returns), and the entry's finally clears switchingTo.
                status.value = ConversationStatusKey.LISTENING
                switching.done()
            }
        }
        assertTrue(switched)
        // The writes above happen outside composition with the frame clock frozen (autoAdvance = false): change notifications are delivered asynchronously via the main looper,
        // whether they arrive before advanceTimeBy is nondeterministic, and if they do not, these 500 ms produce no recomposition frame. Deliver them explicitly; frames advance only through the code below.
        Snapshot.sendApplyNotifications()
        composeRule.mainClock.advanceTimeBy(500)
        composeRule.waitForIdle()
        val diag = "state=${switching.state.value} shown=$shownCalls texts=$texts"
        // (1) The stage received the report and the host has cleared the hint name.
        assertEquals("host notice name: $diag", listOf("gemini-3.8-live"), shownCalls)
        assertEquals("host notice name: $diag", null, switching.state.value)
        // (2) The status word carries clearAndSetSemantics (announced by the orb); assert against the status line's layout result.
        assertEquals("status line: $diag", notice, layout?.layoutInput?.text?.text)
        composeRule.mainClock.advanceTimeBy(2_000)
        composeRule.waitForIdle()
        assertEquals("status line: state=${switching.state.value} texts=$texts", listening, layout?.layoutInput?.text?.text)
        activity.finish()
    }

    /** Pixel bounds (dp) of the node screenshot pixels that satisfy [hit]: width and height. */
    private fun glyphBox(tag: String, hit: (androidx.compose.ui.graphics.Color) -> Boolean): Pair<Float, Float> {
        val map = composeRule.onNodeWithTag(tag).captureToImage().toPixelMap()
        var minX = Int.MAX_VALUE; var maxX = -1; var minY = Int.MAX_VALUE; var maxY = -1
        // Only look at the inner circle of the round button (radius 0.42 x side length); the screenshot corners are page background outside the button.
        val cx = map.width / 2f; val cy = map.height / 2f; val r = map.width * 0.42f
        for (y in 0 until map.height) for (x in 0 until map.width) {
            val inside = (x - cx) * (x - cx) + (y - cy) * (y - cy) < r * r
            if (inside && hit(map[x, y])) {
                minX = minOf(minX, x); maxX = maxOf(maxX, x); minY = minOf(minY, y); maxY = maxOf(maxY, y)
            }
        }
        assertTrue("no glyph pixels in $tag", maxX >= 0)
        return (maxX - minX + 1) / stageDensity to (maxY - minY + 1) / stageDensity
    }

    // iOS visible outline: xmark 22 bold = 17x17 pt; mic / mic.slash 25 medium calibrated with the same rendering (17 / 17.875)
    // heights 25.7 / 26.3 pt. After converting by the ratio of the Material glyph within its 24-unit grid, the Android-rendered glyph outline differs from it by no more than 1.5 dp.
    @Test
    fun stage_button_glyphs_match_ios_bbox() {
        RuntimeEnvironment.setQualifiers("+en-w360dp-h640dp-xxhdpi")
        assertEquals(29f, StageEndGlyphSize.value, 0f)
        assertEquals(32f, StageMicGlyphSize.value, 0f)
        assertEquals(31f, StageMicOffGlyphSize.value, 0f)
        fun white(c: androidx.compose.ui.graphics.Color) = c.red > 0.95f && c.green > 0.95f && c.blue > 0.95f
        fun violet(c: androidx.compose.ui.graphics.Color) =
            kotlin.math.abs(c.red - 0x7C / 255f) < 0.12f && kotlin.math.abs(c.green - 0x4D / 255f) < 0.12f && c.blue > 0.88f

        val listening = stage(status = { ConversationStatusKey.LISTENING })
        val (endW, endH) = glyphBox("voice_conversation_end_button", ::white)
        assertEquals("end ✕ width", 17f, endW, 1.5f)
        assertEquals("end ✕ height", 17f, endH, 1.5f)
        val (_, micH) = glyphBox("voice_conversation_mute_button", ::violet)
        assertEquals("mic height", 25.7f, micH, 1.5f)
        listening.setContent {}
        composeRule.waitForIdle()
        listening.finish()

        val muted = stage(status = { ConversationStatusKey.MUTED })
        val (_, offH) = glyphBox("voice_conversation_mute_button", ::white)
        assertEquals("mic_off height", 26.3f, offH, 1.5f)
        muted.setContent {}
        composeRule.waitForIdle()
        muted.finish()
    }

    // Button bottom to screen bottom = max(54 - nav bar, 20) + nav bar: with the stage against the nav bar (host padding 0 / 24 / 48 dp) it is 54 / 54 / 68 respectively.
    @Test
    fun stage_buttons_bottom_at_least_54_from_screen_bottom() {
        RuntimeEnvironment.setQualifiers("+en-w392dp-h720dp")
        for ((nav, expected) in listOf(0 to 54f, 24 to 54f, 48 to 68f)) {
            val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
            var d = 1f
            var view: android.view.View? = null
            activity.setContent {
                OriveoTheme(darkTheme = false) {
                    d = LocalDensity.current.density
                    view = LocalView.current
                    Box(Modifier.fillMaxSize()) {
                        Box(Modifier.align(Alignment.BottomCenter).padding(bottom = nav.dp)) {
                            VoiceConversationBar(
                                status = ConversationStatusKey.LISTENING,
                                level = null,
                                page = VoiceConversationPage.Chat,
                                onEnd = {},
                                onTapOrb = {},
                                onToggleMute = {},
                            )
                        }
                    }
                }
            }
            composeRule.waitForIdle()
            val host = checkNotNull(view)
            val location = IntArray(2).also { host.getLocationInWindow(it) }
            for (tag in listOf("voice_conversation_mute_button", "voice_conversation_end_button")) {
                val button = composeRule.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
                val gapDp = (host.rootView.height - (location[1] + button.bottom)) / d
                assertEquals("nav $nav $tag", expected, gapDp, 1f)
            }
            activity.setContent {}
            composeRule.waitForIdle()
            activity.finish()
        }
    }

    @Test
    fun switching_notice_clears_after_1600ms() {
        RuntimeEnvironment.setQualifiers("+en")
        val app = RuntimeEnvironment.getApplication()
        val listening = app.getString(R.string.voice_conversation_status_listening)
        val notice = app.getString(R.string.voice_realtime_switched_to, "GPT Realtime")
        composeRule.mainClock.autoAdvance = false

        var switching by mutableStateOf<String?>(null)
        var layout: TextLayoutResult? = null
        val activity = stage(status = { ConversationStatusKey.LISTENING }, onLayout = { layout = it }, switchingTo = { switching })
        composeRule.mainClock.advanceTimeBy(500)
        composeRule.waitForIdle()
        switching = "GPT Realtime"
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.waitForIdle()
        assertEquals(notice, layout?.layoutInput?.text?.text)
        // Switching finishes before 1.6 s: the hint still stays for the full 1.6 s.
        switching = null
        composeRule.mainClock.advanceTimeBy(400)
        composeRule.waitForIdle()
        assertEquals(notice, layout?.layoutInput?.text?.text)
        composeRule.mainClock.advanceTimeBy(800)
        composeRule.waitForIdle()
        assertEquals(listening, layout?.layoutInput?.text?.text)
        activity.finish()
    }
    private fun tagged(tag: String) =
        composeRule.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes()

    // Same as iOS RealtimeIdleStageSurface(failure:): after a failure no session stage remains (no mute / end), and it returns to the idle stage: the explanation slot shows the failure card,
    // the bottom row is "switch to typing"; the max_duration card has text only and no buttons, and tapping the orb = continue the chat.
    @Test
    fun failureReturnsToIdleStage() {
        RuntimeEnvironment.setQualifiers("+en")
        val app = RuntimeEnvironment.getApplication()
        val auth = RealtimeFailure(RealtimeModel.CATEGORY_AUTH, "conn-1", "OpenAI", "gpt-realtime")
        val failure = mutableStateOf<RealtimeFailure?>(auth)
        val opened = mutableListOf<String>()
        var continued = 0
        var started = 0
        val handle = VoiceConversationHandle(
            page = VoiceConversationPage.Chat,
            statusState = mutableStateOf(null),
            level = null,
            onEnd = {},
            onTapOrb = {},
            onToggleMute = {},
            captionState = mutableStateOf(""),
            nudgesState = mutableStateOf(0),
            failureState = failure,
            failureActions = RealtimeFailureActions(
                openConnection = { opened += it },
                continueWithHistory = { continued++ },
            ),
        )
        val settings = languageSettings()
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceConversationSwitcher(handle = handle, languageSettings = settings) {
                    RealtimeVoiceDock(onStart = { started++ }, onKeyboard = {})
                }
            }
        }
        composeRule.waitForIdle()
        assertTrue("no mute button on the idle stage", tagged("voice_conversation_mute_button").isEmpty())
        assertTrue("no end button on the idle stage", tagged("voice_conversation_end_button").isEmpty())
        assertTrue("switch-to-typing chip shown", tagged(RealtimeVoiceDockKeyboardTag).isNotEmpty())
        assertTrue("failure card shown on the idle stage", tagged("voice_realtime_failure_card").isNotEmpty())
        val authCard = realtimeFailureCard(auth)!!
        val authTitle = app.getString(authCard.title, *authCard.titleArgs.toTypedArray())
        assertTrue(composeRule.onAllNodesWithText(authTitle, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())
        composeRule.onNodeWithTag("voice_realtime_failure_action_${RealtimeModel.ACTION_OPEN_CONNECTION}").performClick()
        assertEquals(listOf("conn-1"), opened)

        failure.value = auth.copy(category = RealtimeModel.CATEGORY_MAX_DURATION)
        composeRule.waitForIdle()
        assertTrue("max_duration card shown", tagged("voice_realtime_failure_card").isNotEmpty())
        val word = app.getString(realtimeFailureStatusWord(failure.value)!!)
        assertTrue(composeRule.onAllNodesWithText(word, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())
        RealtimeModel.ACTIONS.values.flatten().toSet().forEach { raw ->
            assertTrue("max_duration card has no $raw button", tagged("voice_realtime_failure_action_$raw").isEmpty())
        }
        assertTrue(tagged("voice_conversation_mute_button").isEmpty())
        composeRule.onNodeWithTag(RealtimeVoiceDockOrbTag).performClick()
        assertEquals(1, continued)
        assertEquals(0, started)
        activity.finish()
    }

    // Same as iOS: failure card buttons are laid out in a row, each taking an equal share of the line (a single button takes full width), and the primary button (brand gradient) is on the right.
    @Test
    fun failureCardButtonsFillWidth() {
        RuntimeEnvironment.setQualifiers("+en")
        val model = mutableStateOf(realtimeFailureCard(RealtimeFailure(RealtimeModel.CATEGORY_QUOTA, "c", "OpenAI", "m"))!!)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Box(Modifier.width(360.dp)) { RealtimeFailureCard(model = model.value, onAction = {}) }
            }
        }
        composeRule.waitForIdle()
        fun bounds(tag: String) = composeRule.onNodeWithTag(tag, useUnmergedTree = true).getUnclippedBoundsInRoot()
        val card = bounds("voice_realtime_failure_card")
        // The card tag sits inside the 16 inset: its bounds are the usable width of the button row; button spacing 10. weight splits by whole pixels, tolerance 1 dp.
        fun near(a: androidx.compose.ui.unit.Dp, b: androidx.compose.ui.unit.Dp) = kotlin.math.abs((a - b).value) < 1f
        val content = card.width
        val primary = bounds("voice_realtime_failure_action_${RealtimeModel.ACTION_RETRY}")
        val secondary = bounds("voice_realtime_failure_action_${RealtimeModel.ACTION_SWITCH_MODEL}")
        assertTrue("primary ${primary.width} vs ${(content - 10.dp) / 2}", near(primary.width, (content - 10.dp) / 2))
        assertTrue("secondary ${secondary.width}", near(secondary.width, (content - 10.dp) / 2))
        assertTrue("primary on the right", primary.left > secondary.left)
        assertTrue(near(secondary.left, card.left))
        assertTrue(near(primary.right, card.right))

        model.value = realtimeFailureCard(RealtimeFailure(RealtimeModel.CATEGORY_AUTH, "c", "OpenAI", "m"))!!
        composeRule.waitForIdle()
        val single = bounds("voice_realtime_failure_action_${RealtimeModel.ACTION_OPEN_CONNECTION}")
        assertTrue("single button ${single.width} spans $content", near(single.width, content))
        activity.finish()
    }
}

private const val STAGE_HOST = "voice_stage_host"

private fun near(a: androidx.compose.ui.unit.Dp, b: androidx.compose.ui.unit.Dp): Boolean = kotlin.math.abs((a - b).value) < 0.5f
