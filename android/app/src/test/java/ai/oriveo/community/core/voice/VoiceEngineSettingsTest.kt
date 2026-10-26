package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.testing.TestSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceEngineSettingsTest {

    private val prefs = TestSharedPreferences()
    private val settings = VoiceEngineSettings(prefsProvider = { prefs })

    private val sttCloud = VoiceEngineSelection.Cloud(
        providerKind = ProviderKind.OpenAI,
        connectionId = "conn-openai",
        model = "gpt-4o-transcribe",
    )
    private val ttsCloud = VoiceEngineSelection.Cloud(
        providerKind = ProviderKind.Gemini,
        connectionId = "conn-gemini",
        model = "gemini-2.5-flash-preview-tts",
        voice = "Kore",
    )

    @Test
    fun `defaults to system and automatic language`() {
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Tts))
        assertNull(settings.recognitionLanguage())
    }

    @Test
    fun `both directions and language round trip through a new instance`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)
        settings.setSelection(VoiceDirection.Tts, ttsCloud)
        settings.setRecognitionLanguage("zh-Hans")

        val reloaded = VoiceEngineSettings(prefsProvider = { prefs })
        assertEquals(sttCloud, reloaded.selection(VoiceDirection.Stt))
        assertEquals(ttsCloud, reloaded.selection(VoiceDirection.Tts))
        assertEquals("zh-Hans", reloaded.recognitionLanguage())

        reloaded.setSelection(VoiceDirection.Stt, VoiceEngineSelection.System)
        reloaded.setRecognitionLanguage(null)

        val again = VoiceEngineSettings(prefsProvider = { prefs })
        assertEquals(VoiceEngineSelection.System, again.selection(VoiceDirection.Stt))
        assertEquals(ttsCloud, again.selection(VoiceDirection.Tts))
        assertNull(again.recognitionLanguage())
    }

    @Test
    fun `realtime selection persists under realtime keys`() {
        val realtimeCloud = VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-realtime-2.1", voice = "marin")
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Realtime))

        settings.setSelection(VoiceDirection.Realtime, realtimeCloud)

        assertEquals("cloud", prefs.getString("oriveo.voice.realtime.engine", null))
        assertEquals("openAI", prefs.getString("oriveo.voice.realtime.providerKind", null))
        assertEquals("conn-openai", prefs.getString("oriveo.voice.realtime.connectionId", null))
        assertEquals("gpt-realtime-2.1", prefs.getString("oriveo.voice.realtime.model", null))
        assertEquals("marin", prefs.getString("oriveo.voice.realtime.voice", null))
        assertEquals(realtimeCloud, VoiceEngineSettings(prefsProvider = { prefs }).selection(VoiceDirection.Realtime))
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Tts))

        val fallback = VoiceEngineResolver.resolve(VoiceCatalog(), VoiceDirection.Realtime, realtimeCloud, emptyList())
        assertEquals(VoiceFallbackReason.ConnectionMissing, settings.applyResolution(VoiceDirection.Realtime, fallback, VoiceNoticeSite.Use))
        assertEquals("system", prefs.getString("oriveo.voice.realtime.engine", null))
        assertFalse(prefs.contains("oriveo.voice.realtime.model"))
        assertEquals(
            VoiceFallbackReason.ConnectionMissing,
            settings.takePendingNotice(VoiceDirection.Realtime, VoiceNoticeSite.Settings),
        )
    }

    @Test
    fun `resolution with persist system rewrites stored selection`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)
        settings.setSelection(VoiceDirection.Tts, ttsCloud)
        val resolution = VoiceEngineResolver.resolve(
            catalog = VoiceCatalog(),
            direction = VoiceDirection.Tts,
            selection = settings.selection(VoiceDirection.Tts),
            connections = emptyList(),
        )
        assertEquals(VoiceSelectionPersist.System, resolution.persist)

        settings.applyResolution(VoiceDirection.Tts, resolution, VoiceNoticeSite.Settings)

        val reloaded = VoiceEngineSettings(prefsProvider = { prefs })
        assertEquals(VoiceEngineSelection.System, reloaded.selection(VoiceDirection.Tts))
        assertEquals(sttCloud, reloaded.selection(VoiceDirection.Stt))
    }

    @Test
    fun `resolution with persist keep leaves stored selection`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)

        settings.applyResolution(
            VoiceDirection.Stt,
            VoiceEngineResolution(engine = VoiceEngine.System, reason = null),
            VoiceNoticeSite.Settings,
        )
        settings.applyResolution(
            VoiceDirection.Stt,
            VoiceEngineResolution(
                engine = VoiceEngine.System,
                reason = VoiceFallbackReason.KeyMissing,
                notice = true,
                persist = VoiceSelectionPersist.Keep,
            ),
            VoiceNoticeSite.Settings,
        )

        assertEquals(sttCloud, VoiceEngineSettings(prefsProvider = { prefs }).selection(VoiceDirection.Stt))
    }

    @Test
    fun `speech rate defaults to one`() {
        assertEquals(1.0, settings.speechRate(), 0.0)
        assertFalse(prefs.contains(VoiceEngineSettings.KEY_SPEECH_RATE))
    }

    @Test
    fun `speech rate clamps and rounds to tenth`() {
        settings.setSpeechRate(1.23)
        assertEquals(1.2, VoiceEngineSettings(prefsProvider = { prefs }).speechRate(), 0.0)
        settings.setSpeechRate(1.06)
        assertEquals(1.1, settings.speechRate(), 0.0)
        settings.setSpeechRate(0.1)
        assertEquals(0.5, settings.speechRate(), 0.0)
        settings.setSpeechRate(3.7)
        assertEquals(2.0, settings.speechRate(), 0.0)
        assertTrue(prefs.contains("oriveo.voice.tts.speechRate"))
    }

    // ---- a fallback is announced once at each of the two sites ----

    /** The fallback result the production resolver gives for a deleted connection. */
    private fun sttFallback(): VoiceEngineResolution = VoiceEngineResolver.resolve(
        catalog = VoiceCatalog(),
        direction = VoiceDirection.Stt,
        selection = settings.selection(VoiceDirection.Stt),
        connections = emptyList(),
    )

    private val sttAvailable = VoiceEngineResolution(
        engine = VoiceEngine.Cloud(ProviderKind.OpenAI, "conn-openai", "gpt-4o-transcribe"),
    )

    @Test
    fun `first discovery at use leaves pending for settings`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)

        val shown = settings.applyResolution(VoiceDirection.Stt, sttFallback(), VoiceNoticeSite.Use)

        assertEquals(VoiceFallbackReason.ConnectionMissing, shown)
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
        val reloaded = VoiceEngineSettings(prefsProvider = { prefs })
        assertNull(reloaded.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Use))
        assertNull(reloaded.takePendingNotice(VoiceDirection.Tts, VoiceNoticeSite.Settings))
        assertEquals(
            VoiceFallbackReason.ConnectionMissing,
            reloaded.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings),
        )
    }

    @Test
    fun `first discovery at settings leaves pending for use`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)

        val shown = settings.applyResolution(VoiceDirection.Stt, sttFallback(), VoiceNoticeSite.Settings)

        assertEquals(VoiceFallbackReason.ConnectionMissing, shown)
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings))
        // At the point of use the selection is already system: take the pending notice and show it once, never again.
        val systemResolution = VoiceEngineResolver.resolve(
            catalog = VoiceCatalog(),
            direction = VoiceDirection.Stt,
            selection = settings.selection(VoiceDirection.Stt),
            connections = emptyList(),
        )
        assertEquals(
            VoiceFallbackReason.ConnectionMissing,
            settings.applyResolution(VoiceDirection.Stt, systemResolution, VoiceNoticeSite.Use),
        )
        assertNull(settings.applyResolution(VoiceDirection.Stt, systemResolution, VoiceNoticeSite.Use))
    }

    @Test
    fun `taking pending clears it`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)
        settings.applyResolution(VoiceDirection.Stt, sttFallback(), VoiceNoticeSite.Use)

        assertEquals(
            VoiceFallbackReason.ConnectionMissing,
            settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings),
        )
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings))
        assertNull(
            VoiceEngineSettings(prefsProvider = { prefs })
                .takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings),
        )
    }

    @Test
    fun `sheet selection clears both pending`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)
        settings.applyResolution(VoiceDirection.Stt, sttFallback(), VoiceNoticeSite.Use)
        settings.setSelection(VoiceDirection.Tts, ttsCloud)
        val ttsFallback = VoiceEngineResolver.resolve(
            catalog = VoiceCatalog(),
            direction = VoiceDirection.Tts,
            selection = settings.selection(VoiceDirection.Tts),
            connections = emptyList(),
        )
        settings.applyResolution(VoiceDirection.Tts, ttsFallback, VoiceNoticeSite.Settings)

        // Re-selecting system also counts as a write through the picker.
        settings.setSelection(VoiceDirection.Stt, VoiceEngineSelection.System)

        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings))
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Use))
        assertEquals(
            VoiceFallbackReason.ConnectionMissing,
            settings.takePendingNotice(VoiceDirection.Tts, VoiceNoticeSite.Use),
        )
    }

    @Test
    fun `use site takes pending silently when reselected available`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)
        settings.applyResolution(VoiceDirection.Stt, sttFallback(), VoiceNoticeSite.Settings)

        assertNull(settings.applyResolution(VoiceDirection.Stt, sttAvailable, VoiceNoticeSite.Use))

        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Use))
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Stt))
    }

    @Test
    fun `catalog unavailable leaves no pending`() {
        settings.setSelection(VoiceDirection.Stt, sttCloud)

        assertNull(settings.applyResolution(VoiceDirection.Stt, null, VoiceNoticeSite.Use))
        assertNull(settings.applyResolution(VoiceDirection.Stt, null, VoiceNoticeSite.Settings))

        assertEquals(sttCloud, settings.selection(VoiceDirection.Stt))
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings))
        assertNull(settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Use))

        // Existing pending notices can still be taken.
        settings.applyResolution(VoiceDirection.Stt, sttFallback(), VoiceNoticeSite.Use)
        assertNull(settings.applyResolution(VoiceDirection.Stt, null, VoiceNoticeSite.Settings))
        assertEquals(
            VoiceFallbackReason.ConnectionMissing,
            settings.takePendingNotice(VoiceDirection.Stt, VoiceNoticeSite.Settings),
        )
    }
}
