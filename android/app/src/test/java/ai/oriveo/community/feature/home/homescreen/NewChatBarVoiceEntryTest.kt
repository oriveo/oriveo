package ai.oriveo.community.feature.home.homescreen

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.DictationCommands
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.feature.chat.composer.DictationHostActions
import ai.oriveo.community.feature.chat.composer.DICTATION_GLOW_TAG
import ai.oriveo.community.feature.chat.composer.DictationGlowCornerRadiusKey
import ai.oriveo.community.feature.chat.composer.DictationHostCoordinator
import ai.oriveo.community.feature.chat.composer.DictationToastSpec
import ai.oriveo.community.feature.chat.voice.RealtimeVoiceDockKeyboardTag
import ai.oriveo.community.feature.chat.voice.RealtimeVoiceDockOrbTag
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import kotlin.math.abs
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The rendered hero card: the up arrow is always the primary key; the voice key is a secondary key left of it on an empty draft only. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NewChatBarVoiceEntryTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private fun activeModel(vararg capabilities: ModelCapability, id: String = "gpt-4o-mini"): HomeViewModel.ActiveModel {
        val model = AIModel(id = id, name = "GPT-4o mini", isDefault = true, capabilities = capabilities.toList())
        return HomeViewModel.ActiveModel(
            provider = Provider(
                id = "provider-1",
                kind = ProviderKind.OpenAI,
                status = ProviderConnectionState.Connected,
                models = listOf(model),
            ),
            model = model,
        )
    }

    private class Taps {
        var voice = 0
        var send = 0
        var addProvider = 0
    }

    private fun render(
        model: HomeViewModel.ActiveModel?,
        hasProvider: Boolean = true,
        dictation: DictationHostCoordinator? = null,
        text: () -> String,
    ): Pair<ComponentActivity, Taps> {
        val taps = Taps()
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                NewChatBar(
                    activeModel = model,
                    hasProvider = hasProvider,
                    isDark = false,
                    heroText = text(),
                    onHeroTextChange = {},
                    isSendingFromHero = false,
                    isSearchActive = false,
                    onSend = { taps.send++ },
                    onModelSelect = {},
                    onAddProvider = { taps.addProvider++ },
                    onStartVoiceConversation = { taps.voice++ },
                    dictation = dictation,
                )
            }
        }
        composeRule.waitForIdle()
        return activity to taps
    }

    @Test
    fun `empty hero draft shows voice next to send, text hides voice and keeps send`() {
        var text by mutableStateOf("")
        val (activity, taps) = render(activeModel(ModelCapability.Text)) { text }
        val voice = activity.getString(R.string.voice_conversation_start_a11y)
        val send = activity.getString(R.string.send)

        composeRule.onNodeWithContentDescription(voice).performClick()
        assertEquals(1, taps.voice)
        assertEquals(0, taps.send)
        // The up arrow is always there: an empty draft still sends (opens the chat page)
        composeRule.onNodeWithContentDescription(send).performClick()
        assertEquals(1, taps.send)

        composeRule.runOnIdle { text = "hello" }
        composeRule.waitForIdle()
        composeRule.onNodeWithContentDescription(voice).assertDoesNotExist()
        composeRule.onNodeWithContentDescription(send).performClick()
        assertEquals(2, taps.send)
        assertEquals(1, taps.voice)
    }

    @Test
    fun `image only model hides voice and keeps send on an empty hero draft`() {
        val (activity, taps) = render(activeModel(ModelCapability.ImageGen, id = "gpt-image-1")) { "" }
        composeRule.onNodeWithContentDescription(activity.getString(R.string.voice_conversation_start_a11y)).assertDoesNotExist()
        composeRule.onNodeWithContentDescription(activity.getString(R.string.send)).performClick()
        assertEquals(1, taps.send)
        assertEquals(0, taps.voice)
    }

    @Test
    fun `no connected provider still offers voice, send goes through onSend before provider setup`() {
        // Both the voice key and the up arrow hand over to the home view model, which decides whether to ask for provider setup; neither jumps straight to it.
        val (activity, taps) = render(model = null, hasProvider = false) { "" }
        composeRule.onNodeWithContentDescription(activity.getString(R.string.voice_conversation_start_a11y)).performClick()
        assertEquals(1, taps.voice)
        assertEquals(0, taps.addProvider)
        composeRule.onNodeWithContentDescription(activity.getString(R.string.send)).performClick()
        assertEquals(1, taps.send)
        assertEquals(0, taps.addProvider)
    }

    @Test
    fun `home screen routes the hero voice entry to the view model placeholder`() {
        val home = File("src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt").readText()
        assertTrue(home.contains("onStartVoiceConversation = viewModel::requestVoiceConversation"))
    }

    @Test
    fun `voice key sits on the bottom row just left of send and there is no mic`() {
        val handle = DictationHostCoordinator("draft:home", IdleCommands(), NoopActions())
        val (activity, _) = render(activeModel(ModelCapability.Text), dictation = handle) { "" }
        composeRule.onNodeWithContentDescription(activity.getString(R.string.voice_dictate)).assertDoesNotExist()
        val voice = composeRule.onNodeWithContentDescription(activity.getString(R.string.voice_conversation_start_a11y))
            .getUnclippedBoundsInRoot()
        val send = composeRule.onNodeWithContentDescription(activity.getString(R.string.send))
            .getUnclippedBoundsInRoot()

        // Vertically centered in the same Row; the 1dp tolerance only absorbs pixel rounding
        val voiceCenterY = (voice.top + voice.bottom).value / 2
        val sendCenterY = (send.top + send.bottom).value / 2
        assertTrue("voice key center y $voiceCenterY must match send $sendCenterY", abs(voiceCenterY - sendCenterY) < 1f)
        assertTrue("voice key (right ${voice.right}) must sit left of send (left ${send.left})", voice.right <= send.left)
        // The voice key tap target sits 10dp from the up arrow (the 1dp tolerance only absorbs pixel rounding)
        assertTrue("voice key to send gap ${send.left - voice.right} must be 10dp", abs((send.left - voice.right).value - 10f) < 1f)
    }

    @Test
    fun `recording into the home slot rings the hero card with the glow border at corner 26, idle shows none`() {
        val commands = IdleCommands()
        val handle = DictationHostCoordinator("draft:home", commands, NoopActions())
        render(activeModel(ModelCapability.Text), dictation = handle) { "" }
        composeRule.onNodeWithTag(DICTATION_GLOW_TAG, useUnmergedTree = true).assertDoesNotExist()

        composeRule.runOnIdle { commands.state.value = DictationState.Recording("draft:home", startedAt = 0L) }
        composeRule.waitForIdle()
        val glow = composeRule.onNodeWithTag(DICTATION_GLOW_TAG, useUnmergedTree = true).fetchSemanticsNode()
        val radius = glow.config.getOrElseNullable(DictationGlowCornerRadiusKey) { null }
        assertNotNull("glow border must carry its corner radius", radius)
        assertEquals(26.dp, radius)
        assertEquals(26.dp, HOME_HERO_CORNER_RADIUS)
    }

    private class RealtimeBar {
        var model by mutableStateOf<HomeViewModel.ActiveModel?>(null)
        var hasProvider by mutableStateOf(false)
        var preparing by mutableStateOf(true)
        var stored by mutableStateOf<Pair<String, String>?>("provider-1" to "gpt-realtime")
    }

    private fun renderRealtime(bar: RealtimeBar): ComponentActivity {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                NewChatBar(
                    activeModel = bar.model,
                    hasProvider = bar.hasProvider,
                    isDark = false,
                    heroText = "",
                    onHeroTextChange = {},
                    isSendingFromHero = false,
                    isSearchActive = false,
                    onSend = {},
                    onModelSelect = {},
                    onAddProvider = {},
                    onStartVoiceConversation = {},
                    realtimeSelected = true,
                    realtimePreparing = bar.preparing,
                    realtimeStoredSelection = bar.stored,
                )
            }
        }
        composeRule.waitForIdle()
        return activity
    }

    /**
     * While preparing, the pill shows the stored model id directly (no "add provider" flash). After
     * switching to typing, the catalog arriving for the same selection does not bounce back to the voice dock.
     * Mirrors the iOS test.
     */
    @Test
    fun typingStaysWhenCatalogArrivesForSameSelection() {
        val bar = RealtimeBar()
        val activity = renderRealtime(bar)
        composeRule.onNodeWithText("gpt-realtime").assertExists()
        composeRule.onNodeWithText(activity.getString(R.string.add_provider)).assertDoesNotExist()

        composeRule.onNodeWithTag(RealtimeVoiceDockKeyboardTag).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag(RealtimeVoiceDockOrbTag).assertDoesNotExist()

        // List and catalog arrived: activeModel goes from absent to present; the store selection did not change.
        composeRule.runOnIdle {
            bar.model = activeModel(ModelCapability.Text, id = "gpt-realtime")
            bar.hasProvider = true
            bar.preparing = false
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithTag(RealtimeVoiceDockOrbTag).assertDoesNotExist()
        composeRule.onNodeWithContentDescription(activity.getString(R.string.send)).assertExists()
    }

    @Test
    fun typingResetsWhenStoredSelectionChanges() {
        val bar = RealtimeBar().apply {
            model = activeModel(ModelCapability.Text, id = "gpt-realtime")
            hasProvider = true
            preparing = false
        }
        renderRealtime(bar)
        composeRule.onNodeWithTag(RealtimeVoiceDockKeyboardTag).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag(RealtimeVoiceDockOrbTag).assertDoesNotExist()

        // The stored selection really changed: back to the voice dock.
        composeRule.runOnIdle { bar.stored = "provider-1" to "gpt-realtime-mini" }
        composeRule.waitForIdle()
        composeRule.onNodeWithTag(RealtimeVoiceDockOrbTag).assertExists()
    }

    private class IdleCommands : DictationCommands {
        override val state = MutableStateFlow<DictationState>(DictationState.Idle)
        override val engineInfo = MutableStateFlow<DictationEngineInfo?>(null)
        override val pendingDurationSec = MutableStateFlow<Double?>(null)
        override val levelMeter = MutableStateFlow<List<Float>>(emptyList())
        override val boundOwner = MutableStateFlow<Any?>(null)
        override fun start(slotKey: String) = Unit
        override fun finish(submit: DictationSubmit) = Unit
        override fun discard() = Unit
        override fun transcribeSaved(submit: DictationSubmit) = Unit
        override fun discardAndRestart() = Unit
        override fun dismissDenied() = Unit
        override fun undoDiscard(slotKey: String): Boolean = false
        override fun bind(slotKey: String, owner: Any) = Unit
        override fun detach(slotKey: String, owner: Any) = Unit
    }

    private class NoopActions : DictationHostActions {
        override fun insert(text: String) = Unit
        override fun canSend(): Boolean = true
        override fun send() = Unit
        override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) = Unit
        override fun openAppSettings() = Unit
        override fun openProviderDetail(providerId: String) = Unit
        override fun openProviderSetup() = Unit
        override fun openVoiceSettings() = Unit
    }
}
