package ai.oriveo.community.core.voice

import java.util.Locale
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SystemTtsVoiceProbeTest {
    private fun voice(
        locale: Locale = Locale.US,
        quality: Int = 300,
        networkRequired: Boolean = false,
        features: Set<String> = emptySet(),
    ) = TtsVoiceInfo(locale = locale, quality = quality, networkRequired = networkRequired, features = features)

    @Test
    fun `no voices no hint`() {
        assertFalse(ttsHintNeeded(emptyList(), Locale.US))
    }

    @Test
    fun `only low quality hints`() {
        assertTrue(ttsHintNeeded(listOf(voice(quality = 200), voice(quality = 100)), Locale.US))
    }

    @Test
    fun `high quality offline no hint`() {
        assertFalse(ttsHintNeeded(listOf(voice(quality = 200), voice(quality = 400)), Locale.US))
    }

    @Test
    fun `network required hints`() {
        assertTrue(ttsHintNeeded(listOf(voice(quality = 500, networkRequired = true), voice(quality = 200)), Locale.US))
    }

    @Test
    fun `not installed ignored`() {
        // The only high-quality offline voice is not installed: only low quality remains after exclusion -> hint
        val voices = listOf(
            voice(quality = 400, features = setOf(TTS_FEATURE_NOT_INSTALLED)),
            voice(quality = 200),
        )
        assertTrue(ttsHintNeeded(voices, Locale.US))
        // All uninstalled: empty after exclusion -> no hint
        assertFalse(ttsHintNeeded(listOf(voice(quality = 200, features = setOf(TTS_FEATURE_NOT_INSTALLED))), Locale.US))
    }

    @Test
    fun `filters by ui language`() {
        // The same language in a different region also counts
        assertFalse(ttsHintNeeded(listOf(voice(locale = Locale.UK, quality = 400)), Locale.US))
        // High-quality voices of other languages do not count
        assertTrue(ttsHintNeeded(listOf(voice(locale = Locale.FRANCE, quality = 400), voice(quality = 200)), Locale.US))
        // No voices for the UI language -> no hint
        assertFalse(ttsHintNeeded(listOf(voice(locale = Locale.FRANCE, quality = 100)), Locale.US))
    }
}
