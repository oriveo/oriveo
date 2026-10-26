package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.conversation.VoiceConversationServiceStarter
import ai.oriveo.community.core.voice.conversation.VoiceReplyEvent
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/** Entry order and the home → chat handoff on production classes. */
@OptIn(ExperimentalCoroutinesApi::class)
class VoiceConversationSessionsTest {

    // HandoffPort switches conversation creation and navigation to Main: on a plain JVM Main is the test scheduler, and runTest shares its scheduler.
    @Before
    fun setMainDispatcher() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
    }

    @After
    fun resetMainDispatcher() {
        Dispatchers.resetMain()
    }

    private class FakePort : VoiceConversationChatPort {
        val sent = mutableListOf<String>()
        var cancels = 0
        val flow = MutableSharedFlow<VoiceReplyEvent>(extraBufferCapacity = 8)
        override val replies: Flow<VoiceReplyEvent> = flow
        override suspend fun send(text: String): Boolean {
            sent += text
            return true
        }
        override fun cancel() {
            cancels++
        }
    }

    // ── entry flow order ──

    private fun flow(
        steps: MutableList<String>,
        gate: Boolean = true,
        mic: Boolean = true,
        service: VoiceConversationServiceStarter.Result = VoiceConversationServiceStarter.Result.Started,
    ) = VoiceConversationEntryFlow(
        gate = { steps += "gate"; gate },
        microphone = { steps += "mic"; mic },
        notifications = { steps += "notifications" },
        startService = { steps += "service"; service },
        startConversation = { steps += "start" },
        onMicrophoneDenied = { steps += "micDenied" },
        onStartFailed = { steps += "startFailedToast" },
    )

    @Test
    fun `entry runs send gates, microphone, notifications, service, then the controller`() = runTest(timeout = 10.seconds) {
        val steps = mutableListOf<String>()
        assertTrue(flow(steps).run())
        assertEquals(listOf("gate", "mic", "notifications", "service", "start"), steps)
    }

    @Test
    fun `a blocked send gate stops before the microphone`() = runTest(timeout = 10.seconds) {
        val steps = mutableListOf<String>()
        assertFalse(flow(steps, gate = false).run())
        assertEquals(listOf("gate"), steps)
    }

    @Test
    fun `microphone denial stops before notifications and the service`() = runTest(timeout = 10.seconds) {
        val steps = mutableListOf<String>()
        assertFalse(flow(steps, mic = false).run())
        assertEquals(listOf("gate", "mic", "micDenied"), steps)
    }

    @Test
    fun `a rejected service shows the start failed toast and never starts the controller`() = runTest(timeout = 10.seconds) {
        val steps = mutableListOf<String>()
        assertFalse(flow(steps, service = VoiceConversationServiceStarter.Result.Rejected(SecurityException())).run())
        assertEquals(listOf("gate", "mic", "notifications", "service", "startFailedToast"), steps)
        val quiet = mutableListOf<String>()
        assertFalse(flow(quiet, service = VoiceConversationServiceStarter.Result.NotVisible).run())
        assertEquals("not visible: no toast", listOf("gate", "mic", "notifications", "service"), quiet)
    }

    // ── home handoff ──

    @Test
    fun `home with zero turns leaves no trace`() = runTest(timeout = 10.seconds) {
        val sessions = VoiceConversationSessions()
        var created = 0
        val home = Any()
        val port = sessions.beginHome(home, createConversation = { created++; "c1" }, navigate = {})
        port.cancel()
        assertEquals(0, created)
        assertFalse(sessions.handingOff)
        assertFalse(sessions.ownedBy(home))
    }

    @Test
    fun `first home send creates the conversation, navigates and is sent by the attached chat page`() = runTest(timeout = 10.seconds) {
        val sessions = VoiceConversationSessions()
        val home = Any()
        val chat = Any()
        val navigated = mutableListOf<String>()
        var created = 0
        val port = sessions.beginHome(home, createConversation = { created++; "c1" }, navigate = { navigated += it })
        val replies = mutableListOf<VoiceReplyEvent>()
        backgroundScope.launch { port.replies.collect { replies += it } }

        val send = async { port.send("\u7b2c\u4e8c\u5929\u6362\u6210\u5948\u826f") }
        runCurrent()
        assertEquals(1, created)
        assertEquals(listOf("c1"), navigated)
        assertTrue("home leaving now is the handoff, not an end", sessions.handingOff)

        val page = FakePort()
        assertFalse("another conversation can't take it", sessions.attach("c2", chat) { FakePort() })
        assertTrue(sessions.attach("c1", chat) { page })
        runCurrent()
        assertTrue(send.await())
        assertEquals(listOf("\u7b2c\u4e8c\u5929\u6362\u6210\u5948\u826f"), page.sent)
        assertTrue(sessions.ownedBy(chat))
        assertFalse(sessions.handingOff)

        // Later turns and replies go straight through the chat page's port.
        page.flow.tryEmit(VoiceReplyEvent.Completed())
        runCurrent()
        assertEquals(listOf<VoiceReplyEvent>(VoiceReplyEvent.Completed()), replies)
        port.send("\u518d\u6765\u4e00\u4e2a")
        assertEquals(1, created)
        assertEquals(listOf("\u7b2c\u4e8c\u5929\u6362\u6210\u5948\u826f", "\u518d\u6765\u4e00\u4e2a"), page.sent)
        port.cancel()
        assertEquals(1, page.cancels)
    }

    @Test
    fun home_status_cleared_on_attach() = runTest(timeout = 10.seconds) {
        // Whether the home bar renders the conversation state follows the deterministic handoff event: at the attach tick the home instance's ownedBy turns false, and Compose can observe it.
        val sessions = VoiceConversationSessions()
        val home = Any()
        val chat = Any()
        val port = sessions.beginHome(home, createConversation = { "c1" }, navigate = {})
        val send = async { port.send("x") }
        runCurrent()

        val reads = mutableSetOf<Any>()
        val homeOwned = Snapshot.observe(readObserver = { reads += it }) { sessions.ownedBy(home) }
        assertTrue(homeOwned)
        assertTrue("ownedBy must read snapshot state so the bar recomposes", reads.isNotEmpty())

        val changed = mutableSetOf<Any>()
        val handle = Snapshot.registerApplyObserver { set, _ -> changed.addAll(set) }
        try {
            assertTrue(sessions.attach("c1", chat) { FakePort() })
            assertFalse("home stops owning in the same beat as the attach", sessions.ownedBy(home))
            assertTrue(sessions.ownedBy(chat))
            Snapshot.sendApplyNotifications()
            assertTrue("the attach is a snapshot change the home bar observes", changed.any { it in reads })
        } finally {
            handle.dispose()
        }
        runCurrent()
        assertTrue(send.await())
    }

    @Test
    fun `no usable model or no chat page means the first send fails`() = runTest(timeout = 10.seconds) {
        val sessions = VoiceConversationSessions()
        val noModel = sessions.beginHome(Any(), createConversation = { null }, navigate = {})
        assertFalse(noModel.send("x"))

        val port = sessions.beginHome(Any(), createConversation = { "c1" }, navigate = {})
        val send = async { port.send("x") }
        runCurrent()
        advanceTimeBy(VoiceConversationSessions.HANDOFF_TIMEOUT_MS + 1)
        assertFalse(send.await())
    }

    @Test
    fun `chat entry owns the conversation and nothing can attach to it`() {
        val sessions = VoiceConversationSessions()
        val chat = Any()
        sessions.beginChat(chat)
        assertTrue(sessions.ownedBy(chat))
        assertFalse(sessions.attach("c1", Any()) { FakePort() })
        assertFalse(sessions.handingOff)
    }

    // ── home disclosure gate ──

    private class FakeDisclosure(var required: Boolean) : VoiceEntryDisclosure {
        val accepted = mutableListOf<ai.oriveo.community.core.model.ProviderKind>()
        override suspend fun required(kind: ai.oriveo.community.core.model.ProviderKind) = required
        override suspend fun accept(kind: ai.oriveo.community.core.model.ProviderKind) {
            accepted += kind
            required = false
        }
    }

    private fun homeEntry(steps: MutableList<String>, gate: VoiceDisclosureGate, created: IntArray) =
        VoiceConversationEntryFlow(
            gate = { steps += "gate"; gate.allows(ai.oriveo.community.core.model.ProviderKind.OpenAI) },
            microphone = { steps += "mic"; true },
            notifications = {},
            startService = { VoiceConversationServiceStarter.Result.Started },
            startConversation = {
                steps += "start"
                VoiceConversationSessions().beginHome(Any(), createConversation = { created[0]++; "c1" }, navigate = {})
            },
            onMicrophoneDenied = {},
            onStartFailed = {},
        )

    @Test
    fun `home voice entry shows the disclosure first and starts only after it is accepted`() = runTest(timeout = 10.seconds) {
        val steps = mutableListOf<String>()
        val created = IntArray(1)
        var reentered = 0
        val disclosure = FakeDisclosure(required = true)
        val gate = VoiceDisclosureGate(disclosure, reenter = { reentered++ }, onAcceptFailed = {})
        assertFalse(homeEntry(steps, gate, created).run())
        assertEquals(listOf("gate"), steps)
        assertEquals(ai.oriveo.community.core.model.ProviderKind.OpenAI, gate.prompt?.kind)

        gate.confirm()
        assertEquals(listOf(ai.oriveo.community.core.model.ProviderKind.OpenAI), disclosure.accepted)
        assertEquals(null, gate.prompt)
        assertEquals(1, reentered)
        // The re-entry runs the flow again, now past the gate.
        assertTrue(homeEntry(steps, gate, created).run())
        assertEquals(listOf("gate", "gate", "mic", "start"), steps)
        assertEquals("no conversation before the first transcript", 0, created[0])
    }

    @Test
    fun `declining the home disclosure neither enters nor creates a conversation`() = runTest(timeout = 10.seconds) {
        val steps = mutableListOf<String>()
        val created = IntArray(1)
        var reentered = 0
        val gate = VoiceDisclosureGate(FakeDisclosure(required = true), reenter = { reentered++ }, onAcceptFailed = {})
        assertFalse(homeEntry(steps, gate, created).run())
        gate.cancel()
        assertEquals(null, gate.prompt)
        assertEquals(0, reentered)
        assertEquals(listOf("gate"), steps)
        assertEquals(0, created[0])
    }

    @Test
    fun `a failed acknowledgement keeps the sheet and does not enter`() = runTest(timeout = 10.seconds) {
        val failing = object : VoiceEntryDisclosure {
            override suspend fun required(kind: ai.oriveo.community.core.model.ProviderKind) = true
            override suspend fun accept(kind: ai.oriveo.community.core.model.ProviderKind) = throw IllegalStateException("ack")
        }
        val errors = mutableListOf<Throwable>()
        var reentered = 0
        val gate = VoiceDisclosureGate(failing, reenter = { reentered++ }, onAcceptFailed = { errors += it })
        assertFalse(gate.allows(ai.oriveo.community.core.model.ProviderKind.Anthropic))
        gate.confirm()
        assertEquals(1, errors.size)
        assertEquals(0, reentered)
        assertEquals(ai.oriveo.community.core.model.ProviderKind.Anthropic, gate.prompt?.kind)
    }

    @Test
    fun `no disclosure needed passes straight through`() = runTest(timeout = 10.seconds) {
        val gate = VoiceDisclosureGate(FakeDisclosure(required = false), reenter = {}, onAcceptFailed = {})
        assertTrue(gate.allows(ai.oriveo.community.core.model.ProviderKind.OpenAI))
        assertEquals(null, gate.prompt)
    }

    @Test
    fun host_engine_is_interface_cascade_default() {
        assertTrue(VoiceConversationEngine::class.java.isAssignableFrom(VoiceConversationController::class.java))
        val cascade = object : VoiceConversationEngine {
            override val statusKey = MutableStateFlow<ConversationStatusKey?>(null)
            override val level = MutableStateFlow(0f)
            override val active = MutableStateFlow(false)
            override val events = MutableSharedFlow<VoiceConversationEvent>()
            override fun start(chat: VoiceConversationChatPort) = Unit
            override fun tapOrb() = Unit
            override fun toggleMute() = Unit
            override fun screenReaderSpeaking(speaking: Boolean) = Unit
            override fun end(reason: EndReason) = Unit
        }
        assertSame(cascade, selectVoiceConversationEngine(cascade))
        assertNull(selectVoiceConversationEngine(null))
    }
}
