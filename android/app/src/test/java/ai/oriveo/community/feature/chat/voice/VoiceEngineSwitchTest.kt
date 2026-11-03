package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelExecutionLocality
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceTelemetry
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Switching the responder during an active voice session: the old session ends only when the engine changes, then the entry path runs again. */
class VoiceEngineSwitchTest {
    /** Fake engine that records end calls; active becomes false after end. */
    private class FakeEngine(active: Boolean) : VoiceConversationEngine {
        override val statusKey = MutableStateFlow<ConversationStatusKey?>(null)
        override val level = MutableStateFlow(0f)
        override val active = MutableStateFlow(active)
        override val events = MutableSharedFlow<VoiceConversationEvent>()
        val ends = mutableListOf<Pair<EndReason, VoiceTelemetry.ConversationEndReason?>>()
        override fun start(chat: VoiceConversationChatPort, entry: VoiceTelemetry.ConversationEntry) {
            active.value = true
        }
        override fun tapOrb() = Unit
        override fun toggleMute() = Unit
        override fun screenReaderSpeaking(speaking: Boolean) = Unit
        override fun end(reason: EndReason, telemetryReason: VoiceTelemetry.ConversationEndReason?) {
            ends += reason to telemetryReason
            active.value = false
        }
    }

    private val openAi = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-realtime").voiceEngineKey()
    private val gemini = VoiceEngineSelection.Cloud(ProviderKind.Gemini, "conn-gemini", "gemini-live").voiceEngineKey()

    /** Runs switchVoiceEngine and returns (whether it switched, number of re-entries). */
    private suspend fun switch(
        engine: FakeEngine,
        from: VoiceEngineKey?,
        to: VoiceEngineKey?,
        capturing: Boolean = true,
    ): Pair<Boolean, Int> {
        var reentered = 0
        val switched = switchVoiceEngine(engine, from, to, capturing) { reentered++ }
        return switched to reentered
    }

    private fun FakeEngine.assertEndedOnceByUser() {
        assertEquals(listOf(EndReason.USER to VoiceTelemetry.ConversationEndReason.User), ends)
        assertFalse(active.value)
    }

    @Test
    fun text_to_realtime_while_active_switches() = runTest {
        assertTrue(shouldSwitchEngine(null, openAi, active = true))
        val engine = FakeEngine(active = true)
        assertEquals(true to 1, switch(engine, null, openAi))
        engine.assertEndedOnceByUser()
    }

    @Test
    fun realtime_to_text_while_active_switches() = runTest {
        assertTrue(shouldSwitchEngine(openAi, null, active = true))
        val engine = FakeEngine(active = true)
        assertEquals(true to 1, switch(engine, openAi, null))
        engine.assertEndedOnceByUser()
    }

    @Test
    fun realtime_to_other_realtime_switches() = runTest {
        assertTrue(shouldSwitchEngine(openAi, gemini, active = true))
        // Switching to another realtime model on the same connection also counts as an engine switch.
        val otherModel = VoiceEngineKey("conn-openai", "gpt-realtime-mini")
        assertTrue(shouldSwitchEngine(openAi, otherModel, active = true))
        val engine = FakeEngine(active = true)
        assertEquals(true to 1, switch(engine, openAi, gemini))
        engine.assertEndedOnceByUser()
    }

    @Test
    fun text_to_text_keeps_session() = runTest {
        // Switching between text models: both engines are cascaded (key is null), so the session stays.
        assertFalse(shouldSwitchEngine(null, null, active = true))
        val engine = FakeEngine(active = true)
        assertEquals(false to 0, switch(engine, null, null))
        assertTrue(engine.ends.isEmpty())
        assertTrue(engine.active.value)
    }

    @Test
    fun idle_change_never_starts() = runTest {
        assertFalse(shouldSwitchEngine(null, openAi, active = false))
        assertFalse(shouldSwitchEngine(openAi, null, active = false))
        assertFalse(shouldSwitchEngine(openAi, gemini, active = false))
        val engine = FakeEngine(active = false)
        assertEquals(false to 0, switch(engine, null, openAi))
        assertTrue(engine.ends.isEmpty())
        assertFalse(engine.active.value)
    }

    @Test
    fun same_key_no_switch() = runTest {
        val again = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-realtime", voice = "cedar")
            .voiceEngineKey()
        // A different voice is not an engine switch.
        assertEquals(openAi, again)
        assertFalse(shouldSwitchEngine(openAi, again, active = true))
        val engine = FakeEngine(active = true)
        assertEquals(false to 0, switch(engine, openAi, again))
        assertTrue(engine.ends.isEmpty())
    }

    /** A typed-only playback session switches responder: only the old session ends, with no re-entry and no mic opened; the next typed message opens a connection with the new model. */
    @Test
    fun typed_only_session_switch_ends_without_reenter() = runTest {
        val engine = FakeEngine(active = true)
        assertEquals(true to 0, switch(engine, openAi, gemini, capturing = false))
        engine.assertEndedOnceByUser()
        // Realtime to text works the same way.
        val toText = FakeEngine(active = true)
        assertEquals(true to 0, switch(toText, openAi, null, capturing = false))
        toText.assertEndedOnceByUser()
    }

    /** Model name in the switch-responder hint: both directions use the page's display name; realtime to text uses the text model's name. */
    @Test
    fun switching_to_names_the_new_model_both_ways() {
        val toText = VoiceConversationTarget.Chat(
            conversationId = "c1",
            context = { error("not planned") },
            modelName = "GPT-5",
            port = { error("not started") },
        )
        assertEquals("GPT-5", voiceEngineSwitchName(toText))
        val toRealtime = VoiceConversationTarget.Home(
            createConversation = { null },
            navigate = {},
            realtimeSelection = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-realtime"),
            modelName = "GPT Realtime",
        )
        assertEquals("GPT Realtime", voiceEngineSwitchName(toRealtime))
        // No display name from the page: falls back to the realtime model id.
        val bare = VoiceConversationTarget.Home(
            createConversation = { null },
            navigate = {},
            realtimeSelection = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-realtime"),
        )
        assertEquals("gpt-realtime", voiceEngineSwitchName(bare))
    }

    /** The chat page passes only the short model name to the voice target: a cloud-proxied text model does not carry the "via Ollama cloud" suffix. */
    @Test
    fun switch_name_is_short_model_name() {
        val proxied = AIModel(
            id = "gpt-oss:120b-cloud",
            name = "gpt-oss 120B",
            executionLocality = ModelExecutionLocality.ProxiedCloud,
        )
        assertEquals("gpt-oss 120B", voiceSwitchModelName(proxied, "gpt-oss:120b-cloud"))
        // Model object not yet available: falls back to the model id selected on the page.
        assertEquals("gpt-oss:120b-cloud", voiceSwitchModelName(null, "gpt-oss:120b-cloud"))
        // Realtime model: the model name from the catalog.
        val realtime = AIModel(id = "gpt-realtime", name = "GPT Realtime")
        assertEquals("GPT Realtime", voiceSwitchModelName(realtime, "gpt-realtime"))
        // Still the short name once handed to the hint.
        val target = VoiceConversationTarget.Chat(
            conversationId = "c1",
            context = { error("not planned") },
            modelName = voiceSwitchModelName(proxied, proxied.id),
            port = { error("not started") },
        )
        assertEquals("gpt-oss 120B", voiceEngineSwitchName(target))
    }
}
