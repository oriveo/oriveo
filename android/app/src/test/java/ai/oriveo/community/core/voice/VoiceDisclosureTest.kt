package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.testing.TestSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceDisclosureTest {

    private val prefs = TestSharedPreferences()
    private val settings = VoiceEngineSettings(prefsProvider = { prefs })
    private val store = VoiceDisclosureStore(prefsProvider = { prefs })
    private val chooser = VoiceEngineChooser(settings, store)

    private val ttsEntry = VoiceTtsEntry(
        model = "gpt-4o-mini-tts",
        transport = VoiceTransport.OpenAISpeech,
        path = "/v1/audio/speech",
        voices = listOf(VoiceOption("alloy"), VoiceOption("nova", isDefault = true)),
        outputFormat = "mp3",
        maxChars = 4096,
    )
    private val sttEntry = VoiceSttEntry(
        model = "gpt-4o-transcribe",
        transport = VoiceTransport.OpenAITranscriptions,
        path = "/v1/audio/transcriptions",
        maxBytes = 25_000_000,
        maxDurationSec = 600,
    )
    private val realtimeEntry = VoiceRealtimeEntry(
        model = "gpt-realtime-2.1",
        transport = VoiceTransport.OpenAIRealtime,
        path = "/v1/realtime",
        contextWindow = 128_000,
        voices = listOf(VoiceOption("alloy"), VoiceOption("marin", isDefault = true)),
        inputTranscriptionModel = "gpt-4o-mini-transcribe",
    )
    private val catalog = VoiceCatalog(
        providers = mapOf(
            ProviderKind.OpenAI to VoiceProviderCatalog(
                stt = listOf(sttEntry),
                tts = listOf(ttsEntry),
                realtime = listOf(realtimeEntry),
            ),
        ),
    )
    private val sttOption = VoiceEngineOption.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-4o-transcribe", isDefault = true)
    private val ttsOption = VoiceEngineOption.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-4o-mini-tts", isDefault = true)
    private val ttsSelection = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-4o-mini-tts", voice = "nova")

    @Test
    fun `choosing system writes immediately`() {
        settings.setSelection(VoiceDirection.Stt, VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-4o-transcribe"))

        assertEquals(VoiceChoice.Written, chooser.choose(VoiceDirection.Stt, VoiceEngineOption.System, catalog))

        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
    }

    @Test
    fun `cloud not accepted needs disclosure`() {
        val choice = chooser.choose(VoiceDirection.Tts, ttsOption, catalog)

        assertEquals(VoiceChoice.NeedsDisclosure(VoiceDirection.Tts, ttsSelection), choice)
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Tts))
    }

    @Test
    fun `accept records and writes`() {
        val pending = chooser.choose(VoiceDirection.Tts, ttsOption, catalog) as VoiceChoice.NeedsDisclosure

        assertEquals(VoiceChoice.Accepted, chooser.accept(pending))

        assertTrue(store.isAccepted(ProviderKind.OpenAI, VoiceDirection.Tts))
        assertEquals(ttsSelection, settings.selection(VoiceDirection.Tts))
        assertEquals(setOf("openAI/tts"), prefs.getStringSet(VoiceDisclosureStore.KEY_ACCEPTED, null))
        // After consent, choosing the same (providerKind, direction) again writes directly without another disclosure.
        settings.setSelection(VoiceDirection.Tts, VoiceEngineSelection.System)
        assertEquals(VoiceChoice.Written, chooser.choose(VoiceDirection.Tts, ttsOption, catalog))
        assertEquals(ttsSelection, settings.selection(VoiceDirection.Tts))
    }

    @Test
    fun `decline writes nothing`() {
        val pending = chooser.choose(VoiceDirection.Stt, sttOption, catalog) as VoiceChoice.NeedsDisclosure

        assertEquals(VoiceChoice.Declined, chooser.decline(pending))

        assertFalse(store.isAccepted(ProviderKind.OpenAI, VoiceDirection.Stt))
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
    }

    @Test
    fun `realtime accept uses realtime token and entry default voice`() {
        val option = VoiceEngineOption.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-realtime-2.1", isDefault = true)
        store.markAccepted(ProviderKind.OpenAI, VoiceDirection.Tts)
        val pending = chooser.choose(VoiceDirection.Realtime, option, catalog) as VoiceChoice.NeedsDisclosure

        assertEquals(VoiceChoice.Accepted, chooser.accept(pending))

        val selection = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-realtime-2.1", voice = "marin")
        assertEquals(selection, settings.selection(VoiceDirection.Realtime))
        assertEquals(setOf("openAI/tts", "openAI/realtime"), prefs.getStringSet(VoiceDisclosureStore.KEY_ACCEPTED, null))
    }

    @Test
    fun `accepted per kind and direction`() {
        store.markAccepted(ProviderKind.OpenAI, VoiceDirection.Stt)

        assertTrue(store.isAccepted(ProviderKind.OpenAI, VoiceDirection.Stt))
        assertFalse(store.isAccepted(ProviderKind.OpenAI, VoiceDirection.Tts))
        assertFalse(store.isAccepted(ProviderKind.Gemini, VoiceDirection.Stt))

        store.markAccepted(ProviderKind.Gemini, VoiceDirection.Tts)
        val reloaded = VoiceDisclosureStore(prefsProvider = { prefs })
        assertTrue(reloaded.isAccepted(ProviderKind.OpenAI, VoiceDirection.Stt))
        assertTrue(reloaded.isAccepted(ProviderKind.Gemini, VoiceDirection.Tts))
        assertFalse(reloaded.isAccepted(ProviderKind.Gemini, VoiceDirection.Stt))

        assertEquals(VoiceChoice.Written, chooser.choose(VoiceDirection.Stt, sttOption, catalog))
        assertTrue(chooser.choose(VoiceDirection.Tts, ttsOption, catalog) is VoiceChoice.NeedsDisclosure)
    }
}
