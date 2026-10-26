package ai.oriveo.community.feature.home.homescreen

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
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
import ai.oriveo.community.feature.chat.composer.DictationHostCoordinator
import ai.oriveo.community.feature.chat.composer.DictationToastSpec
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import kotlin.math.abs
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
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
