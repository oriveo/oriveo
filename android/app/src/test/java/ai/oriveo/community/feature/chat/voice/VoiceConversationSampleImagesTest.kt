package ai.oriveo.community.feature.chat.voice

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.feature.chat.composer.ComposerActionCluster
import ai.oriveo.community.feature.home.homescreen.HOME_HERO_CORNER_RADIUS
import ai.oriveo.community.feature.home.auroraGlassCard
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Voice conversation samples: renders PNGs with production components under Robolectric native graphics, for visual review.
 * Runs only when ORIVEO_VOICE_SAMPLES_DIR is non-empty; skipped in full runs, produces no files.
 * File name `<locale>-<theme>-<page>-<state>.png`; level fixed at 0.5, animation clock advanced manually.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VoiceConversationSampleImagesTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var outDir: File

    @Before
    fun requireOutputDir() {
        val dir = System.getenv("ORIVEO_VOICE_SAMPLES_DIR")
        assumeTrue("ORIVEO_VOICE_SAMPLES_DIR not set", !dir.isNullOrBlank())
        outDir = File(dir!!).apply { mkdirs() }
    }

    @Test
    @Config(qualifiers = "+zh-rCN-night")
    fun `zh-Hans dark`() = renderSet("zh-Hans", dark = true)

    @Test
    @Config(qualifiers = "+zh-rCN-notnight")
    fun `zh-Hans light`() = renderSet("zh-Hans", dark = false)

    @Test
    @Config(qualifiers = "+en-night")
    fun `en dark`() = renderSet("en", dark = true)

    @Test
    @Config(qualifiers = "+en-notnight")
    fun `en light`() = renderSet("en", dark = false)

    // fr speakingTapToInterrupt is the longest string across locales; only this one is checked for font-size reduction / wrapping
    @Test
    @Config(qualifiers = "+fr-night")
    fun `fr dark longest status`() {
        render("fr-dark-chat-speakingTapToInterrupt", dark = true) {
            ChatScene(ConversationStatusKey.SPEAKING_TAP_TO_INTERRUPT)
        }
    }

    private fun renderSet(locale: String, dark: Boolean) {
        val theme = if (dark) "dark" else "light"
        VoiceConversationBarStatus.reachable(VoiceConversationPage.Chat).sortedBy { it.ordinal }.forEach { status ->
            render("$locale-$theme-chat-${status.rawValue}", dark) { ChatScene(status) }
        }
        VoiceConversationBarStatus.reachable(VoiceConversationPage.Home).sortedBy { it.ordinal }.forEach { status ->
            render("$locale-$theme-home-${status.rawValue}", dark) { HomeScene(status, dark) }
        }
        listOf(
            Triple("voice", false, false),
            Triple("send", true, false),
            Triple("stop", false, true),
        ).forEach { (name, primed, generating) ->
            render("$locale-$theme-composer-$name", dark) { ClusterScene(primed = primed, generating = generating) }
        }
    }

    private fun render(name: String, dark: Boolean, content: @Composable () -> Unit) {
        composeRule.mainClock.autoAdvance = false
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = dark) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .background(OriveoTheme.colors.background)
                        .testTag(SAMPLE_TAG),
                ) { content() }
            }
        }
        // Advance a fixed duration so the level spring settles at 0.5 and long text finishes shrinking; the thinking-state flow stays at the same phase
        composeRule.mainClock.advanceTimeBy(SETTLE_MILLIS)
        composeRule.waitForIdle()
        val bitmap = composeRule.onNodeWithTag(SAMPLE_TAG).captureToImage().asAndroidBitmap()
        File(outDir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        activity.finish()
    }

    // Chat page: the same outer margins as the barModifier of VoiceConversationSwitcher in ChatComposerHost
    @Composable
    private fun ChatScene(status: ConversationStatusKey) {
        VoiceConversationBar(
            status = status,
            level = MutableStateFlow(LEVEL),
            page = VoiceConversationPage.Chat,
            onEnd = {},
            onTapOrb = {},
            onToggleMute = {},
            modifier = Modifier
                .padding(horizontal = OriveoTheme.spacing.lg)
                .padding(top = OriveoTheme.spacing.xs, bottom = OriveoTheme.spacing.sm),
        )
    }

    // Home: the same outer hero card as NewChatBar (20dp margin + auroraGlassCard + 19/19/19/15 inner padding)
    @Composable
    private fun HomeScene(status: ConversationStatusKey, dark: Boolean) {
        Column(
            modifier = Modifier
                .padding(vertical = 24.dp)
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .auroraGlassCard(isDark = dark, cornerRadius = HOME_HERO_CORNER_RADIUS, focused = false)
                .padding(start = 19.dp, end = 19.dp, top = 19.dp, bottom = 15.dp),
        ) {
            VoiceConversationBar(
                status = status,
                level = MutableStateFlow(LEVEL),
                page = VoiceConversationPage.Home,
                onEnd = {},
                onTapOrb = {},
                onToggleMute = {},
            )
        }
    }

    @Composable
    private fun ClusterScene(primed: Boolean, generating: Boolean) {
        Row(Modifier.padding(24.dp)) {
            ComposerActionCluster(
                isGenerating = generating,
                isPrimed = primed,
                enabled = true,
                voiceAvailable = true,
                onClick = {},
            )
        }
    }

    private companion object {
        const val SAMPLE_TAG = "voice_sample_root"
        const val LEVEL = 0.5f
        const val SETTLE_MILLIS = 1_500L
    }
}
