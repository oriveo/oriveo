package ai.oriveo.community.feature.chat.composer

import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.DictationCatalogSource
import ai.oriveo.community.core.voice.DictationCommands
import ai.oriveo.community.core.voice.DictationController
import ai.oriveo.community.core.voice.DictationEngineFactory
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationEnvironment
import ai.oriveo.community.core.voice.DictationEvent
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.core.voice.PcmSink
import ai.oriveo.community.core.voice.RecordingStore
import ai.oriveo.community.core.voice.STTEngine
import ai.oriveo.community.core.voice.SystemSTTRoute
import ai.oriveo.community.core.voice.SystemSTTSelfRecordSession
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceSttEntry
import ai.oriveo.community.testing.TestSharedPreferences
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
        // Koin not started: the default parameter cannot resolve a controller.
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

        // Navigation: the new page enters composition and binds first, the old page leaves and detaches afterwards.
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

        // After a second host with the same key binds, it becomes the current host and is the only one receiving events.
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

        // Host leaves while recording: restore the pre-entry value.
        composeRule.runOnIdle { view.keepScreenOn = false }
        composeRule.runOnIdle { commands.state.value = DictationState.Recording("conv:1", startedAt = 0L) }
        composeRule.waitForIdle()
        assertTrue(view.keepScreenOn)
        composeRule.runOnIdle { shown = false }
        composeRule.waitForIdle()
        assertFalse(view.keepScreenOn)
    }

    /** Real controller: only bind / detach are used, other dependencies are never called. */
    private fun realController(): DictationController {
        val dispatcher = UnconfinedTestDispatcher()
        return DictationController(
            engines = object : DictationEngineFactory {
                override fun system(): STTEngine = error("unused")

                override suspend fun systemRoute(language: String?): SystemSTTRoute = error("unused")

                override suspend fun startSelfRecord(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
                    error("unused")

                override fun cloud(entry: VoiceSttEntry, baseUrl: String, apiKey: String): STTEngine = error("unused")
            },
            settings = VoiceEngineSettings(prefsProvider = { TestSharedPreferences() }),
            catalog = object : DictationCatalogSource {
                override suspend fun loadCached(): VoiceCatalog? = null

                override suspend fun refresh(): VoiceCatalogState = VoiceCatalogState.LoadFailed
            },
            providers = { emptyList() },
            capture = object : AudioCapture {
                override fun start(sinks: List<PcmSink>) = error("unused")

                override fun stop() = Unit
            },
            store = RecordingStore(File(temp.root, "voice/pending")),
            encoderFactory = { error("unused") },
            permission = { false },
            environment = object : DictationEnvironment {
                override fun stopReadAloud() = Unit

                override fun recognitionLanguage(): String? = null

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
