package ai.oriveo.community.feature.chat.voice

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
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
    fun `status words fit in two lines for every reachable status in every locale`() {
        // 360 dp phone: home bar sits inside the hero card (20 + 19 dp each side), chat bar inside 16 dp margins.
        val widths = mapOf(VoiceConversationPage.Home to 282.dp, VoiceConversationPage.Chat to 328.dp)
        val truncated = mutableListOf<String>()
        for (qualifier in qualifiers) {
            RuntimeEnvironment.setQualifiers("+$qualifier-w360dp")
            for ((page, width) in widths) {
                var status by mutableStateOf(ConversationStatusKey.LISTENING)
                var layout: TextLayoutResult? = null
                val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
                activity.setContent {
                    OriveoTheme(darkTheme = false) {
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
                for (key in VoiceConversationBarStatus.reachable(page)) {
                    status = key
                    composeRule.waitForIdle()
                    val result = requireNotNull(layout)
                    val last = result.lineCount - 1
                    if (result.lineCount > 2 || result.isLineEllipsized(last) || result.hasVisualOverflow) {
                        truncated += "$qualifier/$page/${key.rawValue}: ${result.layoutInput.text}"
                    }
                }
                activity.finish()
            }
        }
        assertTrue("truncated status words: $truncated", truncated.isEmpty())
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
        composeRule.onNodeWithTag("voice_conversation_end_button").fetchSemanticsNode()
        composeRule.onNodeWithTag("voice_conversation_mute_button").fetchSemanticsNode()
        val live = composeRule.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion), useUnmergedTree = true)
            .fetchSemanticsNodes()
        assertTrue("no live region in the bar: the host announces once", live.isEmpty())
        assertEquals(null, orb.config.getOrNull(SemanticsProperties.LiveRegion))
    }

    // Old behavior: in the THINKING state composition read driftA / driftB .value, so every animation frame recomposed the orb once (about 60 times per second).
    @Test
    fun thinking_orb_does_not_recompose_per_frame() {
        var compositions = 0
        composeRule.mainClock.autoAdvance = false
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceOrb(
                    status = ConversationStatusKey.THINKING,
                    level = null,
                    motion = null,
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
}
