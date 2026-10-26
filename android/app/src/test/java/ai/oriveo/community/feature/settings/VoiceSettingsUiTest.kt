package ai.oriveo.community.feature.settings

import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.ReadAloudEnvironment
import ai.oriveo.community.core.voice.SystemTtsVoiceProbe
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogClient
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngine
import ai.oriveo.community.core.voice.VoiceEngineResolution
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceFallbackReason
import ai.oriveo.community.core.voice.VoiceNoticeSite
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoicePreviewController
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceSelectionPersist
import ai.oriveo.community.core.voice.VoiceSpeedRange
import ai.oriveo.community.core.voice.VoiceSttEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.core.voice.VoiceTtsEntry
import ai.oriveo.community.ui.theme.OriveoTheme
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Settings > Voice page: the group rows and footers, cloud voice / speed, pending notices, the system voice hint jump, voice preview, and single-choice recognition language. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VoiceSettingsUiTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val prefs = RuntimeEnvironment.getApplication()
        .getSharedPreferences("voice-settings-ui-test", Context.MODE_PRIVATE)
        .also { it.edit().clear().commit() }
    private val settings = VoiceEngineSettings { prefs }

    private val openAI = Provider(
        id = "conn-openai",
        kind = ProviderKind.OpenAI,
        apiKey = "sk-live",
        baseUrlText = "https://api.openai.com/v1",
    )
    private val sttEntry = VoiceSttEntry(
        model = "whisper-1",
        transport = VoiceTransport.OpenAITranscriptions,
        path = "/audio/transcriptions",
        maxBytes = 25_000_000,
        maxDurationSec = 600,
        isDefault = true,
    )
    private val ttsWithSpeed = VoiceTtsEntry(
        model = "tts-1",
        transport = VoiceTransport.OpenAISpeech,
        path = "/audio/speech",
        voices = listOf(VoiceOption("alloy", isDefault = true), VoiceOption("nova")),
        outputFormat = "mp3",
        maxChars = 4096,
        speedRange = VoiceSpeedRange(0.25, 4.0),
        isDefault = true,
    )
    private val ttsNoSpeed = ttsWithSpeed.copy(model = "gpt-4o-mini-tts", speedRange = null, isDefault = false)
    private val realtimeEntry = VoiceRealtimeEntry(
        model = "gpt-realtime",
        transport = VoiceTransport.OpenAIRealtime,
        path = "/realtime",
        contextWindow = 32_000,
        voices = listOf(VoiceOption("marin", isDefault = true)),
        inputTranscriptionModel = "gpt-4o-transcribe",
        isDefault = true,
    )
    private val catalog = VoiceCatalog(
        schemaVersion = 2,
        providers = mapOf(
            ProviderKind.OpenAI to VoiceProviderCatalog(
                stt = listOf(sttEntry),
                tts = listOf(ttsWithSpeed, ttsNoSpeed),
                realtime = listOf(realtimeEntry),
            ),
        ),
    )

    private val catalogClient = mockk<VoiceCatalogClient> {
        every { state } returns MutableStateFlow<VoiceCatalogState?>(VoiceCatalogState.Available(catalog))
        coEvery { ensureFresh() } returns null
        coEvery { refresh() } returns VoiceCatalogState.Available(catalog)
    }
    private val providerRepository = mockk<ProviderRepository> {
        every { observeAll() } returns MutableStateFlow(listOf(openAI))
    }
    private var hintNeeded = false
    private val probe = object : SystemTtsVoiceProbe {
        override suspend fun hintNeeded(locale: java.util.Locale): Boolean = hintNeeded
    }

    /** The preview engine never becomes ready: the session stays in "previewing" and only ends through toggle / stop. */
    private val preview = VoicePreviewController(
        engineSource = { awaitCancellation() },
        environment = mockk<ReadAloudEnvironment>(relaxed = true),
        sampleText = { "" },
        stopReadAloud = {},
    )

    private var visible by mutableStateOf(true)
    private lateinit var activity: ComponentActivity

    private fun launch() {
        val model = VoiceSettingsViewModel(settings, catalogClient, probe, providerRepository)
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                if (visible) VoiceSettingsScreen(viewModel = model, previewController = preview)
            }
        }
        composeRule.waitForIdle()
    }

    private fun cloud(direction: VoiceDirection, model: String, voice: String? = null, connectionId: String = openAI.id) {
        settings.setSelection(direction, VoiceEngineSelection.Cloud(ProviderKind.OpenAI, connectionId, model, voice))
    }

    private fun text(value: String) = composeRule.onNodeWithText(value).performScrollTo()

    private val slider = SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)

    @Test
    fun `system rows and footers`() {
        launch()

        // Copy from p2-copy.v1.json.
        text("You don't need to change anything here: dictation, read aloud, and voice conversations use your " +
            "device's built-in voice at no cost. For better accuracy or a nicer voice, switch to a provider you've connected.").assertIsDisplayed()
        text("Dictation").assertIsDisplayed()
        // Engine row: the title is the engine name, with no separate "Dictation Engine" leading title; the direction is read out only in the accessibility description.
        composeRule.onNodeWithText("Dictation Engine").assertDoesNotExist()
        composeRule.onNodeWithContentDescription("Dictation Engine, System", substring = true).assertExists()
        composeRule.onAllNodesWithText("System").assertCountEquals(2)
        composeRule.onAllNodesWithText("Built into your device, free").assertCountEquals(2)
        text("Recognition Language").assertIsDisplayed()
        text("Automatic").assertIsDisplayed()
        text(
            "System dictation is handled by this device's speech recognition service, which may go through Google " +
                "or your device manufacturer. If transcription fails, the saved recording stays on this device for up to 7 days. " +
                "Voice conversations listen with this engine too.",
        ).assertIsDisplayed()
        text("Read Aloud").assertIsDisplayed()
        composeRule.onNodeWithText("Read-Aloud Engine").assertDoesNotExist()
        composeRule.onNodeWithContentDescription("Read-Aloud Engine, System", substring = true).assertExists()
        text("1.0×").assertIsDisplayed()
        composeRule.onNode(slider).assertIsEnabled()
        text(
            "Read aloud skips thinking and code. If the cloud voice is unavailable, the system voice takes over. " +
                "Voice conversations speak with this voice and speed too.",
        ).assertIsDisplayed()
        composeRule.onNodeWithText("Speaking Voice").assertDoesNotExist()
        composeRule.onNodeWithText("This engine doesn't support speed control.").assertDoesNotExist()
        composeRule.onNodeWithText("The selected engine is no longer available. Switched back to System.")
            .assertDoesNotExist()
    }

    @Test
    fun `cloud voice and speed rows`() {
        cloud(VoiceDirection.Stt, "whisper-1")
        cloud(VoiceDirection.Tts, "tts-1", voice = "nova")
        launch()

        composeRule.onAllNodesWithText(ProviderKind.OpenAI.displayName).assertCountEquals(2)
        composeRule.onNodeWithContentDescription("Dictation Engine, OpenAI", substring = true).assertExists()
        text("whisper-1 · Billed to your connection").assertIsDisplayed()
        text("tts-1 · Billed to your connection").assertIsDisplayed()
        text(
            "Recordings are sent only to the provider you choose. If transcription fails, the recording stays " +
                "on this device for up to 7 days. Voice conversations listen with this engine too.",
        ).assertIsDisplayed()
        text("Speaking Voice").assertIsDisplayed()
        text("Nova").assertIsDisplayed()

        composeRule.onNode(slider).assertIsEnabled()
            .performSemanticsAction(SemanticsActions.SetProgress) { it(1.5f) }
        composeRule.waitForIdle()
        assertEquals(1.5, settings.speechRate(), 0.0)
        text("1.5×").assertIsDisplayed()
    }

    @Test
    fun `conversation group disclosure writes only on agree`() {
        launch()

        text("Voice Conversation").assertIsDisplayed()
        text("Follow Current Model").assertIsDisplayed()
        text(
            "A realtime model hears you and answers directly, so replies come faster, but this chat's model isn't used.",
        ).assertIsDisplayed()

        // With the system engine the title is the direction name "Conversation Engine" and the subtitle is "Follow Current Model".
        text("Conversation Engine").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Conversation Engine, Follow Current Model", substring = true)
            .performScrollTo()
            .performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Dictation → current model → read aloud").assertIsDisplayed()
        composeRule.onNodeWithText("gpt-realtime").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Use OpenAI for Voice Conversations?").assertIsDisplayed()
        composeRule.onNodeWithText(
            "In voice conversations, OpenAI answers instead of this chat's model. Your voice and this chat's history " +
                "are sent to OpenAI, usage is billed to your connection, and OpenAI's privacy policy applies.",
        ).assertIsDisplayed()

        // Not now: nothing is written and no consent is recorded.
        composeRule.onNodeWithText("Not Now").performClick()
        composeRule.waitForIdle()
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Realtime))
        assertFalse(settings.disclosure.isAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime))

        // Agree: the selection is written and consent recorded, and the row subtitle becomes "provider · model".
        composeRule.onNodeWithText("gpt-realtime").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Agree and Use").performClick()
        composeRule.waitForIdle()
        val selection = settings.selection(VoiceDirection.Realtime) as VoiceEngineSelection.Cloud
        assertEquals("gpt-realtime", selection.model)
        assertEquals(openAI.id, selection.connectionId)
        assertTrue(settings.disclosure.isAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime))
        text("OpenAI · gpt-realtime").assertIsDisplayed()
    }

    @Test
    fun `cloud conversation engine row keeps direction title`() {
        cloud(VoiceDirection.Realtime, "gpt-realtime")
        launch()

        // With a cloud engine the title is still "Conversation Engine"; the provider name appears only in the subtitle "provider name · model".
        text("Conversation Engine").assertIsDisplayed()
        text("OpenAI · gpt-realtime").assertIsDisplayed()
        composeRule.onNodeWithText(ProviderKind.OpenAI.displayName).assertDoesNotExist()
    }

    @Test
    fun `engine row merged semantics reads provider name once`() {
        cloud(VoiceDirection.Stt, "whisper-1")
        launch()

        val row = composeRule.onNodeWithContentDescription("Dictation Engine, OpenAI", substring = true)
            .fetchSemanticsNode()
        assertEquals(1, row.spokenText().split(ProviderKind.OpenAI.displayName).size - 1)
    }

    @Test
    fun `speed disabled footer`() {
        cloud(VoiceDirection.Tts, "gpt-4o-mini-tts")
        launch()

        composeRule.onNode(slider).assertIsNotEnabled()
        text("This engine doesn't support speed control.").assertIsDisplayed()
    }

    @Test
    fun `pending notice`() {
        // The call site finds a fallback and leaves one pending notice for the settings page.
        cloud(VoiceDirection.Stt, "whisper-1", connectionId = "gone")
        settings.applyResolution(
            VoiceDirection.Stt,
            VoiceEngineResolution(
                engine = VoiceEngine.System,
                reason = VoiceFallbackReason.ConnectionMissing,
                notice = true,
                persist = VoiceSelectionPersist.System,
            ),
            VoiceNoticeSite.Use,
        )
        launch()

        text("The selected engine is no longer available. Switched back to System.").assertIsDisplayed()
        composeRule.onAllNodesWithText("System").assertCountEquals(2)
    }

    @Test
    fun `tts hint opens settings`() {
        hintNeeded = true
        launch()

        text("For a more natural voice, download voice data in your system's text-to-speech settings.").performClick()
        composeRule.waitForIdle()

        assertEquals("com.android.settings.TTS_SETTINGS", shadowOf(activity).nextStartedActivity.action)
    }

    @Test
    fun `preview toggles`() {
        cloud(VoiceDirection.Tts, "tts-1", voice = "nova")
        launch()

        text("Speaking Voice").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Alloy").assertIsDisplayed()
        composeRule.onNode(hasText("Nova") and isSelected()).assertExists()

        composeRule.onAllNodesWithContentDescription("Preview")[1].performClick()
        composeRule.waitForIdle()
        assertEquals("nova", preview.previewing.value)
        composeRule.onNodeWithContentDescription("Stop").assertIsDisplayed()
        composeRule.onAllNodesWithContentDescription("Preview").assertCountEquals(1)

        composeRule.onNodeWithContentDescription("Stop").performClick()
        composeRule.waitForIdle()
        assertNull(preview.previewing.value)

        // Picking a voice does not interrupt; leaving the page stops the preview.
        composeRule.onAllNodesWithContentDescription("Preview")[0].performClick()
        composeRule.onNodeWithText("Alloy").performClick()
        composeRule.waitForIdle()
        assertEquals("alloy", (settings.selection(VoiceDirection.Tts) as VoiceEngineSelection.Cloud).voice)
        assertEquals("alloy", preview.previewing.value)
        visible = false
        composeRule.waitForIdle()
        assertNull(preview.previewing.value)
    }

    @Test
    fun `recognition language selects`() {
        launch()

        text("Recognition Language").performClick()
        composeRule.waitForIdle()
        composeRule.onAllNodesWithText("Automatic").assertCountEquals(2)
        composeRule.onNodeWithText("\u65e5\u672c\u8a9e").performScrollTo().performClick()
        composeRule.waitForIdle()

        assertEquals("ja", settings.recognitionLanguage())
        text("\u65e5\u672c\u8a9e").assertIsDisplayed()
    }
}

/** When a row sets a custom description TalkBack reads the merged description (including child descriptions); otherwise it reads the child text. */
private fun SemanticsNode.spokenText(): String {
    val descriptions = config.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
    val parts = descriptions.ifEmpty { config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } }
    return parts.joinToString(", ")
}
