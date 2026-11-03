package ai.oriveo.community.feature.chat.composer

import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import ai.oriveo.community.R
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.voice.AacEncodedUnit
import ai.oriveo.community.core.voice.AacEncoder
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.DictationCatalogSource
import ai.oriveo.community.core.voice.DictationCommands
import ai.oriveo.community.core.voice.DictationController
import ai.oriveo.community.core.voice.DictationEngineFactory
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationEnvironment
import ai.oriveo.community.core.voice.DictationEvent
import ai.oriveo.community.core.voice.DictationFailedAction
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.core.voice.PcmSink
import ai.oriveo.community.core.voice.RecordingSlotStatus
import ai.oriveo.community.core.voice.RecordingStore
import ai.oriveo.community.core.voice.STTEngine
import ai.oriveo.community.core.voice.STTResult
import ai.oriveo.community.core.voice.STTSegment
import ai.oriveo.community.core.voice.SystemSTTEngine
import ai.oriveo.community.core.voice.SystemSTTRoute
import ai.oriveo.community.core.voice.SystemSTTSelfRecordSession
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceSttEntry
import ai.oriveo.community.testing.TestSharedPreferences
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** rememberDictationHost attaches the coordinator to the host lifecycle: bind / rebind / detach / no controller / event routing. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DictationHostBindingTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val commands = FakeCommands()
    private val actions = FakeActions()
    private val events = MutableSharedFlow<DictationEvent>(extraBufferCapacity = 8)

    @get:Rule
    val temp = TemporaryFolder()

    private var slot by mutableStateOf("conv:1")
    private var shown by mutableStateOf(true)
    private var coordinator: DictationHostCoordinator? = null
    private var hostView: View? = null

    @Test
    fun `entering composition binds the slot`() {
        launchHost()

        assertEquals(listOf("bind:conv:1"), commands.calls)
        assertNotNull(coordinator)
    }

    @Test
    fun `slot change rebinds and rebuilds the coordinator`() {
        launchHost()
        val first = coordinator

        composeRule.runOnIdle { slot = "conv:2" }
        composeRule.waitForIdle()

        assertEquals(listOf("bind:conv:1", "detach:conv:1", "bind:conv:2"), commands.calls)
        assertTrue(first !== coordinator)
    }

    @Test
    fun `leaving composition detaches the slot`() {
        launchHost()

        composeRule.runOnIdle { shown = false }
        composeRule.waitForIdle()

        assertEquals(listOf("bind:conv:1", "detach:conv:1"), commands.calls)
    }

    @Test
    fun `returns null when no controller is available`() {
        var result: DictationHostCoordinator? = DictationHostCoordinator("x", commands, actions)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        // Koin is not started: the default parameter cannot resolve a controller.
        activity.setContent { result = rememberDictationHost(slotKey = "conv:1", actions = actions) }
        composeRule.waitForIdle()

        assertNull(result)
    }

    @Test
    fun `controller events are routed to host actions`() {
        launchHost()

        composeRule.runOnIdle {
            events.tryEmit(DictationEvent.Insert("conv:1", "hello"))
            events.tryEmit(DictationEvent.Insert("conv:2", "elsewhere"))
            events.tryEmit(DictationEvent.Send("conv:1", " world"))
        }
        composeRule.waitForIdle()

        assertEquals(listOf("insert:hello", "insert: world", "send"), actions.calls)
    }

    @Test
    fun `old host disposed after new host on same key keeps new bound`() {
        val controller = realController()
        var showOld by mutableStateOf(true)
        var showNew by mutableStateOf(false)
        var old: DictationHostCoordinator? = null
        var new: DictationHostCoordinator? = null
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            if (showOld) old = rememberDictationHost(slotKey = HOME, actions = actions, commands = controller)
            if (showNew) new = rememberDictationHost(slotKey = HOME, actions = FakeActions(), commands = controller)
        }
        composeRule.waitForIdle()
        assertSame(old!!.owner, controller.boundOwner.value)

        // Navigation: the new page enters composition and binds first; the old page leaves and detaches afterwards.
        composeRule.runOnIdle { showNew = true }
        composeRule.waitForIdle()
        composeRule.runOnIdle { showOld = false }
        composeRule.waitForIdle()

        assertTrue(old!!.owner !== new!!.owner)
        assertSame(new!!.owner, controller.boundOwner.value)
    }

    @Test
    fun `only bound owner collects events`() {
        val otherActions = FakeActions()
        var other: DictationHostCoordinator? = null
        var showOther by mutableStateOf(false)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            coordinator = rememberDictationHost(slotKey = HOME, actions = actions, commands = commands, events = events)
            if (showOther) {
                other = rememberDictationHost(slotKey = HOME, actions = otherActions, commands = commands, events = events)
            }
        }
        composeRule.waitForIdle()

        composeRule.runOnIdle { events.tryEmit(DictationEvent.Insert(HOME, "first")) }
        composeRule.waitForIdle()

        // A second host with the same key binds and becomes the current host; only it receives events.
        composeRule.runOnIdle { showOther = true }
        composeRule.waitForIdle()
        assertSame(other!!.owner, commands.boundOwner.value)
        composeRule.runOnIdle { events.tryEmit(DictationEvent.Insert(HOME, "second")) }
        composeRule.waitForIdle()

        // Switch back to the first host: the collector follows.
        composeRule.runOnIdle { commands.boundOwner.value = coordinator!!.owner }
        composeRule.waitForIdle()
        composeRule.runOnIdle { events.tryEmit(DictationEvent.Insert(HOME, "third")) }
        composeRule.waitForIdle()

        assertEquals(listOf("insert:first", "insert:third"), actions.calls)
        assertEquals(listOf("insert:second"), otherActions.calls)
    }

    @Test
    fun `keeps screen on only while this host records`() {
        launchHost()
        val view = requireNotNull(hostView)
        assertFalse(view.keepScreenOn)

        composeRule.runOnIdle { commands.state.value = DictationState.Recording("conv:1", startedAt = 0L) }
        composeRule.waitForIdle()
        assertTrue(view.keepScreenOn)

        // Another slot is recording: not owned by this host.
        composeRule.runOnIdle { commands.state.value = DictationState.Recording("conv:2", startedAt = 0L) }
        composeRule.waitForIdle()
        assertFalse(view.keepScreenOn)

        // This slot is recording but the current host is a different instance: this host does not hold keep-screen-on.
        composeRule.runOnIdle {
            commands.state.value = DictationState.Recording("conv:1", startedAt = 0L)
            commands.boundOwner.value = Any()
        }
        composeRule.waitForIdle()
        assertFalse(view.keepScreenOn)

        // Transcribing does not count as recording.
        composeRule.runOnIdle {
            commands.boundOwner.value = coordinator!!.owner
            commands.state.value = DictationState.Transcribing("conv:1", DictationSubmit.Insert)
        }
        composeRule.waitForIdle()
        assertFalse(view.keepScreenOn)
    }

    @Test
    fun `restores keep screen on after recording ends or host leaves`() {
        launchHost()
        val view = requireNotNull(hostView)

        composeRule.runOnIdle { commands.state.value = DictationState.Recording("conv:1", startedAt = 0L) }
        composeRule.waitForIdle()
        assertTrue(view.keepScreenOn)

        composeRule.runOnIdle { commands.state.value = DictationState.Idle }
        composeRule.waitForIdle()
        assertFalse(view.keepScreenOn)

        // Already keeping the screen on before entry: restored to on afterwards.
        composeRule.runOnIdle { view.keepScreenOn = true }
        composeRule.runOnIdle { commands.state.value = DictationState.Recording("conv:1", startedAt = 0L) }
        composeRule.waitForIdle()
        composeRule.runOnIdle { commands.state.value = DictationState.Idle }
        composeRule.waitForIdle()
        assertTrue(view.keepScreenOn)

        // The host leaves while recording: restore the pre-entry value.
        composeRule.runOnIdle { view.keepScreenOn = false }
        composeRule.runOnIdle { commands.state.value = DictationState.Recording("conv:1", startedAt = 0L) }
        composeRule.waitForIdle()
        assertTrue(view.keepScreenOn)
        composeRule.runOnIdle { shown = false }
        composeRule.waitForIdle()
        assertFalse(view.keepScreenOn)
    }

    @Test
    fun `change language opens the picker instead of voice settings and switch engine still opens settings`() {
        launchHost()
        val host = requireNotNull(coordinator)

        composeRule.runOnIdle { host.onCardAction(DictationCardAction.ChangeLanguage) }
        assertTrue(host.languagePickerOpen.value)
        assertFalse("openVoiceSettings" in actions.calls)

        // Tapping the mic while the form is open does not start a new dictation.
        composeRule.runOnIdle { host.onMicTap() }
        assertFalse(commands.calls.any { it.startsWith("start:") })

        // Closing without changes: only the form is collapsed, no retry.
        composeRule.runOnIdle { host.closeLanguagePicker(changed = false) }
        assertFalse(host.languagePickerOpen.value)
        assertFalse(commands.calls.any { it.startsWith("transcribeSaved") })

        composeRule.runOnIdle { host.onCardAction(DictationCardAction.SwitchEngine) }
        assertEquals(listOf("openVoiceSettings"), actions.calls)
    }

    @Test
    fun `picking a new language retries the kept recording with the new language`() {
        val prefs = TestSharedPreferences()
        val settings = VoiceEngineSettings { prefs }
        settings.setRecognitionLanguage(LanguageOption.Japanese.localeTag)
        val engine = LanguageRecordingEngine(STTResult.Success(" "), STTResult.Success("bonjour"))
        val activity = showFailedNoTranscriptCard(engine, settings)

        composeRule.onNodeWithText(activity.getString(R.string.voice_dictation_action_change_language)).performClick()
        composeRule.waitForIdle()
        assertFalse("openVoiceSettings" in actions.calls)
        composeRule.onNodeWithText(activity.getString(R.string.voice_recognition_language)).assertExists()

        composeRule.onNodeWithText(LanguageOption.French.displayName).performScrollTo().performClick()
        composeRule.waitForIdle()

        assertEquals(listOf(LanguageOption.Japanese.localeTag, LanguageOption.French.localeTag), engine.languages)
        assertEquals(listOf("insert:bonjour"), actions.calls)
        assertEquals(DictationState.Idle, controllerUnderTest!!.state.value)
        assertFalse(coordinator!!.languagePickerOpen.value)
        activity.finish()
    }

    @Test
    fun `closing the picker without a change keeps the failed card`() {
        val prefs = TestSharedPreferences()
        val settings = VoiceEngineSettings { prefs }
        settings.setRecognitionLanguage(LanguageOption.Japanese.localeTag)
        val engine = LanguageRecordingEngine(STTResult.Success(" "))
        val activity = showFailedNoTranscriptCard(engine, settings)

        composeRule.onNodeWithText(activity.getString(R.string.voice_dictation_action_change_language)).performClick()
        composeRule.waitForIdle()
        // Tapping the already-selected language = no change.
        composeRule.onNodeWithText(LanguageOption.Japanese.displayName).performScrollTo().performClick()
        composeRule.waitForIdle()

        assertEquals(listOf(LanguageOption.Japanese.localeTag), engine.languages)
        assertTrue(controllerUnderTest!!.state.value is DictationState.Failed)
        assertFalse(coordinator!!.languagePickerOpen.value)
        composeRule.onNodeWithText(activity.getString(R.string.voice_dictation_action_change_language)).assertExists()
        assertTrue(actions.calls.isEmpty())
        activity.finish()
    }

    private var controllerUnderTest: DictationController? = null

    /** Leave an interrupted recording whose transcription yields empty text: this slot's failure card "No speech heard" (with "Change recognition language"). */
    private fun showFailedNoTranscriptCard(engine: LanguageRecordingEngine, settings: VoiceEngineSettings): ComponentActivity {
        val store = RecordingStore(File(temp.root, "voice/pending"))
        val seeded = store.open(HOME, SystemSTTEngine.ENGINE_NAME, FakeEncoder())
        seeded.write(ShortArray(16_000) { if (it % 2 == 0) 3000 else -3000 })
        seeded.finish(RecordingSlotStatus.Interrupted)
        val controller = realController(system = engine, settings = settings, store = store)
        controllerUnderTest = controller
        RuntimeEnvironment.setQualifiers("+en")
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                val handle = rememberDictationHost(slotKey = HOME, actions = actions, commands = controller)
                coordinator = handle
                DictationPromptSlot(handle = handle, languageSettings = settings)
            }
        }
        composeRule.waitForIdle()
        assertEquals(DictationState.Interrupted(HOME), controller.state.value)
        composeRule.runOnIdle { controller.transcribeSaved(DictationSubmit.Insert) }
        composeRule.waitForIdle()
        val failed = controller.state.value as DictationState.Failed
        assertEquals(DictationFailedAction.NoTranscript, failed.action)
        assertTrue(failed.hasRecording)
        return activity
    }

    /** Fake system engine: returns [results] in order and records the language each request carried. */
    private class LanguageRecordingEngine(vararg results: STTResult) : STTEngine {
        override val engineName: String = SystemSTTEngine.ENGINE_NAME
        private val queued = ArrayDeque(results.toList())
        val languages = mutableListOf<String?>()

        override suspend fun transcribe(segment: STTSegment, language: String?): STTResult {
            languages += language
            return queued.removeFirst()
        }
    }

    /** One AU per 1024 samples. */
    private class FakeEncoder : AacEncoder {
        private var pending = 0
        override val encoderDelay: Int? = 2112

        override fun encode(samples: ShortArray, count: Int): List<AacEncodedUnit> {
            pending += count
            val out = mutableListOf<AacEncodedUnit>()
            while (pending >= 1024) {
                pending -= 1024
                out += AacEncodedUnit(ByteArray(16) { it.toByte() }, isCodecConfig = false)
            }
            return out
        }

        override fun finish(): List<AacEncodedUnit> {
            if (pending == 0) return emptyList()
            pending = 0
            return listOf(AacEncodedUnit(ByteArray(16) { it.toByte() }, isCodecConfig = false))
        }

        override fun release() = Unit
    }

    /** Real controller: only bind / detach are used by default; when [system] is given, transcription goes through it and the recognition language is read from [settings]. */
    private fun realController(
        system: STTEngine? = null,
        settings: VoiceEngineSettings = VoiceEngineSettings(prefsProvider = { TestSharedPreferences() }),
        store: RecordingStore = RecordingStore(File(temp.root, "voice/pending")),
    ): DictationController {
        val dispatcher = UnconfinedTestDispatcher()
        return DictationController(
            engines = object : DictationEngineFactory {
                override fun system(): STTEngine = system ?: error("unused")

                override suspend fun systemRoute(language: String?): SystemSTTRoute = error("unused")

                override suspend fun startSelfRecord(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
                    error("unused")

                override fun cloud(entry: VoiceSttEntry, baseUrl: String, apiKey: String): STTEngine = error("unused")
            },
            settings = settings,
            catalog = object : DictationCatalogSource {
                override suspend fun loadCached(): VoiceCatalog? = null

                override suspend fun refresh(): VoiceCatalogState = VoiceCatalogState.LoadFailed
            },
            providers = { emptyList() },
            capture = object : AudioCapture {
                override fun start(sinks: List<PcmSink>) = error("unused")

                override fun stop() = Unit
            },
            store = store,
            encoderFactory = { error("unused") },
            permission = { false },
            environment = object : DictationEnvironment {
                override fun stopReadAloud() = Unit

                override fun recognitionLanguage(): String? = settings.recognitionLanguage()

                override fun uiLanguageTag(): String = "en-US"

                override fun observeInterruptions(onInterrupted: () -> Unit): AutoCloseable = AutoCloseable {}
            },
            scope = CoroutineScope(dispatcher),
            io = dispatcher,
        )
    }

    private fun launchHost() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            hostView = LocalView.current
            if (shown) {
                coordinator = rememberDictationHost(
                    slotKey = slot,
                    actions = actions,
                    commands = commands,
                    events = events,
                )
            }
        }
        composeRule.waitForIdle()
    }

    private class FakeCommands : DictationCommands {
        val calls = mutableListOf<String>()
        override val state = MutableStateFlow<DictationState>(DictationState.Idle)
        override val engineInfo = MutableStateFlow<DictationEngineInfo?>(null)
        override val pendingDurationSec = MutableStateFlow<Double?>(null)
        override val levelMeter = MutableStateFlow<List<Float>>(emptyList())
        override val boundOwner = MutableStateFlow<Any?>(null)

        override fun start(slotKey: String) {
            calls += "start:$slotKey"
        }

        override fun finish(submit: DictationSubmit) {
            calls += "finish:$submit"
        }

        override fun discard() {
            calls += "discard"
        }

        override fun transcribeSaved(submit: DictationSubmit) {
            calls += "transcribeSaved:$submit"
        }

        override fun discardAndRestart() {
            calls += "discardAndRestart"
        }

        override fun dismissDenied() {
            calls += "dismissDenied"
        }

        override fun undoDiscard(slotKey: String): Boolean {
            calls += "undoDiscard:$slotKey"
            return true
        }

        override fun bind(slotKey: String, owner: Any) {
            calls += "bind:$slotKey"
            boundOwner.value = owner
        }

        override fun detach(slotKey: String, owner: Any) {
            calls += "detach:$slotKey"
            if (boundOwner.value === owner) boundOwner.value = null
        }
    }

    private companion object {
        const val HOME = "draft:home"
    }

    private class FakeActions : DictationHostActions {
        val calls = mutableListOf<String>()

        override fun insert(text: String) {
            calls += "insert:$text"
        }

        override fun canSend(): Boolean = true

        override fun send() {
            calls += "send"
        }

        override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) {
            calls += "toast"
        }

        override fun openAppSettings() {
            calls += "openAppSettings"
        }

        override fun openProviderDetail(providerId: String) {
            calls += "openProviderDetail:$providerId"
        }

        override fun openProviderSetup() {
            calls += "openProviderSetup"
        }

        override fun openVoiceSettings() {
            calls += "openVoiceSettings"
        }
    }
}
