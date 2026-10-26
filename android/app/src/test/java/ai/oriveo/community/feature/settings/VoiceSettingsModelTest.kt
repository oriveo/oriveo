package ai.oriveo.community.feature.settings

import ai.oriveo.community.R
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.SystemTtsVoiceProbe
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogClient
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngine
import ai.oriveo.community.core.voice.VoiceEngineOption
import ai.oriveo.community.core.voice.VoiceEngineResolution
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceFallbackReason
import ai.oriveo.community.core.voice.VoiceNoticeSite
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceSelectionPersist
import ai.oriveo.community.core.voice.VoiceSpeedRange
import ai.oriveo.community.core.voice.VoiceSttEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.core.voice.VoiceTtsEntry
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Settings > Voice page state: row values, footers, pending notices, catalog refresh and the system voice hint, all against a real [VoiceEngineSettings]. */
@OptIn(ExperimentalCoroutinesApi::class)
class VoiceSettingsModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val prefs = TestSharedPreferences()
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

    private val catalogState = MutableStateFlow<VoiceCatalogState?>(VoiceCatalogState.Available(catalog))
    private val catalogClient = client(catalogState)
    private val providerRepository = mockk<ProviderRepository> {
        every { observeAll() } returns MutableStateFlow(listOf(openAI))
    }
    private var hintNeeded = false
    private val probedLocales = mutableListOf<Locale>()
    private val probe = object : SystemTtsVoiceProbe {
        override suspend fun hintNeeded(locale: Locale): Boolean {
            probedLocales += locale
            return hintNeeded
        }
    }

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun client(state: MutableStateFlow<VoiceCatalogState?>) = mockk<VoiceCatalogClient> {
        every { this@mockk.state } returns state
        coEvery { ensureFresh() } returns null
        coEvery { refresh() } returns VoiceCatalogState.Available(catalog)
    }

    private fun newModel(client: VoiceCatalogClient = catalogClient) =
        VoiceSettingsViewModel(settings, client, probe, providerRepository)

    private fun cloud(direction: VoiceDirection, model: String, voice: String? = null, connectionId: String = openAI.id) =
        VoiceEngineSelection.Cloud(ProviderKind.OpenAI, connectionId, model, voice).also {
            settings.setSelection(direction, it)
        }

    @Test
    fun `system labels and footer`() = runTest(dispatcher) {
        val model = newModel()
        advanceUntilIdle()

        val state = model.uiState.value
        assertEquals(UiText.Resource(R.string.voice_settings_header), state.header)
        assertEquals(UiText.Resource(R.string.voice_engine_system), state.dictation.engineValue)
        assertEquals(UiText.Resource(R.string.voice_engine_system_subtitle), state.dictation.billedTo)
        assertNull(state.dictation.fallbackNotice)
        assertEquals(UiText.Resource(R.string.voice_dictation_footer_system), state.dictation.footer)
        assertEquals(UiText.Resource(R.string.voice_engine_system), state.readAloud.engineValue)
        assertNull(state.readAloud.voiceValue)
        assertTrue(state.readAloud.speedEnabled)
        assertNull(state.readAloud.speedFooter)
        assertEquals(UiText.Resource(R.string.voice_read_aloud_footer), state.readAloud.footer)
    }

    @Test
    fun `system row has free subtitle`() = runTest(dispatcher) {
        cloud(VoiceDirection.Stt, "whisper-1")
        val model = newModel()
        advanceUntilIdle()

        val state = model.uiState.value
        assertEquals(UiText.Resource(R.string.voice_engine_system), state.readAloud.engineValue)
        assertEquals(UiText.Resource(R.string.voice_engine_system_subtitle), state.readAloud.billedTo)

        settings.setSelection(VoiceDirection.Stt, VoiceEngineSelection.System)
        model.onEngineSheetDismissed(VoiceDirection.Stt)
        assertEquals(UiText.Resource(R.string.voice_engine_system), model.uiState.value.dictation.engineValue)
        assertEquals(UiText.Resource(R.string.voice_engine_system_subtitle), model.uiState.value.dictation.billedTo)
    }

    @Test
    fun `cloud dictation row`() = runTest(dispatcher) {
        val selection = cloud(VoiceDirection.Stt, "whisper-1")
        val model = newModel()
        advanceUntilIdle()

        val dictation = model.uiState.value.dictation
        // The value is the provider display name (not the connection name); the small text carries the model id.
        assertEquals(UiText.Dynamic(ProviderKind.OpenAI.displayName), dictation.engineValue)
        assertEquals(
            UiText.Resource(R.string.voice_engine_billed_to_connection, listOf("whisper-1")),
            dictation.billedTo,
        )
        assertNull(dictation.fallbackNotice)
        assertEquals(UiText.Resource(R.string.voice_dictation_footer_cloud), dictation.footer)
        assertEquals(selection, settings.selection(VoiceDirection.Stt))
        val input = model.engineSheetInput(VoiceDirection.Stt)
        assertEquals(catalog, input.catalog)
        val checked = input.model.rows.single { it.isChecked }.option as VoiceEngineOption.Cloud
        assertEquals("whisper-1", checked.model)
        assertEquals(openAI.id, checked.connectionId)
    }

    @Test
    fun `engine sheet dismissed republishes`() = runTest(dispatcher) {
        cloud(VoiceDirection.Stt, "whisper-1", connectionId = "gone")
        val model = newModel()
        advanceUntilIdle()
        assertNotNull(model.uiState.value.dictation.fallbackNotice)

        // Dismissed by swiping down with the engine unchanged: the pending notice stays.
        model.onEngineSheetDismissed(VoiceDirection.Stt)
        assertNotNull(model.uiState.value.dictation.fallbackNotice)

        // A cloud engine was chosen in the sheet through the same chooser: publish the new value and clear the pending notice.
        settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Stt)
        val option = model.engineSheetInput(VoiceDirection.Stt).model.rows
            .first { it.option is VoiceEngineOption.Cloud }.option
        model.chooser.choose(VoiceDirection.Stt, option, catalog)
        model.onEngineSheetDismissed(VoiceDirection.Stt)
        assertNull(model.uiState.value.dictation.fallbackNotice)
        assertEquals(UiText.Dynamic(ProviderKind.OpenAI.displayName), model.uiState.value.dictation.engineValue)
        assertEquals(
            UiText.Resource(R.string.voice_engine_billed_to_connection, listOf("whisper-1")),
            model.uiState.value.dictation.billedTo,
        )

        // Catalog not arrived: the sheet lists only the system engine and gets an empty catalog.
        catalogState.value = null
        advanceUntilIdle()
        val input = model.engineSheetInput(VoiceDirection.Stt)
        assertEquals(VoiceCatalog(), input.catalog)
        assertEquals(listOf(VoiceEngineOption.System), input.model.rows.map { it.option })
    }

    @Test
    fun `realtime row follows model then shows provider and model`() = runTest(dispatcher) {
        val model = newModel()
        advanceUntilIdle()

        val conversation = model.uiState.value.conversation
        assertEquals(UiText.Resource(R.string.voice_realtime_follow_model), conversation.engineSubtitle)
        assertNull(conversation.fallbackNotice)
        assertEquals(UiText.Resource(R.string.voice_realtime_group_footer), conversation.footer)
        val systemInput = model.engineSheetInput(VoiceDirection.Realtime)
        assertEquals(UiText.Resource(R.string.voice_realtime_follow_model), systemInput.model.systemTitle)
        assertEquals(UiText.Resource(R.string.voice_realtime_follow_model_subtitle), systemInput.model.systemSubtitle)
        assertEquals(VoiceEngineOption.System, systemInput.model.rows.single { it.isChecked }.option)

        cloud(VoiceDirection.Realtime, "gpt-realtime", voice = "marin")
        model.onEngineSheetDismissed(VoiceDirection.Realtime)
        assertEquals(
            UiText.Dynamic("${ProviderKind.OpenAI.displayName} · gpt-realtime"),
            model.uiState.value.conversation.engineSubtitle,
        )
        val checked = model.engineSheetInput(VoiceDirection.Realtime).model.rows
            .single { it.isChecked }.option as VoiceEngineOption.Cloud
        assertEquals("gpt-realtime", checked.model)
        // The system row copy of the other directions is unchanged.
        assertEquals(UiText.Resource(R.string.voice_engine_system), model.engineSheetInput(VoiceDirection.Stt).model.systemTitle)
    }

    @Test
    fun `realtime fallback shows realtime settings notice`() = runTest(dispatcher) {
        cloud(VoiceDirection.Realtime, "gpt-realtime", connectionId = "gone")
        val model = newModel()
        advanceUntilIdle()

        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Realtime))
        val conversation = model.uiState.value.conversation
        assertEquals(UiText.Resource(R.string.voice_realtime_engine_fallback_settings), conversation.fallbackNotice)
        assertEquals(UiText.Resource(R.string.voice_realtime_follow_model), conversation.engineSubtitle)
        assertNull(model.uiState.value.dictation.fallbackNotice)
    }

    @Test
    fun `recognition languages`() = runTest(dispatcher) {
        val model = newModel()
        advanceUntilIdle()

        val rows = model.uiState.value.recognitionLanguages
        assertEquals(17, rows.size)
        assertEquals(null, rows.first().tag)
        assertTrue(rows.first().selected)
        assertEquals(UiText.Resource(R.string.voice_language_automatic), model.uiState.value.dictation.languageValue)

        model.setRecognitionLanguage("ja")
        assertEquals("ja", settings.recognitionLanguage())
        assertEquals(UiText.Dynamic("\u65e5\u672c\u8a9e"), model.uiState.value.dictation.languageValue)
        assertEquals("ja", model.uiState.value.recognitionLanguages.single { it.selected }.tag)

        model.setRecognitionLanguage(null)
        assertNull(settings.recognitionLanguage())
        assertNull(model.uiState.value.recognitionLanguages.single { it.selected }.tag)
    }

    @Test
    fun `cloud voices capitalized`() = runTest(dispatcher) {
        cloud(VoiceDirection.Tts, "tts-1", voice = "nova")
        val model = newModel()
        advanceUntilIdle()

        val readAloud = model.uiState.value.readAloud
        assertEquals("Nova", readAloud.voiceValue)
        assertEquals(listOf("Alloy", "Nova"), readAloud.voices.map { it.label })
        assertEquals("nova", readAloud.voices.single { it.selected }.id)

        model.setVoice("alloy")
        assertEquals("Alloy", model.uiState.value.readAloud.voiceValue)
        assertEquals("alloy", (settings.selection(VoiceDirection.Tts) as VoiceEngineSelection.Cloud).voice)
    }

    @Test
    fun `speed disabled without speedRange`() = runTest(dispatcher) {
        cloud(VoiceDirection.Tts, "gpt-4o-mini-tts")
        val model = newModel()
        advanceUntilIdle()
        assertFalse(model.uiState.value.readAloud.speedEnabled)
        assertEquals(UiText.Resource(R.string.voice_speed_unsupported), model.uiState.value.readAloud.speedFooter)

        cloud(VoiceDirection.Tts, "tts-1")
        model.setSpeed(1.26)
        assertTrue(model.uiState.value.readAloud.speedEnabled)
        assertNull(model.uiState.value.readAloud.speedFooter)
        assertEquals(1.3, model.uiState.value.readAloud.speed, 0.0)

        catalogState.value = null
        advanceUntilIdle()
        assertFalse(model.uiState.value.readAloud.speedEnabled)
    }

    @Test
    fun `settings site pending once`() = runTest(dispatcher) {
        // The call site finds the fallback first: rewrite to system and leave one pending notice for the settings page; the catalog is gone afterwards.
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
        // Each page instance subscribes to the catalog on its own: an earlier instance that was not destroyed must not take the pending notice of a later one.
        val first = newModel(client(MutableStateFlow(null)))
        advanceUntilIdle()
        assertEquals(
            UiText.Resource(R.string.voice_engine_fallback_settings),
            first.uiState.value.dictation.fallbackNotice,
        )
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings))

        val second = newModel(client(MutableStateFlow(null)))
        advanceUntilIdle()
        assertNull(second.uiState.value.dictation.fallbackNotice)

        // The settings page finds the fallback itself: rewrite to system and notify on the spot, and do not notify again on the next visit.
        cloud(VoiceDirection.Tts, "tts-1", connectionId = "gone")
        val third = newModel()
        advanceUntilIdle()
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Tts))
        assertNotNull(third.uiState.value.readAloud.fallbackNotice)
        val fourth = newModel()
        advanceUntilIdle()
        assertNull(fourth.uiState.value.readAloud.fallbackNotice)
    }

    @Test
    fun `tts hint from probe`() = runTest(dispatcher) {
        hintNeeded = true
        val system = newModel()
        system.onEnter(Locale.ENGLISH)
        advanceUntilIdle()
        assertEquals(UiText.Resource(R.string.voice_tts_voice_hint), system.uiState.value.readAloud.ttsHint)

        cloud(VoiceDirection.Tts, "tts-1")
        val cloudModel = newModel()
        cloudModel.onEnter(Locale.ENGLISH)
        advanceUntilIdle()
        assertNull(cloudModel.uiState.value.readAloud.ttsHint)

        settings.setSelection(VoiceDirection.Tts, VoiceEngineSelection.System)
        hintNeeded = false
        val noHint = newModel()
        noHint.onEnter(Locale.ENGLISH)
        advanceUntilIdle()
        assertNull(noHint.uiState.value.readAloud.ttsHint)
    }

    @Test
    fun `tts hint uses ui locale`() = runTest(dispatcher) {
        val previous = Locale.getDefault()
        Locale.setDefault(Locale.US)
        try {
            hintNeeded = true
            val model = newModel()
            advanceUntilIdle()
            assertTrue(probedLocales.isEmpty())
            assertNull(model.uiState.value.readAloud.ttsHint)

            model.onEnter(Locale.JAPANESE)
            advanceUntilIdle()
            assertEquals(listOf(Locale.JAPANESE), probedLocales)
            assertEquals(UiText.Resource(R.string.voice_tts_voice_hint), model.uiState.value.readAloud.ttsHint)

            // Entering again after the UI language changed: re-probe for the new locale; the catalog is not refreshed again.
            hintNeeded = false
            model.onEnter(Locale.GERMAN)
            advanceUntilIdle()
            assertEquals(listOf(Locale.JAPANESE, Locale.GERMAN), probedLocales)
            assertNull(model.uiState.value.readAloud.ttsHint)
            coVerify(exactly = 1) { catalogClient.refresh() }
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun `entering refreshes catalog`() = runTest(dispatcher) {
        val model = newModel()
        advanceUntilIdle()
        coVerify(exactly = 0) { catalogClient.refresh() }

        // Entering force-refreshes (bypassing the 10-minute throttle); repeated calls do not refresh again.
        model.onEnter(Locale.ENGLISH)
        model.onEnter(Locale.ENGLISH)
        advanceUntilIdle()
        coVerify(exactly = 1) { catalogClient.refresh() }
        coVerify(exactly = 0) { catalogClient.ensureFresh() }
    }

    @Test
    fun `engine sheet keeps provider list order`() = runTest(dispatcher) {
        // The repository order is deliberately not the kind alphabetical order, and two connections of one provider are separated by another provider; a connection without a key (unusable) is inserted in between.
        val openAIWork = openAI.copy(id = "conn-openai-work", customName = "Work")
        val groq = Provider(id = "conn-groq", kind = ProviderKind.Groq, apiKey = "gsk-live")
        val openAINoKey = openAI.copy(id = "conn-openai-nokey", apiKey = "")
        val gemini = Provider(id = "conn-gemini", kind = ProviderKind.Gemini, apiKey = "AIza-live")
        val repoOrder = listOf(openAIWork, groq, openAINoKey, gemini, openAI)
        val repository = mockk<ProviderRepository> {
            every { observeAll() } returns MutableStateFlow(repoOrder)
        }
        val multiCatalog = catalog.copy(
            providers = catalog.providers + mapOf(
                ProviderKind.Groq to VoiceProviderCatalog(stt = listOf(sttEntry.copy(model = "whisper-large-v3"))),
                ProviderKind.Gemini to VoiceProviderCatalog(stt = listOf(sttEntry.copy(model = "gemini-stt"))),
            ),
        )
        val state = MutableStateFlow<VoiceCatalogState?>(VoiceCatalogState.Available(multiCatalog))
        val model = VoiceSettingsViewModel(settings, client(state), probe, repository)
        advanceUntilIdle()

        val rows = model.engineSheetInput(VoiceDirection.Stt).model.rows
        assertEquals(VoiceEngineOption.System, rows.first().option)
        val connectionOrder = rows.drop(1).map { (it.option as VoiceEngineOption.Cloud).connectionId }.distinct()
        assertEquals(
            listOf(openAIWork.id, groq.id, gemini.id, openAI.id),
            connectionOrder,
        )
        assertFalse(openAINoKey.id in connectionOrder)
    }
}
