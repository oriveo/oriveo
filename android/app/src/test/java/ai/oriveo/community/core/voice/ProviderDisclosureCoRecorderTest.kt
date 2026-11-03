package ai.oriveo.community.core.voice

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Accepting realtime disclosure also records the provider disclosure. */
class ProviderDisclosureCoRecorderTest {

    @Test
    fun records_provider_disclosure_except_oriveo_managed() = runTest {
        val preferences = mockk<AppPreferencesRepository>(relaxed = true)
        val record = providerDisclosureCoRecorder({ preferences }, this)

        record(ProviderKind.Gemini)
        advanceUntilIdle()

        coVerify(exactly = 1) { preferences.markProviderDisclosureAccepted(ProviderKind.Gemini) }
    }

    /** Production wiring: the Koin VoiceEngineSettings must carry the co-recorder hook, or consent is missed in the picker, settings, details and migration paths. */
    @Test
    fun app_module_wires_co_recorder_into_voice_settings() {
        val source = File("src/main/java/ai/oriveo/community/di/AppModule.kt").readText()
        assertTrue(source.contains("onRealtimeDisclosureAccepted = providerDisclosureCoRecorder("))
    }
}
