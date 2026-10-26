package ai.oriveo.community.feature.chat.composer

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the dictation wiring of the chat composer: the input row is wrapped in [DictationInputSwitcher],
 * the text shell carries [DictationMicButton], and the selection goes through selectionProbe into
 * rememberComposerLengthLimitedField. This is a source scan because EnhancedComposer is too large to compose
 * as a whole in a unit test. ChatComposerHost attaches the conversation-slot host (HOME_DRAFT_KEY when there is
 * no conversation), the status card sits above the input, and the handle and probe are passed into EnhancedComposer.
 */
class ChatComposerDictationWiringTest {
    private val source: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/composer/EnhancedComposer.kt").readText()
    }

    private val hostSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/composer/ChatComposerHost.kt").readText()
    }

    @Test
    fun `input row is wrapped by the dictation switcher`() {
        assertTrue("The input row is not wrapped in DictationInputSwitcher, so the recording bar would never swap in", source.contains("DictationInputSwitcher("))
    }

    @Test
    fun `text shell shows the mic button only with a dictation handle`() {
        val micAt = source.indexOf("DictationMicButton(")
        assertTrue("The text shell is missing DictationMicButton", micAt >= 0)
        val gateAt = source.lastIndexOf("if (dictation != null)", micAt)
        assertTrue("The mic button must only show when dictation is non-null", gateAt in 0 until micAt)
    }

    @Test
    fun `selection probe reaches the length limited field`() {
        assertTrue("EnhancedComposer is missing the selectionProbe wiring", source.contains("selectionProbe = "))
        assertTrue(
            "selectionProbe must be passed to rememberComposerLengthLimitedField",
            source.contains("rememberComposerLengthLimitedField(text = text, onTextChange = onValueChange, selectionProbe = selectionProbe)"),
        )
    }

    @Test
    fun `chat host binds the conversation slot or the home draft slot`() {
        assertTrue("ChatComposerHost is missing rememberDictationHost", hostSource.contains("rememberDictationHost("))
        assertTrue(
            "The slot key must be conversationId ?: HOME_DRAFT_KEY",
            hostSource.contains("conversationId ?: RecordingStore.HOME_DRAFT_KEY"),
        )
    }

    @Test
    fun `prompt card sits above the composer and the handle reaches EnhancedComposer`() {
        val slotAt = hostSource.indexOf("DictationPromptSlot(")
        assertTrue("ChatComposerHost is missing DictationPromptSlot", slotAt >= 0)
        val composerAt = hostSource.indexOf("EnhancedComposer(", slotAt)
        assertTrue("The status card must sit above the input (before EnhancedComposer)", composerAt > slotAt)
        val call = hostSource.substring(composerAt)
        assertTrue("The handle must be passed into EnhancedComposer", call.contains("dictation = "))
        assertTrue("The probe must be passed into EnhancedComposer", call.contains("selectionProbe = "))
    }
}
