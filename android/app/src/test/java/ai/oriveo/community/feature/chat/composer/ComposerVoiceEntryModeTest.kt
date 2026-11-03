package ai.oriveo.community.feature.chat.composer

import org.junit.Assert.assertEquals
import org.junit.Test

/** While waiting for the voice catalog, the primary key turns into a loading state that overrides ↑ / ≋ / back-to-voice-stage, but not ■. */
class ComposerVoiceEntryModeTest {

    @Test
    fun loading_wins_over_send_and_voice_but_not_stop() {
        assertEquals(
            ComposerActionMode.Loading,
            ComposerVoiceEntry.mode(isGenerating = false, hasContent = true, voiceAvailable = true, awaitingCatalog = true),
        )
        assertEquals(
            ComposerActionMode.Loading,
            ComposerVoiceEntry.mode(isGenerating = false, hasContent = false, voiceAvailable = true, awaitingCatalog = true),
        )
        assertEquals(
            ComposerActionMode.Loading,
            ComposerVoiceEntry.mode(
                isGenerating = false,
                hasContent = false,
                voiceAvailable = true,
                backToStage = true,
                awaitingCatalog = true,
            ),
        )
        assertEquals(
            ComposerActionMode.Loading,
            ComposerVoiceEntry.mode(isGenerating = false, hasContent = false, voiceAvailable = false, awaitingCatalog = true),
        )
        assertEquals(
            ComposerActionMode.Stop,
            ComposerVoiceEntry.mode(isGenerating = true, hasContent = true, voiceAvailable = true, awaitingCatalog = true),
        )
        // Catalog arrives (awaitingCatalog back to false): the original mode is restored
        assertEquals(
            ComposerActionMode.Send,
            ComposerVoiceEntry.mode(isGenerating = false, hasContent = true, voiceAvailable = true, awaitingCatalog = false),
        )
        assertEquals(
            ComposerActionMode.Voice,
            ComposerVoiceEntry.mode(isGenerating = false, hasContent = false, voiceAvailable = true),
        )
    }
}
