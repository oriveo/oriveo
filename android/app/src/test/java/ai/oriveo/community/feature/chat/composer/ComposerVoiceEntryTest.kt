package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Main button mode, image-only judgement and the 500 ms re-arm guard, on production code. */
class ComposerVoiceEntryTest {

    private fun model(id: String, vararg capabilities: ModelCapability) =
        AIModel(id = id, name = id, capabilities = capabilities.toList())

    @Test
    fun `mode is stop while generating, send with content, voice on an empty draft`() {
        assertEquals(ComposerActionMode.Stop, ComposerVoiceEntry.mode(isGenerating = true, hasContent = true, voiceAvailable = true))
        assertEquals(ComposerActionMode.Send, ComposerVoiceEntry.mode(isGenerating = false, hasContent = true, voiceAvailable = true))
        assertEquals(ComposerActionMode.Voice, ComposerVoiceEntry.mode(isGenerating = false, hasContent = false, voiceAvailable = true))
        assertEquals(ComposerActionMode.Idle, ComposerVoiceEntry.mode(isGenerating = false, hasContent = false, voiceAvailable = false))
    }

    @Test
    fun home_empty_draft_send_and_voice() {
        assertEquals(
            HomeComposerActions(sendEnabled = true, showsVoice = true),
            ComposerVoiceEntry.home(isSending = false, hasContent = false, voiceAvailable = true),
        )
    }

    @Test
    fun home_text_send_only() {
        assertEquals(
            HomeComposerActions(sendEnabled = true, showsVoice = false),
            ComposerVoiceEntry.home(isSending = false, hasContent = true, voiceAvailable = true),
        )
    }

    @Test
    fun home_voice_unavailable_hides_voice() {
        assertEquals(
            HomeComposerActions(sendEnabled = true, showsVoice = false),
            ComposerVoiceEntry.home(isSending = false, hasContent = false, voiceAvailable = false),
        )
    }

    @Test
    fun home_image_only_hides_voice() {
        val imageOnly = model("gpt-image-1", ModelCapability.ImageGen)
        val actions = ComposerVoiceEntry.home(
            isSending = false,
            hasContent = false,
            voiceAvailable = ComposerVoiceEntry.voiceAvailable(imageOnly, ProviderKind.OpenAI),
        )
        assertFalse(actions.showsVoice)
        assertTrue(actions.sendEnabled)
    }

    @Test
    fun home_sending_disables_both() {
        assertEquals(
            HomeComposerActions(sendEnabled = false, showsVoice = false),
            ComposerVoiceEntry.home(isSending = true, hasContent = false, voiceAvailable = true),
        )
    }

    @Test
    fun `image only covers dedicated image ids and dedicated image routes`() {
        assertTrue(ComposerVoiceEntry.isImageOnly(model("gpt-image-1", ModelCapability.Text), imageGenRoute = null))
        assertTrue(ComposerVoiceEntry.isImageOnly(model("chatgpt-image-latest"), imageGenRoute = null))
        for (route in listOf("images_api", "dashscope_multimodal", "minimax_image_generation")) {
            assertTrue(route, ComposerVoiceEntry.isImageOnly(model("m", ModelCapability.Text, ModelCapability.ImageGen), route))
        }
    }

    @Test
    fun `image only third branch - image generation without text in the metadata`() {
        assertTrue(ComposerVoiceEntry.isImageOnly(model("flux-pro", ModelCapability.ImageGen), imageGenRoute = null))
        assertTrue(ComposerVoiceEntry.isImageOnly(model("flux-pro", ModelCapability.ImageGen, ModelCapability.Image), null))
        // Text next to image generation answers in text: keeps the voice entry.
        assertFalse(ComposerVoiceEntry.isImageOnly(model("m", ModelCapability.Text, ModelCapability.ImageGen), null))
        // Unknown (empty) capabilities are not image only.
        assertFalse(ComposerVoiceEntry.isImageOnly(model("m"), null))
    }

    @Test
    fun `text models keep voice, including chat_api image models`() {
        assertFalse(ComposerVoiceEntry.isImageOnly(model("gpt-4o", ModelCapability.Text), imageGenRoute = null))
        assertFalse(ComposerVoiceEntry.isImageOnly(model("unknown"), imageGenRoute = null))
        assertFalse(
            ComposerVoiceEntry.isImageOnly(
                model("gemini-2.5-flash-image", ModelCapability.Text, ModelCapability.ImageGen),
                imageGenRoute = "chat_api",
            ),
        )
        assertFalse(ComposerVoiceEntry.voiceAvailable(null, null))
    }

    @Test
    fun `re-arm guard ignores taps for 500 ms after generation stops`() {
        var now = 1_000L
        val guard = VoiceEntryRearmGuard { now }
        guard.observe(isGenerating = false)
        assertTrue("never generated: no guard", guard.accepts())

        guard.observe(isGenerating = true)
        now = 5_000L
        guard.observe(isGenerating = false)
        now = 5_499L
        assertFalse(guard.accepts())
        now = 5_500L
        assertTrue(guard.accepts())
        // Recomposing while idle does not restart the window.
        guard.observe(isGenerating = false)
        assertTrue(guard.accepts())
    }
}
