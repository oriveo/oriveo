package ai.oriveo.community.feature.settings

import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasText
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.performClick
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineChooser
import ai.oriveo.community.core.voice.VoiceEngineOption
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.ui.theme.OriveoTheme
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

/** Engine sheet and cloud voice disclosure sheet: rows and checkmarks, footer, tap to close, disclosure agree / not now, and add-connection closing before navigating. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VoiceEngineSheetUiTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val prefs = RuntimeEnvironment.getApplication()
        .getSharedPreferences("voice-engine-sheet-test", Context.MODE_PRIVATE)
    private val settings = VoiceEngineSettings { prefs }
    private val chooser = VoiceEngineChooser(settings, settings.disclosure)

    private val work = VoiceEngineOption.Cloud(ProviderKind.OpenAI, "conn-work", "gpt-4o-transcribe", isDefault = true)
    private val home = VoiceEngineOption.Cloud(ProviderKind.OpenAI, "conn-home", "whisper-1", isDefault = false)
    private val options = listOf(VoiceEngineOption.System, work, home)
    private val names = mapOf("conn-work" to "Work", "conn-home" to "Home")

    private val events = mutableListOf<String>()
    private var visible by mutableStateOf(true)
    private var footer by mutableStateOf<VoiceEngineSheetFooter>(VoiceEngineSheetFooter.None)

    private fun launch(selection: VoiceEngineSelection = VoiceEngineSelection.System) {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                if (visible) {
                    VoiceEngineSheet(
                        direction = VoiceDirection.Stt,
                        model = VoiceEngineSheetModel(
                            rows = VoiceEngineSheetModels.rows(options, selection, names),
                            footer = footer,
                        ),
                        catalog = VoiceCatalog(),
                        chooser = chooser,
                        onDismiss = {
                            events += "dismiss"
                            visible = false
                        },
                        onAddConnection = { events += "add" },
                    )
                }
            }
        }
        composeRule.waitForIdle()
    }

    private fun assertEngineSheetGone() {
        composeRule.onNodeWithText("Dictation Engine").assertDoesNotExist()
    }

    private fun assertDisclosureGone() {
        composeRule.onNodeWithText("Use OpenAI for Dictation?").assertDoesNotExist()
    }

    @Test
    fun `rows and check`() {
        launch(selection = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-work", "gpt-4o-transcribe"))

        composeRule.onNodeWithText("Dictation Engine").assertIsDisplayed()
        composeRule.onNodeWithText("System").assertIsNotSelected()
        composeRule.onNodeWithText("Built into your device, free").assertIsDisplayed()
        composeRule.onNodeWithText("gpt-4o-transcribe · Work").assertIsSelected()
        composeRule.onNodeWithText("whisper-1 · Home").assertIsNotSelected()
        composeRule.onNodeWithText("Add Connection").assertIsDisplayed()
    }

    @Test
    fun `cloud row shows provider name and model`() {
        launch()

        // A cloud row has two lines: title = provider display name, subtitle = model id (suffixed with the connection name when a provider has several connections).
        composeRule.onAllNodesWithText(ProviderKind.OpenAI.displayName, useUnmergedTree = true).assertCountEquals(2)
        composeRule.onNodeWithText("gpt-4o-transcribe · Work", useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText("whisper-1 · Home", useUnmergedTree = true).assertIsDisplayed()
    }

    @Test
    fun `cloud row merged semantics reads provider name once`() {
        launch()

        // The row has no custom description, so TalkBack reads the badge description together with the child text: the provider name may appear only once in total.
        val config = composeRule.onNode(hasText("gpt-4o-transcribe · Work")).fetchSemanticsNode().config
        val spoken = (
            config.getOrNull(SemanticsProperties.ContentDescription).orEmpty() +
                config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text }
            ).joinToString(", ")
        assertEquals(1, spoken.split(ProviderKind.OpenAI.displayName).size - 1)
    }

    @Test
    fun `footer variants`() {
        launch()
        composeRule.onNodeWithText("No cloud voice engines yet").assertDoesNotExist()
        composeRule.onNodeWithText("Cloud engines can't be loaded right now").assertDoesNotExist()

        footer = VoiceEngineSheetFooter.CatalogEmpty
        composeRule.onNodeWithText("No cloud voice engines yet").assertIsDisplayed()

        footer = VoiceEngineSheetFooter.LoadFailed
        composeRule.onNodeWithText("Cloud engines can't be loaded right now").assertIsDisplayed()
        composeRule.onNodeWithText("No cloud voice engines yet").assertDoesNotExist()

        footer = VoiceEngineSheetFooter.PendingProviders(listOf(ProviderKind.Anthropic, ProviderKind.DeepSeek))
        composeRule.onNodeWithText("Voice isn't available yet for your Anthropic and DeepSeek connections")
            .assertIsDisplayed()
    }

    @Test
    fun `system selects and closes`() {
        settings.setSelection(VoiceDirection.Stt, VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-work", "gpt-4o-transcribe"))
        launch(selection = settings.selection(VoiceDirection.Stt))

        composeRule.onNodeWithText("System").performClick()
        composeRule.waitForIdle()

        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
        assertEquals(listOf("dismiss"), events)
        assertEngineSheetGone()
    }

    @Test
    fun `cloud without consent shows disclosure`() {
        launch()

        composeRule.onNodeWithText("whisper-1 · Home").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithText("Use OpenAI for Dictation?").assertIsDisplayed()
        composeRule.onNodeWithText(
            "Your recordings will be sent to OpenAI to be transcribed. " +
                "Oriveo doesn't keep them, and the provider's privacy policy applies.",
        ).assertIsDisplayed()
        composeRule.onNodeWithText("Privacy Policy").assertIsDisplayed()
        composeRule.onNodeWithText("Not Now").assertIsDisplayed()
        // Nothing is written before consent, and the engine sheet stays open
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
        assertTrue(events.isEmpty())
        composeRule.onNodeWithText("Dictation Engine").assertExists()
    }

    @Test
    fun `disclosure body scrolls while buttons stay outside scroll`() {
        launch()
        composeRule.onNodeWithText("whisper-1 · Home").performClick()
        composeRule.waitForIdle()

        // Regression guard: when the whole disclosure sheet had no scroll container, large fonts pushed the buttons off screen where they could not be tapped
        val inScroll = hasAnyAncestor(SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange))
        composeRule.onNode(hasText("Use OpenAI for Dictation?") and inScroll).assertExists()
        composeRule.onNode(hasText("Privacy Policy") and inScroll).assertExists()
        composeRule.onNode(hasText("Agree and Use")).assertIsDisplayed()
        composeRule.onNode(hasText("Agree and Use") and inScroll).assertDoesNotExist()
        composeRule.onNode(hasText("Not Now") and inScroll).assertDoesNotExist()
    }

    @Test
    fun `agree closes both`() {
        launch()
        composeRule.onNodeWithText("whisper-1 · Home").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithText("Agree and Use").performClick()
        composeRule.waitForIdle()

        assertEquals(
            VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-home", "whisper-1"),
            settings.selection(VoiceDirection.Stt),
        )
        assertTrue(settings.disclosure.isAccepted(ProviderKind.OpenAI, VoiceDirection.Stt))
        assertEquals(listOf("dismiss"), events)
        assertDisclosureGone()
        assertEngineSheetGone()
    }

    @Test
    fun `decline keeps sheet`() {
        launch()
        composeRule.onNodeWithText("whisper-1 · Home").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithText("Not Now").performClick()
        composeRule.waitForIdle()

        assertDisclosureGone()
        composeRule.onNodeWithText("Dictation Engine").assertIsDisplayed()
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
        assertFalse(settings.disclosure.isAccepted(ProviderKind.OpenAI, VoiceDirection.Stt))
        assertTrue(events.isEmpty())
    }

    @Test
    fun `add connection closes then navigates`() {
        launch()

        composeRule.onNodeWithText("Add Connection").performClick()
        composeRule.waitForIdle()

        assertEquals(listOf("dismiss", "add"), events)
        assertEngineSheetGone()
    }
}
